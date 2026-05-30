"""
Faithful MLX forward of USEF-TFGridNet (USEF-TSE, arXiv 2409.02615) at the released
8 kHz checkpoint config, for RTF / latency measurement on Apple Silicon.

Weights are RANDOM (timing depends on architecture/shapes, not weight values). Shapes,
sequence lengths, attention sizes and the sequential BLSTMs match the reference repo
(ZBang/USEF-TSE: models/model_USEF_TFGridNet.py + models/local/TFgridnet.py).

Config (chkpt/USEF-TFGridNet/config.yaml):
  sample_rate 8000 | STFT n_fft 128, hop 64, win 128 (hann) -> 65 freqs
  emb_dim D=128 (conv out) -> blocks run on 2D=256 channels
  hidden_channels H=256 (BLSTM) | num_layers B=6 | n_head 4 | approx_qk_dim 512 (E=ceil(512/65)=8)
  emb_ks=emb_hs=1 (unfold collapses to Linear)
"""
import math
import time
import mlx.core as mx
import mlx.nn as nn
from mlx.utils import tree_flatten

SR = 8000
N_FFT = 128
HOP = 64
WIN = 128
N_FREQS = N_FFT // 2 + 1           # 65
D = 128                            # conv embedding dim
C = 2 * D                          # 256 channels inside blocks
H = 256                            # BLSTM hidden
B_LAYERS = 6
N_HEAD = 4
APPROX_QK = 512
E = math.ceil(APPROX_QK / N_FREQS)  # 8


def hann(n):
    k = mx.arange(n)
    return 0.5 - 0.5 * mx.cos(2 * math.pi * k / n)


# Precompute rfft DFT matrices [WIN, N_FREQS]
_n = mx.arange(WIN).reshape(WIN, 1)
_k = mx.arange(N_FREQS).reshape(1, N_FREQS)
_ang = -2 * math.pi * _n * _k / N_FFT
DFT_R = mx.cos(_ang)               # [128,65]
DFT_I = mx.sin(_ang)
WINDOW = hann(WIN)


def stft_ri(x):
    """x: [B, L] -> real, imag each [B, T, 65] (center-padded)."""
    Bsz, L = x.shape
    pad = WIN // 2
    xp = mx.concatenate([mx.zeros((Bsz, pad)), x, mx.zeros((Bsz, pad))], axis=1)
    Lp = xp.shape[1]
    T = 1 + (Lp - WIN) // HOP
    idx = (mx.arange(T).reshape(T, 1) * HOP) + mx.arange(WIN).reshape(1, WIN)  # [T,WIN]
    frames = xp[:, idx]                       # [B, T, WIN]
    frames = frames * WINDOW.reshape(1, 1, WIN)
    real = frames @ DFT_R                     # [B,T,65]
    imag = frames @ DFT_I
    return real, imag, T


def istft_ri(real, imag, length):
    """real, imag: [B,T,65] -> [B, length]. Representative inverse (cost is minor)."""
    Bsz, T, _ = real.shape
    # inverse rfft via matmul back to time frames [B,T,WIN]
    frames = (real @ DFT_R.T + imag @ DFT_I.T) / N_FFT
    frames = frames * WINDOW.reshape(1, 1, WIN)
    pad = WIN // 2
    Lp = (T - 1) * HOP + WIN
    out = mx.zeros((Bsz, Lp))
    # overlap-add
    for t in range(T):
        out[:, t * HOP : t * HOP + WIN] = out[:, t * HOP : t * HOP + WIN] + frames[:, t]
    return out[:, pad : pad + length]


def all_head_prelu_ln(x, prelu_w, gamma, beta, Hh, Ee, eps=1e-5):
    """x: [B, Hh*Ee, T, Q] -> [B, Hh, Ee, T, Q] with per-head PReLU then LN over (Ee,Q)."""
    Bsz, _, T, Qn = x.shape
    x = x.reshape(Bsz, Hh, Ee, T, Qn)
    # PReLU per head (prelu_w: [Hh])
    pw = prelu_w.reshape(1, Hh, 1, 1, 1)
    x = mx.where(x >= 0, x, pw * x)
    mu = x.mean(axis=(2, 4), keepdims=True)
    var = ((x - mu) ** 2).mean(axis=(2, 4), keepdims=True)
    x = (x - mu) / mx.sqrt(var + eps) * gamma + beta
    return x


def ln4dcf(x, gamma, beta, eps=1e-5):
    """x: [B,C,T,Q] LN over (C,Q)."""
    mu = x.mean(axis=(1, 3), keepdims=True)
    var = ((x - mu) ** 2).mean(axis=(1, 3), keepdims=True)
    return (x - mu) / mx.sqrt(var + eps) * gamma + beta


class CrossAttn(nn.Module):
    """TF_gridnet_attentionblock: Q from `batch`, K/V from `aux`. emb_dim=ed."""
    def __init__(self, ed):
        super().__init__()
        self.ed = ed
        self.q = nn.Conv2d(ed, N_HEAD * E, 1)
        self.k = nn.Conv2d(ed, N_HEAD * E, 1)
        self.v = nn.Conv2d(ed, N_HEAD * (ed // N_HEAD), 1)
        self.qg = mx.ones((1, N_HEAD, E, 1, N_FREQS)); self.qb = mx.zeros((1, N_HEAD, E, 1, N_FREQS)); self.qp = mx.full((N_HEAD,), 0.25)
        self.kg = mx.ones((1, N_HEAD, E, 1, N_FREQS)); self.kb = mx.zeros((1, N_HEAD, E, 1, N_FREQS)); self.kp = mx.full((N_HEAD,), 0.25)
        vd = ed // N_HEAD
        self.vg = mx.ones((1, N_HEAD, vd, 1, N_FREQS)); self.vb = mx.zeros((1, N_HEAD, vd, 1, N_FREQS)); self.vp = mx.full((N_HEAD,), 0.25)
        self.proj = nn.Conv2d(ed, ed, 1)
        self.proj_prelu = nn.PReLU()
        self.pg = mx.ones((1, ed, 1, N_FREQS)); self.pb = mx.zeros((1, ed, 1, N_FREQS))

    def _conv_nhwc(self, conv, x_nchw):
        # x_nchw [B,C,T,Q] -> NHWC [B,T,Q,C] -> conv -> back [B,Cout,T,Q]
        y = conv(x_nchw.transpose(0, 2, 3, 1))
        return y.transpose(0, 3, 1, 2)

    def __call__(self, batch, aux):
        Bsz = batch.shape[0]
        Tq = batch.shape[2]; Ta = aux.shape[2]
        Q = all_head_prelu_ln(self._conv_nhwc(self.q, batch), self.qp, self.qg, self.qb, N_HEAD, E)
        K = all_head_prelu_ln(self._conv_nhwc(self.k, aux), self.kp, self.kg, self.kb, N_HEAD, E)
        vd = self.ed // N_HEAD
        V = all_head_prelu_ln(self._conv_nhwc(self.v, aux), self.vp, self.vg, self.vb, N_HEAD, vd)
        # Q [B,Hh,E,Tq,Q] -> [B*Hh, Tq, E*Q]
        Q = Q.reshape(Bsz * N_HEAD, E, Tq, N_FREQS).transpose(0, 2, 1, 3).reshape(Bsz * N_HEAD, Tq, E * N_FREQS)
        K = K.reshape(Bsz * N_HEAD, E, Ta, N_FREQS).transpose(0, 1, 3, 2).reshape(Bsz * N_HEAD, E * N_FREQS, Ta)
        V = V.reshape(Bsz * N_HEAD, vd, Ta, N_FREQS).transpose(0, 2, 1, 3).reshape(Bsz * N_HEAD, Ta, vd * N_FREQS)
        scale = (E * N_FREQS) ** 0.5
        attn = mx.softmax((Q @ K) / scale, axis=2)        # [B', Tq, Ta]
        out = attn @ V                                     # [B', Tq, vd*Q]
        out = out.reshape(Bsz * N_HEAD, Tq, vd, N_FREQS).transpose(0, 2, 1, 3).reshape(Bsz, N_HEAD * vd, Tq, N_FREQS)
        out = self._conv_nhwc(self.proj, out)
        out = self.proj_prelu(out)
        out = ln4dcf(out, self.pg, self.pb)
        return out


def blstm(fwd, bwd, x):
    """x [N, L, in] -> [N, L, 2H] using two unidirectional LSTMs."""
    f = fwd(x)[0]
    b = bwd(x[:, ::-1, :])[0][:, ::-1, :]
    return mx.concatenate([f, b], axis=-1)


class GridNetBlock(nn.Module):
    def __init__(self):
        super().__init__()
        self.intra_norm = nn.LayerNorm(C)
        self.intra_f = nn.LSTM(C, H); self.intra_b = nn.LSTM(C, H)
        self.intra_lin = nn.Linear(2 * H, C)
        self.inter_norm = nn.LayerNorm(C)
        self.inter_f = nn.LSTM(C, H); self.inter_b = nn.LSTM(C, H)
        self.inter_lin = nn.Linear(2 * H, C)
        self.attn = CrossAttn(C)

    def __call__(self, x):
        # x: [B, C, T, Q]
        Bsz, _, T, Qn = x.shape
        # intra (along freq Q), seq=Q, batch=B*T
        xi = x.transpose(0, 2, 3, 1)                       # [B,T,Q,C]
        h = self.intra_norm(xi).reshape(Bsz * T, Qn, C)
        h = self.intra_lin(blstm(self.intra_f, self.intra_b, h)).reshape(Bsz, T, Qn, C)
        xi = xi + h                                        # [B,T,Q,C]
        # inter (along time T), seq=T, batch=B*Q
        xt = xi.transpose(0, 2, 1, 3)                      # [B,Q,T,C]
        h = self.inter_norm(xt).reshape(Bsz * Qn, T, C)
        h = self.inter_lin(blstm(self.inter_f, self.inter_b, h)).reshape(Bsz, Qn, T, C)
        xt = xt + h                                        # [B,Q,T,C]
        x = xt.transpose(0, 3, 2, 1)                       # [B,C,T,Q]
        # self-attention over time
        x = x + self.attn(x, x)
        return x


class USEFTFGridNet(nn.Module):
    def __init__(self):
        super().__init__()
        self.conv = nn.Conv2d(2, D, (3, 3), padding=(1, 1))
        self.gn = nn.GroupNorm(1, D, pytorch_compatible=True)
        self.cross = CrossAttn(D)
        self.blocks = [GridNetBlock() for _ in range(B_LAYERS)]
        self.deconv = nn.ConvTranspose2d(C, 2, (3, 3), padding=(1, 1))

    def _enc(self, ri):
        # ri: [B,2,T,Q] -> conv (NHWC) -> [B,D,T,Q] with GroupNorm
        y = self.conv(ri.transpose(0, 2, 3, 1))           # [B,T,Q,D]
        y = self.gn(y)
        return y.transpose(0, 3, 1, 2)                     # [B,D,T,Q]

    def __call__(self, mix, ref):
        mr, mi, Tm = stft_ri(mix)
        rr, ri_, Tr = stft_ri(ref)
        mix_ri = mx.stack([mr, mi], axis=1)               # [B,2,T,Q]
        ref_ri = mx.stack([rr, ri_], axis=1)
        m = self._enc(mix_ri)                             # [B,D,Tm,Q]
        a = self._enc(ref_ri)                             # [B,D,Tr,Q]
        a = self.cross(m, a)                              # [B,D,Tm,Q]
        x = mx.concatenate([m, a], axis=1)                # [B,C,Tm,Q]
        for blk in self.blocks:
            x = blk(x)
        x = self.deconv(x.transpose(0, 2, 3, 1)).transpose(0, 3, 1, 2)  # [B,2,Tm,Q]
        out = istft_ri(x[:, 0], x[:, 1], mix.shape[1])
        return out


def bench(model, mix_secs, ref_secs=5.0, runs=5, warmup=2):
    Lm = int(mix_secs * SR)
    Lr = int(ref_secs * SR)
    mix = mx.random.normal((1, Lm))
    ref = mx.random.normal((1, Lr))
    for _ in range(warmup):
        mx.eval(model(mix, ref))
    ts = []
    for _ in range(runs):
        t0 = time.perf_counter()
        mx.eval(model(mix, ref))
        ts.append(time.perf_counter() - t0)
    ts.sort()
    med = ts[len(ts) // 2]
    return med, ts[0], ts[-1]


if __name__ == "__main__":
    mx.random.seed(0)
    model = USEFTFGridNet()
    nparams = sum(v.size for _, v in tree_flatten(model.parameters()))
    print(f"params: {nparams/1e6:.2f} M  (paper: 15.2 M)")
    print(f"{'mix_s':>6} {'ref_s':>6} {'T_frames':>9} {'median_s':>9} {'min_s':>8} {'RTF':>7}  {'latency_ms':>10}")
    for ms in [1, 3, 5, 10]:
        med, lo, hi = bench(model, ms)
        T = 1 + (int(ms*SR) + WIN) // HOP
        print(f"{ms:6.1f} {5.0:6.1f} {T:9d} {med:9.3f} {lo:8.3f} {med/ms:7.3f}  {med*1000:10.1f}")

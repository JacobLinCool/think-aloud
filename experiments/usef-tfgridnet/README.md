# USEF-TFGridNet — MLX RTF/latency experiment

Faithful MLX (Python) forward of USEF-TFGridNet (USEF-TSE, arXiv 2409.02615) at the
released 8 kHz checkpoint config (ZBang/USEF-TSE). RANDOM weights — timing only, not
correctness. Param count 15.62 M ≈ paper's 15.2 M (validates shapes).

Run:
    python3 -m venv .venv && . .venv/bin/activate && pip install mlx numpy
    python usef_tfgridnet_mlx.py

Measured on Apple M5 Pro (mlx 0.31.2, fp32): RTF ≈ 0.12–0.15; 97% of time in the 6
dual-path GridNet blocks (sequential BLSTM + per-block O(T²) attention). fp16 does not
help (latency/launch-bound, not throughput-bound).

Next step toward the real port: load chkpt/USEF-TFGridNet/*.pth.tar (torch), map state_dict
keys to these MLX modules, and validate output parity vs the PyTorch reference.

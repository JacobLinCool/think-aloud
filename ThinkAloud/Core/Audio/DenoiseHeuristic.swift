import Accelerate
import Foundation

/// The outcome of the Auto-denoise heuristic for one recorded clip. Carries the metrics behind the
/// decision so they can be logged (and later used to calibrate the threshold against a dataset).
struct DenoiseDecision: Sendable, Equatable {
    var shouldDenoise: Bool
    var snrDB: Float
    var speechLevelDBFS: Float
    var noiseFloorDBFS: Float
    var peakDBFS: Float
    var frameCount: Int

    enum Reason: String, Sendable {
        case noisy, clean, noSpeech, tooShort, clipping
    }
    var reason: Reason

    var logLine: String {
        func f(_ v: Float) -> String { String(format: "%.1f", v) }
        return "auto=\(shouldDenoise) reason=\(reason.rawValue) snr=\(f(snrDB)) "
            + "floor=\(f(noiseFloorDBFS)) speech=\(f(speechLevelDBFS)) peak=\(f(peakDBFS)) frames=\(frameCount)"
    }
}

/// Decides whether a recorded clip is noisy enough to be worth running DeepFilterNet on (Auto mode).
///
/// PRIMARY SIGNAL: a percentile SNR estimate — `P90(frameLevel) − P10(frameLevel)` in dB. Microphone
/// gain multiplies every sample by a constant, shifting every frame's dBFS by the same offset, which
/// cancels in a *difference* — so this discriminator and the `snr < minSpeechAboveFloorDB` no-speech
/// gate are gain/hardware-invariant and need no per-device calibration. A steady background bed
/// (fan/HVAC/street/café) lifts the quiet-frame floor (P10) toward the speech level (P90), compressing
/// the spread; clean dictation has deep silence in word gaps, so the spread is wide.
///
/// The ONLY gain-dependent gate is the clipping guard, which deliberately inspects the actual recorded
/// peak (a property of the real capture, never re-gained). Pure CPU (~sub-ms for a multi-second clip),
/// no model — safe to call inline.
///
/// The one tunable knob is `snrNoisyDB`; calibrate later via a 1-D sweep over the personal dataset
/// (run the benchmark On vs Off per record, pick the threshold that best matches the WER-better choice).
enum DenoiseHeuristic {
    static let refFrame = 1024       // ~21 ms @ 48 kHz reference
    static let refSampleRate = 48000
    static let eps: Float = 1e-7     // ≈ -140 dBFS; avoids -inf on digital silence

    static let snrNoisyDB: Float = 18           // PRIMARY threshold (gain-invariant)
    static let minSpeechAboveFloorDB: Float = 8 // below this the clip has no usable speech → skip
    static let clipPeakDBFS: Float = -1.0       // peak at/above this → force denoise (clipping)
    static let minFrames = 16                   // ~0.17 s after 50% overlap

    /// Analyze a mono clip. Frame/hop scale with `sampleRate` so the window stays ~21 ms at any rate.
    static func analyze(_ samples: [Float], sampleRate: Int) -> DenoiseDecision {
        let frame = max(64, refFrame * sampleRate / refSampleRate)
        let hop = max(1, frame / 2)

        var peak: Float = 0
        if !samples.isEmpty {
            samples.withUnsafeBufferPointer { vDSP_maxmgv($0.baseAddress!, 1, &peak, vDSP_Length($0.count)) }
        }
        let peakDB = 20 * log10f(max(peak, eps))

        var levels: [Float] = []
        levels.reserveCapacity(samples.count / hop + 1)
        samples.withUnsafeBufferPointer { p in
            var i = 0
            while i + frame <= p.count {
                var rms: Float = 0
                vDSP_rmsqv(p.baseAddress! + i, 1, &rms, vDSP_Length(frame))
                levels.append(20 * log10f(max(rms, eps)))
                i += hop
            }
        }

        let n = levels.count
        func decision(_ on: Bool, _ reason: DenoiseDecision.Reason,
                      snr: Float = 0, speech: Float = 0, floor: Float = 0) -> DenoiseDecision {
            DenoiseDecision(shouldDenoise: on, snrDB: snr, speechLevelDBFS: speech, noiseFloorDBFS: floor,
                            peakDBFS: peakDB, frameCount: n, reason: reason)
        }

        // Gate 1: too short for the percentile estimate to mean anything.
        if n < minFrames { return decision(false, .tooShort) }

        levels.sort()
        func percentile(_ p: Float) -> Float {
            let idx = Int(p * Float(n - 1) + 0.5)   // nearest-rank
            return levels[min(n - 1, max(0, idx))]
        }
        let floorDB = percentile(0.10)
        let speechDB = percentile(0.90)
        let snr = speechDB - floorDB

        // Ordered gates — first match wins. Clipping (on the real recording) beats the SNR decision.
        if peakDB >= clipPeakDBFS {
            return decision(true, .clipping, snr: snr, speech: speechDB, floor: floorDB)
        }
        // No usable dynamic range (pure silence, or continuous tone/speech with no quiet anchor) →
        // the SNR estimate is unreliable; skip (gain-invariant: depends only on the P90−P10 spread).
        if snr < minSpeechAboveFloorDB {
            return decision(false, .noSpeech, snr: snr, speech: speechDB, floor: floorDB)
        }
        return snr < snrNoisyDB
            ? decision(true, .noisy, snr: snr, speech: speechDB, floor: floorDB)
            : decision(false, .clean, snr: snr, speech: speechDB, floor: floorDB)
    }
}

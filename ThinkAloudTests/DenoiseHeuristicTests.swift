import XCTest
@testable import ThinkAloud

final class DenoiseHeuristicTests: XCTestCase {
    /// Alternating ±rms gives a frame RMS of exactly `rms` (so dBFS = 20·log10(rms)), deterministic.
    /// Builds a clip alternating `speechRMS` and `gapRMS` segments at 48 kHz.
    private func clip(speechRMS: Float, gapRMS: Float, seconds: Double = 3, segmentMs: Double = 250) -> [Float] {
        let sr = 48000
        let seg = Int(Double(sr) * segmentMs / 1000)
        let total = Int(Double(sr) * seconds)
        var out: [Float] = []
        out.reserveCapacity(total)
        var isSpeech = true
        while out.count < total {
            let r = isSpeech ? speechRMS : gapRMS
            for j in 0..<min(seg, total - out.count) { out.append(j % 2 == 0 ? r : -r) }
            isSpeech.toggle()
        }
        return out
    }

    func testCleanSkips() {
        // Speech ~-20 dBFS, deep silence gaps ~-70 dBFS → wide SNR → clean → skip.
        let d = DenoiseHeuristic.analyze(clip(speechRMS: 0.1, gapRMS: 0.000316), sampleRate: 48000)
        XCTAssertEqual(d.reason, .clean)
        XCTAssertFalse(d.shouldDenoise)
        XCTAssertGreaterThan(d.snrDB, DenoiseHeuristic.snrNoisyDB)
    }

    func testNoisyDenoises() {
        // Speech ~-20 dBFS over a steady noise bed ~-30 dBFS (gaps = bed) → compressed SNR → denoise.
        let d = DenoiseHeuristic.analyze(clip(speechRMS: 0.1, gapRMS: 0.0316), sampleRate: 48000)
        XCTAssertEqual(d.reason, .noisy)
        XCTAssertTrue(d.shouldDenoise)
        XCTAssertLessThan(d.snrDB, DenoiseHeuristic.snrNoisyDB)
    }

    func testGainInvariance() {
        // The central guarantee: scaling every sample (mic gain) must not change the decision —
        // including extreme low gain (k=0.001), which would have tripped the old absolute silence gate.
        for k: Float in [0.001, 0.1, 4.0] {
            let clean = DenoiseHeuristic.analyze(clip(speechRMS: 0.1, gapRMS: 0.000316).map { $0 * k }, sampleRate: 48000)
            XCTAssertEqual(clean.reason, .clean, "clean@\(k)")
            XCTAssertFalse(clean.shouldDenoise)
            let noisy = DenoiseHeuristic.analyze(clip(speechRMS: 0.1, gapRMS: 0.0316).map { $0 * k }, sampleRate: 48000)
            XCTAssertEqual(noisy.reason, .noisy, "noisy@\(k)")
            XCTAssertTrue(noisy.shouldDenoise)
        }
    }

    func testSilenceSkips() {
        let d = DenoiseHeuristic.analyze([Float](repeating: 0, count: 48000), sampleRate: 48000)
        XCTAssertEqual(d.reason, .noSpeech)
        XCTAssertFalse(d.shouldDenoise)
    }

    func testTooShortSkips() {
        let d = DenoiseHeuristic.analyze([Float](repeating: 0.1, count: 4000), sampleRate: 48000)
        XCTAssertEqual(d.reason, .tooShort)
        XCTAssertFalse(d.shouldDenoise)
    }

    func testMinFramesBoundaryIsProcessed() {
        // frame=1024, hop=512 → exactly 16 frames at 8704 samples. The boundary must be processed,
        // not rejected as .tooShort.
        let clean = clip(speechRMS: 0.1, gapRMS: 0.000316, seconds: 8704.0 / 48000.0, segmentMs: 60)
        let d = DenoiseHeuristic.analyze(Array(clean.prefix(8704)), sampleRate: 48000)
        XCTAssertEqual(d.frameCount, 16)
        XCTAssertNotEqual(d.reason, .tooShort)
    }

    func testEmptyDoesNotCrash() {
        let d = DenoiseHeuristic.analyze([], sampleRate: 48000)
        XCTAssertEqual(d.reason, .tooShort)
        XCTAssertFalse(d.shouldDenoise)
    }

    func testClippingForcesDenoise() {
        // Otherwise-clean clip, but a near-full-scale peak → clipping guard wins over the SNR decision.
        var samples = clip(speechRMS: 0.1, gapRMS: 0.000316)
        samples[0] = 0.97   // peak ≈ -0.26 dBFS ≥ CLIP_PEAK_DBFS (-1)
        let d = DenoiseHeuristic.analyze(samples, sampleRate: 48000)
        XCTAssertEqual(d.reason, .clipping)
        XCTAssertTrue(d.shouldDenoise)
    }
}

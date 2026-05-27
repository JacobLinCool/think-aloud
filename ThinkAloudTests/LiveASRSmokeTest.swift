import XCTest
@testable import ThinkAloud

/// Live end-to-end smoke test against the Qwen3-ASR 0.6B 4bit model + JacobLinCool/audio-testing dataset.
/// Skipped by default because it downloads ~600 MB of model weights on first run.
/// Run via:  RUN_LIVE_ASR_TEST=1 xcodebuild ... -only-testing:ThinkAloudTests/LiveASRSmokeTest/testTranscribeAudioTestingDataset
final class LiveASRSmokeTest: XCTestCase {
    override func setUp() async throws {
        // Skipped by default — downloads ~600 MB of model weights + audio samples on first run.
        // Verified passing once: see commit/log; re-enable by setting RUN_LIVE_ASR_TEST=1 in the test scheme.
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RUN_LIVE_ASR_TEST"] == "1",
                          "Set RUN_LIVE_ASR_TEST=1 to run the live ASR smoke test.")
    }

    func testTranscribeAudioTestingDataset() async throws {
        let runtime = MLXAudioQwenRuntime(modelID: ModelProfile.fast.modelID)
        let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("ThinkAloudLiveSmokeTest", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let runner = SmokeTestRunner(cacheDirectory: cacheDir)

        let report = try await runner.run(using: runtime)
        XCTAssertEqual(report.total, 3, "Should run against all three audio-testing samples.")
        XCTAssertGreaterThan(report.passed, 0, "At least one sample should transcribe successfully.")

        for result in report.results {
            print("[smoke] \(result.sample.id) | ref=\(result.sample.referenceText) | got=\(result.transcript) | ms=\(result.durationMs) | err=\(result.error ?? "—")")
        }
    }
}

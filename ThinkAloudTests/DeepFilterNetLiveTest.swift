import XCTest
@testable import ThinkAloud

/// Live end-to-end test of the DeepFilterNet denoiser: downloads the v3 weights (~8.7 MB) from
/// Hugging Face, loads them via `fromLocal`, and enhances a 1 s 48 kHz clip. Guards against the
/// `incompleteDownload` regression (the repo's weights live in a `v3/` subfolder).
/// Skipped by default — it hits the network and loads MLX weights.
/// Run via:  RUN_LIVE_DFN_TEST=1 xcodebuild ... -only-testing:ThinkAloudTests/DeepFilterNetLiveTest/testDownloadAndEnhance
final class DeepFilterNetLiveTest: XCTestCase {
    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RUN_LIVE_DFN_TEST"] == "1",
                          "Set RUN_LIVE_DFN_TEST=1 to run the live DeepFilterNet test.")
    }

    func testDownloadAndEnhance() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThinkAloudDFNLive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let runtime = DeepFilterNetRuntime(modelsDirectory: dir)

        // 1 second of 48 kHz noise — exercises download + fromLocal + enhance.
        let input = (0..<DeepFilterNetRuntime.requiredSampleRate).map { _ in Float.random(in: -0.2...0.2) }
        let output = try await runtime.enhance(input)

        let loaded = await runtime.isLoaded
        XCTAssertTrue(loaded, "model should be loaded after enhance()")
        XCTAssertFalse(output.isEmpty, "enhance should produce output")
        // DeepFilterNet compensates its own algorithmic delay → output length ≈ input length.
        XCTAssertEqual(output.count, input.count, accuracy: 480,
                       "expected ~\(input.count) samples, got \(output.count)")
        XCTAssertTrue(output.allSatisfy { $0.isFinite }, "output must be finite")
    }
}

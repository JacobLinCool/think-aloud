import XCTest
@testable import ThinkAloud

final class SmokeTestRunnerTests: XCTestCase {
    func testReportSummaryAggregatesResults() {
        let samples = [
            SmokeTestSample(id: "s1", audioURL: URL(fileURLWithPath: "/tmp/a"), referenceText: "a", language: nil),
            SmokeTestSample(id: "s2", audioURL: URL(fileURLWithPath: "/tmp/b"), referenceText: "b", language: nil)
        ]
        let results = [
            SmokeTestResult(id: "s1", sample: samples[0], transcript: "a", editedTranscript: "a", durationMs: 100, error: nil),
            SmokeTestResult(id: "s2", sample: samples[1], transcript: "", editedTranscript: "", durationMs: 200, error: "boom")
        ]
        let report = SmokeTestReport(modelID: "mock", chinesePreference: .model, results: results)
        XCTAssertEqual(report.passed, 1)
        XCTAssertEqual(report.total, 2)
        XCTAssertEqual(report.averageLatencyMs, 150)
    }

    func testRunAppliesChinesePreference() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("SmokeRunnerCN-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        for filename in ["audio-1.mp3", "audio-2.mp3", "audio-3.wav"] {
            try Data([0x00]).write(to: tempDir.appendingPathComponent(filename))
        }
        // Mock returns simplified Chinese text. With .traditional preference, the edited variant
        // must differ from the raw one — proving post-processing actually ran inside the runner.
        let mock = ChineseMockASRRuntime(modelID: "cn-mock", raw: "这是简体中文")
        let runner = SmokeTestRunner(cacheDirectory: tempDir)
        let report = try await runner.run(using: mock, chinesePreference: .traditional)
        XCTAssertEqual(report.chinesePreference, .traditional)
        for r in report.results {
            XCTAssertEqual(r.transcript, "这是简体中文")
            XCTAssertNotEqual(r.editedTranscript, r.transcript, "post-processor should have converted to traditional")
            XCTAssertEqual(r.editedTranscript, "這是簡體中文")
        }
    }

    func testRunIteratesOverEachSample() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("SmokeRunner-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Pre-seed audio files matching the SmokeTestRunner manifest so the runner skips network download.
        for filename in ["audio-1.mp3", "audio-2.mp3", "audio-3.wav"] {
            try Data([0x00]).write(to: tempDir.appendingPathComponent(filename))
        }

        let mock = MockASRRuntime(modelID: "mock-model")
        let runner = SmokeTestRunner(cacheDirectory: tempDir)
        let report = try await runner.run(using: mock)
        XCTAssertEqual(report.total, 3)
        XCTAssertEqual(report.passed, 3)
        XCTAssertEqual(report.modelID, "mock-model")
    }
}

private actor MockASRRuntime: ASRRuntime {
    let id: String = "mock"
    let modelID: String

    init(modelID: String) { self.modelID = modelID }

    func status() -> ASRRuntimeStatus { .ready }
    func preload() async throws {}
    func transcribe(audioURL: URL, options: ASROptions) async throws -> ASRResult {
        ASRResult(text: "mock transcript for \(audioURL.lastPathComponent)", language: options.language, modelID: modelID, runtimeID: id, durationMs: 42)
    }
    nonisolated func transcribeStream(samples: [Float], sampleRate: Int, options: ASROptions) -> AsyncThrowingStream<ASREvent, Error> {
        let modelIDLocal = modelID
        let idLocal = id
        return AsyncThrowingStream { continuation in
            continuation.yield(.result(ASRResult(text: "mock stream", language: options.language, modelID: modelIDLocal, runtimeID: idLocal, durationMs: 0)))
            continuation.finish()
        }
    }
}

private actor ChineseMockASRRuntime: ASRRuntime {
    let id: String = "cn-mock"
    let modelID: String
    let raw: String

    init(modelID: String, raw: String) { self.modelID = modelID; self.raw = raw }

    func status() -> ASRRuntimeStatus { .ready }
    func preload() async throws {}
    func transcribe(audioURL: URL, options: ASROptions) async throws -> ASRResult {
        ASRResult(text: raw, language: options.language, modelID: modelID, runtimeID: id, durationMs: 7)
    }
    nonisolated func transcribeStream(samples: [Float], sampleRate: Int, options: ASROptions) -> AsyncThrowingStream<ASREvent, Error> {
        AsyncThrowingStream { c in c.finish() }
    }
}

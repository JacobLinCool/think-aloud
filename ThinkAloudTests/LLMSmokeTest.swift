import XCTest
@testable import ThinkAloud

/// Live smoke tests for the on-device LLM stack — DOWNLOAD a real model and generate. Network + GBs
/// of disk + minutes, so they're skipped in CI (added to the -skip-testing list, like LiveASRSmokeTest)
/// and run manually to verify the runtime path.
final class LLMSmokeTest: XCTestCase {
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("llm-smoke-\(UUID().uuidString)", isDirectory: true)
        return d
    }

    /// Dense Qwen3 via the MLXLLM (text) factory — the guaranteed-supported path. ~0.34 GB.
    func testQwen3DenseLoadAndGenerate() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = try await LLMProbe.generate(
            modelID: "mlx-community/Qwen3-0.6B-4bit",
            cacheDirectory: dir,
            instructions: "You clean up dictated speech into clear written text. Output ONLY the cleaned text, no commentary.",
            prompt: "um so like the meeting is uh at 3pm tomorrow ok thanks",
            progress: { NSLog("LLM(Qwen3) download \(Int($0 * 100))%") }
        )
        NSLog("LLM(Qwen3-0.6B) OUTPUT: <<<\(out)>>>")
        XCTAssertFalse(out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "expected non-empty rewrite")
    }

    /// Qwen3.5 via the MLXVLM factory, run text-only (no images). The user's chosen model line. ~2.2 GB.
    func testQwen35VLMTextOnlyGenerate() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = try await LLMProbe.generate(
            modelID: "mlx-community/Qwen3.5-2B-OptiQ-4bit",
            cacheDirectory: dir,
            instructions: "You clean up dictated speech into clear written text. Output ONLY the cleaned text.",
            prompt: "um so like the meeting is uh at 3pm tomorrow ok thanks",
            progress: { NSLog("LLM(Qwen3.5) download \(Int($0 * 100))%") }
        )
        NSLog("LLM(Qwen3.5-2B) OUTPUT: <<<\(out)>>>")
        XCTAssertFalse(out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "expected non-empty rewrite")
    }
}

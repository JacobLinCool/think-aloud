import Foundation
import MLXLMCommon
import MLXLLM
import MLXVLM
import MLXHuggingFace
import HuggingFace
import Tokenizers

/// Minimal load + generate helper used to verify the MLX LLM stack end-to-end, and the basis for the
/// real runtime. `loadModelContainer` tries every registered factory and returns the first that loads
/// the repo — MLXLLM for dense Qwen3 (text), MLXVLM for Qwen3.5 (a VLM run text-only) — so one path
/// handles both. Importing both MLXLLM and MLXVLM is what registers the two factories.
enum LLMProbe {
    static func generate(
        modelID: String,
        cacheDirectory: URL,
        instructions: String,
        prompt: String,
        temperature: Float = 0.2,
        progress: @Sendable @escaping (Double) -> Void = { _ in }
    ) async throws -> String {
        let hub = HubClient(cache: HubCache(cacheDirectory: cacheDirectory))
        let container = try await loadModelContainer(
            from: #hubDownloader(hub),
            using: #huggingFaceTokenizerLoader(),
            id: modelID
        ) { p in progress(p.fractionCompleted) }

        let session = ChatSession(
            container,
            instructions: instructions,
            generateParameters: GenerateParameters(temperature: temperature),
            additionalContext: ["enable_thinking": false]
        )
        var out = ""
        for try await chunk in session.streamResponse(to: prompt) {
            out += chunk
        }
        return out
    }
}

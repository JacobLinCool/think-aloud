import Foundation
import HuggingFace
import MLX
import MLXAudioCore
import MLXAudioSTS

/// Wraps mlx-audio-swift's `DeepFilterNetModel` (speech enhancement / background-noise
/// suppression) as the engine behind the Auto Pre-Edit `denoise` step.
///
/// DeepFilterNet operates strictly on **48 kHz mono** audio; callers must pass samples at
/// that rate (ThinkAloud's `AudioRecorder` now captures at 48 kHz). The output has the same
/// length as the input (the model compensates its own algorithmic delay).
///
/// Weights (~`mlx-community/DeepFilterNet-mlx` v3, a few MB) are downloaded once into the
/// shared models directory and held in memory until `unload()` (driven by the same idle
/// eviction policy as the ASR model). The underlying model is `@unchecked Sendable`; we keep
/// it inside this actor so the MLX inference runs off the main actor.
actor DeepFilterNetRuntime {
    static let repoID = "mlx-community/DeepFilterNet-mlx"
    /// The sample rate DeepFilterNet requires for both input and output.
    static let requiredSampleRate = 48000

    private let modelsDirectory: URL
    private var model: DeepFilterNetModel?
    private(set) var status: ASRRuntimeStatus = .unloaded

    init(modelsDirectory: URL) {
        self.modelsDirectory = modelsDirectory
    }

    var isLoaded: Bool { model != nil }

    /// Downloads (if needed) and loads the model into memory. Idempotent.
    func preload() async throws {
        if model != nil {
            status = .ready
            return
        }
        status = .loading
        do {
            let loaded = try await DeepFilterNetModel.fromPretrained(
                cache: HubCache(cacheDirectory: modelsDirectory)
            )
            model = loaded
            status = .ready
        } catch {
            status = .failed(String(describing: error))
            throw error
        }
    }

    /// Enhances one complete 48 kHz mono clip, lazily loading the model on first use.
    /// Returns samples of the same length and rate.
    func enhance(_ samples: [Float]) async throws -> [Float] {
        if model == nil {
            try await preload()
        }
        guard let model else { throw ASRError.modelNotReady }
        let input = MLXArray(samples)
        let output = try model.enhance(input)
        return output.asArray(Float.self)
    }

    /// Drops the weights to free memory. Cached files on disk are kept.
    func unload() {
        model = nil
        status = .unloaded
    }
}

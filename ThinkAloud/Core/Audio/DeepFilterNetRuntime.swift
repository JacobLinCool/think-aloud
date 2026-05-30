import Foundation
import MLX
import MLXAudioSTS

/// Wraps mlx-audio-swift's `DeepFilterNetModel` (speech enhancement / background-noise
/// suppression) as the engine behind the Auto Pre-Edit `denoise` step.
///
/// DeepFilterNet operates strictly on **48 kHz mono** audio; callers must pass samples at
/// that rate (ThinkAloud's `AudioRecorder` now captures at 48 kHz). The output has the same
/// length as the input (the model compensates its own algorithmic delay).
///
/// Weights (~8.7 MB) are fetched once into the shared models directory and held in memory until
/// `unload()` (driven by the same idle eviction policy as the ASR model). The underlying model is
/// `@unchecked Sendable`; we keep it inside this actor so the MLX inference runs off the main actor.
///
/// NOTE: we deliberately do NOT use `DeepFilterNetModel.fromPretrained(...)`. Its downloader
/// (mlx-audio's `ModelUtils.resolveOrDownloadModel`) only matches/validates `*.safetensors` at the
/// repo's TOP LEVEL, but `mlx-community/DeepFilterNet-mlx` stores its weights in a `v3/` subfolder
/// (`v3/config.json` + `v3/model.safetensors`). So it downloads nothing usable and then throws
/// `incompleteDownload` (after wiping the cache). We fetch the two `v3` files directly and load
/// them with `fromLocal`, which is happy with a flat directory containing config.json + safetensors.
actor DeepFilterNetRuntime {
    static let repoID = "mlx-community/DeepFilterNet-mlx"
    /// The sample rate DeepFilterNet requires for both input and output.
    static let requiredSampleRate = 48000

    private static let downloadBase = "https://huggingface.co/mlx-community/DeepFilterNet-mlx/resolve/main/v3"
    private static let requiredFiles = ["config.json", "model.safetensors"]

    private let modelsDirectory: URL
    private var model: DeepFilterNetModel?
    private(set) var status: ASRRuntimeStatus = .unloaded

    init(modelsDirectory: URL) {
        self.modelsDirectory = modelsDirectory
    }

    var isLoaded: Bool { model != nil }

    /// Where the v3 weights live (flat: config.json + model.safetensors).
    private var modelDirectory: URL {
        modelsDirectory.appendingPathComponent("deepfilternet-v3", isDirectory: true)
    }

    /// Downloads (if needed) and loads the model into memory. Idempotent.
    func preload() async throws {
        if model != nil {
            status = .ready
            return
        }
        status = .loading
        do {
            try await ensureDownloaded()
            let loaded = try DeepFilterNetModel.fromLocal(modelDirectory)
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

    // MARK: - Download

    private func ensureDownloaded() async throws {
        let fm = FileManager.default
        let dir = modelDirectory
        func nonEmpty(_ name: String) -> Bool {
            let url = dir.appendingPathComponent(name)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return fm.fileExists(atPath: url.path) && size > 0
        }
        if Self.requiredFiles.allSatisfy(nonEmpty) { return }

        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in Self.requiredFiles {
            guard !nonEmpty(name) else { continue }
            guard let url = URL(string: "\(Self.downloadBase)/\(name)") else {
                throw ASRError.modelLoadFailed("bad DeepFilterNet URL for \(name)")
            }
            let (tmp, response) = try await URLSession.shared.download(from: url)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(code) else {
                throw ASRError.modelLoadFailed("download \(name) failed (HTTP \(code))")
            }
            let dest = dir.appendingPathComponent(name)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: tmp, to: dest)
        }
        guard Self.requiredFiles.allSatisfy(nonEmpty) else {
            throw ASRError.modelLoadFailed("DeepFilterNet download incomplete")
        }
    }
}

import Foundation

protocol ASRRuntime: Sendable {
    var id: String { get }
    var modelID: String { get }
    func status() async -> ASRRuntimeStatus
    func preload() async throws
    func transcribe(audioURL: URL, options: ASROptions) async throws -> ASRResult
    /// In-memory streaming transcription. Avoids WAV round-trip when caller already holds PCM samples.
    func transcribeStream(samples: [Float], sampleRate: Int, options: ASROptions) -> AsyncThrowingStream<ASREvent, Error>
    /// Drop any loaded weights and return to `.unloaded`. Cached files on disk are kept.
    /// Default implementation is a no-op for runtimes that don't hold significant memory.
    func unload() async
}

extension ASRRuntime {
    func unload() async {}
}

enum ASREvent: Sendable {
    case token(String)
    case result(ASRResult)
}

enum ASRRuntimeStatus: Sendable, Equatable {
    case unloaded
    /// Model files are being fetched. `progress` is 0...1 if `totalBytes` is known, else `nil`.
    case downloading(progress: Double?, downloadedBytes: Int64, totalBytes: Int64?)
    /// Files are present; weights are being loaded into memory.
    case loading
    case ready
    case failed(String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var isLoading: Bool {
        switch self {
        case .loading, .downloading: return true
        default: return false
        }
    }
}

struct ASROptions: Sendable, Equatable {
    var language: String?

    init(language: String? = nil) {
        self.language = language
    }
}

struct ASRResult: Sendable, Equatable {
    var text: String
    var language: String?
    var modelID: String
    var runtimeID: String
    var durationMs: Int
}

enum ASRError: Error, LocalizedError {
    case modelNotReady
    case audioLoadFailed(String)
    case modelLoadFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotReady: return "ASR model is not ready."
        case .audioLoadFailed(let msg): return "Failed to load audio: \(msg)"
        case .modelLoadFailed(let msg): return "Failed to load model: \(msg)"
        }
    }
}

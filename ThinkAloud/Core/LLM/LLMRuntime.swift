import Foundation
import HuggingFace

/// On-device text-refinement runtime for the AI Refine post-edit stage. Mirrors `ASRRuntime`'s
/// lifecycle (status / preload / unload) and REUSES `ASRRuntimeStatus`, so the Settings download UI
/// (`ModelDownloadList`-style) and the idle-unload machinery work for LLMs unchanged.
protocol LLMRuntime: Sendable {
    var modelID: String { get }
    func status() async -> ASRRuntimeStatus
    func preload() async throws
    /// Streams a refined rewrite of `transcript` under `instructions` (the per-app system prompt).
    /// Yields text chunks; the caller stops early on cancellation and falls back to the deterministic
    /// transcript on any thrown error (guardrail refusal, load failure, timeout).
    func refine(_ transcript: String, instructions: String, params: LLMGenerateParams) -> AsyncThrowingStream<String, Error>
    func unload() async
}

struct LLMGenerateParams: Sendable {
    /// Low by default — faithful cleanup, not creative writing.
    var temperature: Float
    init(temperature: Float = 0.3) {
        self.temperature = temperature
    }
}

/// Text helpers for LLM output.
enum LLMText {
    /// Strips chain-of-thought reasoning that "thinking" models (Qwen3) emit before their answer.
    /// Returns everything after the LAST `</think>`; if a `<think>` block is still open (no close), the
    /// model hasn't produced its answer yet, so returns empty — the caller treats that as "no output"
    /// and keeps the deterministic transcript. We also disable thinking at the prompt level, so this is
    /// belt-and-suspenders for models that ignore that flag.
    static func stripReasoning(_ text: String) -> String {
        let closeTag = "</think>"
        if let r = text.range(of: closeTag, options: .backwards) {
            return String(text[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if text.contains("<think>") {
            return ""
        }
        return text
    }
}

enum LLMError: Error, LocalizedError {
    case notReady
    case loadFailed(String)

    var errorDescription: String? {
        switch self {
        case .notReady: return "The refine model is not ready."
        case .loadFailed(let m): return "Failed to load the refine model: \(m)"
        }
    }
}

/// On-disk layout helpers for LLM weights. MLXLLM/MLXVLM download through swift-huggingface's
/// `HubCache`, whose layout is `<cache>/models--org--repo/{snapshots,blobs}/` — DIFFERENT from the
/// ASR runtimes' flat `<cache>/mlx-audio/<id>/`. The LLM cache dir is a dedicated sibling
/// (`<appSupport>/llm/`), so `ModelManager.pruneRedundantHFCache()` — which only scans the ASR
/// models dir — can never delete these live weights.
enum LLMModelPaths {
    static func repoDirectory(for modelID: String, cache: HubCache) -> URL {
        let repo = "models--" + modelID.replacingOccurrences(of: "/", with: "--")
        return cache.cacheDirectory.appendingPathComponent(repo)
    }

    static func snapshotsDirectory(for modelID: String, cache: HubCache) -> URL {
        repoDirectory(for: modelID, cache: cache).appendingPathComponent("snapshots")
    }

    static func blobsDirectory(for modelID: String, cache: HubCache) -> URL {
        repoDirectory(for: modelID, cache: cache).appendingPathComponent("blobs")
    }

    /// "Downloaded" once any `*.safetensors` weight file exists under the snapshots dir.
    static func hasModelFiles(for modelID: String, cache: HubCache) -> Bool {
        let dir = snapshotsDirectory(for: modelID, cache: cache)
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path),
              let e = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { return false }
        for case let url as URL in e where url.pathExtension == "safetensors" { return true }
        return false
    }

    /// Bytes on disk so far — max of the blob store (where the big weight streams in) and the
    /// snapshot (where finished files land), mirroring `ASRRuntimeFactory.downloadedBytes`.
    static func downloadedBytes(for modelID: String, cache: HubCache) -> Int64 {
        max(directorySize(blobsDirectory(for: modelID, cache: cache)),
            directorySize(snapshotsDirectory(for: modelID, cache: cache)))
    }

    static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path),
              let e = fm.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let entry as URL in e {
            let v = try? entry.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            total += Int64(v?.totalFileAllocatedSize ?? v?.fileSize ?? 0)
        }
        return total
    }

    /// Removes a model's weights from the LLM cache dir.
    static func remove(modelID: String, cache: HubCache) throws {
        let dir = repoDirectory(for: modelID, cache: cache)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }
}

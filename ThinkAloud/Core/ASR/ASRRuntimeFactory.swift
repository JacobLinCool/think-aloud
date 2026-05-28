import Foundation
import HuggingFace

/// Builds the right runtime for a `ModelProfile` and exposes the shared on-disk layout
/// helpers (snapshot directory + "is the snapshot present?" check). Both family runtimes
/// resolve weights through mlx-audio's `ModelUtils.resolveOrDownloadModel`, which uses the
/// same `<cache>/mlx-audio/<modelID-with-slashes-replaced-by-underscores>/` convention, so
/// path resolution is family-agnostic.
enum ASRRuntimeFactory {
    static func make(profile: ModelProfile, cacheDirectory: URL?) -> any ASRRuntime {
        switch profile.family {
        case .qwen3:
            return MLXAudioQwenRuntime(modelID: profile.modelID, cacheDirectory: cacheDirectory)
        case .whisper:
            return MLXAudioWhisperRuntime(modelID: profile.modelID, cacheDirectory: cacheDirectory)
        }
    }

    static func snapshotDirectory(for modelID: String, cache: HubCache) -> URL {
        let subdir = modelID.replacingOccurrences(of: "/", with: "_")
        return cache.cacheDirectory
            .appendingPathComponent("mlx-audio")
            .appendingPathComponent(subdir)
    }

    /// Heuristic shared with both runtimes: a snapshot directory is "downloaded" once any
    /// `*.safetensors` weight file is present. mlx-audio downloads weights last so partial
    /// downloads don't trip this check.
    static func hasModelFiles(in directory: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path),
              let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return false
        }
        for case let url as URL in enumerator {
            if url.pathExtension == "safetensors" { return true }
        }
        return false
    }

    static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path),
              let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let entry as URL in enumerator {
            let values = try? entry.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }
}

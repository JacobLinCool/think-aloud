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

    /// The Hugging Face Hub blob store where the downloader streams in-progress files,
    /// e.g. `<cache>/models--openai--whisper-large/blobs/`. Each file (including the
    /// multi-GB weights) lands here as a `<etag>.incomplete` blob and is only *copied*
    /// into `snapshotDirectory` once finished — so this is where bytes actually grow
    /// during a download.
    static func blobsDirectory(for modelID: String, cache: HubCache) -> URL {
        let repoDir = "models--" + modelID.replacingOccurrences(of: "/", with: "--")
        return cache.cacheDirectory
            .appendingPathComponent(repoDir)
            .appendingPathComponent("blobs")
    }

    /// Bytes downloaded so far for an in-progress model fetch. We poll *both* the blob
    /// store (where the big weight file streams in smoothly) and the snapshot dir (where
    /// finished files are copied out) and take the larger. Polling the snapshot alone made
    /// progress jump file-by-file and stall for the entire duration of the big weight
    /// download; the blob store grows byte-by-byte so the percentage tracks real size.
    static func downloadedBytes(for modelID: String, snapshotDir: URL, cache: HubCache) -> Int64 {
        max(directorySize(snapshotDir), directorySize(blobsDirectory(for: modelID, cache: cache)))
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

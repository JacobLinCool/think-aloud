import Foundation
import HuggingFace
import MLX
import MLXAudioCore
import MLXAudioSTT

/// Wraps a non-Sendable reference so it can cross the actor isolation boundary on load.
/// We only touch the wrapped model inside MLXAudioQwenRuntime, so confining it to a single actor is safe.
private struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
}

/// Free function so the actor can `await` a Sendable wrapper instead of the raw non-Sendable model.
private func loadQwenModel(modelID: String, cache: HubCache) async throws -> UncheckedBox<Qwen3ASRModel> {
    let model = try await Qwen3ASRModel.fromPretrained(modelID, cache: cache)
    return UncheckedBox(value: model)
}

actor MLXAudioQwenRuntime: ASRRuntime {
    let id: String = "mlx-audio-swift-qwen3-asr"
    let modelID: String
    private let cache: HubCache
    private let cacheDirectory: URL?

    private var model: UncheckedBox<Qwen3ASRModel>?
    private var currentStatus: ASRRuntimeStatus = .unloaded
    private var expectedTotalBytes: Int64?

    init(modelID: String, cacheDirectory: URL? = nil) {
        self.modelID = modelID
        self.cacheDirectory = cacheDirectory
        if let cacheDirectory {
            self.cache = HubCache(cacheDirectory: cacheDirectory)
        } else {
            self.cache = .default
        }
    }

    func status() -> ASRRuntimeStatus {
        currentStatus
    }

    func unload() async {
        model = nil
        currentStatus = .unloaded
        expectedTotalBytes = nil
        NSLog("ThinkAloud: MLXAudioQwenRuntime unloaded modelID=\(modelID)")
    }

    func preload() async throws {
        if model != nil { return }
        switch currentStatus {
        case .loading, .downloading:
            return
        default:
            break
        }

        let snapshotDir = Self.snapshotDirectory(for: modelID, cache: cache)
        // Skip the .downloading state (and the HF API round-trip + size poller) when the snapshot
        // is already on disk — otherwise users see a spurious "Downloading 99%" flash while we're
        // really just mmap'ing existing weights.
        let alreadyDownloaded = Self.hasModelFiles(in: snapshotDir)

        var pollingTask: Task<Void, Never>?

        if alreadyDownloaded {
            currentStatus = .loading
        } else {
            currentStatus = .downloading(progress: nil, downloadedBytes: directorySize(snapshotDir), totalBytes: expectedTotalBytes)

            if expectedTotalBytes == nil {
                let modelID = modelID
                let total = await HuggingFaceMetadata.totalRepoSize(modelID: modelID)
                expectedTotalBytes = total
                updateDownloadStatus(currentBytes: directorySize(snapshotDir))
            }

            let runtimeRef = self
            pollingTask = Task { [snapshotDir] in
                while !Task.isCancelled {
                    let bytes = directorySizeNonisolated(snapshotDir)
                    await runtimeRef.updateDownloadStatus(currentBytes: bytes)
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }

        do {
            let box = try await loadQwenModel(modelID: modelID, cache: cache)
            pollingTask?.cancel()
            currentStatus = .loading
            model = box
            currentStatus = .ready
        } catch {
            pollingTask?.cancel()
            currentStatus = .failed(String(describing: error))
            throw ASRError.modelLoadFailed(String(describing: error))
        }
    }

    /// Heuristic: the snapshot is considered "downloaded" once any *.safetensors weight file is
    /// present. mlx-audio downloads weights last, so partial downloads won't trip this check.
    nonisolated static func hasModelFiles(in directory: URL) -> Bool {
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

    /// Called by the polling task on the runtime actor to update visible bytes.
    fileprivate func updateDownloadStatus(currentBytes: Int64) {
        switch currentStatus {
        case .downloading:
            let total = expectedTotalBytes
            let progress: Double? = total.flatMap { $0 > 0 ? min(Double(currentBytes) / Double($0), 0.999) : nil }
            currentStatus = .downloading(progress: progress, downloadedBytes: currentBytes, totalBytes: total)
        default:
            break
        }
    }

    private func directorySize(_ url: URL) -> Int64 {
        Self.directorySizeNonisolated(url)
    }

    nonisolated fileprivate func directorySizeNonisolated(_ url: URL) -> Int64 {
        Self.directorySizeNonisolated(url)
    }

    nonisolated static func directorySizeNonisolated(_ url: URL) -> Int64 {
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

    /// Mirrors `MLXAudioCore.ModelUtils.resolveOrDownloadModel`'s convention:
    /// `<cache>/mlx-audio/<repo-with-slashes-replaced-by-underscores>/`.
    nonisolated static func snapshotDirectory(for modelID: String, cache: HubCache) -> URL {
        let subdir = modelID.replacingOccurrences(of: "/", with: "_")
        return cache.cacheDirectory
            .appendingPathComponent("mlx-audio")
            .appendingPathComponent(subdir)
    }

    func transcribe(audioURL: URL, options: ASROptions) async throws -> ASRResult {
        if model == nil { try await preload() }
        guard let model else { throw ASRError.modelNotReady }

        let sampleRate: Int
        let audio: MLXArray
        do {
            (sampleRate, audio) = try loadAudioArray(from: audioURL, sampleRate: 16000)
        } catch {
            NSLog("ThinkAloud: loadAudioArray failed: \(error)")
            throw ASRError.audioLoadFailed(String(describing: error))
        }
        NSLog("ThinkAloud: transcribe audio sampleRate=\(sampleRate) shape=\(audio.shape) url=\(audioURL.lastPathComponent)")

        let start = Date()
        let language = options.language ?? "Auto"
        let output = model.value.generate(audio: audio, language: language)
        let elapsed = Int(Date().timeIntervalSince(start) * 1000)
        NSLog("ThinkAloud: transcribe output text=\"\(output.text)\" elapsed=\(elapsed)ms")

        return ASRResult(
            text: output.text,
            language: options.language,
            modelID: modelID,
            runtimeID: id,
            durationMs: elapsed
        )
    }

    /// In-memory streaming transcription — caller passes 16 kHz Float32 mono samples directly.
    /// Avoids WAV round-trip; matches the format AudioRecorder already produces.
    nonisolated func transcribeStream(samples: [Float], sampleRate: Int, options: ASROptions) -> AsyncThrowingStream<ASREvent, Error> {
        AsyncThrowingStream<ASREvent, Error> { continuation in
            let runtime = self
            let task = Task {
                await runtime.runStreaming(samples: samples, sampleRate: sampleRate, options: options, continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runStreaming(samples: [Float], sampleRate: Int, options: ASROptions, continuation: AsyncThrowingStream<ASREvent, Error>.Continuation) async {
        do {
            if model == nil { try await preload() }
            guard let model else {
                continuation.finish(throwing: ASRError.modelNotReady)
                return
            }
            // Qwen3-ASR expects 16 kHz mono. The caller (PopupCoordinator / BenchmarkRunner)
            // resamples to 16 kHz — from AudioRecorder's 48 kHz capture, after optional
            // denoising — before getting here, so we feed samples straight into an MLXArray.
            precondition(sampleRate == 16000, "MLXAudioQwenRuntime expects 16 kHz samples")
            let audio = MLXArray(samples)
            let start = Date()
            let language = options.language ?? "Auto"
            let modelIDLocal = self.modelID
            let runtimeIDLocal = self.id
            NSLog("ThinkAloud: transcribeStream begin samples=\(samples.count) sr=\(sampleRate) lang=\(language)")

            for try await event in model.value.generateStream(audio: audio, language: language) {
                if Task.isCancelled {
                    continuation.finish()
                    return
                }
                switch event {
                case .token(let token):
                    continuation.yield(.token(token))
                case .result(let r):
                    let elapsed = Int(Date().timeIntervalSince(start) * 1000)
                    NSLog("ThinkAloud: transcribeStream final text=\"\(r.text)\" elapsed=\(elapsed)ms")
                    continuation.yield(.result(ASRResult(
                        text: r.text,
                        language: options.language,
                        modelID: modelIDLocal,
                        runtimeID: runtimeIDLocal,
                        durationMs: elapsed
                    )))
                case .info:
                    break
                }
            }
            continuation.finish()
        } catch {
            NSLog("ThinkAloud: transcribeStream failed: \(error)")
            continuation.finish(throwing: error)
        }
    }
}

import Foundation
import HuggingFace
import MLX
import MLXAudioCore
import MLXAudioSTT

private struct WhisperBox: @unchecked Sendable {
    let value: WhisperModel
}

private func loadWhisperModel(modelID: String, cache: HubCache) async throws -> WhisperBox {
    let model = try await WhisperModel.fromPretrained(modelID, cache: cache)
    return WhisperBox(value: model)
}

actor MLXAudioWhisperRuntime: ASRRuntime {
    let id: String = "mlx-audio-swift-whisper"
    let modelID: String
    private let cache: HubCache
    private let cacheDirectory: URL?

    private var model: WhisperBox?
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
        NSLog("ThinkAloud: MLXAudioWhisperRuntime unloaded modelID=\(modelID)")
    }

    func preload() async throws {
        if model != nil { return }
        switch currentStatus {
        case .loading, .downloading:
            return
        default:
            break
        }

        let snapshotDir = ASRRuntimeFactory.snapshotDirectory(for: modelID, cache: cache)
        let alreadyDownloaded = ASRRuntimeFactory.hasModelFiles(in: snapshotDir)

        var pollingTask: Task<Void, Never>?

        if alreadyDownloaded {
            currentStatus = .loading
        } else {
            currentStatus = .downloading(progress: nil, downloadedBytes: ASRRuntimeFactory.directorySize(snapshotDir), totalBytes: expectedTotalBytes)

            if expectedTotalBytes == nil {
                let modelID = modelID
                let total = await HuggingFaceMetadata.totalRepoSize(modelID: modelID)
                expectedTotalBytes = total
                updateDownloadStatus(currentBytes: ASRRuntimeFactory.directorySize(snapshotDir))
            }

            let runtimeRef = self
            pollingTask = Task { [snapshotDir] in
                while !Task.isCancelled {
                    let bytes = ASRRuntimeFactory.directorySize(snapshotDir)
                    await runtimeRef.updateDownloadStatus(currentBytes: bytes)
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }

        do {
            let box = try await loadWhisperModel(modelID: modelID, cache: cache)
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
        NSLog("ThinkAloud: whisper transcribe audio sampleRate=\(sampleRate) shape=\(audio.shape) url=\(audioURL.lastPathComponent)")

        let start = Date()
        let params = STTGenerateParameters(language: options.language)
        let output = model.value.generate(audio: audio, generationParameters: params)
        let elapsed = Int(Date().timeIntervalSince(start) * 1000)
        NSLog("ThinkAloud: whisper transcribe output text=\"\(output.text)\" elapsed=\(elapsed)ms")

        return ASRResult(
            text: output.text,
            language: options.language,
            modelID: modelID,
            runtimeID: id,
            durationMs: elapsed
        )
    }

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
            // Whisper expects 16 kHz mono — same as AudioRecorder's output.
            precondition(sampleRate == 16000, "MLXAudioWhisperRuntime expects 16 kHz samples")
            let audio = MLXArray(samples)
            let start = Date()
            let modelIDLocal = self.modelID
            let runtimeIDLocal = self.id
            let params = STTGenerateParameters(language: options.language)
            NSLog("ThinkAloud: whisper transcribeStream begin samples=\(samples.count) sr=\(sampleRate) lang=\(options.language ?? "auto")")

            for try await event in model.value.generateStream(audio: audio, generationParameters: params) {
                if Task.isCancelled {
                    continuation.finish()
                    return
                }
                switch event {
                case .token(let token):
                    continuation.yield(.token(token))
                case .result(let r):
                    let elapsed = Int(Date().timeIntervalSince(start) * 1000)
                    NSLog("ThinkAloud: whisper transcribeStream final text=\"\(r.text)\" elapsed=\(elapsed)ms")
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
            NSLog("ThinkAloud: whisper transcribeStream failed: \(error)")
            continuation.finish(throwing: error)
        }
    }
}

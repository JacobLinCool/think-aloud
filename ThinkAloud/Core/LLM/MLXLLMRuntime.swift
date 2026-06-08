import Foundation
import HuggingFace
import Tokenizers
import MLXLMCommon
import MLXLLM
import MLXVLM
import MLXHuggingFace

/// Confines a non-Sendable model container to one actor (same pattern as `MLXAudioQwenRuntime`).
private struct UncheckedBox<T>: @unchecked Sendable { let value: T }

/// MLX-backed text refinement. `loadModelContainer` tries every registered factory and returns the
/// first that loads the repo — MLXLLM for dense Qwen3 (text), MLXVLM for Qwen3.5 (a VLM run
/// text-only, no images). Importing both MLXLLM and MLXVLM is what registers the two factories.
actor MLXLLMRuntime: LLMRuntime {
    let modelID: String
    private let cache: HubCache
    private var container: UncheckedBox<ModelContainer>?
    private var currentStatus: ASRRuntimeStatus = .unloaded
    private var expectedTotalBytes: Int64?

    init(modelID: String, cacheDirectory: URL) {
        self.modelID = modelID
        self.cache = HubCache(cacheDirectory: cacheDirectory)
    }

    func status() -> ASRRuntimeStatus { currentStatus }

    func unload() {
        container = nil
        currentStatus = .unloaded
        expectedTotalBytes = nil
        NSLog("ThinkAloud: MLXLLMRuntime unloaded modelID=\(modelID)")
    }

    func preload() async throws {
        if container != nil { return }
        if currentStatus.isLoading { return }

        let alreadyDownloaded = LLMModelPaths.hasModelFiles(for: modelID, cache: cache)
        var pollingTask: Task<Void, Never>?

        if alreadyDownloaded {
            currentStatus = .loading
        } else {
            currentStatus = .downloading(progress: nil,
                                         downloadedBytes: LLMModelPaths.downloadedBytes(for: modelID, cache: cache),
                                         totalBytes: expectedTotalBytes)
            if expectedTotalBytes == nil {
                expectedTotalBytes = await HuggingFaceMetadata.totalRepoSize(modelID: modelID)
                updateDownloadStatus(currentBytes: LLMModelPaths.downloadedBytes(for: modelID, cache: cache))
            }
            let runtimeRef = self
            let modelID = modelID
            let cache = cache
            pollingTask = Task {
                while !Task.isCancelled {
                    let bytes = LLMModelPaths.downloadedBytes(for: modelID, cache: cache)
                    await runtimeRef.updateDownloadStatus(currentBytes: bytes)
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }

        do {
            let box = try await loadContainer()
            pollingTask?.cancel()
            currentStatus = .loading
            container = box
            currentStatus = .ready
            NSLog("ThinkAloud: MLXLLMRuntime ready modelID=\(modelID)")
        } catch {
            pollingTask?.cancel()
            currentStatus = .failed(String(describing: error))
            throw LLMError.loadFailed(String(describing: error))
        }
    }

    private func loadContainer() async throws -> UncheckedBox<ModelContainer> {
        let c = try await loadModelContainer(
            from: #hubDownloader(HubClient(cache: cache)),
            using: #huggingFaceTokenizerLoader(),
            id: modelID
        )
        return UncheckedBox(value: c)
    }

    fileprivate func updateDownloadStatus(currentBytes: Int64) {
        if case .downloading = currentStatus {
            let total = expectedTotalBytes
            let progress = total.flatMap { $0 > 0 ? min(Double(currentBytes) / Double($0), 0.999) : nil }
            currentStatus = .downloading(progress: progress, downloadedBytes: currentBytes, totalBytes: total)
        }
    }

    nonisolated func refine(_ transcript: String, instructions: String, params: LLMGenerateParams) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let runtime = self
            let task = Task {
                await runtime.runRefine(transcript: transcript, instructions: instructions, params: params, continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runRefine(transcript: String, instructions: String, params: LLMGenerateParams,
                           continuation: AsyncThrowingStream<String, Error>.Continuation) async {
        do {
            if container == nil { try await preload() }
            guard let box = container else { continuation.finish(throwing: LLMError.notReady); return }

            let session = ChatSession(
                box.value,
                instructions: instructions,
                generateParameters: GenerateParameters(temperature: params.temperature)
            )
            // Runaway guard: a faithful cleanup shouldn't exceed the input by much. Cap output chars
            // so a confused small model can't hang dictation with an unbounded generation.
            let charBudget = max(400, transcript.count * 3 + 200)
            var emitted = 0
            for try await chunk in session.streamResponse(to: transcript) {
                if Task.isCancelled { continuation.finish(); return }
                continuation.yield(chunk)
                emitted += chunk.count
                if emitted > charBudget { break }
            }
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }
}

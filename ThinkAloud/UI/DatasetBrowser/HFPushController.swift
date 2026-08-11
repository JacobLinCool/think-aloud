import Foundation
import Observation

@MainActor
@Observable
final class HFPushController {
    enum SummaryState: Equatable {
        case idle
        case loading
        case loaded(DatasetStatistics)
        case failed(String)
    }

    // Form state
    var repoName: String = "thinkaloud-personal"
    var organization: String = ""
    var isPrivate: Bool = true
    var includeAudio: Bool = true
    /// Privacy-first default OFF — the app the user dictates into is not published unless they opt in.
    var includeSourceApp: Bool = false

    /// Aggregate stats for the pre-push consent summary. Push stays gated until this succeeds.
    private(set) var summaryState: SummaryState = .idle

    // Runtime state
    private(set) var isRunning: Bool = false
    private(set) var isCancelling: Bool = false
    private(set) var wasCancelled: Bool = false
    private(set) var stage: HFPushProgress.Stage = .prepare
    private(set) var stageCompleted: Int = 0
    private(set) var stageTotal: Int = 0
    private(set) var currentLabel: String = ""
    private(set) var result: HFPushResult?
    private(set) var errorMessage: String?

    private let tokenStore: any HFAuthStore
    private let datasetStore: DatasetStore
    private let audioFileStore: AudioFileStore
    private let clientFactory: @Sendable (String) -> any HFHubClientProtocol

    private var task: Task<Void, Never>?

    init(
        tokenStore: any HFAuthStore,
        datasetStore: DatasetStore,
        audioFileStore: AudioFileStore,
        clientFactory: @escaping @Sendable (String) -> any HFHubClientProtocol = { HFHubClient(token: $0) }
    ) {
        self.tokenStore = tokenStore
        self.datasetStore = datasetStore
        self.audioFileStore = audioFileStore
        self.clientFactory = clientFactory
    }

    var validationMessage: String? {
        HFPushValidation.destinationError(repoName: repoName, organization: organization)
    }

    var canPush: Bool {
        guard case .loaded(let summary) = summaryState, !summary.isEmpty else { return false }
        return tokenStore.hasToken && validationMessage == nil && !isRunning
    }

    var canCancel: Bool {
        isRunning && !isCancelling && stage != .commit && stage != .done
    }

    /// Loads the aggregate summary shown in the consent block. Failures remain visible and retryable.
    func loadSummary() async {
        switch summaryState {
        case .idle, .failed:
            await recomputeSummary()
        case .loading, .loaded:
            break
        }
    }

    /// A single controller backs every presentation of the sheet. Reset only transient outcome state
    /// and always recompute consent statistics so reopening can never show a stale result or summary.
    func prepareForPresentation() async {
        guard !isRunning else { return }
        result = nil
        errorMessage = nil
        wasCancelled = false
        isCancelling = false
        stage = .prepare
        stageCompleted = 0
        stageTotal = 0
        currentLabel = ""
        await recomputeSummary()
    }

    private func recomputeSummary() async {
        summaryState = .loading
        do {
            summaryState = .loaded(try await datasetStore.computeStatistics())
        } catch {
            NSLog("ThinkAloud: upload summary load failed: \(error)")
            summaryState = .failed(
                String(
                    localized: "ThinkAloud couldn’t load the upload summary. Refresh the dataset and try again."
                )
            )
        }
    }

    func push() {
        guard canPush, let token = tokenStore.token else { return }
        let datasetStore = datasetStore
        let audioFileStore = audioFileStore
        let org = organization.trimmingCharacters(in: .whitespacesAndNewlines)
        let options = HFPushOptions(
            repoName: repoName.trimmingCharacters(in: .whitespacesAndNewlines),
            organization: org.isEmpty ? nil : org,
            isPrivate: isPrivate,
            includeAudio: includeAudio,
            includeSourceApp: includeSourceApp
        )

        isRunning = true
        isCancelling = false
        wasCancelled = false
        result = nil
        errorMessage = nil
        stage = .prepare
        stageCompleted = 0
        stageTotal = 0
        currentLabel = ""

        task = Task { @MainActor [weak self] in
            defer {
                self?.isRunning = false
                self?.isCancelling = false
                self?.task = nil
            }
            guard let self else { return }
            let client = self.clientFactory(token)
            // Resolve owner from whoami so the user doesn't have to type it.
            let owner: String
            do {
                let me = try await client.whoami()
                try Task.checkCancellation()
                owner = me.name
                self.tokenStore.verifiedUsername = me.name
            } catch is CancellationError {
                self.wasCancelled = true
                return
            } catch {
                if Task.isCancelled {
                    self.wasCancelled = true
                } else {
                    NSLog("ThinkAloud: Hugging Face authentication failed: \(error)")
                    self.errorMessage = Self.authenticationMessage(for: error)
                }
                return
            }
            let service = HFPushService(client: client, datasetStore: datasetStore, audioFileStore: audioFileStore, defaultOwner: owner)
            do {
                let res = try await service.push(options: options) { [weak self] p in
                    await MainActor.run {
                        self?.stage = p.stage
                        self?.stageCompleted = p.completed
                        self?.stageTotal = p.total
                        self?.currentLabel = p.currentLabel
                    }
                }
                self.result = res
            } catch is CancellationError {
                self.wasCancelled = true
            } catch let error as HFPushService.PushError {
                NSLog("ThinkAloud: Hugging Face dataset upload failed: \(error)")
                if case .preCommitFailureAndCleanupFailed(
                    _,
                    _,
                    _,
                    let wasCancelled
                ) = error {
                    self.wasCancelled = wasCancelled
                    self.errorMessage = Self.uploadMessage(for: error)
                } else if Task.isCancelled {
                    self.wasCancelled = true
                } else {
                    self.errorMessage = Self.uploadMessage(for: error)
                }
            } catch {
                if Task.isCancelled {
                    self.wasCancelled = true
                } else {
                    NSLog("ThinkAloud: Hugging Face dataset upload failed: \(error)")
                    self.errorMessage = String(
                        localized: "The upload couldn’t finish. Check your connection, repository access, and available storage, then try again."
                    )
                }
            }
        }
    }

    func cancel() {
        guard canCancel else { return }
        isCancelling = true
        task?.cancel()
    }

    private static func authenticationMessage(for error: Error) -> String {
        if let hubError = error as? HFHubClient.HFError {
            return hubError.localizedDescription
        }
        return String(
            localized: "ThinkAloud couldn’t verify the Hugging Face token. Check your connection and token, then try again."
        )
    }

    private static func uploadMessage(for error: HFPushService.PushError) -> String {
        switch error {
        case .emptyDataset:
            return String(localized: "There are no saved records to upload.")
        case .invalidDestination(let message):
            return message
        case .missingAudioFiles(let paths):
            return String(
                localized: "Upload stopped because \(paths.count) saved audio file(s) are missing. Restore the files or turn off Include audio files, then try again."
            )
        case .unreadableAudioFile:
            return String(
                localized: "Upload stopped because a saved audio file couldn’t be read. Restore the file or turn off Include audio files, then try again."
            )
        case .visibilityMismatch:
            return String(
                localized: "Hugging Face reports a different repository visibility than selected. Correct the visibility and try again; no commit was created."
            )
        case .incompletePreuploadResponse(let paths):
            return String(
                localized: "Hugging Face did not return upload instructions for \(paths.count) file(s). Try again later; no commit was created."
            )
        case .ignoredRequiredFiles(let paths):
            return String(
                localized: "Hugging Face refused \(paths.count) required dataset file(s). Check repository access and try again; no commit was created."
            )
        case .filePreparationFailed:
            return String(
                localized: "ThinkAloud couldn’t prepare a local file for upload. Check available storage and folder permissions, then try again."
            )
        case .preCommitFailureAndCleanupFailed(
            let recoveryDirectory,
            _,
            _,
            let wasCancelled
        ):
            if wasCancelled {
                return String(
                    localized: "Upload was cancelled before a commit was created, and temporary files could not be removed. Some uploaded objects may remain on Hugging Face. Remove \(recoveryDirectory.path) manually."
                )
            }
            return String(
                localized: "Upload failed before a commit was created, and temporary files could not be removed. Remove \(recoveryDirectory.path) manually, then try again."
            )
        }
    }
}

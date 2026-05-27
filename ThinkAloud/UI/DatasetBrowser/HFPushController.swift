import Foundation
import Observation

@MainActor
@Observable
final class HFPushController {
    // Form state
    var repoName: String = "thinkaloud-personal"
    var organization: String = ""
    var isPrivate: Bool = true
    var includeAudio: Bool = true

    // Runtime state
    private(set) var isRunning: Bool = false
    private(set) var stage: HFPushProgress.Stage = .prepare
    private(set) var stageCompleted: Int = 0
    private(set) var stageTotal: Int = 0
    private(set) var currentLabel: String = ""
    private(set) var result: HFPushResult?
    private(set) var errorMessage: String?

    private let tokenStore: HFTokenStore
    private let datasetStore: DatasetStore
    private let audioFileStore: AudioFileStore

    private var task: Task<Void, Never>?

    init(tokenStore: HFTokenStore, datasetStore: DatasetStore, audioFileStore: AudioFileStore) {
        self.tokenStore = tokenStore
        self.datasetStore = datasetStore
        self.audioFileStore = audioFileStore
    }

    var canPush: Bool {
        tokenStore.hasToken && !repoName.isEmpty && !isRunning
    }

    func push() {
        guard !isRunning, let token = tokenStore.token else { return }
        let datasetStore = datasetStore
        let audioFileStore = audioFileStore
        let org = organization.trimmingCharacters(in: .whitespacesAndNewlines)
        let options = HFPushOptions(
            repoName: repoName.trimmingCharacters(in: .whitespacesAndNewlines),
            organization: org.isEmpty ? nil : org,
            isPrivate: isPrivate,
            includeAudio: includeAudio
        )

        isRunning = true
        result = nil
        errorMessage = nil
        stage = .prepare
        stageCompleted = 0
        stageTotal = 0
        currentLabel = ""

        task = Task { @MainActor [weak self] in
            defer {
                self?.isRunning = false
                self?.task = nil
            }
            let client = HFHubClient(token: token)
            // Resolve owner from whoami so the user doesn't have to type it.
            let owner: String
            do {
                let me = try await client.whoami()
                owner = me.name
                self?.tokenStore.verifiedUsername = me.name
            } catch {
                self?.errorMessage = String(localized: "Auth failed: \(error.localizedDescription)")
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
                self?.result = res
            } catch is CancellationError {
                self?.errorMessage = String(localized: "Cancelled.")
            } catch {
                self?.errorMessage = String(localized: "Push failed: \(error.localizedDescription)")
            }
        }
    }

    func cancel() {
        task?.cancel()
    }
}

import Foundation
import Observation

@MainActor
@Observable
final class BenchmarkController {
    // Configuration (bound to UI pickers)
    var selectedProfile: ModelProfile
    var selectedPostEdit: PostEditConfig
    var selectedPreEdit: PreEditConfig
    /// When true, CER / exact-match read the aggressive-normalized fields (Whisper-style:
    /// lowercase, strip punctuation, full→half width). When false, they use the strict fields
    /// (whitespace-only normalization). Pure view toggle — both metrics are always computed.
    var useNormalizedMetrics: Bool = true

    // Runtime state
    private(set) var isRunning: Bool = false
    private(set) var progressCompleted: Int = 0
    private(set) var progressTotal: Int = 0
    private(set) var currentRecordID: String?
    /// History of completed runs, newest first. Lets the user compare different model / preference
    /// configurations in one session. Cleared when the browser window closes.
    private(set) var history: [BenchmarkReport] = []
    /// The currently-displayed report from history. Defaults to the newest entry; user can switch.
    var displayedRunAt: String?
    private(set) var errorMessage: String?

    /// One-off feedback flag — view sets to nil after surfacing it.
    var lastExportPath: String?

    // Dependencies
    private let datasetStore: DatasetStore
    private let audioFileStore: AudioFileStore
    private let modelsDirectory: URL

    private var task: Task<Void, Never>?

    init(
        datasetStore: DatasetStore,
        audioFileStore: AudioFileStore,
        modelsDirectory: URL,
        initialProfile: ModelProfile,
        initialPostEdit: PostEditConfig,
        initialPreEdit: PreEditConfig
    ) {
        self.datasetStore = datasetStore
        self.audioFileStore = audioFileStore
        self.modelsDirectory = modelsDirectory
        self.selectedProfile = initialProfile
        self.selectedPostEdit = initialPostEdit
        self.selectedPreEdit = initialPreEdit
    }

    var progressFraction: Double {
        guard progressTotal > 0 else { return 0 }
        return Double(progressCompleted) / Double(progressTotal)
    }

    func run() {
        guard !isRunning else { return }
        let profile = selectedProfile
        let postEdit = selectedPostEdit
        let preEdit = selectedPreEdit
        let datasetStore = datasetStore
        let audioFileStore = audioFileStore
        let modelsDirectory = modelsDirectory

        isRunning = true
        errorMessage = nil
        progressCompleted = 0
        progressTotal = 0
        currentRecordID = nil

        task = Task { @MainActor [weak self] in
            defer {
                self?.isRunning = false
                self?.currentRecordID = nil
                self?.task = nil
            }
            do {
                let records = try await datasetStore.all()
                guard !records.isEmpty else {
                    self?.errorMessage = String(localized: "Dataset is empty — nothing to benchmark.")
                    return
                }
                self?.progressTotal = records.count

                // Transient runtime so the popup's active runtime is undisturbed. It will be
                // unloaded after the run completes.
                let runtime = ASRRuntimeFactory.make(profile: profile, cacheDirectory: modelsDirectory)
                do {
                    try await runtime.preload()
                } catch {
                    self?.errorMessage = String(localized: "Model preload failed: \(error.localizedDescription)")
                    return
                }

                // Transient denoiser, created only when denoise is enabled, unloaded after the run.
                // Build the transient denoiser for .on and .auto (the per-record heuristic decides
                // whether it actually runs); skip it entirely for .off.
                let dfn = preEdit.denoise != .off ? DeepFilterNetRuntime(modelsDirectory: modelsDirectory) : nil

                let runner = BenchmarkRunner()
                let report: BenchmarkReport
                do {
                    report = try await runner.run(
                        records: records,
                        runtime: runtime,
                        postEdit: postEdit,
                        preEdit: preEdit,
                        audioURLProvider: { record in
                            await audioFileStore.absoluteURL(for: record.audioPath)
                        },
                        denoise: dfn.map { d in { @Sendable (samples: [Float]) async throws -> [Float] in try await d.enhance(samples) } },
                        progress: { [weak self] p in
                            await MainActor.run {
                                self?.progressCompleted = p.completed
                                self?.currentRecordID = p.currentRecordID.isEmpty ? nil : p.currentRecordID
                            }
                        }
                    )
                } catch is CancellationError {
                    await runtime.unload()
                    await dfn?.unload()
                    self?.errorMessage = String(localized: "Cancelled.")
                    return
                } catch {
                    await runtime.unload()
                    await dfn?.unload()
                    self?.errorMessage = String(localized: "Benchmark failed: \(error.localizedDescription)")
                    return
                }
                await runtime.unload()
                await dfn?.unload()
                if let self {
                    self.history.insert(report, at: 0)
                    self.displayedRunAt = report.runAt
                }
            } catch {
                self?.errorMessage = String(localized: "Failed to load records: \(error.localizedDescription)")
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    /// The displayed report — either an explicit selection from history or the newest run.
    var displayedReport: BenchmarkReport? {
        if let runAt = displayedRunAt, let hit = history.first(where: { $0.runAt == runAt }) {
            return hit
        }
        return history.first
    }

    /// Encodes the displayed report to pretty-printed JSON and writes it to `url`.
    func exportJSON(to url: URL) throws {
        guard let report = displayedReport else {
            throw NSError(domain: "Benchmark", code: 1, userInfo: [NSLocalizedDescriptionKey: "No report to export"])
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(report)
        try data.write(to: url, options: .atomic)
        lastExportPath = url.path
    }
}

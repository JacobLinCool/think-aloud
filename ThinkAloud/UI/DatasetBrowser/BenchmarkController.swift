import Foundation
import Observation

@MainActor
@Observable
final class BenchmarkController {
    enum Stage: Equatable {
        case idle
        case loadingRecords
        case downloadingModel(estimatedSize: String)
        case loadingModel
        case preparingDenoiser
        case running
    }

    struct RunConfiguration: Equatable {
        let profile: ModelProfile
        let postEdit: PostEditConfig
        let preEdit: PreEditConfig
    }

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
    private(set) var cancellationRequested: Bool = false
    private(set) var progressCompleted: Int = 0
    private(set) var progressTotal: Int = 0
    private(set) var currentRecordID: String?
    private(set) var stage: Stage = .idle
    private(set) var activeConfiguration: RunConfiguration?
    /// History of completed runs, newest first. Lets the user compare different model / preference
    /// configurations in one session. Cleared when the browser window closes.
    private(set) var history: [BenchmarkReport] = []
    /// The currently-displayed report from history. Defaults to the newest entry; user can switch.
    var displayedRunID: String?
    private(set) var errorMessage: String?
    private(set) var exportErrorMessage: String?

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

    var selectedModelIsDownloaded: Bool {
        let snapshot = modelsDirectory
            .appendingPathComponent("mlx-audio", isDirectory: true)
            .appendingPathComponent(selectedProfile.modelID.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
        return ASRRuntimeFactory.hasModelFiles(in: snapshot)
    }

    func run() {
        guard !isRunning else { return }
        let configuration = RunConfiguration(
            profile: selectedProfile,
            postEdit: selectedPostEdit,
            preEdit: selectedPreEdit
        )
        let profile = configuration.profile
        let postEdit = configuration.postEdit
        let preEdit = configuration.preEdit
        let datasetStore = datasetStore
        let audioFileStore = audioFileStore
        let modelsDirectory = modelsDirectory

        isRunning = true
        cancellationRequested = false
        activeConfiguration = configuration
        stage = .loadingRecords
        errorMessage = nil
        progressCompleted = 0
        progressTotal = 0
        currentRecordID = nil

        task = Task { @MainActor [weak self] in
            defer {
                self?.isRunning = false
                self?.currentRecordID = nil
                self?.task = nil
                self?.stage = .idle
                self?.activeConfiguration = nil
                self?.cancellationRequested = false
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
                let snapshot = modelsDirectory
                    .appendingPathComponent("mlx-audio", isDirectory: true)
                    .appendingPathComponent(profile.modelID.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
                self?.stage = ASRRuntimeFactory.hasModelFiles(in: snapshot)
                    ? .loadingModel
                    : .downloadingModel(estimatedSize: profile.estimatedDownloadSize)
                do {
                    try await runtime.preload()
                } catch is CancellationError {
                    await runtime.unload()
                    self?.errorMessage = String(localized: "Benchmark cancelled.")
                    return
                } catch {
                    NSLog("ThinkAloud: benchmark model preparation failed: \(error)")
                    await runtime.unload()
                    self?.errorMessage = String(
                        localized: "The benchmark model couldn’t be prepared. Check Model settings, available storage, and your connection, then retry."
                    )
                    return
                }

                // Transient denoiser, created only when denoise is enabled, unloaded after the run.
                // Build the transient denoiser for .on and .auto (the per-record heuristic decides
                // whether it actually runs); skip it entirely for .off.
                let dfn = preEdit.denoise != .off ? DeepFilterNetRuntime(modelsDirectory: modelsDirectory) : nil
                if let dfn {
                    self?.stage = .preparingDenoiser
                    do {
                        try await dfn.preload()
                    } catch is CancellationError {
                        await runtime.unload()
                        await dfn.unload()
                        self?.errorMessage = String(localized: "Benchmark cancelled.")
                        return
                    } catch {
                        NSLog("ThinkAloud: benchmark audio cleanup preparation failed: \(error)")
                        await runtime.unload()
                        await dfn.unload()
                        self?.errorMessage = String(
                            localized: "Audio cleanup couldn’t be prepared. Choose Off, or check Audio Cleanup settings and retry."
                        )
                        return
                    }
                }

                let runner = BenchmarkRunner()
                let report: BenchmarkReport
                self?.stage = .running
                do {
                    report = try await runner.run(
                        records: records,
                        runtime: runtime,
                        postEdit: postEdit,
                        preEdit: preEdit,
                        audioURLProvider: { record in
                            guard try await audioFileStore.fileExists(relativePath: record.audioPath) else {
                                throw AudioFileStore.StoreError.sourceMissing(record.audioPath)
                            }
                            return try await audioFileStore.validatedAbsoluteURL(for: record.audioPath)
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
                    self?.errorMessage = String(localized: "Benchmark cancelled.")
                    return
                } catch {
                    NSLog("ThinkAloud: benchmark run failed: \(error)")
                    await runtime.unload()
                    await dfn?.unload()
                    self?.errorMessage = String(
                        localized: "The benchmark couldn’t finish. Verify the selected model and saved audio files, then retry."
                    )
                    return
                }
                await runtime.unload()
                await dfn?.unload()
                if let self {
                    self.history.insert(report, at: 0)
                    self.displayedRunID = report.runID
                }
            } catch {
                NSLog("ThinkAloud: benchmark record load failed: \(error)")
                self?.errorMessage = String(
                    localized: "ThinkAloud couldn’t load records for the benchmark. Refresh the dataset and try again."
                )
            }
        }
    }

    func cancel() {
        guard isRunning, !cancellationRequested else { return }
        cancellationRequested = true
        task?.cancel()
    }

    func clearError() {
        errorMessage = nil
    }

    /// The displayed report — either an explicit selection from history or the newest run.
    var displayedReport: BenchmarkReport? {
        if let runID = displayedRunID, let hit = history.first(where: { $0.runID == runID }) {
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
        exportErrorMessage = nil
        lastExportPath = url.path
    }

    func recordExportFailure(_ error: Error) {
        NSLog("ThinkAloud: benchmark report export failed: \(error)")
        exportErrorMessage = String(
            localized: "ThinkAloud couldn’t export the benchmark report. Choose a writable folder and try again."
        )
    }
}

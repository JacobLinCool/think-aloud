import Foundation
import XCTest
@testable import ThinkAloud

final class DictationCoordinatorPersistenceTests: XCTestCase {
    @MainActor
    func testInsertOnlyWritesOneHistorySessionAndNoDatasetAudio() async throws {
        let harness = try await makeHarness(outcomes: [.inserted])
        defer { harness.cleanup() }
        harness.prepareTerminalResult()

        await harness.coordinator.performInsert(save: false)

        let historyCount = try await harness.history.count()
        let datasetCount = try await harness.dataset.count()
        let sessions = try await harness.history.all()
        XCTAssertEqual(historyCount, 1)
        XCTAssertEqual(datasetCount, 0)
        XCTAssertEqual(harness.inserter.callCount, 1)
        XCTAssertEqual(try regularFileCount(at: harness.audioRoot), 0)
        let stats = try await harness.history.computeStatistics()
        XCTAssertEqual(stats.recordCount, 1)
        XCTAssertEqual(sessions.first?.action, .insert)
    }

    @MainActor
    func testInsertAndSaveWritesOneSessionOneDatasetRecordAndOneAudioFile() async throws {
        let harness = try await makeHarness(outcomes: [.inserted])
        defer { harness.cleanup() }
        harness.prepareTerminalResult()

        await harness.coordinator.performInsert(save: true)

        let historyCount = try await harness.history.count()
        let datasetCount = try await harness.dataset.count()
        let sessions = try await harness.history.all()
        XCTAssertEqual(historyCount, 1)
        XCTAssertEqual(datasetCount, 1)
        XCTAssertEqual(harness.inserter.callCount, 1)
        XCTAssertEqual(try regularFileCount(at: harness.audioRoot), 1)
        XCTAssertEqual(sessions.first?.action, .insertAndSave)
    }

    @MainActor
    func testExplicitDeliveryRetryUpsertsSameSessionAndLocksFirstText() async throws {
        let harness = try await makeHarness(outcomes: [.clipboard, .inserted])
        defer { harness.cleanup() }
        harness.prepareTerminalResult(finalText: "first locked text")

        await harness.coordinator.performInsert(save: false)
        let firstCount = try await harness.history.count()
        let firstSessions = try await harness.history.all()
        XCTAssertEqual(firstCount, 1)
        XCTAssertEqual(firstSessions.first?.deliveryOutcome, .clipboard)
        XCTAssertTrue(harness.coordinator.isDeliveryRetry)

        harness.coordinator.viewModel.editedTranscript = "attempted mutation"
        await harness.coordinator.performInsert(save: false)

        let sessions = try await harness.history.all()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].deliveryOutcome, .inserted)
        XCTAssertEqual(sessions[0].finalTranscript, "first locked text")
        XCTAssertEqual(harness.inserter.callCount, 2)
        XCTAssertEqual(harness.inserter.insertedTexts, ["first locked text", "first locked text"])
    }

    @MainActor
    func testHistoryRetryNeverRepeatsInsertion() async throws {
        let harness = try await makeHarness(
            outcomes: [.inserted],
            historyFailures: 1
        )
        defer { harness.cleanup() }
        harness.prepareTerminalResult()

        await harness.coordinator.performInsert(save: false)

        let failedHistoryCount = try await harness.history.count()
        XCTAssertEqual(failedHistoryCount, 0)
        XCTAssertEqual(harness.inserter.callCount, 1)
        guard case .error(let failure) = harness.coordinator.viewModel.phase else {
            return XCTFail("Expected a retryable history failure")
        }
        XCTAssertEqual(failure.kind, .historySave)

        await harness.coordinator.retryPendingPersistence()

        let historyCount = try await harness.history.count()
        let historyAttempts = await harness.historyWriter.attemptCount
        XCTAssertEqual(historyCount, 1)
        XCTAssertEqual(historyAttempts, 2)
        XCTAssertEqual(harness.inserter.callCount, 1)
    }

    @MainActor
    func testDatasetRetryAddsNoDuplicateSessionInsertionOrAudio() async throws {
        let harness = try await makeHarness(
            outcomes: [.inserted],
            datasetFailures: 1
        )
        defer { harness.cleanup() }
        harness.prepareTerminalResult()

        await harness.coordinator.performInsert(save: true)

        let initialHistoryCount = try await harness.history.count()
        let initialDatasetCount = try await harness.dataset.count()
        XCTAssertEqual(initialHistoryCount, 1)
        XCTAssertEqual(initialDatasetCount, 0)
        XCTAssertEqual(try regularFileCount(at: harness.audioRoot), 0)
        XCTAssertEqual(harness.inserter.callCount, 1)
        guard case .error(let failure) = harness.coordinator.viewModel.phase else {
            return XCTFail("Expected a retryable Dataset failure")
        }
        XCTAssertEqual(failure.kind, .datasetSave)

        await harness.coordinator.retryPendingPersistence()

        let historyCount = try await harness.history.count()
        let datasetCount = try await harness.dataset.count()
        let datasetAttempts = await harness.datasetWriter.attemptCount
        XCTAssertEqual(historyCount, 1)
        XCTAssertEqual(datasetCount, 1)
        XCTAssertEqual(datasetAttempts, 2)
        XCTAssertEqual(harness.inserter.callCount, 1)
        XCTAssertEqual(try regularFileCount(at: harness.audioRoot), 1)
    }

    @MainActor
    func testClosingReviewAndTerminalFailuresDoNotCreateHistory() async throws {
        let harness = try await makeHarness(outcomes: [.inserted])
        defer { harness.cleanup() }

        harness.coordinator.viewModel.phase = .error(.noSpeech)
        harness.coordinator.cancel()
        try await waitUntil { harness.coordinator.viewModel.phase == .idle }
        var historyCount = try await harness.history.count()
        XCTAssertEqual(historyCount, 0)

        harness.prepareTerminalResult()
        harness.coordinator.cancel()
        try await waitUntil { harness.coordinator.viewModel.phase == .idle }
        historyCount = try await harness.history.count()
        XCTAssertEqual(historyCount, 0)

        harness.coordinator.viewModel.phase = .error(.transcription(StubError.expected))
        harness.coordinator.cancel()
        try await waitUntil { harness.coordinator.viewModel.phase == .idle }
        historyCount = try await harness.history.count()
        XCTAssertEqual(historyCount, 0)
        XCTAssertEqual(harness.inserter.callCount, 0)
    }

    @MainActor
    private func makeHarness(
        outcomes: [TextInsertionManager.InsertionOutcome],
        historyFailures: Int = 0,
        datasetFailures: Int = 0
    ) async throws -> Harness {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThinkAloudCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let audioRoot = root.appendingPathComponent("audio", isDirectory: true)
        let database = LocalDatabase(fileURL: root.appendingPathComponent("local.sqlite"))
        let dataset = DatasetStore(database: database)
        let history = DictationHistoryStore(database: database)
        try await dataset.setup()
        let audio = AudioFileStore(rootDirectory: audioRoot)
        let recovery = DatasetSaveRecoveryService(
            datasetStore: dataset,
            audioFileStore: audio,
            recoveryRoot: root.appendingPathComponent("Pending Dataset Saves", isDirectory: true)
        )
        let historyWriter = ScriptedHistoryWriter(base: history, failures: historyFailures)
        let datasetWriter = ScriptedDatasetWriter(base: dataset, failures: datasetFailures)
        let inserter = ScriptedInserter(outcomes: outcomes)
        let suiteName = "ThinkAloudCoordinatorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let modelManager = try ModelManager(
            modelsDirectory: root.appendingPathComponent("models", isDirectory: true),
            defaults: defaults
        )
        let llmManager = try LLMManager(
            cacheDirectory: root.appendingPathComponent("llm-models", isDirectory: true),
            defaults: defaults
        )
        let coordinator = PopupCoordinator(
            permissions: PermissionsService(),
            modelManager: modelManager,
            llmManager: llmManager,
            recorder: AudioRecorder(),
            insertion: inserter,
            datasetStore: datasetWriter,
            historyStore: historyWriter,
            audioFileStore: audio,
            datasetSaveRecovery: recovery,
            windowController: NoopPopupWindowPresenter()
        )
        return Harness(
            root: root,
            audioRoot: audioRoot,
            defaultsSuiteName: suiteName,
            coordinator: coordinator,
            inserter: inserter,
            dataset: dataset,
            history: history,
            datasetWriter: datasetWriter,
            historyWriter: historyWriter
        )
    }

    private func regularFileCount(at root: URL) throws -> Int {
        guard FileManager.default.fileExists(atPath: root.path) else { return 0 }
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        return try enumerator.compactMap { item -> URL? in
            guard let url = item as? URL,
                  try url.resourceValues(forKeys: Set(keys)).isRegularFile == true else { return nil }
            return url
        }.count
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ predicate: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !predicate() {
            guard clock.now < deadline else { throw StubError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private enum StubError: Error {
    case expected
    case timedOut
}

@MainActor
private final class ScriptedInserter: TextInserting {
    private var outcomes: [TextInsertionManager.InsertionOutcome]
    private(set) var insertedTexts: [String] = []

    init(outcomes: [TextInsertionManager.InsertionOutcome]) {
        self.outcomes = outcomes
    }

    var callCount: Int { insertedTexts.count }

    func insert(
        _ text: String,
        into _: FocusContext?
    ) async -> TextInsertionManager.InsertionOutcome {
        insertedTexts.append(text)
        precondition(!outcomes.isEmpty, "Each expected insertion attempt needs a scripted outcome")
        return outcomes.removeFirst()
    }
}

private extension TextInsertionManager.InsertionOutcome {
    static let inserted = Self(
        inserted: true,
        copiedToClipboard: false,
        message: "Inserted.",
        requiresAttention: false
    )

    static let clipboard = Self(
        inserted: false,
        copiedToClipboard: true,
        message: "Copied.",
        requiresAttention: true
    )
}

private actor ScriptedHistoryWriter: DictationHistoryWriting {
    private let base: DictationHistoryStore
    private var failuresRemaining: Int
    private(set) var attemptCount = 0

    init(base: DictationHistoryStore, failures: Int) {
        self.base = base
        self.failuresRemaining = failures
    }

    func save(_ session: DictationSession) async throws {
        attemptCount += 1
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw StubError.expected
        }
        try await base.save(session)
    }
}

private actor ScriptedDatasetWriter: DatasetRecordWriting {
    private let base: DatasetStore
    private var failuresRemaining: Int
    private(set) var attemptCount = 0

    init(base: DatasetStore, failures: Int) {
        self.base = base
        self.failuresRemaining = failures
    }

    func save(_ record: DatasetRecord) async throws {
        attemptCount += 1
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw StubError.expected
        }
        try await base.save(record)
    }
}

@MainActor
private final class NoopPopupWindowPresenter: PopupWindowPresenting {
    private(set) var isVisible = false

    func show(
        viewModel _: PopupViewModel,
        coordinator _: PopupCoordinator,
        modelManager _: ModelManager
    ) {
        isVisible = true
    }

    func close() {
        isVisible = false
    }
}

@MainActor
private struct Harness {
    let root: URL
    let audioRoot: URL
    let defaultsSuiteName: String
    let coordinator: PopupCoordinator
    let inserter: ScriptedInserter
    let dataset: DatasetStore
    let history: DictationHistoryStore
    let datasetWriter: ScriptedDatasetWriter
    let historyWriter: ScriptedHistoryWriter

    func prepareTerminalResult(finalText: String = "final text") {
        coordinator.viewModel.focusContext = FocusContext(
            appBundleID: "com.apple.TextEdit",
            appName: "TextEdit",
            processID: nil,
            timestamp: Date(timeIntervalSince1970: 1_785_600_000)
        )
        coordinator.acceptTerminalResult(
            recording: RecordingResult(
                samples: Array(repeating: 0.01, count: 4_800),
                sampleRate: 48_000,
                channels: 1,
                durationSeconds: 0.1,
                startedAt: Date(timeIntervalSince1970: 1_785_600_000)
            ),
            result: ASRResult(
                text: "raw text",
                language: "en",
                modelID: "test/model",
                runtimeID: "test-runtime",
                durationMs: 50
            ),
            rawTranscript: "raw text",
            autoEditedTranscript: "auto text"
        )
        coordinator.viewModel.editedTranscript = finalText
    }

    func cleanup() {
        UserDefaults.standard.removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: root)
    }
}

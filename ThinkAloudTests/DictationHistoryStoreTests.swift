import GRDB
import XCTest
@testable import ThinkAloud

final class DictationHistoryStoreTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() async throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThinkAloudHistoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    func testRoundTripPersistsCompleteTextAndMetadataWithoutAudioColumn() async throws {
        let databaseURL = tempDirectory.appendingPathComponent("local.sqlite")
        let store = DictationHistoryStore(databaseURL: databaseURL)
        try await store.setup()

        let session = makeSession(id: "session_complete", outcome: .clipboard)
        try await store.save(session)

        let fetched = try await store.fetch(id: session.id)
        XCTAssertEqual(fetched, session)
        let database = try DatabaseQueue(path: databaseURL.path)
        let columns = try await database.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('dictation_sessions')")
        }
        XCTAssertFalse(columns.contains("audio_path"))
        XCTAssertFalse(columns.contains(where: { $0.localizedCaseInsensitiveContains("audio_data") }))
    }

    func testRetryUpsertsStableSessionIDInsteadOfDoubleCounting() async throws {
        let store = DictationHistoryStore(
            databaseURL: tempDirectory.appendingPathComponent("retry.sqlite")
        )
        try await store.setup()

        var session = makeSession(id: "session_stable", outcome: .failed)
        try await store.save(session)
        session.deliveryOutcome = .inserted
        session.finalTranscript = "The first Insert snapshot remains canonical."
        try await store.save(session)

        let count = try await store.count()
        let fetched = try await store.fetch(id: session.id)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(fetched, session)
    }

    func testAllDeliveryOutcomesFeedUsageMetricsIncludingTimeSaved() async throws {
        let store = DictationHistoryStore(
            databaseURL: tempDirectory.appendingPathComponent("outcomes.sqlite")
        )
        try await store.setup()

        for (index, outcome) in DictationDeliveryOutcome.allCases.enumerated() {
            var session = makeSession(id: "session_\(index)", outcome: outcome)
            session.createdAt = "2026-08-0\(index + 1)T10:00:00Z"
            session.durationMs = 1_000
            session.finalTranscript = String(repeating: "useful dictation ", count: 20)
            session.autoEditedTranscript = session.finalTranscript
            session.llmEditedTranscript = nil
            try await store.save(session)
        }

        let stats = try await store.computeStatistics()
        XCTAssertEqual(stats.recordCount, 3)
        XCTAssertEqual(stats.insertedCount, 1)
        XCTAssertEqual(stats.productivity.recordCount, 3)
        XCTAssertEqual(stats.productivity.spokenSeconds, 3, accuracy: 0.001)
        XCTAssertGreaterThan(stats.productivity.timeSavedSeconds, 0)
        XCTAssertEqual(stats.activeDayCount, 3)
    }

    func testUsageBreakdownsAndCleanRateComeOnlyFromHistory() async throws {
        let database = LocalDatabase(
            fileURL: tempDirectory.appendingPathComponent("separated.sqlite")
        )
        let dataset = DatasetStore(database: database)
        let history = DictationHistoryStore(database: database)
        try await dataset.setup()

        try await dataset.save(makeDatasetRecord(id: "dataset_only"))
        let emptyUsage = try await history.computeStatistics()
        XCTAssertTrue(emptyUsage.isEmpty)

        var session = makeSession(id: "usage_only", outcome: .failed)
        session.asrModel = "usage/model"
        session.sourceAppBundleID = "com.apple.Notes"
        session.sourceAppName = "Notes"
        session.autoEditedTranscript = "automatic"
        session.finalTranscript = "manual"
        try await history.save(session)

        let usage = try await history.computeStatistics()
        let datasetStats = try await dataset.computeStatistics()
        XCTAssertEqual(usage.recordCount, 1)
        XCTAssertEqual(usage.byModel.map(\.key), ["usage/model"])
        XCTAssertEqual(usage.byApp.map(\.key), ["com.apple.Notes"])
        XCTAssertEqual(usage.editing.eligibleCount, 1)
        XCTAssertEqual(usage.editing.cleanCount, 0)
        XCTAssertEqual(datasetStats.recordCount, 1)
        XCTAssertEqual(datasetStats.byModel.map(\.key), ["dataset/model"])
    }

    func testDatasetDeletionDoesNotChangeHistory() async throws {
        let database = LocalDatabase(
            fileURL: tempDirectory.appendingPathComponent("deletion.sqlite")
        )
        let dataset = DatasetStore(database: database)
        let history = DictationHistoryStore(database: database)
        try await dataset.setup()
        try await dataset.save(makeDatasetRecord(id: "favorite"))
        try await history.save(makeSession(id: "usage", outcome: .inserted))

        _ = try await dataset.deleteAll()

        let datasetCount = try await dataset.count()
        let historyCount = try await history.count()
        let usage = try await history.computeStatistics()
        XCTAssertEqual(datasetCount, 0)
        XCTAssertEqual(historyCount, 1)
        XCTAssertEqual(usage.recordCount, 1)
    }

    @MainActor
    func testUsageAchievementsStartAtZeroAndRetiredDatasetStateIsRemoved() async throws {
        let history = DictationHistoryStore(
            databaseURL: tempDirectory.appendingPathComponent("achievements.sqlite")
        )
        try await history.setup()
        let suiteName = "ThinkAloudHistoryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(["sessions.100", "time.30"], forKey: "ThinkAloud.achievements.unlocked")
        defaults.set(true, forKey: "ThinkAloud.achievements.baselineEstablished")

        let service = AchievementService(historyStore: history, defaults: defaults)
        await service.refresh()

        XCTAssertTrue(service.unlockedIDs.isEmpty)
        XCTAssertTrue(service.stats.isEmpty)
        XCTAssertNil(defaults.object(forKey: "ThinkAloud.achievements.unlocked"))
        XCTAssertNil(defaults.object(forKey: "ThinkAloud.achievements.baselineEstablished"))
    }

    func testMigrationPreserves127DatasetRecordsAndAudioWhileStartingHistoryEmpty() async throws {
        let databaseURL = tempDirectory.appendingPathComponent("legacy.sqlite")
        let audioDirectory = tempDirectory.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        try createPreSeparationDatabase(at: databaseURL, recordCount: 127)
        let sentinelURL = audioDirectory.appendingPathComponent("rec_126.wav")
        let sentinelData = Data("unchanged-audio".utf8)
        try sentinelData.write(to: sentinelURL)

        let database = LocalDatabase(fileURL: databaseURL)
        let dataset = DatasetStore(database: database)
        let history = DictationHistoryStore(database: database)
        try await dataset.setup()

        let datasetCount = try await dataset.count()
        let historyCount = try await history.count()
        let sentinelRecord = try await dataset.fetch(id: "rec_126")
        XCTAssertEqual(datasetCount, 127)
        XCTAssertEqual(historyCount, 0)
        XCTAssertEqual(sentinelRecord?.rawTranscript, "raw 126")
        XCTAssertEqual(try Data(contentsOf: sentinelURL), sentinelData)

        let queue = try DatabaseQueue(path: databaseURL.path)
        let savedFlagCount = try await queue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM pragma_table_info('records') WHERE name = 'saved_to_dataset'"
            ) ?? -1
        }
        XCTAssertEqual(savedFlagCount, 0)
    }

    private func makeSession(
        id: String,
        outcome: DictationDeliveryOutcome
    ) -> DictationSession {
        DictationSession(
            id: id,
            createdAt: "2026-08-03T00:00:00Z",
            durationMs: 2_000,
            sampleRate: 48_000,
            channels: 1,
            sourceAppBundleID: "com.apple.TextEdit",
            sourceAppName: "TextEdit",
            asrProvider: "mlx-audio-swift",
            asrModel: "usage/model",
            asrRuntime: "usage-runtime",
            language: "en",
            transcriptionDurationMs: 420,
            rawTranscript: "raw text",
            autoEditedTranscript: "auto text",
            llmEditedTranscript: "refined text",
            finalTranscript: "final text",
            action: .insert,
            deliveryOutcome: outcome
        )
    }

    private func makeDatasetRecord(id: String) -> DatasetRecord {
        DatasetRecord(
            id: id,
            createdAt: "2026-08-03T00:00:00Z",
            audioPath: "audio/\(id).wav",
            durationMs: 2_000,
            sampleRate: 48_000,
            channels: 1,
            sourceAppBundleID: nil,
            sourceAppName: nil,
            asrProvider: "mlx-audio-swift",
            asrModel: "dataset/model",
            asrRuntime: "dataset-runtime",
            asrConfigJSON: nil,
            rawTranscript: "dataset raw",
            editedTranscript: "dataset edited",
            inserted: true,
            language: "en",
            metadataJSON: nil,
            autoEditedTranscript: "dataset edited"
        )
    }

    private func createPreSeparationDatabase(at url: URL, recordCount: Int) throws {
        let queue = try DatabaseQueue(path: url.path)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createRecords") { db in
            try db.execute(sql: """
                CREATE TABLE records (
                    id TEXT PRIMARY KEY NOT NULL,
                    created_at TEXT NOT NULL,
                    audio_path TEXT NOT NULL,
                    duration_ms INTEGER,
                    sample_rate INTEGER,
                    channels INTEGER,
                    source_app_bundle_id TEXT,
                    source_app_name TEXT,
                    asr_provider TEXT NOT NULL,
                    asr_model TEXT NOT NULL,
                    asr_runtime TEXT NOT NULL,
                    asr_config_json TEXT,
                    raw_transcript TEXT NOT NULL,
                    edited_transcript TEXT NOT NULL,
                    inserted INTEGER NOT NULL,
                    saved_to_dataset INTEGER NOT NULL,
                    language TEXT,
                    metadata_json TEXT,
                    auto_edited_transcript TEXT,
                    llm_edited_transcript TEXT
                )
                """)
            try db.create(index: "records_created_at", on: "records", columns: ["created_at"])
            for index in 0..<recordCount {
                try db.execute(
                    sql: """
                        INSERT INTO records (
                            id, created_at, audio_path, duration_ms, sample_rate, channels,
                            asr_provider, asr_model, asr_runtime, raw_transcript,
                            edited_transcript, inserted, saved_to_dataset, language,
                            auto_edited_transcript
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        "rec_\(index)", "2026-08-03T00:00:00Z", "audio/rec_\(index).wav",
                        1_000, 48_000, 1, "provider", "dataset/model", "runtime",
                        "raw \(index)", "edited \(index)", 1, 1, "en", "edited \(index)"
                    ]
                )
            }
        }
        migrator.registerMigration("addAutoEditedTranscript") { _ in }
        migrator.registerMigration("addLLMEditedTranscript") { _ in }
        try migrator.migrate(queue)
    }
}

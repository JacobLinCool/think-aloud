import XCTest
import GRDB
@testable import ThinkAloud

final class DatasetStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ThinkAloudTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testRoundTripSaveAndFetch() async throws {
        let dbURL = tempDir.appendingPathComponent("dataset.sqlite")
        let store = DatasetStore(databaseURL: dbURL)
        try await store.setup()

        let record = DatasetRecord(
            id: "rec_test_001",
            createdAt: "2026-05-28T10:00:00Z",
            audioPath: "audio/2026-05-28/rec_test_001.wav",
            durationMs: 1234,
            sampleRate: 16000,
            channels: 1,
            sourceAppBundleID: "com.apple.TextEdit",
            sourceAppName: "TextEdit",
            asrProvider: "mlx-audio-swift",
            asrModel: "mlx-community/Qwen3-ASR-1.7B-4bit",
            asrRuntime: "mlx-audio-swift-qwen3-asr",
            asrConfigJSON: nil,
            rawTranscript: "raw",
            editedTranscript: "edited",
            inserted: true,
            language: "zh",
            metadataJSON: nil,
            autoEditedTranscript: "auto edited"
        )
        try await store.save(record)

        let count = try await store.count()
        XCTAssertEqual(count, 1)

        let all = try await store.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first, record)
    }

    private func storeCount(_ store: DatasetStore) async throws -> Int {
        try await store.count()
    }

    func testCanonicalAutoEditedTranscriptRoundTrips() async throws {
        let dbURL = tempDir.appendingPathComponent("dataset.sqlite")
        let store = DatasetStore(databaseURL: dbURL)
        try await store.setup()

        var record = makeRecord(
            id: "rec_auto",
            createdAt: "2026-06-05T10:00:00Z",
            raw: "raw model",
            edited: "final text"
        )
        record.autoEditedTranscript = "auto formatted"
        try await store.save(record)
        let fetchedAuto = try await store.fetch(id: "rec_auto")
        XCTAssertEqual(fetchedAuto?.autoEditedTranscript, "auto formatted")
    }

    func testFreshSchemaKeepsAutoEditedTranscriptNullableForHistoricalRows() async throws {
        let dbURL = tempDir.appendingPathComponent("fresh-schema.sqlite")
        let store = DatasetStore(databaseURL: dbURL)
        try await store.setup()

        let database = try DatabaseQueue(path: dbURL.path)
        let notNull = try await database.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT "notnull"
                    FROM pragma_table_info('records')
                    WHERE name = 'auto_edited_transcript'
                    """
            )
        }
        XCTAssertEqual(notNull, 0)
    }

    func testSetupPreservesLegacyNullAutoEditedTranscriptWithoutBackfill() async throws {
        let dbURL = tempDir.appendingPathComponent("legacy.sqlite")
        try createPreCanonicalDatabase(at: dbURL)

        let store = DatasetStore(databaseURL: dbURL)
        try await store.setup()
        let legacyRecord = try await store.fetch(id: "rec_missing_auto")
        XCTAssertNotNil(legacyRecord)
        XCTAssertNil(legacyRecord?.autoEditedTranscript)

        let database = try DatabaseQueue(path: dbURL.path)
        let state = try await database.read { db in
            let nullCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM records WHERE auto_edited_transcript IS NULL"
            )
            let notNull = try Int.fetchOne(
                db,
                sql: """
                    SELECT "notnull"
                    FROM pragma_table_info('records')
                    WHERE name = 'auto_edited_transcript'
                    """
            )
            return (nullCount, notNull)
        }
        XCTAssertEqual(state.0, 1, "setup must not guess or backfill historical content")
        XCTAssertEqual(state.1, 0, "the historical column must remain nullable")
    }

    func testSaveRejectsNewRecordWithoutAutoEditedTranscript() async throws {
        let dbURL = tempDir.appendingPathComponent("required-new-record.sqlite")
        let store = DatasetStore(databaseURL: dbURL)
        try await store.setup()

        var record = makeRecord(id: "missing-auto", createdAt: "2026-08-01T00:00:00Z")
        record.autoEditedTranscript = nil

        do {
            try await store.save(record)
            XCTFail("Expected new records without Auto Post-Edit text to be rejected")
        } catch DatasetStore.StoreError.missingRequiredAutoEditedTranscript(let recordID) {
            XCTAssertEqual(recordID, "missing-auto")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let storedCount = try await store.count()
        XCTAssertEqual(storedCount, 0)
    }

    func testDeleteAll() async throws {
        let dbURL = tempDir.appendingPathComponent("dataset.sqlite")
        let store = DatasetStore(databaseURL: dbURL)
        try await store.setup()

        for i in 0..<3 {
            let record = DatasetRecord(
                id: "rec_\(i)",
                createdAt: "2026-05-28T10:00:0\(i)Z",
                audioPath: "audio/2026-05-28/rec_\(i).wav",
                durationMs: 100,
                sampleRate: 16000,
                channels: 1,
                sourceAppBundleID: nil,
                sourceAppName: nil,
                asrProvider: "mlx-audio-swift",
                asrModel: "model",
                asrRuntime: "runtime",
                asrConfigJSON: nil,
                rawTranscript: "raw",
                editedTranscript: "edit",
                inserted: false,
                language: nil,
                metadataJSON: nil,
                autoEditedTranscript: "edit"
            )
            try await store.save(record)
        }
        let preCount = try await store.count()
        XCTAssertEqual(preCount, 3)
        try await store.deleteAll()
        let postCount = try await store.count()
        XCTAssertEqual(postCount, 0)
    }

    func testPagePaginatesNewestFirst() async throws {
        let dbURL = tempDir.appendingPathComponent("dataset.sqlite")
        let store = DatasetStore(databaseURL: dbURL)
        try await store.setup()
        for i in 0..<5 {
            try await store.save(makeRecord(id: "rec_\(i)", createdAt: "2026-05-29T10:00:0\(i)Z"))
        }
        let firstPage = try await store.page(offset: 0, limit: 3)
        XCTAssertEqual(firstPage.map(\.id), ["rec_4", "rec_3", "rec_2"])
        let secondPage = try await store.page(offset: 3, limit: 3)
        XCTAssertEqual(secondPage.map(\.id), ["rec_1", "rec_0"])
    }

    func testFetchByID() async throws {
        let dbURL = tempDir.appendingPathComponent("dataset.sqlite")
        let store = DatasetStore(databaseURL: dbURL)
        try await store.setup()
        try await store.save(makeRecord(id: "rec_one", createdAt: "2026-05-29T10:00:00Z"))
        let hit = try await store.fetch(id: "rec_one")
        XCTAssertEqual(hit?.id, "rec_one")
        let miss = try await store.fetch(id: "missing")
        XCTAssertNil(miss)
    }

    func testUpdateOverwritesEditedTranscriptOnly() async throws {
        let dbURL = tempDir.appendingPathComponent("dataset.sqlite")
        let store = DatasetStore(databaseURL: dbURL)
        try await store.setup()
        let initial = makeRecord(id: "rec_e", createdAt: "2026-05-29T10:00:00Z", raw: "原始輸出", edited: "原始輸出")
        try await store.save(initial)

        try await store.update(id: "rec_e", editedTranscript: "我修過了")
        let after = try await store.fetch(id: "rec_e")
        XCTAssertEqual(after?.rawTranscript, "原始輸出", "raw must never change")
        XCTAssertEqual(after?.editedTranscript, "我修過了")

        // Re-edit overwrites — no history kept.
        try await store.update(id: "rec_e", editedTranscript: "我又修了一次")
        let final = try await store.fetch(id: "rec_e")
        XCTAssertEqual(final?.editedTranscript, "我又修了一次")
        XCTAssertEqual(final?.rawTranscript, "原始輸出")
    }

    func testUpdateMissingIDFailsInsteadOfReportingSuccess() async throws {
        let store = DatasetStore(databaseURL: tempDir.appendingPathComponent("dataset.sqlite"))
        try await store.setup()

        do {
            try await store.update(id: "missing", editedTranscript: "must not appear saved")
            XCTFail("Expected a precise missing-record error")
        } catch let error as DatasetStore.StoreError {
            guard case .recordsNotFound(let ids) = error else {
                return XCTFail("Unexpected store error: \(error)")
            }
            XCTAssertEqual(ids, ["missing"])
        }
    }

    func testDeleteByID() async throws {
        let dbURL = tempDir.appendingPathComponent("dataset.sqlite")
        let store = DatasetStore(databaseURL: dbURL)
        try await store.setup()
        try await store.save(makeRecord(id: "rec_keep", createdAt: "2026-05-29T10:00:00Z"))
        try await store.save(makeRecord(id: "rec_drop", createdAt: "2026-05-29T10:00:01Z"))
        try await store.delete(id: "rec_drop")
        let count = try await store.count()
        XCTAssertEqual(count, 1)
        let survivor = try await store.fetch(id: "rec_keep")
        XCTAssertNotNil(survivor)
    }

    func testDeleteMissingIDFailsInsteadOfReportingSuccess() async throws {
        let store = DatasetStore(databaseURL: tempDir.appendingPathComponent("dataset.sqlite"))
        try await store.setup()

        do {
            try await store.delete(id: "missing")
            XCTFail("Expected a precise missing-record error")
        } catch let error as DatasetStore.StoreError {
            guard case .recordsNotFound(let ids) = error else {
                return XCTFail("Unexpected store error: \(error)")
            }
            XCTAssertEqual(ids, ["missing"])
        }
    }

    func testBulkDeleteIsAllOrNothingWhenAnyIDIsMissing() async throws {
        let store = DatasetStore(databaseURL: tempDir.appendingPathComponent("dataset.sqlite"))
        try await store.setup()
        try await store.save(makeRecord(id: "present", createdAt: "2026-05-29T10:00:00Z"))

        do {
            try await store.delete(ids: ["present", "missing"])
            XCTFail("Expected bulk delete to fail")
        } catch {}

        let survivor = try await store.fetch(id: "present")
        XCTAssertNotNil(survivor)
    }

    func testSearchQueriesEntireStoreAndPaginatesNewestFirst() async throws {
        let store = DatasetStore(databaseURL: tempDir.appendingPathComponent("dataset.sqlite"))
        try await store.setup()
        for i in 0..<75 {
            var record = makeRecord(
                id: "rec_\(i)",
                createdAt: String(format: "2026-05-29T10:%02d:00Z", i)
            )
            record.editedTranscript = i >= 60 ? "needle \(i)" : "ordinary \(i)"
            try await store.save(record)
        }

        let first = try await store.search(query: "needle", offset: 0, limit: 10)
        XCTAssertEqual(first.totalCount, 15)
        XCTAssertEqual(first.records.map(\.id), (65...74).reversed().map { "rec_\($0)" })
        XCTAssertTrue(first.hasMore)

        let second = try await store.search(query: "needle", offset: 10, limit: 10)
        XCTAssertEqual(second.records.map(\.id), (60...64).reversed().map { "rec_\($0)" })
        XCTAssertFalse(second.hasMore)
    }

    func testSearchCoversIDRawTranscriptAndSourceApp() async throws {
        let store = DatasetStore(databaseURL: tempDir.appendingPathComponent("dataset.sqlite"))
        try await store.setup()
        var record = makeRecord(id: "special_id", createdAt: "2026-05-29T10:00:00Z")
        record.rawTranscript = "raw phrase"
        record.sourceAppName = "TextEdit"
        record.sourceAppBundleID = "com.apple.TextEdit"
        try await store.save(record)

        let idResult = try await store.search(query: "special_id", offset: 0, limit: 10)
        let rawResult = try await store.search(query: "raw phrase", offset: 0, limit: 10)
        let appResult = try await store.search(query: "textedit", offset: 0, limit: 10)
        XCTAssertEqual(idResult.totalCount, 1)
        XCTAssertEqual(rawResult.totalCount, 1)
        XCTAssertEqual(appResult.totalCount, 1)
    }

    func testSearchTreatsLikeWildcardsAsLiteralCharacters() async throws {
        let store = DatasetStore(databaseURL: tempDir.appendingPathComponent("dataset.sqlite"))
        try await store.setup()
        var literal = makeRecord(id: "literal", createdAt: "2026-05-29T10:00:00Z")
        literal.editedTranscript = "100%_done"
        try await store.save(literal)
        try await store.save(makeRecord(id: "ordinary", createdAt: "2026-05-29T10:00:01Z"))

        let result = try await store.search(query: "%_", offset: 0, limit: 10)
        XCTAssertEqual(result.records.map(\.id), ["literal"])
    }

    func testTotalAudioBytesThrowsWhenRootCannotBeEnumerated() async throws {
        let store = DatasetStore(databaseURL: tempDir.appendingPathComponent("unused.sqlite"))
        let missingRoot = tempDir.appendingPathComponent("missing-audio", isDirectory: true)

        do {
            _ = try await store.totalAudioBytes(rootDirectory: missingRoot)
            XCTFail("Expected unreadable audio storage to be reported")
        } catch let error as DatasetStore.StoreError {
            switch error {
            case .audioStorageEnumerationFailed, .audioStorageMetadataFailed:
                break
            default:
                return XCTFail("Unexpected storage error: \(error)")
            }
        }
    }

    func testTotalAudioBytesCountsOnlyRegularFiles() async throws {
        let store = DatasetStore(databaseURL: tempDir.appendingPathComponent("unused.sqlite"))
        let root = tempDir.appendingPathComponent("audio", isDirectory: true)
        let nested = root.appendingPathComponent("2026-07-31", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 32).write(to: nested.appendingPathComponent("record.wav"))

        let bytes = try await store.totalAudioBytes(rootDirectory: root)

        XCTAssertGreaterThanOrEqual(bytes, 32)
    }

    @MainActor
    func testBrowserDraftBlocksSelectionUntilSaved() async throws {
        let dbURL = tempDir.appendingPathComponent("browser-draft.sqlite")
        let store = DatasetStore(databaseURL: dbURL)
        try await store.setup()
        let first = makeRecord(id: "rec_first", createdAt: "2026-05-29T10:00:00Z", edited: "before")
        let second = makeRecord(id: "rec_second", createdAt: "2026-05-29T10:00:01Z")
        try await store.save(first)
        try await store.save(second)
        let audioStore = AudioFileStore(rootDirectory: tempDir.appendingPathComponent("audio"))
        let controller = DatasetBrowserController(
            datasetStore: store,
            audioFileStore: audioStore,
            deletionService: DatasetDeletionService(
                datasetStore: store,
                audioFileStore: audioStore,
                recoveryRoot: tempDir.appendingPathComponent("recoveries")
            )
        )
        await controller.reload()
        controller.selectedIDs = [first.id]
        controller.beginEditing(first)
        controller.editDraft = "after"

        controller.requestSelection([second.id])
        XCTAssertEqual(controller.selectedIDs, [first.id])
        XCTAssertTrue(controller.isAwaitingSelectionDecision)
        XCTAssertTrue(controller.hasUnsavedDraft)

        await controller.saveAndApplyPendingSelection([second.id])
        XCTAssertEqual(controller.selectedIDs, [second.id])
        XCTAssertFalse(controller.hasUnsavedDraft)
        let saved = try await store.fetch(id: first.id)
        XCTAssertEqual(saved?.editedTranscript, "after")
    }

    @MainActor
    func testBrowserSaveFailureKeepsDraftAndSelection() async {
        let uninitializedStore = DatasetStore(databaseURL: tempDir.appendingPathComponent("not-setup.sqlite"))
        let record = makeRecord(id: "rec_draft", createdAt: "2026-05-29T10:00:00Z", edited: "before")
        let audioStore = AudioFileStore(rootDirectory: tempDir.appendingPathComponent("audio"))
        let controller = DatasetBrowserController(
            datasetStore: uninitializedStore,
            audioFileStore: audioStore,
            deletionService: DatasetDeletionService(
                datasetStore: uninitializedStore,
                audioFileStore: audioStore,
                recoveryRoot: tempDir.appendingPathComponent("recoveries")
            )
        )
        controller.selectedIDs = [record.id]
        controller.beginEditing(record)
        controller.editDraft = "must survive"
        controller.requestSelection(["another"])

        await controller.saveAndApplyPendingSelection(["another"])

        XCTAssertEqual(controller.selectedIDs, [record.id])
        XCTAssertEqual(controller.editDraft, "must survive")
        XCTAssertTrue(controller.hasUnsavedDraft)
        XCTAssertNotNil(controller.editErrorMessage)
    }

    @MainActor
    func testBrowserSearchMatchesTranscriptAppAndID() async throws {
        let dbURL = tempDir.appendingPathComponent("browser-search.sqlite")
        let store = DatasetStore(databaseURL: dbURL)
        try await store.setup()
        var record = makeRecord(id: "rec_searchable", createdAt: "2026-05-29T10:00:00Z", raw: "raw phrase", edited: "修正版")
        record.sourceAppName = "Notes"
        try await store.save(record)
        let audioStore = AudioFileStore(rootDirectory: tempDir.appendingPathComponent("audio"))
        let controller = DatasetBrowserController(
            datasetStore: store,
            audioFileStore: audioStore,
            deletionService: DatasetDeletionService(
                datasetStore: store,
                audioFileStore: audioStore,
                recoveryRoot: tempDir.appendingPathComponent("recoveries")
            )
        )
        await controller.reload()

        for query in ["修正版", "raw phrase", "notes", "searchable"] {
            await controller.applySearch(query)
            XCTAssertEqual(controller.filteredRecords.map(\.id), [record.id])
        }
        await controller.applySearch("missing")
        XCTAssertTrue(controller.filteredRecords.isEmpty)
    }

    @MainActor
    func testBrowserSearchFindsRecordBeyondInitiallyLoadedPage() async throws {
        let dbURL = tempDir.appendingPathComponent("browser-full-search.sqlite")
        let store = DatasetStore(databaseURL: dbURL)
        try await store.setup()
        try await store.save(
            makeRecord(
                id: "rec_old_target",
                createdAt: "2026-05-28T00:00:00Z",
                edited: "needle beyond first page"
            )
        )
        for index in 0..<55 {
            try await store.save(
                makeRecord(
                    id: "rec_new_\(index)",
                    createdAt: String(format: "2026-05-29T10:00:%02dZ", index),
                    edited: "ordinary"
                )
            )
        }
        let audioStore = AudioFileStore(rootDirectory: tempDir.appendingPathComponent("audio"))
        let controller = DatasetBrowserController(
            datasetStore: store,
            audioFileStore: audioStore,
            deletionService: DatasetDeletionService(
                datasetStore: store,
                audioFileStore: audioStore,
                recoveryRoot: tempDir.appendingPathComponent("recoveries")
            )
        )

        await controller.reload()
        XCTAssertFalse(controller.records.contains { $0.id == "rec_old_target" })

        await controller.applySearch("needle beyond")
        XCTAssertEqual(controller.records.map(\.id), ["rec_old_target"])
        XCTAssertEqual(controller.totalMatchingRecords, 1)
    }

    @MainActor
    func testBrowserDeleteUsesAtomicServiceAndSurfacesMissingAudioWarning() async throws {
        let dbURL = tempDir.appendingPathComponent("browser-delete.sqlite")
        let store = DatasetStore(databaseURL: dbURL)
        try await store.setup()
        let record = makeRecord(id: "rec_missing_audio", createdAt: "2026-05-29T10:00:00Z")
        try await store.save(record)
        let audioStore = AudioFileStore(rootDirectory: tempDir.appendingPathComponent("audio"))
        let controller = DatasetBrowserController(
            datasetStore: store,
            audioFileStore: audioStore,
            deletionService: DatasetDeletionService(
                datasetStore: store,
                audioFileStore: audioStore,
                recoveryRoot: tempDir.appendingPathComponent("recoveries")
            )
        )
        await controller.reload()
        controller.selectedIDs = [record.id]

        await controller.deleteAll(ids: [record.id])

        XCTAssertTrue(controller.records.isEmpty)
        XCTAssertTrue(controller.selectedIDs.isEmpty)
        XCTAssertNotNil(controller.actionErrorMessage)
        let deleted = try await store.fetch(id: record.id)
        XCTAssertNil(deleted)
    }

    func testBenchmarkRunIDsRemainUniqueWithinSameSecond() {
        let ids = (0..<1_000).map { _ in BenchmarkReport.makeRunID() }
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    @MainActor
    func testBrowserAudioURLRejectsInvalidOrMissingPaths() async throws {
        let store = DatasetStore(databaseURL: tempDir.appendingPathComponent("browser-audio.sqlite"))
        try await store.setup()
        let audioStore = AudioFileStore(rootDirectory: tempDir.appendingPathComponent("audio"))
        let controller = DatasetBrowserController(
            datasetStore: store,
            audioFileStore: audioStore,
            deletionService: DatasetDeletionService(
                datasetStore: store,
                audioFileStore: audioStore,
                recoveryRoot: tempDir.appendingPathComponent("recoveries")
            )
        )
        var invalid = makeRecord(id: "rec_invalid_audio", createdAt: "2026-05-29T10:00:00Z")
        invalid.audioPath = "audio/../outside.wav"
        do {
            _ = try await controller.audioURL(for: invalid)
            XCTFail("Expected invalid audio path to fail")
        } catch AudioFileStore.StoreError.invalidRelativePath(_) {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let missing = makeRecord(id: "rec_missing_audio", createdAt: "2026-05-29T10:00:00Z")
        do {
            _ = try await controller.audioURL(for: missing)
            XCTFail("Expected missing audio to fail")
        } catch AudioFileStore.StoreError.sourceMissing(_) {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeRecord(id: String, createdAt: String, raw: String = "raw", edited: String = "edit") -> DatasetRecord {
        DatasetRecord(
            id: id,
            createdAt: createdAt,
            audioPath: "audio/2026-05-29/\(id).wav",
            durationMs: 100, sampleRate: 16000, channels: 1,
            sourceAppBundleID: nil, sourceAppName: nil,
            asrProvider: "mlx-audio-swift", asrModel: "model", asrRuntime: "runtime", asrConfigJSON: nil,
            rawTranscript: raw, editedTranscript: edited,
            inserted: false,
            language: nil, metadataJSON: nil,
            autoEditedTranscript: edited
        )
    }

    private func createPreCanonicalDatabase(at url: URL) throws {
        let database = try DatabaseQueue(path: url.path)
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
            try db.execute(sql: """
                INSERT INTO records (
                    id, created_at, audio_path,
                    asr_provider, asr_model, asr_runtime,
                    raw_transcript, edited_transcript, inserted, saved_to_dataset,
                    auto_edited_transcript
                ) VALUES (
                    'rec_missing_auto', '2026-06-05T10:00:00Z', 'audio/rec_missing_auto.wav',
                    'test', 'test', 'test',
                    'raw', 'edited', 1, 1,
                    NULL
                )
                """)
        }
        migrator.registerMigration("addAutoEditedTranscript") { _ in }
        migrator.registerMigration("addLLMEditedTranscript") { _ in }
        try migrator.migrate(database)
    }
}

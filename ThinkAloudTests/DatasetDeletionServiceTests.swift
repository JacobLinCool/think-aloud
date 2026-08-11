import XCTest

@testable import ThinkAloud

final class DatasetDeletionServiceTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThinkAloudDeletionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testSuccessfulDeletePurgesRecoveryBatch() async throws {
        let (dataset, audio, record) = try await makeStores(hasAudio: true)
        let service = DatasetDeletionService(
            datasetStore: dataset,
            audioFileStore: audio,
            recoveryRoot: tempDir.appendingPathComponent("recoveries"),
            makeID: { "test-batch" }
        )

        let report = try await service.delete(ids: [record.id])

        XCTAssertEqual(report.deletedRecordIDs, [record.id])
        XCTAssertTrue(report.missingAudioPaths.isEmpty)
        let deletedRecord = try await dataset.fetch(id: record.id)
        XCTAssertNil(deletedRecord)
        let recoveryBatch =
            tempDir
            .appendingPathComponent("recoveries")
            .appendingPathComponent("deletion-test-batch")
        XCTAssertFalse(FileManager.default.fileExists(atPath: recoveryBatch.path))
        let liveAudio = try await audio.validatedAbsoluteURL(for: record.audioPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: liveAudio.path))
    }

    func testDeleteReportsAlreadyMissingAudioWithoutSilencingIt() async throws {
        let (dataset, audio, record) = try await makeStores(hasAudio: false)
        let service = DatasetDeletionService(
            datasetStore: dataset,
            audioFileStore: audio,
            recoveryRoot: tempDir.appendingPathComponent("recoveries"),
            makeID: { "missing-audio" }
        )

        let report = try await service.delete(ids: [record.id])

        XCTAssertEqual(report.missingAudioPaths, [record.audioPath])
        XCTAssertTrue(report.hasWarnings)
        let deletedRecord = try await dataset.fetch(id: record.id)
        XCTAssertNil(deletedRecord)
        let recoveryBatch =
            tempDir
            .appendingPathComponent("recoveries")
            .appendingPathComponent("deletion-missing-audio")
        XCTAssertFalse(FileManager.default.fileExists(atPath: recoveryBatch.path))
    }

    func testThrowBeforeDeleteRestoresLiveAudioAndPurgesTemporaryRecovery() async throws {
        let (dataset, audio, record) = try await makeStores(hasAudio: true)
        let failingDatabase = FailingDeletionDatabase(store: dataset)
        let service = DatasetDeletionService(
            datasetStore: failingDatabase,
            audioFileStore: audio,
            recoveryRoot: tempDir.appendingPathComponent("recoveries"),
            makeID: { "database-failure" }
        )

        do {
            _ = try await service.delete(ids: [record.id])
            XCTFail("Expected database deletion to fail")
        } catch let error as DatasetDeletionService.DeletionError {
            guard case .databaseDeleteFailed = error else {
                return XCTFail("Unexpected deletion error: \(error)")
            }
        }

        let liveRecord = try await dataset.fetch(id: record.id)
        XCTAssertNotNil(liveRecord)
        let liveAudio = try await audio.validatedAbsoluteURL(for: record.audioPath)
        XCTAssertEqual(try Data(contentsOf: liveAudio), Data([1, 2, 3]))
        let recoveryBatch =
            tempDir
            .appendingPathComponent("recoveries")
            .appendingPathComponent("deletion-database-failure")
        XCTAssertFalse(FileManager.default.fileExists(atPath: recoveryBatch.path))
    }

    func testCommitThenThrowReturnsCommittedDeletionWithoutRestoringAudio() async throws {
        let (dataset, audio, record) = try await makeStores(hasAudio: true)
        let database = CommitThenThrowDeletionDatabase(store: dataset)
        let recoveryRoot = tempDir.appendingPathComponent("recoveries")
        let batch = recoveryRoot.appendingPathComponent("deletion-commit-then-throw")
        let service = DatasetDeletionService(
            datasetStore: database,
            audioFileStore: audio,
            recoveryRoot: recoveryRoot,
            makeID: { "commit-then-throw" }
        )

        let report = try await service.delete(ids: [record.id])

        XCTAssertEqual(report.deletedRecordIDs, [record.id])
        let deletedRecord = try await dataset.fetch(id: record.id)
        XCTAssertNil(deletedRecord)
        let liveAudio = try await audio.validatedAbsoluteURL(for: record.audioPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: liveAudio.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: batch.path))
    }

    func testPartialCommitThenThrowPreservesRecoveryBatchWithoutGuessing() async throws {
        let (dataset, audio, first) = try await makeStores(hasAudio: true)
        let second = makeRecord(id: "rec_second")
        try await dataset.save(second)
        let secondLive = try await audio.validatedAbsoluteURL(for: second.audioPath)
        try FileManager.default.createDirectory(
            at: secondLive.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([4, 5, 6]).write(to: secondLive)

        let database = PartialCommitThenThrowDeletionDatabase(
            store: dataset,
            recordIDToDelete: first.id
        )
        let recoveryRoot = tempDir.appendingPathComponent("recoveries")
        let batch = recoveryRoot.appendingPathComponent("deletion-partial-commit")
        let service = DatasetDeletionService(
            datasetStore: database,
            audioFileStore: audio,
            recoveryRoot: recoveryRoot,
            makeID: { "partial-commit" }
        )

        do {
            _ = try await service.delete(ids: [first.id, second.id])
            XCTFail("Expected a partial commit to retain recovery for explicit reconciliation")
        } catch let error as DatasetDeletionService.DeletionError {
            guard case .mixedRecoveryState(let directory, let liveIDs, let deletedIDs) = error else {
                return XCTFail("Unexpected deletion error: \(error)")
            }
            XCTAssertEqual(directory.pathComponents, batch.pathComponents)
            XCTAssertEqual(liveIDs, [second.id])
            XCTAssertEqual(deletedIDs, [first.id])
        }

        let deletedFirst = try await dataset.fetch(id: first.id)
        let liveSecond = try await dataset.fetch(id: second.id)
        XCTAssertNil(deletedFirst)
        XCTAssertNotNil(liveSecond)
        let firstLive = try await audio.validatedAbsoluteURL(for: first.audioPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstLive.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondLive.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: batch.appendingPathComponent(first.audioPath).path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: batch.appendingPathComponent(second.audioPath).path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: batch.appendingPathComponent("manifest.json").path
            )
        )
    }

    func testReadFailureAfterMutationErrorRetainsRecoveryBatchAsAmbiguous() async throws {
        let (dataset, audio, record) = try await makeStores(hasAudio: true)
        let database = ReadFailingAfterMutationDatabase(store: dataset)
        let recoveryRoot = tempDir.appendingPathComponent("recoveries")
        let batch = recoveryRoot.appendingPathComponent("deletion-read-failure")
        let service = DatasetDeletionService(
            datasetStore: database,
            audioFileStore: audio,
            recoveryRoot: recoveryRoot,
            makeID: { "read-failure" }
        )

        do {
            _ = try await service.delete(ids: [record.id])
            XCTFail("Expected unreadable post-mutation state to remain unresolved")
        } catch let error as DatasetDeletionService.DeletionError {
            guard case .ambiguousDatabaseDelete(let directory, _) = error else {
                return XCTFail("Unexpected deletion error: \(error)")
            }
            XCTAssertEqual(directory.pathComponents, batch.pathComponents)
            XCTAssertTrue(error.localizedDescription.contains(batch.path))
        }

        let liveRecord = try await dataset.fetch(id: record.id)
        XCTAssertNotNil(liveRecord)
        let liveAudio = try await audio.validatedAbsoluteURL(for: record.audioPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: liveAudio.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: batch.appendingPathComponent(record.audioPath).path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: batch.appendingPathComponent("manifest.json").path
            )
        )
    }

    func testPurgeFailureReturnsTypedPartialFailureWithExactRecoveryPath() async throws {
        let (dataset, audio, record) = try await makeStores(hasAudio: true)
        let recoveryBatchName = "deletion-purge-failure"
        let fileManager = PurgeFailingFileManager(failingDirectoryName: recoveryBatchName)
        let service = DatasetDeletionService(
            datasetStore: dataset,
            audioFileStore: audio,
            recoveryRoot: tempDir.appendingPathComponent("recoveries"),
            fileManager: fileManager,
            makeID: { "purge-failure" }
        )

        do {
            _ = try await service.delete(ids: [record.id])
            XCTFail("Expected recovery purge to fail")
        } catch let error as DatasetDeletionService.DeletionError {
            guard case .purgeFailed(let directory, let count, _) = error else {
                return XCTFail("Unexpected deletion error: \(error)")
            }
            XCTAssertEqual(directory.lastPathComponent, recoveryBatchName)
            XCTAssertEqual(count, 1)
            XCTAssertTrue(error.localizedDescription.contains(directory.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        }

        let deletedRecord = try await dataset.fetch(id: record.id)
        XCTAssertNil(deletedRecord)
        let liveAudio = try await audio.validatedAbsoluteURL(for: record.audioPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: liveAudio.path))
    }

    func testReconcileRestoresMissingLiveAudioWhenDatabaseRowsStillExist() async throws {
        let (dataset, audio, record) = try await makeStores(hasAudio: true)
        let recoveryRoot = tempDir.appendingPathComponent("recoveries")
        let batch = recoveryRoot.appendingPathComponent("deletion-interrupted-rollback")
        let liveAudio = try await audio.validatedAbsoluteURL(for: record.audioPath)
        let recoveryAudio = batch.appendingPathComponent(record.audioPath)
        try FileManager.default.createDirectory(
            at: recoveryAudio.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: liveAudio, to: recoveryAudio)
        try writeManifest(batch: batch, records: [record], stagedAudioPaths: [record.audioPath])
        try FileManager.default.removeItem(at: liveAudio)

        let service = DatasetDeletionService(
            datasetStore: dataset,
            audioFileStore: audio,
            recoveryRoot: recoveryRoot
        )
        try await service.reconcileInterruptedDeletions()

        XCTAssertEqual(try Data(contentsOf: liveAudio), Data([1, 2, 3]))
        let restoredRecord = try await dataset.fetch(id: record.id)
        XCTAssertNotNil(restoredRecord)
        XCTAssertFalse(FileManager.default.fileExists(atPath: batch.path))
    }

    func testReconcilePurgesRecoveryWhenDatabaseTransactionCommitted() async throws {
        let (dataset, audio, record) = try await makeStores(hasAudio: true)
        let recoveryRoot = tempDir.appendingPathComponent("recoveries")
        let batch = recoveryRoot.appendingPathComponent("deletion-interrupted-commit")
        let liveAudio = try await audio.validatedAbsoluteURL(for: record.audioPath)
        let recoveryAudio = batch.appendingPathComponent(record.audioPath)
        try FileManager.default.createDirectory(
            at: recoveryAudio.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: liveAudio, to: recoveryAudio)
        try writeManifest(batch: batch, records: [record], stagedAudioPaths: [record.audioPath])
        try FileManager.default.removeItem(at: liveAudio)
        _ = try await dataset.delete(ids: [record.id])

        let service = DatasetDeletionService(
            datasetStore: dataset,
            audioFileStore: audio,
            recoveryRoot: recoveryRoot
        )
        try await service.reconcileInterruptedDeletions()

        let deletedRecord = try await dataset.fetch(id: record.id)
        XCTAssertNil(deletedRecord)
        XCTAssertFalse(FileManager.default.fileExists(atPath: batch.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: liveAudio.path))
    }

    func testReconcilePurgesPreManifestOrphanUnderWriteBeforeRemoveInvariant() async throws {
        let (dataset, audio, record) = try await makeStores(hasAudio: true)
        let recoveryRoot = tempDir.appendingPathComponent("recoveries")
        let batch = recoveryRoot.appendingPathComponent("deletion-before-manifest")
        let liveAudio = try await audio.validatedAbsoluteURL(for: record.audioPath)
        let redundantCopy = batch.appendingPathComponent(record.audioPath)
        try FileManager.default.createDirectory(
            at: redundantCopy.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: liveAudio, to: redundantCopy)

        let service = DatasetDeletionService(
            datasetStore: dataset,
            audioFileStore: audio,
            recoveryRoot: recoveryRoot
        )
        try await service.reconcileInterruptedDeletions()

        XCTAssertEqual(try Data(contentsOf: liveAudio), Data([1, 2, 3]))
        let preservedRecord = try await dataset.fetch(id: record.id)
        XCTAssertNotNil(preservedRecord)
        XCTAssertFalse(FileManager.default.fileExists(atPath: batch.path))
    }

    func testReconcileRejectsMixedDatabaseStateAndPreservesExactBatch() async throws {
        let (dataset, audio, first) = try await makeStores(hasAudio: true)
        let second = makeRecord(id: "rec_second")
        try await dataset.save(second)
        let secondLive = try await audio.validatedAbsoluteURL(for: second.audioPath)
        try FileManager.default.createDirectory(
            at: secondLive.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([4, 5, 6]).write(to: secondLive)

        let recoveryRoot = tempDir.appendingPathComponent("recoveries")
        let batch = recoveryRoot.appendingPathComponent("deletion-mixed")
        for (record, liveURL) in [
            (first, try await audio.validatedAbsoluteURL(for: first.audioPath)),
            (second, secondLive),
        ] {
            let recoveryURL = batch.appendingPathComponent(record.audioPath)
            try FileManager.default.createDirectory(
                at: recoveryURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: liveURL, to: recoveryURL)
        }
        try writeManifest(
            batch: batch,
            records: [first, second],
            stagedAudioPaths: [first.audioPath, second.audioPath]
        )
        _ = try await dataset.delete(ids: [second.id])

        let service = DatasetDeletionService(
            datasetStore: dataset,
            audioFileStore: audio,
            recoveryRoot: recoveryRoot
        )
        do {
            try await service.reconcileInterruptedDeletions()
            XCTFail("Expected mixed transaction state to block startup")
        } catch let error as DatasetDeletionService.DeletionError {
            guard case .mixedRecoveryState(let directory, let liveIDs, let deletedIDs) = error else {
                return XCTFail("Unexpected reconciliation error: \(error)")
            }
            XCTAssertEqual(directory.pathComponents, batch.pathComponents)
            XCTAssertEqual(liveIDs, [first.id])
            XCTAssertEqual(deletedIDs, [second.id])
            XCTAssertTrue(error.localizedDescription.contains(batch.path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: batch.path))
    }

    func testReconcileRejectsCorruptManifestAndPreservesBatch() async throws {
        let (dataset, audio, _) = try await makeStores(hasAudio: true)
        let recoveryRoot = tempDir.appendingPathComponent("recoveries")
        let batch = recoveryRoot.appendingPathComponent("deletion-corrupt")
        try FileManager.default.createDirectory(at: batch, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: batch.appendingPathComponent("manifest.json"))
        let service = DatasetDeletionService(
            datasetStore: dataset,
            audioFileStore: audio,
            recoveryRoot: recoveryRoot
        )

        do {
            try await service.reconcileInterruptedDeletions()
            XCTFail("Expected corrupt manifest to block startup")
        } catch let error as DatasetDeletionService.DeletionError {
            guard case .corruptRecoveryBatch(let directory, _) = error else {
                return XCTFail("Unexpected reconciliation error: \(error)")
            }
            XCTAssertEqual(directory.pathComponents, batch.pathComponents)
            XCTAssertTrue(error.localizedDescription.contains(batch.path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: batch.path))
    }

    func testReconcileRejectsMissingLiveAndRecoveryAudioAsIrrecoverable() async throws {
        let (dataset, audio, record) = try await makeStores(hasAudio: true)
        let recoveryRoot = tempDir.appendingPathComponent("recoveries")
        let batch = recoveryRoot.appendingPathComponent("deletion-irrecoverable")
        try writeManifest(batch: batch, records: [record], stagedAudioPaths: [record.audioPath])
        let liveAudio = try await audio.validatedAbsoluteURL(for: record.audioPath)
        try FileManager.default.removeItem(at: liveAudio)
        let service = DatasetDeletionService(
            datasetStore: dataset,
            audioFileStore: audio,
            recoveryRoot: recoveryRoot
        )

        do {
            try await service.reconcileInterruptedDeletions()
            XCTFail("Expected missing recovery audio to block startup")
        } catch let error as DatasetDeletionService.DeletionError {
            guard case .irrecoverableRecovery(let directory, let path, _) = error else {
                return XCTFail("Unexpected reconciliation error: \(error)")
            }
            XCTAssertEqual(directory.pathComponents, batch.pathComponents)
            XCTAssertEqual(path, record.audioPath)
            XCTAssertTrue(error.localizedDescription.contains(batch.path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: batch.path))
    }

    func testDeleteCapturedIDsKeepsRecordsCreatedAfterConfirmationSnapshot() async throws {
        let (dataset, audio, capturedRecord) = try await makeStores(hasAudio: false)
        let capturedIDs: Set<String> = [capturedRecord.id]
        let laterRecord = makeRecord(id: "rec_created_later")
        try await dataset.save(laterRecord)
        let service = DatasetDeletionService(
            datasetStore: dataset,
            audioFileStore: audio,
            recoveryRoot: tempDir.appendingPathComponent("recoveries")
        )

        let report = try await service.delete(ids: capturedIDs)

        XCTAssertEqual(report.deletedRecordIDs, [capturedRecord.id])
        let deleted = try await dataset.fetch(id: capturedRecord.id)
        let preserved = try await dataset.fetch(id: laterRecord.id)
        XCTAssertNil(deleted)
        XCTAssertNotNil(preserved)
    }

    func testSharedServiceRejectsAConcurrentDeleteInsteadOfInterleaving() async throws {
        let record = makeRecord(id: "rec_blocked")
        let database = BlockingDeletionDatabase(record: record)
        let audio = AudioFileStore(rootDirectory: tempDir.appendingPathComponent("audio"))
        let service = DatasetDeletionService(
            datasetStore: database,
            audioFileStore: audio,
            recoveryRoot: tempDir.appendingPathComponent("recoveries")
        )
        let firstDelete = Task {
            try await service.delete(ids: [record.id])
        }
        await database.waitUntilFetchStarts()

        do {
            _ = try await service.delete(ids: [record.id])
            XCTFail("Expected the shared service to reject an overlapping deletion")
        } catch let error as DatasetDeletionService.DeletionError {
            guard case .operationInProgress = error else {
                return XCTFail("Unexpected concurrent deletion error: \(error)")
            }
        }

        await database.resumeFetch()
        _ = try await firstDelete.value
    }

    private func makeStores(hasAudio: Bool) async throws -> (
        DatasetStore, AudioFileStore, DatasetRecord
    ) {
        let dataset = DatasetStore(databaseURL: tempDir.appendingPathComponent("dataset.sqlite"))
        try await dataset.setup()
        let audioRoot = tempDir.appendingPathComponent("audio")
        let audio = AudioFileStore(rootDirectory: audioRoot)
        let record = makeRecord(id: "rec_test")
        try await dataset.save(record)
        if hasAudio {
            let url = try await audio.validatedAbsoluteURL(for: record.audioPath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data([1, 2, 3]).write(to: url)
        }
        return (dataset, audio, record)
    }

    private func makeRecord(id: String) -> DatasetRecord {
        DatasetRecord(
            id: id,
            createdAt: "2026-07-31T00:00:00Z",
            audioPath: "audio/2026-07-31/\(id).wav",
            durationMs: 100,
            sampleRate: 16_000,
            channels: 1,
            sourceAppBundleID: nil,
            sourceAppName: nil,
            asrProvider: "test",
            asrModel: "test",
            asrRuntime: "test",
            asrConfigJSON: nil,
            rawTranscript: "raw",
            editedTranscript: "edited",
            inserted: true,
            language: "zh",
            metadataJSON: nil,
            autoEditedTranscript: "edited"
        )
    }

    private func writeManifest(
        batch: URL,
        records: [DatasetRecord],
        stagedAudioPaths: [String],
        missingAudioPaths: [String] = []
    ) throws {
        try FileManager.default.createDirectory(at: batch, withIntermediateDirectories: true)
        let manifest = DatasetDeletionService.RecoveryManifest(
            createdAt: Date(timeIntervalSince1970: 0),
            records: records,
            stagedAudioPaths: stagedAudioPaths,
            missingAudioPaths: missingAudioPaths
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: batch.appendingPathComponent("manifest.json"),
            options: .atomic
        )
    }
}

private actor FailingDeletionDatabase: DatasetDeletionDatabase {
    enum ExpectedError: Error {
        case deletionFailed
    }

    let store: DatasetStore

    init(store: DatasetStore) {
        self.store = store
    }

    func all() async throws -> [DatasetRecord] {
        try await store.all()
    }

    func fetch(id: String) async throws -> DatasetRecord? {
        try await store.fetch(id: id)
    }

    func delete(ids: Set<String>) async throws -> [DatasetRecord] {
        throw ExpectedError.deletionFailed
    }
}

private actor CommitThenThrowDeletionDatabase: DatasetDeletionDatabase {
    enum ExpectedError: Error {
        case responseLostAfterCommit
    }

    let store: DatasetStore

    init(store: DatasetStore) {
        self.store = store
    }

    func all() async throws -> [DatasetRecord] {
        try await store.all()
    }

    func fetch(id: String) async throws -> DatasetRecord? {
        try await store.fetch(id: id)
    }

    func delete(ids: Set<String>) async throws -> [DatasetRecord] {
        _ = try await store.delete(ids: ids)
        throw ExpectedError.responseLostAfterCommit
    }
}

private actor PartialCommitThenThrowDeletionDatabase: DatasetDeletionDatabase {
    enum ExpectedError: Error {
        case partialCommit
    }

    let store: DatasetStore
    let recordIDToDelete: String

    init(store: DatasetStore, recordIDToDelete: String) {
        self.store = store
        self.recordIDToDelete = recordIDToDelete
    }

    func all() async throws -> [DatasetRecord] {
        try await store.all()
    }

    func fetch(id: String) async throws -> DatasetRecord? {
        try await store.fetch(id: id)
    }

    func delete(ids _: Set<String>) async throws -> [DatasetRecord] {
        _ = try await store.delete(ids: [recordIDToDelete])
        throw ExpectedError.partialCommit
    }
}

private actor ReadFailingAfterMutationDatabase: DatasetDeletionDatabase {
    enum ExpectedError: Error {
        case mutationFailed
        case stateReadFailed
    }

    let store: DatasetStore
    private var mutationWasAttempted = false

    init(store: DatasetStore) {
        self.store = store
    }

    func all() async throws -> [DatasetRecord] {
        try await store.all()
    }

    func fetch(id: String) async throws -> DatasetRecord? {
        guard !mutationWasAttempted else {
            throw ExpectedError.stateReadFailed
        }
        return try await store.fetch(id: id)
    }

    func delete(ids _: Set<String>) async throws -> [DatasetRecord] {
        mutationWasAttempted = true
        throw ExpectedError.mutationFailed
    }
}

private actor BlockingDeletionDatabase: DatasetDeletionDatabase {
    let record: DatasetRecord
    private var fetchStarted = false
    private var fetchContinuation: CheckedContinuation<Void, Never>?

    init(record: DatasetRecord) {
        self.record = record
    }

    func all() async throws -> [DatasetRecord] {
        [record]
    }

    func fetch(id: String) async throws -> DatasetRecord? {
        fetchStarted = true
        await withCheckedContinuation { continuation in
            fetchContinuation = continuation
        }
        return id == record.id ? record : nil
    }

    func delete(ids: Set<String>) async throws -> [DatasetRecord] {
        [record]
    }

    func waitUntilFetchStarts() async {
        while !fetchStarted {
            await Task.yield()
        }
    }

    func resumeFetch() {
        fetchContinuation?.resume()
        fetchContinuation = nil
    }
}

private final class PurgeFailingFileManager: FileManager, @unchecked Sendable {
    private let failingDirectoryName: String

    init(failingDirectoryName: String) {
        self.failingDirectoryName = failingDirectoryName
        super.init()
    }

    override func removeItem(at URL: URL) throws {
        if URL.lastPathComponent == failingDirectoryName {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.removeItem(at: URL)
    }
}

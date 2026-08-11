import XCTest
@testable import ThinkAloud

final class AudioFileStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ThinkAloudTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testPersistMovesFileIntoDateFolder() async throws {
        let fakeWAV = tempDir.appendingPathComponent("temp.wav")
        try Data([0x00, 0x01, 0x02]).write(to: fakeWAV)

        let store = AudioFileStore(rootDirectory: tempDir.appendingPathComponent("audio", isDirectory: true))
        let date = Date(timeIntervalSince1970: 1_716_854_400) // 2024-05-28 UTC
        let result = try await store.persist(temporaryURL: fakeWAV, recordID: "rec_001", at: date)

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.storedURL.path))
        XCTAssertTrue(result.relativePath.hasPrefix("audio/"))
        XCTAssertTrue(result.relativePath.hasSuffix("rec_001.wav"))
    }

    func testDayFolderFormat() {
        let date = Date(timeIntervalSince1970: 1_716_854_400)
        let folder = AudioFileStore.dayFolder(for: date, calendar: .current)
        XCTAssertEqual(folder.count, 10)
        XCTAssertEqual(folder.filter { $0 == "-" }.count, 2)
    }

    func testRejectsPathTraversal() async throws {
        let store = AudioFileStore(rootDirectory: tempDir.appendingPathComponent("audio"))
        do {
            _ = try await store.validatedAbsoluteURL(for: "audio/../../outside.wav")
            XCTFail("Expected path traversal to be rejected")
        } catch let error as AudioFileStore.StoreError {
            guard case .invalidRelativePath = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testStageForDeletionAndRestorePreservesBytes() async throws {
        let audioRoot = tempDir.appendingPathComponent("audio")
        let source = audioRoot.appendingPathComponent("2026-05-28/rec.wav")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let bytes = Data([1, 2, 3, 4])
        try bytes.write(to: source)
        let store = AudioFileStore(rootDirectory: audioRoot)
        let recovery = tempDir.appendingPathComponent("recovery")

        let recoveryFile = try await store.stageForDeletion(
            relativePath: "audio/2026-05-28/rec.wav",
            recoveryDirectory: recovery
        )
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertEqual(try Data(contentsOf: recoveryFile.recoveryURL), bytes)

        try await store.removeOriginal(for: recoveryFile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        try await store.restore(recoveryFile)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertEqual(try Data(contentsOf: recoveryFile.recoveryURL), bytes)
    }

    func testCanonicalPathRequiresMatchingRecordAndValidDay() async throws {
        let store = AudioFileStore(rootDirectory: tempDir.appendingPathComponent("audio"))

        try await store.validateCanonical(
            relativePath: "audio/2026-07-31/rec_owned.wav",
            recordID: "rec_owned"
        )

        for invalid in [
            "audio/2026-02-30/rec_owned.wav",
            "audio/2026-07-31/rec_other.wav",
            "audio/nested/2026-07-31/rec_owned.wav",
        ] {
            do {
                try await store.validateCanonical(
                    relativePath: invalid,
                    recordID: "rec_owned"
                )
                XCTFail("Expected non-canonical path to be rejected: \(invalid)")
            } catch AudioFileStore.StoreError.invalidRelativePath {
                // Expected.
            }
        }
    }

    func testCrashBeforeDatabaseSaveDeletesOnlyManifestOwnedAudioOnRelaunch() async throws {
        let dataset = DatasetStore(databaseURL: tempDir.appendingPathComponent("dataset.sqlite"))
        try await dataset.setup()
        let audio = AudioFileStore(rootDirectory: tempDir.appendingPathComponent("audio"))
        let recoveryRoot = tempDir.appendingPathComponent("pending-saves")
        let startedAt = Date(timeIntervalSince1970: 1_775_059_200)
        let service = DatasetSaveRecoveryService(
            datasetStore: dataset,
            audioFileStore: audio,
            recoveryRoot: recoveryRoot
        )
        let manifest = try await service.prepare(
            recordID: "rec_interrupted",
            recordingStartedAt: startedAt
        )
        let temporaryAudio = tempDir.appendingPathComponent("interrupted.wav")
        try Data([1, 2, 3]).write(to: temporaryAudio)
        let stored = try await audio.persist(
            temporaryURL: temporaryAudio,
            recordID: manifest.recordID,
            at: startedAt
        )
        XCTAssertEqual(stored.relativePath, manifest.audioPath)

        let unrelatedPath = try await audio.canonicalRelativePath(
            recordID: "rec_unrelated",
            at: startedAt
        )
        let unrelatedURL = try await audio.validatedAbsoluteURL(for: unrelatedPath)
        try FileManager.default.createDirectory(
            at: unrelatedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([9, 8, 7]).write(to: unrelatedURL)

        // A new service instance represents a process relaunch with no in-memory save state.
        let relaunched = DatasetSaveRecoveryService(
            datasetStore: dataset,
            audioFileStore: audio,
            recoveryRoot: recoveryRoot
        )
        try await relaunched.reconcileInterruptedSaves()

        XCTAssertFalse(FileManager.default.fileExists(atPath: stored.storedURL.path))
        XCTAssertEqual(try Data(contentsOf: unrelatedURL), Data([9, 8, 7]))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: recoveryRoot.path).isEmpty)
    }

    func testCrashAfterDatabaseCommitPreservesReferencedAudioOnRelaunch() async throws {
        let dataset = DatasetStore(databaseURL: tempDir.appendingPathComponent("dataset.sqlite"))
        try await dataset.setup()
        let audio = AudioFileStore(rootDirectory: tempDir.appendingPathComponent("audio"))
        let recoveryRoot = tempDir.appendingPathComponent("pending-saves")
        let startedAt = Date(timeIntervalSince1970: 1_775_059_200)
        let service = DatasetSaveRecoveryService(
            datasetStore: dataset,
            audioFileStore: audio,
            recoveryRoot: recoveryRoot
        )
        let manifest = try await service.prepare(
            recordID: "rec_committed",
            recordingStartedAt: startedAt
        )
        let temporaryAudio = tempDir.appendingPathComponent("committed.wav")
        try Data([4, 5, 6]).write(to: temporaryAudio)
        let stored = try await audio.persist(
            temporaryURL: temporaryAudio,
            recordID: manifest.recordID,
            at: startedAt
        )
        try await dataset.save(makeRecord(for: manifest))

        let relaunched = DatasetSaveRecoveryService(
            datasetStore: dataset,
            audioFileStore: audio,
            recoveryRoot: recoveryRoot
        )
        try await relaunched.reconcileInterruptedSaves()

        XCTAssertEqual(try Data(contentsOf: stored.storedURL), Data([4, 5, 6]))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: recoveryRoot.path).isEmpty)
    }

    func testAmbiguousDatabaseErrorResolutionRecognizesCommittedRow() async throws {
        let dataset = DatasetStore(databaseURL: tempDir.appendingPathComponent("dataset.sqlite"))
        try await dataset.setup()
        let audio = AudioFileStore(rootDirectory: tempDir.appendingPathComponent("audio"))
        let recoveryRoot = tempDir.appendingPathComponent("pending-saves")
        let startedAt = Date(timeIntervalSince1970: 1_775_059_200)
        let service = DatasetSaveRecoveryService(
            datasetStore: dataset,
            audioFileStore: audio,
            recoveryRoot: recoveryRoot
        )
        let manifest = try await service.prepare(
            recordID: "rec_ambiguous",
            recordingStartedAt: startedAt
        )
        let temporaryAudio = tempDir.appendingPathComponent("ambiguous.wav")
        try Data([7, 7, 7]).write(to: temporaryAudio)
        let stored = try await audio.persist(
            temporaryURL: temporaryAudio,
            recordID: manifest.recordID,
            at: startedAt
        )
        // Simulates a database API that committed the row before reporting an error to its caller.
        try await dataset.save(makeRecord(for: manifest))

        let resolution = try await service.discard(manifest)

        XCTAssertEqual(resolution.state, .committedRecordPreserved)
        XCTAssertFalse(resolution.hasPendingManifestCleanup)
        XCTAssertEqual(try Data(contentsOf: stored.storedURL), Data([7, 7, 7]))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: recoveryRoot.path).isEmpty)
    }

    func testCommittedSaveSucceedsWhenManifestRemovalMustRetryAtStartup() async throws {
        let dataset = DatasetStore(databaseURL: tempDir.appendingPathComponent("dataset.sqlite"))
        try await dataset.setup()
        let audio = AudioFileStore(rootDirectory: tempDir.appendingPathComponent("audio"))
        let recoveryRoot = tempDir.appendingPathComponent("pending-saves")
        let failingFileManager = ManifestRemovalFailingFileManager()
        let startedAt = Date(timeIntervalSince1970: 1_775_059_200)
        let service = DatasetSaveRecoveryService(
            datasetStore: dataset,
            audioFileStore: audio,
            recoveryRoot: recoveryRoot,
            fileManager: failingFileManager
        )
        let manifest = try await service.prepare(
            recordID: "rec_cleanup_pending",
            recordingStartedAt: startedAt
        )
        let temporaryAudio = tempDir.appendingPathComponent("cleanup-pending.wav")
        try Data([3, 2, 1]).write(to: temporaryAudio)
        let stored = try await audio.persist(
            temporaryURL: temporaryAudio,
            recordID: manifest.recordID,
            at: startedAt
        )
        try await dataset.save(makeRecord(for: manifest))

        let resolution = try await service.complete(manifest)

        XCTAssertEqual(resolution.state, .committedRecordPreserved)
        XCTAssertTrue(resolution.hasPendingManifestCleanup)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stored.storedURL.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: recoveryRoot.appendingPathComponent("\(manifest.recordID).json").path
            )
        )

        let relaunched = DatasetSaveRecoveryService(
            datasetStore: dataset,
            audioFileStore: audio,
            recoveryRoot: recoveryRoot
        )
        try await relaunched.reconcileInterruptedSaves()
        XCTAssertTrue(FileManager.default.fileExists(atPath: stored.storedURL.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: recoveryRoot.path).isEmpty)
    }

    func testDiscardedAudioWithManifestCleanupFailureReusesIdentityOnRetrySave() async throws {
        let dataset = DatasetStore(databaseURL: tempDir.appendingPathComponent("dataset.sqlite"))
        try await dataset.setup()
        let audio = AudioFileStore(rootDirectory: tempDir.appendingPathComponent("audio"))
        let recoveryRoot = tempDir.appendingPathComponent("pending-saves")
        let fileManager = SingleManifestRemovalFailingFileManager()
        let startedAt = Date(timeIntervalSince1970: 1_775_059_200)
        let service = DatasetSaveRecoveryService(
            datasetStore: dataset,
            audioFileStore: audio,
            recoveryRoot: recoveryRoot,
            fileManager: fileManager
        )
        let manifest = try await service.prepare(
            recordID: "rec_retry_identity",
            recordingStartedAt: startedAt
        )
        let temporaryAudio = tempDir.appendingPathComponent("retry-identity.wav")
        try Data([2, 4, 6]).write(to: temporaryAudio)
        let firstStored = try await audio.persist(
            temporaryURL: temporaryAudio,
            recordID: manifest.recordID,
            at: startedAt
        )
        var state = PendingDatasetSaveRecoveryState(
            manifest: manifest,
            audioWasPersisted: true
        )

        let discardResolution = try await state.abandon(using: service)

        XCTAssertEqual(discardResolution?.state, .discarded)
        XCTAssertTrue(discardResolution?.hasPendingManifestCleanup == true)
        XCTAssertEqual(state.manifest, manifest)
        XCTAssertFalse(state.audioWasPersisted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstStored.storedURL.path))

        // Coordinator Retry Save reuses the retained manifest instead of calling prepare(), which
        // would collide with the durable file that intentionally remains.
        let retried = try await audio.persist(
            temporaryURL: temporaryAudio,
            recordID: manifest.recordID,
            at: startedAt
        )
        XCTAssertEqual(retried.relativePath, state.manifest?.audioPath)
        state.markAudioPersisted()
        try await dataset.save(makeRecord(for: manifest))
        let completion = try await service.complete(manifest)
        state.clear()

        XCTAssertEqual(completion.state, .committedRecordPreserved)
        XCTAssertFalse(completion.hasPendingManifestCleanup)
        XCTAssertNil(state.manifest)
        XCTAssertEqual(try Data(contentsOf: retried.storedURL), Data([2, 4, 6]))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: recoveryRoot.path).isEmpty)
    }

    func testCloseRetainsExactRecoveryWhenAudioCleanupFailsAndRetries() async throws {
        let dataset = DatasetStore(databaseURL: tempDir.appendingPathComponent("dataset.sqlite"))
        try await dataset.setup()
        let failingFileManager = AudioCleanupFailingFileManager()
        let audio = AudioFileStore(
            rootDirectory: tempDir.appendingPathComponent("audio"),
            fileManager: failingFileManager
        )
        let recoveryRoot = tempDir.appendingPathComponent("pending-saves")
        let startedAt = Date(timeIntervalSince1970: 1_775_059_200)
        let service = DatasetSaveRecoveryService(
            datasetStore: dataset,
            audioFileStore: audio,
            recoveryRoot: recoveryRoot
        )
        let manifest = try await service.prepare(
            recordID: "rec_close_retry",
            recordingStartedAt: startedAt
        )
        let temporaryAudio = tempDir.appendingPathComponent("close-retry.wav")
        try Data([8, 8, 8]).write(to: temporaryAudio)
        let stored = try await audio.persist(
            temporaryURL: temporaryAudio,
            recordID: manifest.recordID,
            at: startedAt
        )
        var state = PendingDatasetSaveRecoveryState(
            manifest: manifest,
            audioWasPersisted: true
        )

        do {
            _ = try await state.abandon(using: service)
            XCTFail("Close must not complete while its exact audio cannot be removed")
        } catch DatasetSaveRecoveryService.RecoveryError.audioCleanupFailed {
            // Expected.
        }
        XCTAssertEqual(state.manifest, manifest)
        XCTAssertTrue(state.audioWasPersisted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stored.storedURL.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: recoveryRoot.appendingPathComponent("\(manifest.recordID).json").path
            )
        )

        let resolution = try await state.abandon(using: service)

        XCTAssertEqual(resolution?.state, .discarded)
        XCTAssertNil(state.manifest)
        XCTAssertFalse(state.audioWasPersisted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stored.storedURL.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: recoveryRoot.path).isEmpty)
    }

    func testReconcileRejectsManifestNamingAnotherRecordingWithoutDeletingIt() async throws {
        let dataset = DatasetStore(databaseURL: tempDir.appendingPathComponent("dataset.sqlite"))
        try await dataset.setup()
        let audio = AudioFileStore(rootDirectory: tempDir.appendingPathComponent("audio"))
        let recoveryRoot = tempDir.appendingPathComponent("pending-saves")
        let startedAt = Date(timeIntervalSince1970: 1_775_059_200)
        let service = DatasetSaveRecoveryService(
            datasetStore: dataset,
            audioFileStore: audio,
            recoveryRoot: recoveryRoot
        )
        let prepared = try await service.prepare(
            recordID: "rec_manifest",
            recordingStartedAt: startedAt
        )
        let otherPath = try await audio.canonicalRelativePath(
            recordID: "rec_other",
            at: startedAt
        )
        let otherURL = try await audio.validatedAbsoluteURL(for: otherPath)
        try FileManager.default.createDirectory(
            at: otherURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([6, 6, 6]).write(to: otherURL)
        let corrupt = DatasetSaveRecoveryManifest(
            createdAt: prepared.createdAt,
            recordID: prepared.recordID,
            audioPath: otherPath
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let manifestURL = recoveryRoot.appendingPathComponent("\(prepared.recordID).json")
        try encoder.encode(corrupt).write(to: manifestURL, options: .atomic)

        do {
            try await service.reconcileInterruptedSaves()
            XCTFail("Expected a manifest that names another recording to be rejected")
        } catch DatasetSaveRecoveryService.RecoveryError.corruptManifest {
            // Expected.
        }
        XCTAssertEqual(try Data(contentsOf: otherURL), Data([6, 6, 6]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))
    }

    private func makeRecord(
        for manifest: DatasetSaveRecoveryManifest
    ) -> DatasetRecord {
        DatasetRecord(
            id: manifest.recordID,
            createdAt: "2026-04-01T00:00:00Z",
            audioPath: manifest.audioPath,
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
            language: nil,
            metadataJSON: nil,
            autoEditedTranscript: "edited"
        )
    }
}

private final class AudioCleanupFailingFileManager: FileManager, @unchecked Sendable {
    private let failureLock = NSLock()
    private var remainingAudioRemovalFailures = 1

    override func removeItem(at URL: URL) throws {
        failureLock.lock()
        let shouldFail = URL.pathExtension == "wav" && remainingAudioRemovalFailures > 0
        if shouldFail {
            remainingAudioRemovalFailures -= 1
        }
        failureLock.unlock()
        if shouldFail {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.removeItem(at: URL)
    }
}

private final class ManifestRemovalFailingFileManager: FileManager, @unchecked Sendable {
    override func removeItem(at URL: URL) throws {
        if URL.pathExtension == "json" {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.removeItem(at: URL)
    }
}

private final class SingleManifestRemovalFailingFileManager: FileManager, @unchecked Sendable {
    private let failureLock = NSLock()
    private var remainingManifestRemovalFailures = 1

    override func removeItem(at URL: URL) throws {
        failureLock.lock()
        let shouldFail = URL.pathExtension == "json" && remainingManifestRemovalFailures > 0
        if shouldFail {
            remainingManifestRemovalFailures -= 1
        }
        failureLock.unlock()
        if shouldFail {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.removeItem(at: URL)
    }
}

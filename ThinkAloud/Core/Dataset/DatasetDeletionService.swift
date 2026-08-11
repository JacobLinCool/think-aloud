import Foundation

protocol DatasetDeletionDatabase: Sendable {
    func all() async throws -> [DatasetRecord]
    func fetch(id: String) async throws -> DatasetRecord?
    func delete(ids: Set<String>) async throws -> [DatasetRecord]
}

extension DatasetStore: DatasetDeletionDatabase {}

struct DatasetDeletionReport: Sendable, Equatable {
    let deletedRecordIDs: [String]
    let missingAudioPaths: [String]

    var deletedCount: Int { deletedRecordIDs.count }
    var hasWarnings: Bool { !missingAudioPaths.isEmpty }
}

actor DatasetDeletionService {
    enum DeletionError: Error, LocalizedError {
        case noRecordsSelected
        case operationInProgress
        case audioStagingFailed(path: String, reason: String)
        case manifestWriteFailed(URL, String)
        case databaseDeleteFailed(String)
        case rollbackIncomplete(recoveryDirectory: URL, failedPaths: [String], reason: String)
        case rollbackCleanupFailed(recoveryDirectory: URL, reason: String)
        case purgeFailed(recoveryDirectory: URL, deletedRecordCount: Int, reason: String)
        case recoveryScanFailed(recoveryRoot: URL, reason: String)
        case corruptRecoveryBatch(recoveryDirectory: URL, reason: String)
        case ambiguousDatabaseDelete(recoveryDirectory: URL, reason: String)
        case mixedRecoveryState(
            recoveryDirectory: URL, liveRecordIDs: [String], deletedRecordIDs: [String])
        case irrecoverableRecovery(recoveryDirectory: URL, audioPath: String, reason: String)
        case recoveryPurgeFailed(recoveryDirectory: URL, reason: String)

        var errorDescription: String? {
            switch self {
            case .noRecordsSelected:
                return String(localized: "No records were selected for deletion.")
            case .operationInProgress:
                return String(
                    localized:
                        "Another dataset deletion is already in progress. Wait for it to finish and try again.")
            case .audioStagingFailed(let path, let reason):
                return String(localized: "Could not prepare \(path) for deletion: \(reason)")
            case .manifestWriteFailed(let url, let reason):
                return String(localized: "Could not create the recovery manifest at \(url.path): \(reason)")
            case .databaseDeleteFailed(let reason):
                return String(
                    localized:
                        "No records were deleted. Audio was restored after the database operation failed: \(reason)"
                )
            case .rollbackIncomplete(let directory, let paths, let reason):
                return String(
                    localized:
                        "Deletion stopped, but \(paths.count) audio file(s) could not be restored. Recovery folder: \(directory.path). \(reason)"
                )
            case .rollbackCleanupFailed(let directory, let reason):
                return String(
                    localized:
                        "No records were deleted and live audio was restored, but temporary recovery copies remain at \(directory.path). \(reason)"
                )
            case .purgeFailed(let directory, let count, let reason):
                return String(
                    localized:
                        "\(count) record(s) were removed, but deletion is incomplete because recovery files could not be purged. Remove this folder manually: \(directory.path). \(reason)"
                )
            case .recoveryScanFailed(let root, let reason):
                return String(
                    localized:
                        "ThinkAloud could not inspect interrupted deletions in \(root.path). Keep this folder unchanged and check its permissions before reopening the app. \(reason)"
                )
            case .corruptRecoveryBatch(let directory, let reason):
                return String(
                    localized:
                        "ThinkAloud found an invalid interrupted-deletion batch at \(directory.path). Keep this folder unchanged and restore it from backup or contact support. \(reason)"
                )
            case .ambiguousDatabaseDelete(let directory, let reason):
                return String(
                    localized:
                        "ThinkAloud could not confirm whether the dataset deletion committed. Audio recovery was retained at \(directory.path); do not remove or change it. Reopen the app to retry reconciliation. \(reason)"
                )
            case .mixedRecoveryState(let directory, let liveIDs, let deletedIDs):
                return String(
                    localized:
                        "ThinkAloud found a partially committed deletion at \(directory.path). \(liveIDs.count) record(s) still exist and \(deletedIDs.count) are missing. Keep this folder unchanged and restore from backup or contact support."
                )
            case .irrecoverableRecovery(let directory, let audioPath, let reason):
                return String(
                    localized:
                        "ThinkAloud could not restore \(audioPath) from interrupted deletion \(directory.path). Keep this folder unchanged and restore from backup or contact support. \(reason)"
                )
            case .recoveryPurgeFailed(let directory, let reason):
                return String(
                    localized:
                        "ThinkAloud reconciled the interrupted deletion but could not remove \(directory.path). Check the folder permissions and reopen the app. \(reason)"
                )
            }
        }
    }

    /// Durable state is intentionally relocatable: only record snapshots and validated relative
    /// audio paths are persisted. Absolute live/recovery URLs are reconstructed from trusted roots.
    struct RecoveryManifest: Codable, Sendable {
        static let currentVersion = 1

        let version: Int
        let createdAt: Date
        let records: [DatasetRecord]
        let stagedAudioPaths: [String]
        let missingAudioPaths: [String]

        init(
            version: Int = currentVersion,
            createdAt: Date,
            records: [DatasetRecord],
            stagedAudioPaths: [String],
            missingAudioPaths: [String]
        ) {
            self.version = version
            self.createdAt = createdAt
            self.records = records
            self.stagedAudioPaths = stagedAudioPaths
            self.missingAudioPaths = missingAudioPaths
        }
    }

    private let datasetStore: any DatasetDeletionDatabase
    private let audioFileStore: AudioFileStore
    private let recoveryRoot: URL
    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> String
    private var operationInProgress = false

    init(
        datasetStore: any DatasetDeletionDatabase,
        audioFileStore: AudioFileStore,
        recoveryRoot: URL,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = Date.init,
        makeID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.datasetStore = datasetStore
        self.audioFileStore = audioFileStore
        self.recoveryRoot = recoveryRoot.standardizedFileURL.resolvingSymlinksInPath()
        self.fileManager = fileManager
        self.now = now
        self.makeID = makeID
    }

    func delete(ids: Set<String>) async throws -> DatasetDeletionReport {
        try beginOperation()
        defer { finishOperation() }
        guard !ids.isEmpty else { throw DeletionError.noRecordsSelected }
        let records = try await recordsForDeletion(ids: ids)
        return try await delete(records: records) {
            try await self.datasetStore.delete(ids: ids)
        }
    }

    func deleteAll() async throws -> DatasetDeletionReport {
        try beginOperation()
        defer { finishOperation() }
        let records = try await datasetStore.all()
        guard !records.isEmpty else { throw DeletionError.noRecordsSelected }
        let ids = Set(records.map(\.id))
        return try await delete(records: records) {
            // Delete the captured snapshot, not "whatever exists now": a recording saved while audio
            // is being staged must remain live and must never lose its newly-written DB row.
            try await self.datasetStore.delete(ids: ids)
        }
    }

    /// Resolves every durable deletion batch before any interactive UI is shown.
    ///
    /// Invariant: a live audio file is never removed before the manifest's atomic write succeeds.
    /// Therefore a `deletion-*` directory without `manifest.json` contains only redundant copies and
    /// is safe to purge. A complete manifest is resolved solely from the database transaction state:
    /// all rows present means rollback, all absent means commit, and a mixed set is never guessed.
    func reconcileInterruptedDeletions() async throws {
        try beginOperation()
        defer { finishOperation() }

        guard fileManager.fileExists(atPath: recoveryRoot.path) else { return }
        let candidates: [URL]
        do {
            candidates = try fileManager.contentsOfDirectory(
                at: recoveryRoot,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
            .filter { $0.lastPathComponent.hasPrefix("deletion-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            throw DeletionError.recoveryScanFailed(
                recoveryRoot: recoveryRoot,
                reason: error.localizedDescription
            )
        }

        for candidate in candidates {
            let batch = try validatedBatchDirectory(candidate)
            let manifestURL = batch.appendingPathComponent("manifest.json", isDirectory: false)
            guard fileManager.fileExists(atPath: manifestURL.path) else {
                // Proven safe by the write-before-remove invariant documented above.
                try purgeReconciledBatch(batch)
                continue
            }

            let manifest = try await readAndValidateManifest(at: manifestURL, batch: batch)
            var currentRecords: [String: DatasetRecord] = [:]
            var deletedRecordIDs: [String] = []
            do {
                for snapshot in manifest.records {
                    if let current = try await datasetStore.fetch(id: snapshot.id) {
                        currentRecords[snapshot.id] = current
                    } else {
                        deletedRecordIDs.append(snapshot.id)
                    }
                }
            } catch {
                throw DeletionError.corruptRecoveryBatch(
                    recoveryDirectory: batch,
                    reason: String(
                        localized: "The dataset state could not be read: \(error.localizedDescription)")
                )
            }

            if currentRecords.isEmpty {
                // The exact database transaction committed. Recovery copies are no longer needed.
                try purgeReconciledBatch(batch)
                continue
            }

            guard deletedRecordIDs.isEmpty else {
                throw DeletionError.mixedRecoveryState(
                    recoveryDirectory: batch,
                    liveRecordIDs: currentRecords.keys.sorted(),
                    deletedRecordIDs: deletedRecordIDs.sorted()
                )
            }

            for snapshot in manifest.records {
                guard currentRecords[snapshot.id]?.audioPath == snapshot.audioPath else {
                    throw DeletionError.corruptRecoveryBatch(
                        recoveryDirectory: batch,
                        reason: String(localized: "Record \(snapshot.id) now points to a different audio path.")
                    )
                }
            }

            for relativePath in manifest.stagedAudioPaths {
                let recoveryFile: AudioFileStore.RecoveryFile
                do {
                    recoveryFile = try await audioFileStore.recoveryFile(
                        relativePath: relativePath,
                        recoveryDirectory: batch
                    )
                } catch {
                    throw DeletionError.corruptRecoveryBatch(
                        recoveryDirectory: batch,
                        reason: error.localizedDescription
                    )
                }
                let liveExists: Bool
                do {
                    liveExists = try await audioFileStore.fileExists(relativePath: relativePath)
                } catch {
                    throw DeletionError.corruptRecoveryBatch(
                        recoveryDirectory: batch,
                        reason: error.localizedDescription
                    )
                }
                guard !liveExists else { continue }

                var isDirectory: ObjCBool = false
                guard
                    fileManager.fileExists(
                        atPath: recoveryFile.recoveryURL.path,
                        isDirectory: &isDirectory
                    ), !isDirectory.boolValue
                else {
                    throw DeletionError.irrecoverableRecovery(
                        recoveryDirectory: batch,
                        audioPath: relativePath,
                        reason: String(localized: "The recovery copy is missing.")
                    )
                }
                do {
                    try await audioFileStore.restore(recoveryFile)
                } catch {
                    throw DeletionError.irrecoverableRecovery(
                        recoveryDirectory: batch,
                        audioPath: relativePath,
                        reason: error.localizedDescription
                    )
                }
            }
            try purgeReconciledBatch(batch)
        }
    }

    private func beginOperation() throws {
        guard !operationInProgress else { throw DeletionError.operationInProgress }
        operationInProgress = true
    }

    private func finishOperation() {
        operationInProgress = false
    }

    private func recordsForDeletion(ids: Set<String>) async throws -> [DatasetRecord] {
        var records: [DatasetRecord] = []
        records.reserveCapacity(ids.count)
        for id in ids.sorted() {
            guard let record = try await datasetStore.fetch(id: id) else {
                throw DatasetStore.StoreError.recordsNotFound([id])
            }
            records.append(record)
        }
        return records
    }

    private func delete(
        records: [DatasetRecord],
        databaseMutation: () async throws -> [DatasetRecord]
    ) async throws -> DatasetDeletionReport {
        let recoveryDirectory =
            recoveryRoot
            .appendingPathComponent("deletion-\(makeID())", isDirectory: true)
        let manifestURL = recoveryDirectory.appendingPathComponent("manifest.json")
        var recoveryFiles: [AudioFileStore.RecoveryFile] = []
        var missingAudioPaths: [String] = []

        do {
            do {
                try fileManager.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
            } catch {
                throw DeletionError.manifestWriteFailed(recoveryDirectory, error.localizedDescription)
            }
            for record in records {
                do {
                    let recoveryFile = try await audioFileStore.stageForDeletion(
                        relativePath: record.audioPath,
                        recoveryDirectory: recoveryDirectory
                    )
                    recoveryFiles.append(recoveryFile)
                } catch AudioFileStore.StoreError.sourceMissing {
                    missingAudioPaths.append(record.audioPath)
                } catch {
                    throw DeletionError.audioStagingFailed(
                        path: record.audioPath,
                        reason: error.localizedDescription
                    )
                }
            }
            let manifest = RecoveryManifest(
                createdAt: now(),
                records: records,
                stagedAudioPaths: recoveryFiles.map(\.relativePath).sorted(),
                missingAudioPaths: missingAudioPaths.sorted()
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            do {
                try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
            } catch {
                throw DeletionError.manifestWriteFailed(manifestURL, error.localizedDescription)
            }
        } catch {
            let failed = await rollback(recoveryFiles)
            if !failed.isEmpty {
                throw DeletionError.rollbackIncomplete(
                    recoveryDirectory: recoveryDirectory,
                    failedPaths: failed,
                    reason: error.localizedDescription
                )
            }
            if fileManager.fileExists(atPath: recoveryDirectory.path) {
                do {
                    try fileManager.removeItem(at: recoveryDirectory)
                } catch {
                    throw DeletionError.rollbackCleanupFailed(
                        recoveryDirectory: recoveryDirectory,
                        reason: error.localizedDescription
                    )
                }
            }
            throw error
        }

        do {
            for recoveryFile in recoveryFiles {
                try await audioFileStore.removeOriginal(for: recoveryFile)
            }
        } catch {
            let failed = await rollback(recoveryFiles)
            if !failed.isEmpty {
                throw DeletionError.rollbackIncomplete(
                    recoveryDirectory: recoveryDirectory,
                    failedPaths: failed,
                    reason: error.localizedDescription
                )
            }
            if fileManager.fileExists(atPath: recoveryDirectory.path) {
                do {
                    try fileManager.removeItem(at: recoveryDirectory)
                } catch {
                    throw DeletionError.rollbackCleanupFailed(
                        recoveryDirectory: recoveryDirectory,
                        reason: error.localizedDescription
                    )
                }
            }
            throw DeletionError.audioStagingFailed(
                path: recoveryDirectory.path,
                reason: error.localizedDescription
            )
        }

        do {
            let deleted = try await databaseMutation()
            do {
                try fileManager.removeItem(at: recoveryDirectory)
            } catch {
                throw DeletionError.purgeFailed(
                    recoveryDirectory: recoveryDirectory,
                    deletedRecordCount: deleted.count,
                    reason: error.localizedDescription
                )
            }
            return DatasetDeletionReport(
                deletedRecordIDs: deleted.map(\.id).sorted(),
                missingAudioPaths: missingAudioPaths.sorted()
            )
        } catch {
            if case DeletionError.purgeFailed = error {
                throw error
            }
            let mutationError = error
            let databaseState: (
                liveRecords: [String: DatasetRecord],
                deletedRecordIDs: [String]
            )
            do {
                databaseState = try await inspectDatabaseState(records: records)
            } catch {
                // A thrown mutation can mean "failed before commit" or "committed, then failed to
                // report success." Without readable row state, restoring or purging would guess.
                throw DeletionError.ambiguousDatabaseDelete(
                    recoveryDirectory: recoveryDirectory,
                    reason: String(
                        localized:
                            "The database operation reported \(mutationError.localizedDescription), and its resulting row state could not be read: \(error.localizedDescription)"
                    )
                )
            }

            if databaseState.liveRecords.isEmpty {
                // Every manifest row is absent: the exact delete committed despite the thrown
                // result. Keep live audio deleted and purge only the manifest-owned recovery batch.
                do {
                    try fileManager.removeItem(at: recoveryDirectory)
                } catch {
                    throw DeletionError.purgeFailed(
                        recoveryDirectory: recoveryDirectory,
                        deletedRecordCount: records.count,
                        reason: error.localizedDescription
                    )
                }
                return DatasetDeletionReport(
                    deletedRecordIDs: records.map(\.id).sorted(),
                    missingAudioPaths: missingAudioPaths.sorted()
                )
            }

            guard databaseState.deletedRecordIDs.isEmpty else {
                // A partial commit has no safe automatic direction: restoring all audio would
                // orphan files for deleted rows, while purging would break the rows still present.
                throw DeletionError.mixedRecoveryState(
                    recoveryDirectory: recoveryDirectory,
                    liveRecordIDs: databaseState.liveRecords.keys.sorted(),
                    deletedRecordIDs: databaseState.deletedRecordIDs.sorted()
                )
            }

            for snapshot in records {
                guard databaseState.liveRecords[snapshot.id]?.audioPath == snapshot.audioPath else {
                    throw DeletionError.ambiguousDatabaseDelete(
                        recoveryDirectory: recoveryDirectory,
                        reason: String(
                            localized:
                                "Record \(snapshot.id) now points to a different audio path after the database operation reported \(mutationError.localizedDescription)."
                        )
                    )
                }
            }

            // Every exact snapshot row still exists, proving the transaction did not commit.
            let failed = await rollback(recoveryFiles)
            if !failed.isEmpty {
                throw DeletionError.rollbackIncomplete(
                    recoveryDirectory: recoveryDirectory,
                    failedPaths: failed,
                    reason: mutationError.localizedDescription
                )
            }
            do {
                try fileManager.removeItem(at: recoveryDirectory)
            } catch {
                throw DeletionError.rollbackCleanupFailed(
                    recoveryDirectory: recoveryDirectory,
                    reason: error.localizedDescription
                )
            }
            throw DeletionError.databaseDeleteFailed(mutationError.localizedDescription)
        }
    }

    private func inspectDatabaseState(
        records: [DatasetRecord]
    ) async throws -> (
        liveRecords: [String: DatasetRecord],
        deletedRecordIDs: [String]
    ) {
        var liveRecords: [String: DatasetRecord] = [:]
        var deletedRecordIDs: [String] = []
        liveRecords.reserveCapacity(records.count)
        deletedRecordIDs.reserveCapacity(records.count)
        for snapshot in records {
            if let current = try await datasetStore.fetch(id: snapshot.id) {
                liveRecords[snapshot.id] = current
            } else {
                deletedRecordIDs.append(snapshot.id)
            }
        }
        return (liveRecords, deletedRecordIDs)
    }

    private func validatedBatchDirectory(_ candidate: URL) throws -> URL {
        let values: URLResourceValues
        do {
            values = try candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        } catch {
            throw DeletionError.corruptRecoveryBatch(
                recoveryDirectory: candidate,
                reason: error.localizedDescription
            )
        }
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        guard values.isDirectory == true,
            values.isSymbolicLink != true,
            resolved.deletingLastPathComponent() == recoveryRoot,
            resolved.lastPathComponent.hasPrefix("deletion-")
        else {
            throw DeletionError.corruptRecoveryBatch(
                recoveryDirectory: candidate,
                reason: String(
                    localized: "The recovery batch is not a direct, non-symbolic-link directory.")
            )
        }
        return resolved
    }

    private func readAndValidateManifest(
        at manifestURL: URL,
        batch: URL
    ) async throws -> RecoveryManifest {
        do {
            let values = try manifestURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            let resolvedManifest = manifestURL.standardizedFileURL.resolvingSymlinksInPath()
            guard values.isRegularFile == true,
                values.isSymbolicLink != true,
                resolvedManifest.deletingLastPathComponent() == batch
            else {
                throw DeletionError.corruptRecoveryBatch(
                    recoveryDirectory: batch,
                    reason: String(localized: "The recovery manifest is not a regular file inside its batch.")
                )
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let manifest = try decoder.decode(
                RecoveryManifest.self,
                from: Data(contentsOf: resolvedManifest)
            )
            try await validate(manifest: manifest, batch: batch)
            return manifest
        } catch let error as DeletionError {
            throw error
        } catch {
            throw DeletionError.corruptRecoveryBatch(
                recoveryDirectory: batch,
                reason: error.localizedDescription
            )
        }
    }

    private func validate(manifest: RecoveryManifest, batch: URL) async throws {
        guard manifest.version == RecoveryManifest.currentVersion else {
            throw DeletionError.corruptRecoveryBatch(
                recoveryDirectory: batch,
                reason: String(localized: "The recovery manifest version is unsupported.")
            )
        }
        let recordIDs = manifest.records.map(\.id)
        let recordPaths = manifest.records.map(\.audioPath)
        let staged = manifest.stagedAudioPaths
        let missing = manifest.missingAudioPaths
        let stagedSet = Set(staged)
        let missingSet = Set(missing)
        guard !recordIDs.isEmpty,
            Set(recordIDs).count == recordIDs.count,
            Set(recordPaths).count == recordPaths.count,
            stagedSet.count == staged.count,
            missingSet.count == missing.count,
            stagedSet.isDisjoint(with: missingSet),
            stagedSet.union(missingSet) == Set(recordPaths)
        else {
            throw DeletionError.corruptRecoveryBatch(
                recoveryDirectory: batch,
                reason: String(
                    localized:
                        "The recovery manifest contains duplicate or inconsistent records and audio paths.")
            )
        }
        for path in recordPaths {
            do {
                _ = try await audioFileStore.recoveryFile(
                    relativePath: path,
                    recoveryDirectory: batch
                )
            } catch {
                throw DeletionError.corruptRecoveryBatch(
                    recoveryDirectory: batch,
                    reason: error.localizedDescription
                )
            }
        }
    }

    private func purgeReconciledBatch(_ batch: URL) throws {
        do {
            try fileManager.removeItem(at: batch)
        } catch {
            throw DeletionError.recoveryPurgeFailed(
                recoveryDirectory: batch,
                reason: error.localizedDescription
            )
        }
    }

    private func rollback(_ recoveryFiles: [AudioFileStore.RecoveryFile]) async -> [String] {
        var failures: [String] = []
        for recoveryFile in recoveryFiles.reversed() {
            do {
                try await audioFileStore.restore(recoveryFile)
            } catch {
                failures.append(recoveryFile.relativePath)
            }
        }
        return failures.sorted()
    }
}

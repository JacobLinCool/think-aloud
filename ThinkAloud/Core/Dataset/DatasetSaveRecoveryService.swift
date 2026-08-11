import Foundation

protocol DatasetSaveRecoveryDatabase: Sendable {
    func fetch(id: String) async throws -> DatasetRecord?
}

extension DatasetStore: DatasetSaveRecoveryDatabase {}

struct DatasetSaveRecoveryManifest: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let createdAt: Date
    let recordID: String
    let audioPath: String

    init(
        version: Int = currentVersion,
        createdAt: Date,
        recordID: String,
        audioPath: String
    ) {
        self.version = version
        self.createdAt = createdAt
        self.recordID = recordID
        self.audioPath = audioPath
    }
}

struct DatasetSaveRecoveryResolution: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case discarded
        case committedRecordPreserved
    }

    let state: State
    /// Non-nil means the substantive audio/database state is safe, but the durable manifest could
    /// not be removed. It remains available for startup reconciliation.
    let manifestCleanupFailure: String?

    var hasPendingManifestCleanup: Bool {
        manifestCleanupFailure != nil
    }
}

protocol DatasetSaveRecoveryManaging: Sendable {
    func prepare(
        recordID: String,
        recordingStartedAt: Date
    ) async throws -> DatasetSaveRecoveryManifest

    func complete(
        _ manifest: DatasetSaveRecoveryManifest
    ) async throws -> DatasetSaveRecoveryResolution

    func discard(
        _ manifest: DatasetSaveRecoveryManifest
    ) async throws -> DatasetSaveRecoveryResolution
}

/// Coordinates the file/database boundary for a new dataset record.
///
/// The manifest is atomically written before audio persistence. Startup reconciliation can then
/// distinguish every crash point without scanning or guessing at unrelated files:
///
/// - no database row: remove the exact canonical audio path named by the manifest;
/// - matching database row: preserve its audio and remove only the manifest;
/// - different row/path or malformed manifest: stop and preserve everything for inspection.
actor DatasetSaveRecoveryService: DatasetSaveRecoveryManaging {
    enum RecoveryError: Error, LocalizedError {
        case operationInProgress
        case recoveryRootInvalid(URL, String)
        case recoveryScanFailed(URL, String)
        case manifestAlreadyExists(URL)
        case manifestWriteFailed(URL, String)
        case corruptManifest(URL, String)
        case datasetReadFailed(URL, String)
        case recordPathMismatch(URL, recordID: String, expected: String, actual: String)
        case recordNotCommitted(URL, recordID: String)
        case audioCleanupFailed(String, String)
        case manifestRemovalFailed(URL, String)

        var errorDescription: String? {
            switch self {
            case .operationInProgress:
                return String(
                    localized: "Another interrupted-save recovery is already in progress. Wait for it to finish and try again."
                )
            case .recoveryRootInvalid(let root, let reason):
                return String(
                    localized: "The interrupted-save recovery folder at \(root.path) is invalid. Keep it unchanged and check its permissions. \(reason)"
                )
            case .recoveryScanFailed(let root, let reason):
                return String(
                    localized: "ThinkAloud could not inspect interrupted saves in \(root.path). Keep this folder unchanged and check its permissions before reopening the app. \(reason)"
                )
            case .manifestAlreadyExists(let url):
                return String(
                    localized: "An interrupted-save manifest already exists at \(url.path). Reopen ThinkAloud so it can reconcile that save before recording again."
                )
            case .manifestWriteFailed(let url, let reason):
                return String(
                    localized: "ThinkAloud could not create the interrupted-save manifest at \(url.path). No audio was written. \(reason)"
                )
            case .corruptManifest(let url, let reason):
                return String(
                    localized: "ThinkAloud found an invalid interrupted-save manifest at \(url.path). It was left unchanged. Restore it from backup or contact support. \(reason)"
                )
            case .datasetReadFailed(let url, let reason):
                return String(
                    localized: "ThinkAloud could not compare \(url.path) with the local dataset. The manifest and audio were left unchanged. \(reason)"
                )
            case .recordPathMismatch(let url, let recordID, let expected, let actual):
                return String(
                    localized: "Record \(recordID) points to \(actual), but \(url.path) names \(expected). Both were left unchanged; restore from backup or contact support."
                )
            case .recordNotCommitted(let url, let recordID):
                return String(
                    localized: "ThinkAloud could not complete \(url.path) because record \(recordID) is not in the local dataset."
                )
            case .audioCleanupFailed(let path, let reason):
                return String(
                    localized: "ThinkAloud could not remove the unsaved audio at \(path). The recovery manifest was retained so Close or the next launch can retry. \(reason)"
                )
            case .manifestRemovalFailed(let url, let reason):
                return String(
                    localized: "ThinkAloud reconciled the interrupted save but could not remove \(url.path). Check the folder permissions and try again. \(reason)"
                )
            }
        }
    }

    private let datasetStore: any DatasetSaveRecoveryDatabase
    private let audioFileStore: AudioFileStore
    private let recoveryRoot: URL
    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    private var operationInProgress = false

    init(
        datasetStore: any DatasetSaveRecoveryDatabase,
        audioFileStore: AudioFileStore,
        recoveryRoot: URL,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.datasetStore = datasetStore
        self.audioFileStore = audioFileStore
        self.recoveryRoot = recoveryRoot.standardizedFileURL
        self.fileManager = fileManager
        self.now = now
    }

    func prepare(
        recordID: String,
        recordingStartedAt: Date
    ) async throws -> DatasetSaveRecoveryManifest {
        try beginOperation()
        defer { finishOperation() }

        let audioPath = try await audioFileStore.canonicalRelativePath(
            recordID: recordID,
            at: recordingStartedAt
        )
        try await audioFileStore.validateCanonical(
            relativePath: audioPath,
            recordID: recordID
        )
        try ensureRecoveryRoot()

        let manifestURL = recoveryRoot.appendingPathComponent(
            "\(recordID).json",
            isDirectory: false
        )
        guard !fileManager.fileExists(atPath: manifestURL.path) else {
            throw RecoveryError.manifestAlreadyExists(manifestURL)
        }
        let manifest = DatasetSaveRecoveryManifest(
            createdAt: now(),
            recordID: recordID,
            audioPath: audioPath
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
        } catch {
            throw RecoveryError.manifestWriteFailed(
                manifestURL,
                error.localizedDescription
            )
        }
        return manifest
    }

    /// Removes the manifest only after proving the database row committed with the same audio path.
    /// If manifest removal fails, both the committed record and its audio remain valid; startup will
    /// retry removing the stale manifest.
    func complete(
        _ manifest: DatasetSaveRecoveryManifest
    ) async throws -> DatasetSaveRecoveryResolution {
        try beginOperation()
        defer { finishOperation() }

        let (stored, manifestURL) = try await readExpectedManifest(manifest)
        let record = try await readRecord(for: stored, manifestURL: manifestURL)
        guard let record else {
            throw RecoveryError.recordNotCommitted(
                manifestURL,
                recordID: stored.recordID
            )
        }
        try validate(record: record, against: stored, manifestURL: manifestURL)
        return removeManifestIfPossible(
            at: manifestURL,
            resolvedState: .committedRecordPreserved
        )
    }

    /// Abandons an in-memory save only after consulting the database. A matching committed row is
    /// never allowed to lose its audio, even if the preceding database call returned an ambiguous
    /// error after commit.
    func discard(
        _ manifest: DatasetSaveRecoveryManifest
    ) async throws -> DatasetSaveRecoveryResolution {
        try beginOperation()
        defer { finishOperation() }

        let (stored, manifestURL) = try await readExpectedManifest(manifest)
        return try await resolve(stored, manifestURL: manifestURL)
    }

    /// Resolves durable manifests before any interactive surface is presented.
    func reconcileInterruptedSaves() async throws {
        try beginOperation()
        defer { finishOperation() }

        guard fileManager.fileExists(atPath: recoveryRoot.path) else { return }
        try validateExistingRecoveryRoot()

        let candidates: [URL]
        do {
            candidates = try fileManager.contentsOfDirectory(
                at: recoveryRoot,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            throw RecoveryError.recoveryScanFailed(
                recoveryRoot,
                error.localizedDescription
            )
        }

        for manifestURL in candidates {
            let manifest = try await readManifest(at: manifestURL)
            let resolution = try await resolve(manifest, manifestURL: manifestURL)
            if let reason = resolution.manifestCleanupFailure {
                throw RecoveryError.manifestRemovalFailed(manifestURL, reason)
            }
        }
    }

    private func resolve(
        _ manifest: DatasetSaveRecoveryManifest,
        manifestURL: URL
    ) async throws -> DatasetSaveRecoveryResolution {
        let resolvedState: DatasetSaveRecoveryResolution.State
        let record = try await readRecord(for: manifest, manifestURL: manifestURL)
        if let record {
            try validate(record: record, against: manifest, manifestURL: manifestURL)
            resolvedState = .committedRecordPreserved
        } else {
            do {
                if try await audioFileStore.fileExists(relativePath: manifest.audioPath) {
                    try await audioFileStore.delete(relativePath: manifest.audioPath)
                }
            } catch AudioFileStore.StoreError.sourceMissing {
                // A concurrent retry can remove the exact same canonical audio between the existence
                // check and deletion. Missing is already the desired discarded state.
            } catch {
                throw RecoveryError.audioCleanupFailed(
                    manifest.audioPath,
                    error.localizedDescription
                )
            }
            resolvedState = .discarded
        }
        return removeManifestIfPossible(
            at: manifestURL,
            resolvedState: resolvedState
        )
    }

    private func readRecord(
        for manifest: DatasetSaveRecoveryManifest,
        manifestURL: URL
    ) async throws -> DatasetRecord? {
        do {
            return try await datasetStore.fetch(id: manifest.recordID)
        } catch {
            throw RecoveryError.datasetReadFailed(
                manifestURL,
                error.localizedDescription
            )
        }
    }

    private func validate(
        record: DatasetRecord,
        against manifest: DatasetSaveRecoveryManifest,
        manifestURL: URL
    ) throws {
        guard record.audioPath == manifest.audioPath else {
            throw RecoveryError.recordPathMismatch(
                manifestURL,
                recordID: manifest.recordID,
                expected: manifest.audioPath,
                actual: record.audioPath
            )
        }
    }

    private func readExpectedManifest(
        _ expected: DatasetSaveRecoveryManifest
    ) async throws -> (DatasetSaveRecoveryManifest, URL) {
        let manifestURL = recoveryRoot.appendingPathComponent(
            "\(expected.recordID).json",
            isDirectory: false
        )
        let stored = try await readManifest(at: manifestURL)
        guard stored.recordID == expected.recordID,
              stored.audioPath == expected.audioPath
        else {
            throw RecoveryError.corruptManifest(
                manifestURL,
                String(localized: "The in-memory recovery identity does not match the durable manifest.")
            )
        }
        return (stored, manifestURL)
    }

    private func readManifest(at candidate: URL) async throws -> DatasetSaveRecoveryManifest {
        do {
            let values = try candidate.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            let resolvedRoot = recoveryRoot.resolvingSymlinksInPath()
            let resolvedManifest = candidate.standardizedFileURL.resolvingSymlinksInPath()
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  resolvedManifest.deletingLastPathComponent() == resolvedRoot,
                  resolvedManifest.pathExtension == "json"
            else {
                throw RecoveryError.corruptManifest(
                    candidate,
                    String(localized: "The manifest is not a direct, non-symbolic-link JSON file.")
                )
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let manifest = try decoder.decode(
                DatasetSaveRecoveryManifest.self,
                from: Data(contentsOf: resolvedManifest)
            )
            guard manifest.version == DatasetSaveRecoveryManifest.currentVersion else {
                throw RecoveryError.corruptManifest(
                    resolvedManifest,
                    String(localized: "Unsupported manifest version \(manifest.version).")
                )
            }
            guard resolvedManifest.lastPathComponent == "\(manifest.recordID).json" else {
                throw RecoveryError.corruptManifest(
                    resolvedManifest,
                    String(localized: "The manifest filename does not match its record identifier.")
                )
            }
            do {
                try await audioFileStore.validateCanonical(
                    relativePath: manifest.audioPath,
                    recordID: manifest.recordID
                )
            } catch {
                throw RecoveryError.corruptManifest(
                    resolvedManifest,
                    error.localizedDescription
                )
            }
            return manifest
        } catch let error as RecoveryError {
            throw error
        } catch {
            throw RecoveryError.corruptManifest(
                candidate,
                error.localizedDescription
            )
        }
    }

    private func ensureRecoveryRoot() throws {
        if fileManager.fileExists(atPath: recoveryRoot.path) {
            try validateExistingRecoveryRoot()
            return
        }
        do {
            try fileManager.createDirectory(
                at: recoveryRoot,
                withIntermediateDirectories: true
            )
            try validateExistingRecoveryRoot()
        } catch let error as RecoveryError {
            throw error
        } catch {
            throw RecoveryError.recoveryRootInvalid(
                recoveryRoot,
                error.localizedDescription
            )
        }
    }

    private func validateExistingRecoveryRoot() throws {
        do {
            let values = try recoveryRoot.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values.isDirectory == true,
                  values.isSymbolicLink != true
            else {
                throw RecoveryError.recoveryRootInvalid(
                    recoveryRoot,
                    String(localized: "The recovery root must be a non-symbolic-link directory.")
                )
            }
        } catch let error as RecoveryError {
            throw error
        } catch {
            throw RecoveryError.recoveryRootInvalid(
                recoveryRoot,
                error.localizedDescription
            )
        }
    }

    private func removeManifestIfPossible(
        at manifestURL: URL,
        resolvedState: DatasetSaveRecoveryResolution.State
    ) -> DatasetSaveRecoveryResolution {
        do {
            try fileManager.removeItem(at: manifestURL)
            return DatasetSaveRecoveryResolution(
                state: resolvedState,
                manifestCleanupFailure: nil
            )
        } catch {
            return DatasetSaveRecoveryResolution(
                state: resolvedState,
                manifestCleanupFailure: error.localizedDescription
            )
        }
    }

    private func beginOperation() throws {
        guard !operationInProgress else {
            throw RecoveryError.operationInProgress
        }
        operationInProgress = true
    }

    private func finishOperation() {
        operationInProgress = false
    }
}

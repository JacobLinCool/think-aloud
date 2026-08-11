import Foundation
import GRDB

protocol DatasetRecordWriting: Sendable {
    func save(_ record: DatasetRecord) async throws
}

actor DatasetStore: DatasetRecordWriting {
    struct SearchPage: Sendable, Equatable {
        let records: [DatasetRecord]
        let totalCount: Int
        let offset: Int

        var hasMore: Bool { offset + records.count < totalCount }
    }

    enum StoreError: Error, LocalizedError {
        case recordsNotFound([String])
        case audioStorageEnumerationFailed(String)
        case audioStorageMetadataFailed(String, String)
        case missingRequiredAutoEditedTranscript(recordID: String)

        var errorDescription: String? {
            switch self {
            case .recordsNotFound(let ids):
                return String(
                    localized: "Could not find \(ids.count) record(s): \(ids.sorted().joined(separator: ", "))."
                )
            case .audioStorageEnumerationFailed(let path):
                return String(localized: "Could not enumerate the audio folder: \(path)")
            case .audioStorageMetadataFailed(let path, let reason):
                return String(localized: "Could not read audio storage metadata for \(path): \(reason)")
            case .missingRequiredAutoEditedTranscript(let recordID):
                return String(
                    localized: "Record \(recordID) is missing its required Auto Post-Edit text."
                )
            }
        }
    }

    private let database: LocalDatabase

    init(database: LocalDatabase) {
        self.database = database
    }

    init(databaseURL: URL) {
        self.init(database: LocalDatabase(fileURL: databaseURL))
    }

    nonisolated var databaseFileURL: URL { database.fileURL }

    func setup() throws {
        try database.setup()
    }

    func save(_ record: DatasetRecord) async throws {
        let pool = try database.connection()
        guard record.autoEditedTranscript != nil else {
            throw StoreError.missingRequiredAutoEditedTranscript(recordID: record.id)
        }
        try await pool.write { db in
            try record.save(db)
        }
    }

    func count() throws -> Int {
        let pool = try database.connection()
        return try pool.read { db in
            try DatasetRecord.fetchCount(db)
        }
    }

    func all() throws -> [DatasetRecord] {
        let pool = try database.connection()
        return try pool.read { db in
            try DatasetRecord
                .order(Column("created_at").desc)
                .fetchAll(db)
        }
    }

    /// Returns at most `limit` records starting at `offset`, sorted newest first.
    /// Used by the browser to lazy-load as the user scrolls.
    func page(offset: Int, limit: Int) throws -> [DatasetRecord] {
        let pool = try database.connection()
        return try pool.read { db in
            try DatasetRecord
                .order(Column("created_at").desc)
                .limit(limit, offset: offset)
                .fetchAll(db)
        }
    }

    /// Searches the full dataset, not just rows currently loaded by the browser.
    ///
    /// `%` and `_` are escaped so user input is always literal text rather than an accidental LIKE
    /// program. Bound parameters keep transcripts and app names out of SQL syntax.
    func search(query: String, offset: Int, limit: Int) throws -> SearchPage {
        let pool = try database.connection()
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeOffset = max(0, offset)
        let safeLimit = max(1, limit)
        return try pool.read { db in
            if normalizedQuery.isEmpty {
                let records = try DatasetRecord
                    .order(Column("created_at").desc)
                    .limit(safeLimit, offset: safeOffset)
                    .fetchAll(db)
                return SearchPage(
                    records: records,
                    totalCount: try DatasetRecord.fetchCount(db),
                    offset: safeOffset
                )
            }

            let pattern = "%\(Self.escapeLikeLiteral(normalizedQuery))%"
            let predicate = """
                (
                    id LIKE ? ESCAPE '\\' COLLATE NOCASE OR
                    edited_transcript LIKE ? ESCAPE '\\' COLLATE NOCASE OR
                    raw_transcript LIKE ? ESCAPE '\\' COLLATE NOCASE OR
                    source_app_name LIKE ? ESCAPE '\\' COLLATE NOCASE OR
                    source_app_bundle_id LIKE ? ESCAPE '\\' COLLATE NOCASE
                )
                """
            let searchArguments: StatementArguments = [
                pattern, pattern, pattern, pattern, pattern
            ]
            let records = try DatasetRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM records
                    WHERE \(predicate)
                    ORDER BY created_at DESC
                    LIMIT ? OFFSET ?
                    """,
                arguments: searchArguments + [safeLimit, safeOffset]
            )
            let totalCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM records WHERE \(predicate)",
                arguments: searchArguments
            ) ?? 0
            return SearchPage(records: records, totalCount: totalCount, offset: safeOffset)
        }
    }

    /// Aggregate statistics over Dataset records only. The table itself is the explicit collection;
    /// usage history lives in `dictation_sessions` and is never included here.
    func computeStatistics() async throws -> DatasetStatistics {
        let pool = try database.connection()
        // In this async context GRDB resolves `read` to its async overload (runs on a reader queue,
        // off the actor). The Levenshtein compute then runs on a detached task so it never resumes
        // on — and serializes behind — the actor's executor mid-dictation.
        let records = try await pool.read { db in
            try DatasetRecord.order(Column("created_at").desc).fetchAll(db)
        }
        return await Task.detached { DatasetStatistics.compute(from: records) }.value
    }

    func fetch(id: String) throws -> DatasetRecord? {
        let pool = try database.connection()
        return try pool.read { db in
            try DatasetRecord.fetchOne(db, key: id)
        }
    }

    /// Overwrites only the editedTranscript. We never version it — the user wanted
    /// "always keep raw, only keep the latest edited", so this is destructive on the edited side.
    func update(id: String, editedTranscript: String) throws {
        let pool = try database.connection()
        try pool.write { db in
            try db.execute(
                sql: "UPDATE records SET edited_transcript = ? WHERE id = ?",
                arguments: [editedTranscript, id]
            )
            guard db.changesCount == 1 else {
                throw StoreError.recordsNotFound([id])
            }
        }
    }

    /// Deletes exactly the requested records in one database transaction.
    ///
    /// Returning the deleted values lets the data-deletion coordinator preserve a complete recovery
    /// manifest. A missing id is an error: silently treating it as success would make the UI claim a
    /// record was deleted when no mutation occurred.
    @discardableResult
    func delete(ids: Set<String>) throws -> [DatasetRecord] {
        let pool = try database.connection()
        guard !ids.isEmpty else { return [] }
        return try pool.write { db in
            let records = try DatasetRecord
                .filter(ids.contains(Column("id")))
                .fetchAll(db)
            let found = Set(records.map(\.id))
            let missing = ids.subtracting(found)
            guard missing.isEmpty else {
                throw StoreError.recordsNotFound(Array(missing))
            }
            _ = try DatasetRecord
                .filter(ids.contains(Column("id")))
                .deleteAll(db)
            return records
        }
    }

    @discardableResult
    func delete(id: String) throws -> DatasetRecord {
        guard let record = try delete(ids: [id]).first else {
            throw StoreError.recordsNotFound([id])
        }
        return record
    }

    /// Deletes every current record atomically and returns the exact deleted snapshot.
    @discardableResult
    func deleteAll() throws -> [DatasetRecord] {
        let pool = try database.connection()
        return try pool.write { db in
            let records = try DatasetRecord.fetchAll(db)
            _ = try DatasetRecord.deleteAll(db)
            return records
        }
    }

    func totalAudioBytes(rootDirectory: URL) throws -> Int64 {
        let fm = FileManager.default
        var enumerationError: StoreError?
        guard let enumerator = fm.enumerator(
            at: rootDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey],
            errorHandler: { url, error in
                enumerationError = .audioStorageMetadataFailed(url.path, error.localizedDescription)
                return false
            }
        ) else {
            throw StoreError.audioStorageEnumerationFailed(rootDirectory.path)
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values: URLResourceValues
            do {
                values = try url.resourceValues(
                    forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
                )
            } catch {
                throw StoreError.audioStorageMetadataFailed(url.path, error.localizedDescription)
            }
            guard values.isRegularFile == true else { continue }
            guard let bytes = values.totalFileAllocatedSize ?? values.fileSize else {
                throw StoreError.audioStorageMetadataFailed(
                    url.path,
                    String(localized: "The file size is unavailable.")
                )
            }
            total += Int64(bytes)
        }
        if let enumerationError {
            throw enumerationError
        }
        return total
    }

    private nonisolated static func escapeLikeLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}

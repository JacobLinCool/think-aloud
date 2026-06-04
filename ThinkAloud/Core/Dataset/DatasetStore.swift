import Foundation
import GRDB

actor DatasetStore {
    enum StoreError: Error, LocalizedError {
        case notSetup
        var errorDescription: String? {
            switch self {
            case .notSetup: return "Dataset store is not initialized."
            }
        }
    }

    private let databaseURL: URL
    private var pool: DatabasePool?

    init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    nonisolated var databaseFileURL: URL { databaseURL }

    func setup() throws {
        if pool != nil { return }
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.label = "ThinkAloud.dataset"
        let pool = try DatabasePool(path: databaseURL.path, configuration: configuration)
        try migrator.migrate(pool)
        self.pool = pool
    }

    private var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("createRecords") { db in
            try db.create(table: "records") { t in
                t.column("id", .text).primaryKey()
                t.column("created_at", .text).notNull()

                t.column("audio_path", .text).notNull()
                t.column("duration_ms", .integer)
                t.column("sample_rate", .integer)
                t.column("channels", .integer)

                t.column("source_app_bundle_id", .text)
                t.column("source_app_name", .text)

                t.column("asr_provider", .text).notNull()
                t.column("asr_model", .text).notNull()
                t.column("asr_runtime", .text).notNull()
                t.column("asr_config_json", .text)

                t.column("raw_transcript", .text).notNull()
                t.column("edited_transcript", .text).notNull()

                t.column("inserted", .integer).notNull()
                t.column("saved_to_dataset", .integer).notNull()

                t.column("language", .text)
                t.column("metadata_json", .text)
            }
            try db.create(index: "records_created_at", on: "records", columns: ["created_at"])
        }
        // v0.4.0: capture the post-Auto-Post-Edit / pre-manual-edit transcript so statistics can
        // tell automatic formatting apart from real human corrections. Nullable + no backfill —
        // older rows keep NULL and are EXCLUDED from the edit/clean metrics (the engine never
        // substitutes raw_transcript for the missing intermediate).
        m.registerMigration("addAutoEditedTranscript") { db in
            try db.alter(table: "records") { t in
                t.add(column: "auto_edited_transcript", .text)
            }
        }
        return m
    }

    func save(_ record: DatasetRecord) throws {
        guard let pool else { throw StoreError.notSetup }
        try pool.write { db in
            try record.save(db)
        }
    }

    func count() throws -> Int {
        guard let pool else { throw StoreError.notSetup }
        return try pool.read { db in
            try DatasetRecord.fetchCount(db)
        }
    }

    func all() throws -> [DatasetRecord] {
        guard let pool else { throw StoreError.notSetup }
        return try pool.read { db in
            try DatasetRecord
                .order(Column("created_at").desc)
                .fetchAll(db)
        }
    }

    /// Returns at most `limit` records starting at `offset`, sorted newest first.
    /// Used by the browser to lazy-load as the user scrolls.
    func page(offset: Int, limit: Int) throws -> [DatasetRecord] {
        guard let pool else { throw StoreError.notSetup }
        return try pool.read { db in
            try DatasetRecord
                .order(Column("created_at").desc)
                .limit(limit, offset: offset)
                .fetchAll(db)
        }
    }

    /// Aggregate statistics over saved records. Reads once inside the actor, then runs the O(n·m)
    /// edit-distance compute on a detached task so it never serializes behind a live save while the
    /// user is dictating. Defense-in-depth: only `saved_to_dataset` rows feed the stats/publish path,
    /// so a future "review later" state can't silently widen what gets aggregated (and republished).
    func computeStatistics() async throws -> DatasetStatistics {
        guard let pool else { throw StoreError.notSetup }
        // In this async context GRDB resolves `read` to its async overload (runs on a reader queue,
        // off the actor). The Levenshtein compute then runs on a detached task so it never resumes
        // on — and serializes behind — the actor's executor mid-dictation.
        let records = try await pool.read { db in
            try DatasetRecord
                .filter(Column("saved_to_dataset") == true)
                .order(Column("created_at").desc)
                .fetchAll(db)
        }
        return await Task.detached { DatasetStatistics.compute(from: records) }.value
    }

    func fetch(id: String) throws -> DatasetRecord? {
        guard let pool else { throw StoreError.notSetup }
        return try pool.read { db in
            try DatasetRecord.fetchOne(db, key: id)
        }
    }

    /// Overwrites only the editedTranscript. We never version it — the user wanted
    /// "always keep raw, only keep the latest edited", so this is destructive on the edited side.
    func update(id: String, editedTranscript: String) throws {
        guard let pool else { throw StoreError.notSetup }
        try pool.write { db in
            try db.execute(
                sql: "UPDATE records SET edited_transcript = ? WHERE id = ?",
                arguments: [editedTranscript, id]
            )
        }
    }

    func delete(id: String) throws {
        guard let pool else { throw StoreError.notSetup }
        _ = try pool.write { db in
            try DatasetRecord.deleteOne(db, key: id)
        }
    }

    func deleteAll() throws {
        guard let pool else { throw StoreError.notSetup }
        try pool.write { db in
            _ = try DatasetRecord.deleteAll(db)
        }
    }

    func totalAudioBytes(rootDirectory: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: rootDirectory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }
}

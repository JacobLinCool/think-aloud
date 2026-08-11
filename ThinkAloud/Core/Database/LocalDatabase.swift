import Foundation
import GRDB

/// Owns the application's single SQLite pool and the complete local-data migration history.
/// Repositories receive this dependency and remain responsible only for their own tables.
final class LocalDatabase: @unchecked Sendable {
    enum DatabaseError: Error, LocalizedError {
        case notSetup

        var errorDescription: String? {
            String(localized: "The local database is not ready.")
        }
    }

    let fileURL: URL

    private let lock = NSLock()
    private var pool: DatabasePool?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func setup() throws {
        try lock.withLock {
            if pool != nil { return }
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            var configuration = Configuration()
            configuration.label = "ThinkAloud.local-data"
            let openedPool = try DatabasePool(path: fileURL.path, configuration: configuration)
            try Self.migrator.migrate(openedPool)
            pool = openedPool
        }
    }

    func connection() throws -> DatabasePool {
        try lock.withLock {
            guard let pool else { throw DatabaseError.notSetup }
            return pool
        }
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createRecords") { db in
            try db.create(table: "records") { table in
                table.column("id", .text).primaryKey()
                table.column("created_at", .text).notNull()
                table.column("audio_path", .text).notNull()
                table.column("duration_ms", .integer)
                table.column("sample_rate", .integer)
                table.column("channels", .integer)
                table.column("source_app_bundle_id", .text)
                table.column("source_app_name", .text)
                table.column("asr_provider", .text).notNull()
                table.column("asr_model", .text).notNull()
                table.column("asr_runtime", .text).notNull()
                table.column("asr_config_json", .text)
                table.column("raw_transcript", .text).notNull()
                table.column("edited_transcript", .text).notNull()
                table.column("inserted", .integer).notNull()
                table.column("saved_to_dataset", .integer).notNull()
                table.column("language", .text)
                table.column("metadata_json", .text)
            }
            try db.create(index: "records_created_at", on: "records", columns: ["created_at"])
        }
        // Historical rows remain nullable because this intermediate was not captured before v0.4.0.
        migrator.registerMigration("addAutoEditedTranscript") { db in
            try db.alter(table: "records") { table in
                table.add(column: "auto_edited_transcript", .text)
            }
        }
        migrator.registerMigration("addLLMEditedTranscript") { db in
            try db.alter(table: "records") { table in
                table.add(column: "llm_edited_transcript", .text)
            }
        }
        migrator.registerMigration("separateInsightsFromDataset") { db in
            // Membership is now expressed by the table itself. Removing this legacy flag prevents
            // Dataset queries from accidentally becoming a second source of truth.
            try db.execute(sql: "ALTER TABLE records DROP COLUMN saved_to_dataset")

            try db.create(table: "dictation_sessions") { table in
                table.column("id", .text).primaryKey()
                table.column("created_at", .text).notNull()
                table.column("duration_ms", .integer).notNull()
                table.column("sample_rate", .integer).notNull()
                table.column("channels", .integer).notNull()
                table.column("source_app_bundle_id", .text)
                table.column("source_app_name", .text)
                table.column("asr_provider", .text).notNull()
                table.column("asr_model", .text).notNull()
                table.column("asr_runtime", .text).notNull()
                table.column("language", .text)
                table.column("transcription_duration_ms", .integer).notNull()
                table.column("raw_transcript", .text).notNull()
                table.column("auto_edited_transcript", .text).notNull()
                table.column("llm_edited_transcript", .text)
                table.column("final_transcript", .text).notNull()
                table.column("action", .text).notNull()
                table.column("delivery_outcome", .text).notNull()
            }
            try db.create(
                index: "dictation_sessions_created_at",
                on: "dictation_sessions",
                columns: ["created_at"]
            )
        }
        return migrator
    }
}

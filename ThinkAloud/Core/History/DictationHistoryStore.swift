import Foundation
import GRDB

protocol DictationHistoryWriting: Sendable {
    func save(_ session: DictationSession) async throws
}

actor DictationHistoryStore: DictationHistoryWriting {
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

    /// Primary-key save is deliberately idempotent: every retry for one recording updates the same
    /// session instead of incrementing Insights again.
    func save(_ session: DictationSession) async throws {
        let pool = try database.connection()
        try await pool.write { db in
            try session.save(db)
        }
    }

    func count() throws -> Int {
        let pool = try database.connection()
        return try pool.read { db in
            try DictationSession.fetchCount(db)
        }
    }

    func fetch(id: String) throws -> DictationSession? {
        let pool = try database.connection()
        return try pool.read { db in
            try DictationSession.fetchOne(db, key: id)
        }
    }

    func all() throws -> [DictationSession] {
        let pool = try database.connection()
        return try pool.read { db in
            try DictationSession
                .order(Column("created_at").desc)
                .fetchAll(db)
        }
    }

    func computeStatistics() async throws -> DatasetStatistics {
        let pool = try database.connection()
        let sessions = try await pool.read { db in
            try DictationSession
                .order(Column("created_at").desc)
                .fetchAll(db)
        }
        return await Task.detached {
            DatasetStatistics.computeUsage(from: sessions)
        }.value
    }
}

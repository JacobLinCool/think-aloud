import Foundation

actor AudioFileStore {
    enum StoreError: Error, LocalizedError {
        case invalidRelativePath(String)
        case invalidRecordID
        case sourceMissing(String)
        case recoveryCollision(String)

        var errorDescription: String? {
            switch self {
            case .invalidRelativePath(let path):
                return String(localized: "The audio path is invalid: \(path)")
            case .invalidRecordID:
                return String(localized: "The recording identifier is empty or contains a path separator.")
            case .sourceMissing(let path):
                return String(localized: "The audio file is missing: \(path)")
            case .recoveryCollision(let path):
                return String(localized: "A recovery file already exists at \(path).")
            }
        }
    }

    struct RecoveryFile: Sendable, Equatable {
        let relativePath: String
        let originalURL: URL
        let recoveryURL: URL
    }

    private let rootDirectory: URL
    private let calendar: Calendar
    private let fileManager: FileManager

    init(rootDirectory: URL, calendar: Calendar = .current, fileManager: FileManager = .default) {
        self.rootDirectory = rootDirectory.standardizedFileURL.resolvingSymlinksInPath()
        self.calendar = calendar
        self.fileManager = fileManager
    }

    /// Persists a recorded audio file under audio/yyyy-MM-dd/<recordID>.wav, returning the relative path used for the dataset record.
    func persist(temporaryURL: URL, recordID: String, at date: Date = Date()) throws -> (storedURL: URL, relativePath: String) {
        let relativePath = try canonicalRelativePath(recordID: recordID, at: date)
        let storedURL = try validatedAbsoluteURL(for: relativePath)
        let folderURL = storedURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: storedURL.path) {
            try fileManager.removeItem(at: storedURL)
        }
        try fileManager.copyItem(at: temporaryURL, to: storedURL)
        return (storedURL, relativePath)
    }

    /// Writes a WAV directly from in-memory PCM samples into audio/yyyy-MM-dd/<recordID>.wav.
    /// Avoids the temp-file round-trip when the caller already holds the samples.
    func persist(samples: [Float], sampleRate: Double, recordID: String, at date: Date = Date()) throws -> (storedURL: URL, relativePath: String) {
        let relativePath = try canonicalRelativePath(recordID: recordID, at: date)
        let storedURL = try validatedAbsoluteURL(for: relativePath)
        let folderURL = storedURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: storedURL.path) {
            try fileManager.removeItem(at: storedURL)
        }
        try AudioRecorder.writeWavFile(samples: samples, sampleRate: sampleRate, to: storedURL)
        return (storedURL, relativePath)
    }

    /// Computes the only path shape created by this store. Callers can durably record this path
    /// before writing audio, closing the crash window between the file and database mutations.
    func canonicalRelativePath(recordID: String, at date: Date) throws -> String {
        try Self.validateRecordID(recordID)
        let folderName = Self.dayFolder(for: date, calendar: calendar)
        return "audio/\(folderName)/\(recordID).wav"
    }

    /// Accepts only an app-owned canonical recording path for the matching record identifier.
    /// This is intentionally narrower than `validatedAbsoluteURL`, which also supports historical
    /// nested paths needed to read existing records.
    func validateCanonical(relativePath: String, recordID: String) throws {
        try Self.validateRecordID(recordID)
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 3,
              components[0] == "audio",
              Self.isValidDayFolder(String(components[1])),
              components[2] == Substring("\(recordID).wav")
        else {
            throw StoreError.invalidRelativePath(relativePath)
        }
        _ = try validatedAbsoluteURL(for: relativePath)
    }

    func delete(relativePath: String) throws {
        let url = try validatedAbsoluteURL(for: relativePath)
        guard fileManager.fileExists(atPath: url.path) else {
            throw StoreError.sourceMissing(relativePath)
        }
        try fileManager.removeItem(at: url)
    }

    func validatedAbsoluteURL(for relativePath: String) throws -> URL {
        guard relativePath.hasPrefix("audio/") else {
            throw StoreError.invalidRelativePath(relativePath)
        }
        let trimmed = String(relativePath.dropFirst("audio/".count))
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") }) else {
            throw StoreError.invalidRelativePath(relativePath)
        }
        let resolved = components.reduce(rootDirectory) {
            $0.appendingPathComponent(String($1), isDirectory: false)
        }
        .standardizedFileURL
        .resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(rootDirectory.path + "/") else {
            throw StoreError.invalidRelativePath(relativePath)
        }
        return resolved
    }

    func fileExists(relativePath: String) throws -> Bool {
        let url = try validatedAbsoluteURL(for: relativePath)
        return fileManager.fileExists(atPath: url.path)
    }

    /// Copies an audio file into a short-lived recovery batch while preserving its relative layout.
    /// The copy is retained until both the live file and database row have been deleted successfully.
    func stageForDeletion(relativePath: String, recoveryDirectory: URL) throws -> RecoveryFile {
        let recoveryFile = try recoveryFile(
            relativePath: relativePath,
            recoveryDirectory: recoveryDirectory
        )
        let source = recoveryFile.originalURL
        guard fileManager.fileExists(atPath: source.path) else {
            throw StoreError.sourceMissing(relativePath)
        }
        let destination = recoveryFile.recoveryURL
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw StoreError.recoveryCollision(destination.path)
        }
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.copyItem(at: source, to: destination)
        return recoveryFile
    }

    /// Reconstructs recovery URLs from a trusted batch root plus a validated relative audio path.
    /// Persisted absolute URLs are deliberately never accepted.
    func recoveryFile(relativePath: String, recoveryDirectory: URL) throws -> RecoveryFile {
        let source = try validatedAbsoluteURL(for: relativePath)
        let resolvedBatch = recoveryDirectory
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let destination = resolvedBatch
            .appendingPathComponent(relativePath, isDirectory: false)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard destination.path.hasPrefix(resolvedBatch.path + "/") else {
            throw StoreError.invalidRelativePath(relativePath)
        }
        return RecoveryFile(
            relativePath: relativePath,
            originalURL: source,
            recoveryURL: destination
        )
    }

    func removeOriginal(for recoveryFile: RecoveryFile) throws {
        guard fileManager.fileExists(atPath: recoveryFile.originalURL.path) else {
            throw StoreError.sourceMissing(recoveryFile.relativePath)
        }
        try fileManager.removeItem(at: recoveryFile.originalURL)
    }

    func restore(_ recoveryFile: RecoveryFile) throws {
        // Files whose live deletion had not started are already intact.
        if fileManager.fileExists(atPath: recoveryFile.originalURL.path) {
            return
        }
        guard fileManager.fileExists(atPath: recoveryFile.recoveryURL.path) else {
            throw StoreError.sourceMissing(recoveryFile.recoveryURL.path)
        }
        try fileManager.createDirectory(
            at: recoveryFile.originalURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.copyItem(at: recoveryFile.recoveryURL, to: recoveryFile.originalURL)
    }

    static func dayFolder(for date: Date, calendar: Calendar = .current) -> String {
        var cal = calendar
        cal.timeZone = TimeZone.current
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 1970, comps.month ?? 1, comps.day ?? 1)
    }

    var root: URL { rootDirectory }

    private static func validateRecordID(_ recordID: String) throws {
        let trimmed = recordID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == recordID, !recordID.contains("/"), !recordID.contains("\\") else {
            throw StoreError.invalidRecordID
        }
    }

    private static func isValidDayFolder(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4,
              parts[1].count == 2,
              parts[2].count == 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2])
        else {
            return false
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day
        )
        guard let date = calendar.date(from: components) else { return false }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        return roundTrip.year == year && roundTrip.month == month && roundTrip.day == day
    }
}

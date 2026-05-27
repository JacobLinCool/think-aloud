import Foundation

actor AudioFileStore {
    private let rootDirectory: URL
    private let calendar: Calendar

    init(rootDirectory: URL, calendar: Calendar = .current) {
        self.rootDirectory = rootDirectory
        self.calendar = calendar
    }

    /// Persists a recorded audio file under audio/yyyy-MM-dd/<recordID>.wav, returning the relative path used for the dataset record.
    func persist(temporaryURL: URL, recordID: String, at date: Date = Date()) throws -> (storedURL: URL, relativePath: String) {
        let folderName = Self.dayFolder(for: date, calendar: calendar)
        let folderURL = rootDirectory.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let storedURL = folderURL.appendingPathComponent("\(recordID).wav")
        if FileManager.default.fileExists(atPath: storedURL.path) {
            try FileManager.default.removeItem(at: storedURL)
        }
        try FileManager.default.copyItem(at: temporaryURL, to: storedURL)
        let relativePath = "audio/\(folderName)/\(recordID).wav"
        return (storedURL, relativePath)
    }

    /// Writes a WAV directly from in-memory PCM samples into audio/yyyy-MM-dd/<recordID>.wav.
    /// Avoids the temp-file round-trip when the caller already holds the samples.
    func persist(samples: [Float], sampleRate: Double, recordID: String, at date: Date = Date()) throws -> (storedURL: URL, relativePath: String) {
        let folderName = Self.dayFolder(for: date, calendar: calendar)
        let folderURL = rootDirectory.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let storedURL = folderURL.appendingPathComponent("\(recordID).wav")
        if FileManager.default.fileExists(atPath: storedURL.path) {
            try FileManager.default.removeItem(at: storedURL)
        }
        try AudioRecorder.writeWavFile(samples: samples, sampleRate: sampleRate, to: storedURL)
        let relativePath = "audio/\(folderName)/\(recordID).wav"
        return (storedURL, relativePath)
    }

    func delete(relativePath: String) throws {
        let url = absoluteURL(for: relativePath)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func absoluteURL(for relativePath: String) -> URL {
        // relativePath always starts with "audio/" because of how we persist.
        let trimmed = relativePath.hasPrefix("audio/") ? String(relativePath.dropFirst("audio/".count)) : relativePath
        return rootDirectory.appendingPathComponent(trimmed)
    }

    static func dayFolder(for date: Date, calendar: Calendar = .current) -> String {
        var cal = calendar
        cal.timeZone = TimeZone.current
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 1970, comps.month ?? 1, comps.day ?? 1)
    }

    var root: URL { rootDirectory }
}

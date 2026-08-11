import Foundation

struct JSONLExporter {
    enum ExportError: Error, LocalizedError {
        case encodingFailed
        case ioFailed(String)

        var errorDescription: String? {
            switch self {
            case .encodingFailed:
                return String(
                    localized: "ThinkAloud couldn’t prepare the dataset for export. Try again."
                )
            case .ioFailed:
                return String(
                    localized: "ThinkAloud couldn’t save the export. Choose another folder and try again."
                )
            }
        }
    }

    static func export(records: [DatasetRecord], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = Data()
        for record in records {
            do {
                let line = try encoder.encode(record)
                data.append(line)
                data.append(0x0A)
            } catch {
                throw ExportError.encodingFailed
            }
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            throw ExportError.ioFailed(error.localizedDescription)
        }
    }

    static func makeDefaultExportURL(in directory: URL, date: Date = Date()) -> URL {
        let folder = AudioFileStore.dayFolder(for: date)
        let filename = "export_\(folder).jsonl"
        return directory.appendingPathComponent(filename)
    }
}

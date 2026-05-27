import Foundation
import GRDB

struct DatasetRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable, Identifiable {
    static let databaseTableName = "records"

    var id: String
    var createdAt: String

    var audioPath: String
    var durationMs: Int?
    var sampleRate: Int?
    var channels: Int?

    var sourceAppBundleID: String?
    var sourceAppName: String?

    var asrProvider: String
    var asrModel: String
    var asrRuntime: String
    var asrConfigJSON: String?

    var rawTranscript: String
    var editedTranscript: String

    var inserted: Bool
    var savedToDataset: Bool

    var language: String?
    var metadataJSON: String?

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case audioPath = "audio_path"
        case durationMs = "duration_ms"
        case sampleRate = "sample_rate"
        case channels
        case sourceAppBundleID = "source_app_bundle_id"
        case sourceAppName = "source_app_name"
        case asrProvider = "asr_provider"
        case asrModel = "asr_model"
        case asrRuntime = "asr_runtime"
        case asrConfigJSON = "asr_config_json"
        case rawTranscript = "raw_transcript"
        case editedTranscript = "edited_transcript"
        case inserted
        case savedToDataset = "saved_to_dataset"
        case language
        case metadataJSON = "metadata_json"
    }
}

extension DatasetRecord {
    static func generateID(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let prefix = formatter.string(from: date)
        let suffix = UUID().uuidString.split(separator: "-").first.map(String.init) ?? "0000"
        return "rec_\(prefix)_\(suffix.lowercased())"
    }
}

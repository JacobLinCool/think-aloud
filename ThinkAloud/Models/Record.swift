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
    var language: String?
    var metadataJSON: String?

    /// The transcript after Auto Post-Edit (Chinese conversion, spacing, custom dictionary) and
    /// before AI Refine or manual correction. New records must contain this stage. It remains `nil`
    /// for records saved before v0.4.0 because that historical intermediate cannot be reconstructed
    /// safely; consumers exclude those rows from edit metrics instead of guessing a fallback value.
    var autoEditedTranscript: String? = nil

    /// The transcript after the AI Refine (LLM) stage, before any manual human correction. `nil` when
    /// no LLM stage ran. Pipeline: `raw → autoEdited → llmEdited? → edited`.
    var llmEditedTranscript: String? = nil

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
        case language
        case metadataJSON = "metadata_json"
        case autoEditedTranscript = "auto_edited_transcript"
        case llmEditedTranscript = "llm_edited_transcript"
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

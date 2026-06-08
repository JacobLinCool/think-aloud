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

    /// The transcript after the Auto Post-Edit pipeline ran (Chinese conversion, spacing, custom
    /// dictionary) but BEFORE any manual human correction. Lets us separate automatic formatting
    /// from real human edits: `raw → autoEdited` is the auto-format delta, `autoEdited → edited`
    /// is what the person actually fixed. `nil` for records saved before v0.4.0 (no migration
    /// backfill is possible — the intermediate text was never captured); such rows are EXCLUDED from
    /// the edit/clean metrics (not counted in `eligibleCount`), never charged as a human edit — the
    /// stats engine must never substitute `rawTranscript` here (that would punish S↔T-conversion users).
    /// Appended last + defaulted so the synthesized memberwise init keeps existing call sites valid.
    var autoEditedTranscript: String? = nil

    /// The transcript after the AI Refine (LLM) stage, before any manual human correction. `nil` when
    /// no LLM stage ran (feature off / model not ready / refusal fallback). Pipeline:
    /// `raw → autoEdited → llmEdited → edited`. Appended last + defaulted (keeps the memberwise init valid).
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
        case savedToDataset = "saved_to_dataset"
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

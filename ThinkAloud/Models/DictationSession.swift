import Foundation
import GRDB

enum DictationAction: String, Codable, Sendable, CaseIterable {
    case insert
    case insertAndSave
}

enum DictationDeliveryOutcome: String, Codable, Sendable, CaseIterable {
    case inserted
    case clipboard
    case failed
}

/// One completed use of dictation. This contains text and metrics only; audio belongs exclusively
/// to an explicitly saved `DatasetRecord`.
struct DictationSession: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable, Identifiable {
    static let databaseTableName = "dictation_sessions"

    var id: String
    var createdAt: String
    var durationMs: Int
    var sampleRate: Int
    var channels: Int
    var sourceAppBundleID: String?
    var sourceAppName: String?
    var asrProvider: String
    var asrModel: String
    var asrRuntime: String
    var language: String?
    var transcriptionDurationMs: Int
    var rawTranscript: String
    var autoEditedTranscript: String
    var llmEditedTranscript: String?
    var finalTranscript: String
    var action: DictationAction
    var deliveryOutcome: DictationDeliveryOutcome

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case durationMs = "duration_ms"
        case sampleRate = "sample_rate"
        case channels
        case sourceAppBundleID = "source_app_bundle_id"
        case sourceAppName = "source_app_name"
        case asrProvider = "asr_provider"
        case asrModel = "asr_model"
        case asrRuntime = "asr_runtime"
        case language
        case transcriptionDurationMs = "transcription_duration_ms"
        case rawTranscript = "raw_transcript"
        case autoEditedTranscript = "auto_edited_transcript"
        case llmEditedTranscript = "llm_edited_transcript"
        case finalTranscript = "final_transcript"
        case action
        case deliveryOutcome = "delivery_outcome"
    }

    static func generateID() -> String {
        "session_\(UUID().uuidString.lowercased())"
    }
}

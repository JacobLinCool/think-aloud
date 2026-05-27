import Foundation

enum ChinesePreference: String, CaseIterable, Identifiable, Sendable, Codable {
    /// Pass through whatever the model produced.
    case model
    /// Convert Han characters to Traditional.
    case traditional
    /// Convert Han characters to Simplified.
    case simplified

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .model: return String(localized: "Use model default")
        case .traditional: return String(localized: "Prefer Traditional (正體)")
        case .simplified: return String(localized: "Prefer Simplified (简体)")
        }
    }
}

enum TranscriptPostProcessor {
    /// ICU character-level Han conversion. English / Japanese / symbols pass through unchanged.
    static func apply(_ preference: ChinesePreference, to text: String) -> String {
        switch preference {
        case .model:
            return text
        case .traditional:
            return text.applyingTransform(StringTransform("Simplified-Traditional"), reverse: false) ?? text
        case .simplified:
            return text.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? text
        }
    }
}

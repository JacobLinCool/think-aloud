import Foundation

// Auto Post-Edit pipeline. Deterministic, on-device text clean-up applied to raw ASR output
// before it reaches the editor / dataset:
//
//   Audio → [Auto Pre-Edit (future)] → ASR → [Auto Post-Edit] → text
//                                              ├─ 1. Chinese conversion (ChinesePreference)
//                                              └─ 2. CJK/Latin spacing (CJKLatinSpacer, opt-in)
//
// Auto Pre-Edit will be the symmetric stage on the other side of ASR — operating on the
// `[Float]` samples before transcription (e.g. audio enhancement, target-speaker extraction),
// configured by a sibling `PreEditConfig`. It is intentionally not implemented yet.

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
        case .model: return String(localized: "No preference")
        case .traditional: return String(localized: "Prefer Traditional (正體)")
        case .simplified: return String(localized: "Prefer Simplified (简体)")
        }
    }
}

/// Configuration for the Auto Post-Edit pipeline. Add a field + a step in `apply` to grow it.
struct PostEditConfig: Codable, Sendable, Equatable {
    /// Han-script conversion preference.
    var chinese: ChinesePreference = .model
    /// Insert spaces at CJK ↔ Latin/digit boundaries ("盤古之白"). Off by default.
    var cjkLatinSpacing: Bool = false

    static let `default` = PostEditConfig()

    /// Short human-readable description of the active steps, for smoke-test / benchmark reports.
    var summary: String {
        var parts = [chinese.displayName]
        if cjkLatinSpacing {
            parts.append(String(localized: "CJK–Latin spacing"))
        }
        return parts.joined(separator: " · ")
    }
}

enum TranscriptPostProcessor {
    /// Runs the configured Auto Post-Edit steps in order: Chinese conversion first (changes
    /// characters), then CJK/Latin spacing (operates on the final characters). Each step is a
    /// no-op when disabled, so this is safe to call per-token on the growing accumulated text.
    static func apply(_ config: PostEditConfig, to text: String) -> String {
        var result = applyChinese(config.chinese, to: text)
        if config.cjkLatinSpacing {
            result = CJKLatinSpacer.spaced(result)
        }
        return result
    }

    /// ICU character-level Han conversion. English / Japanese / symbols pass through unchanged.
    private static func applyChinese(_ preference: ChinesePreference, to text: String) -> String {
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

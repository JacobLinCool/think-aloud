import Foundation

// Auto Post-Edit pipeline. Deterministic, on-device text clean-up applied to raw ASR output
// before it reaches the editor / dataset:
//
//   Audio → [Auto Pre-Edit (future)] → ASR → [Auto Post-Edit] → text
//                                              ├─ 1. Chinese conversion (ChinesePreference)
//                                              ├─ 2. CJK/Latin spacing (CJKLatinSpacer, opt-in)
//                                              └─ 3. Custom dictionary (CompiledDictionary, LAST)
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

/// A single user-defined substitution rule: every occurrence of `from` becomes `to`.
/// Matched against the final, display-ready text (after Chinese conversion + CJK/Latin spacing).
struct DictionaryRule: Codable, Sendable, Equatable, Identifiable {
    var id = UUID()
    var from: String = ""
    var to: String = ""
    var enabled: Bool = true

    /// `from` is empty or whitespace-only — such a rule is inert (it would otherwise match
    /// at every position) and is skipped at compile time.
    var isBlank: Bool { from.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// Configuration for the Auto Post-Edit pipeline. Add a field + a step in `apply` to grow it.
struct PostEditConfig: Codable, Sendable, Equatable {
    /// Han-script conversion preference.
    var chinese: ChinesePreference = .model
    /// Insert spaces at CJK ↔ Latin/digit boundaries ("盤古之白"). Off by default.
    var cjkLatinSpacing: Bool = false
    /// User dictionary, applied LAST. Longest-match-first; see `CompiledDictionary`.
    var dictionary: [DictionaryRule] = []

    static let `default` = PostEditConfig()

    init(chinese: ChinesePreference = .model, cjkLatinSpacing: Bool = false, dictionary: [DictionaryRule] = []) {
        self.chinese = chinese
        self.cjkLatinSpacing = cjkLatinSpacing
        self.dictionary = dictionary
    }

    enum CodingKeys: String, CodingKey { case chinese, cjkLatinSpacing, dictionary }

    // Explicit decode so older persisted JSON (no `dictionary` key, or — for a future field —
    // no `cjkLatinSpacing` key) still loads. Swift's synthesized Decodable throws keyNotFound for
    // a missing key even when the property has a default; that throw would make ModelManager fall
    // through to legacy migration and silently reset the user's existing post-edit settings.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chinese = try c.decodeIfPresent(ChinesePreference.self, forKey: .chinese) ?? .model
        cjkLatinSpacing = try c.decodeIfPresent(Bool.self, forKey: .cjkLatinSpacing) ?? false
        dictionary = try c.decodeIfPresent([DictionaryRule].self, forKey: .dictionary) ?? []
    }

    /// Number of active (enabled, non-blank) dictionary rules.
    var activeRuleCount: Int { dictionary.lazy.filter { $0.enabled && !$0.isBlank }.count }

    /// Short human-readable description of the active steps, for smoke-test / benchmark reports.
    var summary: String {
        var parts = [chinese.displayName]
        if cjkLatinSpacing {
            parts.append(String(localized: "CJK–Latin spacing"))
        }
        let n = activeRuleCount
        if n > 0 {
            parts.append(String(localized: "Dictionary (\(n))"))
        }
        return parts.joined(separator: " · ")
    }
}

enum TranscriptPostProcessor {
    /// Runs the configured Auto Post-Edit steps in order: Chinese conversion → CJK/Latin spacing
    /// → custom dictionary (LAST). Each step is a no-op when disabled/empty, so this is safe to
    /// call per-token on the growing accumulated text. One-shot path — compiles the dictionary on
    /// each call (fine for once-per-record callers like the smoke test / benchmark).
    static func apply(_ config: PostEditConfig, to text: String) -> String {
        apply(config, dictionary: CompiledDictionary(config.dictionary), to: text)
    }

    /// Streaming hot-path overload: pass a `CompiledDictionary` built ONCE outside the token loop
    /// so the per-token cost stays O(text length) with no recompilation.
    static func apply(_ config: PostEditConfig, dictionary: CompiledDictionary, to text: String) -> String {
        var result = applyChinese(config.chinese, to: text)
        if config.cjkLatinSpacing {
            result = CJKLatinSpacer.spaced(result)
        }
        // LAST: user dictionary — must stay after spacing/conversion so it matches display text.
        result = dictionary.apply(to: result)
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

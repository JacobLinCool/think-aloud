import Foundation

/// Which engine runs the refine. `mlx` = a downloaded Qwen model; `appleFoundation` = Apple's
/// on-device Intelligence model (macOS 26+, no download), offered only when the system supports it.
enum LLMBackend: String, Codable, Sendable, CaseIterable, Identifiable {
    case mlx
    case appleFoundation

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .mlx: return String(localized: "Downloaded model")
        case .appleFoundation: return String(localized: "Apple Intelligence")
        }
    }
}

/// One refine profile — the behaviour applied to a given app (or the default). Per-app behaviour is
/// achieved purely by a different `systemPrompt` over the SAME (globally-selected) model, so one warm
/// model serves every app — no per-app downloads. Uses the `decodeIfPresent` idiom (like
/// `PostEditConfig`) so adding a field later never key-throws and silently resets saved settings.
struct LLMProfileConfig: Codable, Sendable, Equatable {
    var enabled: Bool = false
    var backend: LLMBackend = .mlx
    var systemPrompt: String = LLMProfileConfig.defaultPrompt
    var temperature: Double = 0.3

    static let defaultPrompt = String(localized: """
        Clean up this dictated text into clear, well-punctuated writing. Fix obvious speech errors, \
        remove filler words (um, uh, like), and apply correct capitalization and punctuation. Keep the \
        original meaning and language. Output ONLY the cleaned text — no preamble, no commentary.
        """)

    init(enabled: Bool = false, backend: LLMBackend = .mlx,
         systemPrompt: String = LLMProfileConfig.defaultPrompt, temperature: Double = 0.3) {
        self.enabled = enabled
        self.backend = backend
        self.systemPrompt = systemPrompt
        self.temperature = temperature
    }

    enum CodingKeys: String, CodingKey { case enabled, backend, systemPrompt, temperature }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        backend = try c.decodeIfPresent(LLMBackend.self, forKey: .backend) ?? .mlx
        systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt) ?? LLMProfileConfig.defaultPrompt
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? 0.3
    }
}

/// The full AI Refine configuration: a default profile plus per-app overrides keyed by bundle id.
struct LLMPostEditConfig: Codable, Sendable, Equatable {
    var defaultProfile: LLMProfileConfig
    var perApp: [String: LLMProfileConfig]

    static let `default` = LLMPostEditConfig(defaultProfile: LLMProfileConfig(), perApp: [:])

    init(defaultProfile: LLMProfileConfig = LLMProfileConfig(), perApp: [String: LLMProfileConfig] = [:]) {
        self.defaultProfile = defaultProfile
        self.perApp = perApp
    }

    enum CodingKeys: String, CodingKey { case defaultProfile, perApp }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        defaultProfile = try c.decodeIfPresent(LLMProfileConfig.self, forKey: .defaultProfile) ?? LLMProfileConfig()
        perApp = try c.decodeIfPresent([String: LLMProfileConfig].self, forKey: .perApp) ?? [:]
    }

    /// The effective profile for a dictation's source app: a per-app override wins, else the default.
    /// Returns nil when the resolved profile is disabled (no refine runs for that app). A nil bundle
    /// id (unknown frontmost app) falls back to the default.
    func effectiveConfig(for focus: FocusContext?) -> LLMProfileConfig? {
        let cfg: LLMProfileConfig
        if let bundle = focus?.appBundleID, let override = perApp[bundle] {
            cfg = override
        } else {
            cfg = defaultProfile
        }
        return cfg.enabled ? cfg : nil
    }

    /// True if any profile (default or per-app) is enabled — i.e. the feature is in use at all.
    var isAnyProfileEnabled: Bool {
        defaultProfile.enabled || perApp.values.contains { $0.enabled }
    }
}

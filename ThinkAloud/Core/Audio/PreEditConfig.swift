import Foundation

/// How the Auto Pre-Edit denoise step behaves.
enum DenoiseMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Never denoise.
    case off
    /// Inspect each recording and denoise only clips a heuristic flags as noisy (`DenoiseHeuristic`).
    case auto
    /// Always denoise.
    case on

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off:  return String(localized: "Off")
        case .auto: return String(localized: "Auto")
        case .on:   return String(localized: "On")
        }
    }
}

/// Configuration for the Auto Pre-Edit pipeline — audio clean-up applied to the recorded
/// samples *before* they reach the ASR model:
///
///   Audio → [Auto Pre-Edit] → ASR → [Auto Post-Edit] → text
///           └─ denoise (DeepFilterNet, 48 kHz): off / auto / on
///
/// Mirror of `PostEditConfig`. Add a field + a step in the pre-edit path to grow it
/// (e.g. a future target-speaker-extraction step).
struct PreEditConfig: Codable, Sendable, Equatable {
    /// DeepFilterNet denoising before ASR. Off by default. `.auto` runs a cheap per-clip heuristic
    /// (`DenoiseHeuristic`) and only denoises noisy recordings; `.on` always denoises. Denoising
    /// runs over the whole clip before transcription starts, adding a short delay (and a model
    /// download on first use), and can slightly hurt ASR on already-clean audio — which is what
    /// `.auto` avoids.
    var denoise: DenoiseMode = .off

    static let `default` = PreEditConfig()

    /// Restores the memberwise init (suppressed by the custom `init(from:)` below).
    init(denoise: DenoiseMode = .off) {
        self.denoise = denoise
    }

    enum CodingKeys: String, CodingKey { case denoise }

    // Explicit decode so older persisted JSON (`{"denoise": true/false}` — a Bool from when this
    // was a Bool) still loads. A synthesized Decodable would throw typeMismatch on the old Bool;
    // ModelManager decodes with `try?` and falls back to `.default`, so that throw would silently
    // (and then persistently, via didSet) reset the user's denoise choice. Decode the enum first so
    // re-encoded String values are idempotent and never fall into the Bool branch.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let mode = try? c.decode(DenoiseMode.self, forKey: .denoise) {
            denoise = mode
        } else if let legacy = try? c.decode(Bool.self, forKey: .denoise) {
            denoise = legacy ? .on : .off   // a past explicit "on" stays always-on, not auto
        } else {
            denoise = .off
        }
    }

    /// Whether the pre-edit stage is *potentially* active (so callers build the denoiser / decode at
    /// 48 kHz / show its UI). `.auto` counts as active; whether DFN actually runs is decided per-clip.
    var isActive: Bool { denoise != .off }

    /// Short human-readable description of the active steps, for smoke-test / benchmark reports.
    var summary: String {
        switch denoise {
        case .off:  return String(localized: "Off")
        case .auto: return String(localized: "Auto")
        case .on:   return String(localized: "Denoise")
        }
    }
}

import Foundation

/// Configuration for the Auto Pre-Edit pipeline — audio clean-up applied to the recorded
/// samples *before* they reach the ASR model:
///
///   Audio → [Auto Pre-Edit] → ASR → [Auto Post-Edit] → text
///           └─ denoise (DeepFilterNet, 48 kHz, opt-in)
///
/// Mirror of `PostEditConfig`. Add a field + a step in the pre-edit path to grow it
/// (e.g. a future target-speaker-extraction step).
struct PreEditConfig: Codable, Sendable, Equatable {
    /// Run DeepFilterNet speech enhancement (background-noise suppression) before ASR. Off by default.
    /// Note: enhancement runs over the whole clip before transcription starts, adding a short
    /// (sub-second for typical dictation, model-load cost on first use) delay to the first token.
    /// Best for noisy recordings; may not help — or slightly hurt — clean ones (compare via Benchmark).
    var denoise: Bool = false

    static let `default` = PreEditConfig()

    /// Whether any pre-edit step is active (lets callers skip the whole stage cheaply).
    var isActive: Bool { denoise }

    /// Short human-readable description of the active steps, for smoke-test / benchmark reports.
    var summary: String {
        denoise ? String(localized: "Denoise") : String(localized: "Off")
    }
}

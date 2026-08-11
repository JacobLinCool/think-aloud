import Foundation

enum ASRFamily: String, Sendable {
    case qwen3
    case whisper
}

enum ModelProfile: String, CaseIterable, Identifiable, Sendable {
    // Declaration order drives the UI list — Qwen3 tiers first (accurate → fast),
    // then the Whisper-family additions.
    case accurate
    case balanced
    case fast
    case whisperLargeV3Turbo
    case breezeASR25

    var id: String { rawValue }

    var family: ASRFamily {
        switch self {
        case .accurate, .balanced, .fast: return .qwen3
        case .whisperLargeV3Turbo, .breezeASR25: return .whisper
        }
    }

    var displayName: String {
        switch self {
        case .fast: return String(localized: "Fast (Qwen3-ASR-0.6B-4bit)")
        case .balanced: return String(localized: "Balanced (Qwen3-ASR-1.7B-4bit)")
        case .accurate: return String(localized: "Accurate (Qwen3-ASR-1.7B-8bit)")
        case .whisperLargeV3Turbo: return String(localized: "Whisper Large v3 Turbo")
        case .breezeASR25: return String(localized: "Breeze-ASR-25 (Mandarin)")
        }
    }

    var shortName: String {
        switch self {
        case .fast: return String(localized: "Fast")
        case .balanced: return String(localized: "Balanced")
        case .accurate: return String(localized: "Accurate")
        case .whisperLargeV3Turbo: return String(localized: "Whisper Turbo")
        case .breezeASR25: return String(localized: "Breeze-ASR")
        }
    }

    var modelID: String {
        switch self {
        case .fast: return "mlx-community/Qwen3-ASR-0.6B-4bit"
        case .balanced: return "mlx-community/Qwen3-ASR-1.7B-4bit"
        case .accurate: return "mlx-community/Qwen3-ASR-1.7B-8bit"
        case .whisperLargeV3Turbo: return "mlx-community/whisper-large-v3-turbo"
        case .breezeASR25: return "MediaTek-Research/Breeze-ASR-25"
        }
    }

    /// One-line "what is this for" blurb shown next to each model during onboarding.
    var tagline: String {
        switch self {
        case .fast: return String(localized: "Lowest latency and RAM. Good on older or low-power Macs.")
        case .balanced: return String(localized: "A solid middle ground between speed and accuracy.")
        case .accurate: return String(localized: "Best accuracy. Recommended for most modern Macs.")
        case .whisperLargeV3Turbo: return String(localized: "OpenAI Whisper, strong for multilingual audio.")
        case .breezeASR25: return String(localized: "Tuned for Taiwanese Mandarin by MediaTek Research.")
        }
    }

    /// Rough download size for display before the real byte count is known. The model step
    /// shows live bytes once a download starts; this is just to set expectations up front.
    var estimatedDownloadSize: String {
        "~\(ByteCountFormatter.string(fromByteCount: estimatedDownloadBytes, countStyle: .file))"
    }

    var estimatedDownloadBytes: Int64 {
        switch self {
        // Exact main-revision totals for `downloadMatchingPatterns`, verified through the
        // Hugging Face tree API on 2026-07-31. Runtime progress refreshes this total from the API;
        // these values set expectations and protect the pre-download disk-space check.
        case .fast: return 712_778_752
        case .balanced: return 1_607_630_579
        case .accurate: return 2_467_856_503
        case .whisperLargeV3Turbo: return 1_613_977_880
        case .breezeASR25: return 3_092_400_389
        }
    }

    /// Must stay aligned with `MLXAudioCore.ModelUtils.resolveOrDownloadModel`.
    /// Metadata totals, progress percentages, and disk-space gates all use this same manifest.
    var downloadMatchingPatterns: [String] {
        var patterns = ["*.safetensors", "*.json", "*.txt", "*.wav"]
        if family == .whisper {
            patterns.append(contentsOf: ["*.model", "merges.txt", "vocab.json"])
        }
        return patterns
    }

    /// Sensible default to pre-select in onboarding — matches the app's default profile.
    static var recommended: ModelProfile { .accurate }
}

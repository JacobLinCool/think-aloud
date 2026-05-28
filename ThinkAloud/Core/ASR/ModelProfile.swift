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
}

import Foundation

enum ModelProfile: String, CaseIterable, Identifiable, Sendable {
    // Declaration order drives the UI list — accurate first so the highest-quality option leads.
    case accurate
    case balanced
    case fast

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fast: return String(localized: "Fast (Qwen3-ASR-0.6B-4bit)")
        case .balanced: return String(localized: "Balanced (Qwen3-ASR-1.7B-4bit)")
        case .accurate: return String(localized: "Accurate (Qwen3-ASR-1.7B-8bit)")
        }
    }

    var shortName: String {
        switch self {
        case .fast: return String(localized: "Fast")
        case .balanced: return String(localized: "Balanced")
        case .accurate: return String(localized: "Accurate")
        }
    }

    var modelID: String {
        switch self {
        case .fast: return "mlx-community/Qwen3-ASR-0.6B-4bit"
        case .balanced: return "mlx-community/Qwen3-ASR-1.7B-4bit"
        case .accurate: return "mlx-community/Qwen3-ASR-1.7B-8bit"
        }
    }
}

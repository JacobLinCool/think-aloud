import Foundation

/// Downloadable text-refinement models. Qwen3 dense load through the MLXLLM (text) factory; the
/// Qwen3.5 line is multimodal and loads through the MLXVLM factory, run text-only. The user picks +
/// downloads one; the AI Refine stage is unavailable until a model is on disk.
enum LLMModelProfile: String, CaseIterable, Identifiable, Sendable {
    case qwen35_2b
    case qwen3_1_7b
    case qwen3_0_6b
    case qwen35_4b

    var id: String { rawValue }

    var modelID: String {
        switch self {
        case .qwen35_2b: return "mlx-community/Qwen3.5-2B-OptiQ-4bit"
        case .qwen3_1_7b: return "mlx-community/Qwen3-1.7B-4bit"
        case .qwen3_0_6b: return "mlx-community/Qwen3-0.6B-4bit"
        case .qwen35_4b: return "mlx-community/Qwen3.5-4B-OptiQ-4bit"
        }
    }

    var displayName: String {
        switch self {
        case .qwen35_2b: return String(localized: "Qwen3.5 2B")
        case .qwen3_1_7b: return String(localized: "Qwen3 1.7B")
        case .qwen3_0_6b: return String(localized: "Qwen3 0.6B")
        case .qwen35_4b: return String(localized: "Qwen3.5 4B")
        }
    }

    /// Real 4-bit on-disk size (verified against the HF repos), shown before download.
    var estimatedDownloadSize: String {
        switch self {
        case .qwen35_2b: return "~2.2 GB"
        case .qwen3_1_7b: return "~1.0 GB"
        case .qwen3_0_6b: return "~0.35 GB"
        case .qwen35_4b: return "~3.0 GB"
        }
    }

    var tagline: String {
        switch self {
        case .qwen35_2b: return String(localized: "Latest Qwen, strong multilingual rewriting. Larger download.")
        case .qwen3_1_7b: return String(localized: "A reliable balance of quality and speed. Recommended.")
        case .qwen3_0_6b: return String(localized: "Smallest and fastest. Best for low-RAM Macs and casual cleanup.")
        case .qwen35_4b: return String(localized: "Highest quality rewrites. Needs RAM headroom.")
        }
    }

    static var recommended: LLMModelProfile { .qwen3_1_7b }

    static func profile(forModelID id: String) -> LLMModelProfile? {
        allCases.first { $0.modelID == id }
    }
}

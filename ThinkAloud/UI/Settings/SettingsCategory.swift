import SwiftUI

/// The Settings sidebar categories, in top→bottom order. The raw `String` doubles as the
/// persisted selection token (see `SettingsRouter`), so reordering or adding cases later never
/// corrupts a previously-saved selection.
///
/// Insights is the home page (first item, default landing — every open lands here so the user sees
/// their stats + achievements immediately). The rest are the job-shaped categories: app-level setup
/// (Startup), the dictation hotkeys (Shortcuts), OS grants (Permissions), updates (Software Update),
/// the engine + its files (Model), everyday output shaping (Output), saved records (Dataset), and
/// power/diagnostic tools (Advanced).
enum SettingsCategory: String, CaseIterable, Identifiable, Hashable {
    case insights
    case startup
    case shortcuts
    case permissions
    case softwareUpdate
    case model
    case output
    case refine
    case dataset
    case advanced

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .insights: "Insights"
        case .startup: "Startup"
        case .shortcuts: "Shortcuts"
        case .permissions: "Permissions"
        case .softwareUpdate: "Software Update"
        case .model: "Model"
        case .output: "Output"
        case .refine: "AI Refine"
        case .dataset: "Dataset"
        case .advanced: "Advanced"
        }
    }

    var symbol: String {
        switch self {
        case .insights: "chart.bar.xaxis"
        case .startup: "gearshape"
        case .shortcuts: "keyboard"
        case .permissions: "lock.shield"
        case .softwareUpdate: "arrow.down.circle"
        case .model: "brain"
        case .output: "text.cursor"
        case .refine: "wand.and.stars"
        case .dataset: "tray.full"
        case .advanced: "wrench.and.screwdriver"
        }
    }
}

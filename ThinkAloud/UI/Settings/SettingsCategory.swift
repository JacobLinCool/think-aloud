import SwiftUI

/// The Settings sidebar categories, in top→bottom order. The raw `String` doubles as the
/// persisted selection token (see `SettingsRouter`), so reordering or adding cases later never
/// corrupts a previously-saved selection.
///
/// The eight job-shaped categories. Each mental object lives in exactly one home: app-level setup
/// (Startup), the dictation hotkeys (Shortcuts), OS grants (Permissions), updates (Software Update),
/// the engine + its files (Model), everyday output shaping (Output), saved records (Dataset), and
/// power/diagnostic tools (Advanced).
enum SettingsCategory: String, CaseIterable, Identifiable, Hashable {
    case startup
    case shortcuts
    case permissions
    case softwareUpdate
    case model
    case output
    case dataset
    case advanced

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .startup: "Startup"
        case .shortcuts: "Shortcuts"
        case .permissions: "Permissions"
        case .softwareUpdate: "Software Update"
        case .model: "Model"
        case .output: "Output"
        case .dataset: "Dataset"
        case .advanced: "Advanced"
        }
    }

    var symbol: String {
        switch self {
        case .startup: "gearshape"
        case .shortcuts: "keyboard"
        case .permissions: "lock.shield"
        case .softwareUpdate: "arrow.down.circle"
        case .model: "brain"
        case .output: "text.cursor"
        case .dataset: "tray.full"
        case .advanced: "wrench.and.screwdriver"
        }
    }
}

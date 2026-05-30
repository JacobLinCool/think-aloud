import SwiftUI

/// The Settings sidebar categories, in top→bottom order. The raw `String` doubles as the
/// persisted selection token (see `SettingsRouter`), so reordering or adding cases later never
/// corrupts a previously-saved selection.
///
/// Milestone A (the shell) keeps the SAME six categories the old TabView had, so the sidebar can
/// host the existing pane bodies verbatim and any regression is unambiguously a shell bug. The
/// re-slice to the eight job-shaped categories lands in a later phase.
enum SettingsCategory: String, CaseIterable, Identifiable, Hashable {
    case general
    case permissions
    case model
    case dataset
    case advanced
    case updates

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .permissions: "Permissions"
        case .model: "Model"
        case .dataset: "Dataset"
        case .advanced: "Advanced"
        case .updates: "Updates"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .permissions: "lock.shield"
        case .model: "brain"
        case .dataset: "tray.full"
        case .advanced: "wrench.and.screwdriver"
        case .updates: "arrow.down.circle"
        }
    }
}

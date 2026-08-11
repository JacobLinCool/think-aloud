import Foundation
import Observation

/// Single source of truth for the Settings sidebar selection. Owned by `SettingsWindowController`
/// and injected into `SettingsRootView`, so a deep-link (e.g. the popup's "Open Settings" jumping
/// to Permissions) can re-route an ALREADY-OPEN window — the previous `show()` early-returned and
/// would have swallowed the target.
@MainActor
@Observable
final class SettingsRouter {
    static let selectionKey = "ThinkAloud.settings.lastCategory"
    @ObservationIgnored private let defaults: UserDefaults

    var selection: SettingsCategory {
        didSet { defaults.set(selection.rawValue, forKey: Self.selectionKey) }
    }

    init(initial: SettingsCategory? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.string(forKey: Self.selectionKey).flatMap(SettingsCategory.init(rawValue:))
        self.selection = initial ?? saved ?? .insights
        defaults.set(selection.rawValue, forKey: Self.selectionKey)
    }

    func route(to category: SettingsCategory?) {
        if let category { selection = category }
    }
}

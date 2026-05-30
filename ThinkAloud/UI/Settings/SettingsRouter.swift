import Foundation
import Observation

/// Single source of truth for the Settings sidebar selection. Owned by `SettingsWindowController`
/// and injected into `SettingsRootView`, so a deep-link (e.g. the popup's "Open Settings" jumping
/// to Permissions) can re-route an ALREADY-OPEN window — the previous `show()` early-returned and
/// would have swallowed the target. Also persists the last-viewed category so reopening restores it.
@MainActor
@Observable
final class SettingsRouter {
    /// Persisted under a NEW key, outside the frozen UserDefaults set, so it can never collide with
    /// app behavior keys.
    static let storageKey = "settingsLastCategory"

    var selection: SettingsCategory {
        didSet { UserDefaults.standard.set(selection.rawValue, forKey: Self.storageKey) }
    }

    init(initial: SettingsCategory? = nil) {
        // Deep-link target wins; else restore the last-viewed category; else a friendly default.
        self.selection = initial
            ?? UserDefaults.standard.string(forKey: Self.storageKey).flatMap(SettingsCategory.init(rawValue:))
            ?? .startup
    }

    func route(to category: SettingsCategory?) {
        if let category { selection = category }
    }
}

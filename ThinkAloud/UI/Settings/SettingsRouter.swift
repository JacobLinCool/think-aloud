import Foundation
import Observation

/// Single source of truth for the Settings sidebar selection. Owned by `SettingsWindowController`
/// and injected into `SettingsRootView`, so a deep-link (e.g. the popup's "Open Settings" jumping
/// to Permissions) can re-route an ALREADY-OPEN window — the previous `show()` early-returned and
/// would have swallowed the target.
@MainActor
@Observable
final class SettingsRouter {
    var selection: SettingsCategory

    init(initial: SettingsCategory? = nil) {
        // Deep-link target wins; otherwise every fresh open lands on the Insights home page so the
        // user sees their stats + achievements immediately (no last-viewed restore — the home is
        // the intended first impression each time).
        self.selection = initial ?? .insights
    }

    func route(to category: SettingsCategory?) {
        if let category { selection = category }
    }
}

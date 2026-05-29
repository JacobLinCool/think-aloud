import Foundation
import Observation
import Sparkle

/// Owns Sparkle's updater for the app's lifetime.
///
/// Standard Developer-ID, non-sandboxed configuration — no XPC installer services are needed
/// (those are sandbox-only). `SPUStandardUpdaterController` is `@MainActor`-affined, so this
/// whole type stays on the main actor, which fits how `AppContainer` constructs it.
///
/// The default behaviour is "check automatically, ask before installing":
/// `automaticallyChecksForUpdates == true`, `automaticallyDownloadsUpdates == false`. Both are
/// user-adjustable in Settings → Updates and persist via Sparkle's own user defaults.
@MainActor
@Observable
final class UpdaterController {
    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?

    /// True when a manual check can be started right now. Sparkle flips this to false while a
    /// check/download session is in flight; the menu item and the "Check Now" button observe it.
    private(set) var canCheckForUpdates = false

    /// Background daily checks. Mirrors Sparkle's persisted preference.
    var automaticallyChecksForUpdates: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }

    /// Download + install in the background, only prompting to relaunch. Off (the default) means
    /// Sparkle still notifies and waits for consent before installing.
    var automaticallyDownloadsUpdates: Bool {
        didSet { controller.updater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates }
    }

    init() {
        // startingUpdater: true launches the scheduled-check cycle once the app finishes launching.
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.controller = controller
        let updater = controller.updater
        self.canCheckForUpdates = updater.canCheckForUpdates
        self.automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        self.automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates

        // Keep the UI's enabled/disabled state in sync with Sparkle. The KVO handler is a
        // Sendable closure, so read the new value out of the change (a Sendable Bool) rather than
        // touching the main-actor-isolated `updater.canCheckForUpdates`, then hop onto the main
        // actor to update observed state.
        self.canCheckObservation = updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, change in
            guard let value = change.newValue else { return }
            Task { @MainActor in self?.canCheckForUpdates = value }
        }
    }

    /// Start a user-initiated check (shows progress + the standard update dialog).
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

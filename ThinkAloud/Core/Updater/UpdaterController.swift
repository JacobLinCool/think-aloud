import Foundation
import Observation
import Sparkle

/// Auto-update channel. `stable` follows the tagged releases; `dev` follows the latest `main`
/// build (a prerelease, less stable). Each points Sparkle at its own appcast feed.
enum UpdateChannel: String, CaseIterable, Identifiable, Sendable {
    case stable
    case dev

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .stable: return String(localized: "Stable")
        case .dev: return String(localized: "Dev (latest main)")
        }
    }

    /// The Sparkle appcast URL for this channel. Stable resolves to the newest published (non-
    /// prerelease) release; dev is the fixed `dev` prerelease, updated on every push to main.
    var feedURLString: String {
        switch self {
        case .stable: return "https://github.com/JacobLinCool/think-aloud/releases/latest/download/appcast.xml"
        case .dev:    return "https://github.com/JacobLinCool/think-aloud/releases/download/dev/appcast-dev.xml"
        }
    }
}

/// Supplies Sparkle the feed URL for the currently-selected channel. `SPUUpdaterDelegate` is
/// `NS_SWIFT_UI_ACTOR` (main-actor), so this stays on the main actor. Sparkle reads
/// `feedURLString(for:)` at the start of each check, so flipping `currentFeedURLString` switches
/// channels on the next check with no updater restart.
@MainActor
final class ChannelFeedDelegate: NSObject, SPUUpdaterDelegate {
    var currentFeedURLString: String

    init(_ feedURLString: String) {
        self.currentFeedURLString = feedURLString
        super.init()
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        currentFeedURLString
    }
}

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
    @ObservationIgnored private let feedDelegate: ChannelFeedDelegate
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?
    @ObservationIgnored private let channelKey = "ThinkAloud.updateChannel"

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

    /// Which appcast feed to follow. Switching takes effect on the next update check.
    var channel: UpdateChannel {
        didSet {
            UserDefaults.standard.set(channel.rawValue, forKey: channelKey)
            feedDelegate.currentFeedURLString = channel.feedURLString
        }
    }

    init() {
        let storedChannel = UserDefaults.standard.string(forKey: channelKey)
            .flatMap(UpdateChannel.init(rawValue:)) ?? .stable
        self.channel = storedChannel

        let feedDelegate = ChannelFeedDelegate(storedChannel.feedURLString)
        self.feedDelegate = feedDelegate

        // startingUpdater: true launches the scheduled-check cycle once the app finishes launching.
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: feedDelegate,
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

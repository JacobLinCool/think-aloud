import AppKit
import SwiftUI

/// Hosts the first-run onboarding flow. Mirrors `SettingsWindowController`'s lifecycle
/// (reused, non-released, delegate-driven cleanup) with one twist: the app normally runs
/// as a menu-bar `.accessory` agent with no Dock icon, so a plain window can't become key
/// or appear in the app switcher. We promote to `.regular` while onboarding is on screen
/// and drop back to `.accessory` when it closes.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private weak var container: AppContainer?
    private var window: NSWindow?

    init(container: AppContainer) {
        self.container = container
        super.init()
    }

    func show() {
        guard let container else { return }
        container.onboardingState.rewind()

        if let window {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: OnboardingScene().environment(container))
        let size = NSSize(width: 640, height: 600)
        hosting.preferredContentSize = size

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "Welcome to ThinkAloud")
        window.contentViewController = hosting
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    /// Programmatic close — used by "Skip setup" and the Finish step's primary button.
    /// Routes through `window.close()` so `windowWillClose` does the bookkeeping.
    func finish() {
        window?.close()
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            self.container?.onboardingState.markCompleted()
            self.window = nil
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

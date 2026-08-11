import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private weak var container: AppContainer?
    private var window: NSWindow?
    /// Single source of truth for the sidebar selection; retained for the window's lifetime so a
    /// deep-link can re-route an already-open window.
    private var router: SettingsRouter?

    init(container: AppContainer) {
        self.container = container
        super.init()
    }

    /// Open (or focus) the Settings window. A non-nil `category` deep-links to that pane — and now
    /// works even when the window is already open (the previous early-return swallowed it).
    func show(category: SettingsCategory? = nil) {
        if let window {
            router?.route(to: category)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        guard let container else { return }

        let router = SettingsRouter(initial: category, defaults: container.settingsDefaults)
        self.router = router

        let hosting = NSHostingController(rootView: SettingsRootView(router: router).environment(container))
        hosting.view.setAccessibilityLabel(String(localized: "ThinkAloud Settings"))
        // The window owns hard min/max; the SwiftUI root only hints ideal size. Stop the hosting
        // controller from re-fitting the window to content (which would fight `.resizable`).
        hosting.sizingOptions = []

        let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 760, height: 580)),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        // The detail pane has its own visible heading; the stable window title supplies the
        // Window menu and top-level accessibility name.
        window.title = String(localized: "ThinkAloud Settings")
        window.contentViewController = hosting
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 680, height: 480)
        window.contentMaxSize = NSSize(width: 980, height: 100_000)
        window.setContentSize(NSSize(width: 760, height: 580))
        window.center()
        window.delegate = self

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            self.window = nil
            self.router = nil
        }
    }
}

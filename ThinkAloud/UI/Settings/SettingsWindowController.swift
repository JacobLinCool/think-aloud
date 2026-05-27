import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private weak var container: AppContainer?
    private var window: NSWindow?

    init(container: AppContainer) {
        self.container = container
        super.init()
    }

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        guard let container else { return }
        let hosting = NSHostingController(rootView: SettingsScene().environment(container))
        let size = NSSize(width: 580, height: 560)
        hosting.preferredContentSize = size

        let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "ThinkAloud Settings")
        window.contentViewController = hosting
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            self.window = nil
        }
    }
}

import AppKit
import SwiftUI

/// NSPanel subclass that can become key (so the TextEditor in review state takes keystrokes)
/// while leaving the source app's "main" focus untouched.
final class ThinkAloudPopupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PopupWindowController: NSObject, NSWindowDelegate {
    private var panel: ThinkAloudPopupPanel?
    private var hosting: NSHostingController<PopupRootView>?

    /// First show builds the panel + SwiftUI hosting tree (expensive — ~100–300 ms for the
    /// material backdrop on first paint). Subsequent shows reuse the live panel + hosting tree
    /// and just orderFront, so reopen is effectively free.
    func show(viewModel: PopupViewModel, coordinator: PopupCoordinator, modelManager: ModelManager) {
        if let panel {
            panel.orderFrontRegardless()
            return
        }
        let hosting = NSHostingController(rootView: PopupRootView(viewModel: viewModel, coordinator: coordinator, modelManager: modelManager))
        let size = NSSize(width: 460, height: 280)

        let styleMask: NSWindow.StyleMask = [.titled, .fullSizeContentView, .nonactivatingPanel]
        let panel = ThinkAloudPopupPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        panel.title = "ThinkAloud"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        panel.isReleasedWhenClosed = false        // crucial: keep alive across closes so we own lifecycle
        panel.hidesOnDeactivate = false           // do not auto-hide when source app is active
        panel.level = .statusBar                  // above other floating windows
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true       // only key when user clicks an interactive control
        panel.contentViewController = hosting
        panel.setContentSize(size)
        panel.delegate = self

        panel.center()
        panel.orderFrontRegardless()
        NSLog("ThinkAloud: panel first-shown isVisible=\(panel.isVisible) frame=\(panel.frame)")
        self.panel = panel
        self.hosting = hosting
    }

    func close() {
        NSLog("ThinkAloud: panel close() — keeping panel alive for reuse")
        // Do NOT nil out panel or contentViewController. Tearing them down forces SwiftUI to
        // recompile and AppKit to re-create the material-backed window on every reopen, which
        // shows up as 100–300 ms of jank in the popup-open path. The PopupViewModel's reset()
        // already clears all visible state, so an orderOut leaves nothing observable.
        panel?.orderOut(nil)
    }

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    // MARK: - NSWindowDelegate

    nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
        MainActor.assumeIsolated {
            NSLog("ThinkAloud: windowShouldClose called by AppKit — blocking auto-close")
        }
        return false
    }

    nonisolated func windowDidResignKey(_ notification: Notification) {
        MainActor.assumeIsolated {
            NSLog("ThinkAloud: windowDidResignKey panel=\(self.panel?.isVisible ?? false)")
        }
    }
}

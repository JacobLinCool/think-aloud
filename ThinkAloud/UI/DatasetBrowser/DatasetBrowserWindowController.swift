import AppKit
import Foundation
import SwiftUI

@MainActor
final class DatasetBrowserWindowController: NSObject, NSWindowDelegate {
    private weak var container: AppContainer?
    private var window: NSWindow?
    private var controller: DatasetBrowserController?
    private var player: AudioPlayerController?
    private var benchmark: BenchmarkController?
    private var pushController: HFPushController?

    init(container: AppContainer) {
        self.container = container
        super.init()
    }

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            if let c = controller {
                Task { @MainActor in await c.reload() }
            }
            return
        }
        guard let container else { return }
        let newController = DatasetBrowserController(
            datasetStore: container.datasetStore,
            audioFileStore: container.audioFileStore
        )
        let newPlayer = AudioPlayerController()
        let newBenchmark = BenchmarkController(
            datasetStore: container.datasetStore,
            audioFileStore: container.audioFileStore,
            modelsDirectory: container.modelManager.modelCacheURL,
            initialProfile: container.modelManager.profile,
            initialPostEdit: container.modelManager.postEdit
        )
        let newPush = HFPushController(
            tokenStore: container.hfTokenStore,
            datasetStore: container.datasetStore,
            audioFileStore: container.audioFileStore
        )
        let root = DatasetBrowserRootView(controller: newController, player: newPlayer, benchmark: newBenchmark, pushController: newPush, tokenStore: container.hfTokenStore)
        let hosting = NSHostingController(rootView: root)
        let size = NSSize(width: 880, height: 600)
        hosting.preferredContentSize = size

        let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "Dataset Browser")
        window.contentViewController = hosting
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        window.toolbarStyle = .unified

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        self.window = window
        self.controller = newController
        self.player = newPlayer
        self.benchmark = newBenchmark
        self.pushController = newPush
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            self.player?.stop()
            self.benchmark?.cancel()
            self.pushController?.cancel()
            self.window = nil
            self.controller = nil
            self.player = nil
            self.benchmark = nil
            self.pushController = nil
        }
    }
}

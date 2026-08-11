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
    private var isPresentingCloseAlert = false
    private var allowNextClose = false

    init(container: AppContainer) {
        self.container = container
        super.init()
    }

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            if let c = controller {
                if !c.hasUnsavedDraft {
                    Task { @MainActor in await c.reload() }
                }
            }
            return
        }
        guard let container else { return }
        let newController = DatasetBrowserController(
            datasetStore: container.datasetStore,
            audioFileStore: container.audioFileStore,
            deletionService: container.datasetDeletionService
        )
        let newPlayer = AudioPlayerController()
        let newBenchmark = BenchmarkController(
            datasetStore: container.datasetStore,
            audioFileStore: container.audioFileStore,
            modelsDirectory: container.modelManager.modelCacheURL,
            initialProfile: container.modelManager.profile,
            initialPostEdit: container.modelManager.postEdit,
            initialPreEdit: container.modelManager.preEdit
        )
        let newPush = HFPushController(
            tokenStore: container.hfTokenStore,
            datasetStore: container.datasetStore,
            audioFileStore: container.audioFileStore
        )
        let root = DatasetBrowserRootView(
            controller: newController,
            player: newPlayer,
            benchmark: newBenchmark,
            pushController: newPush,
            tokenStore: container.hfTokenStore
        )
        .environment(container)
        let hosting = NSHostingController(rootView: root)
        hosting.view.setAccessibilityLabel(String(localized: "Dataset Browser"))
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

    nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
        MainActor.assumeIsolated {
            guard !allowNextClose else {
                allowNextClose = false
                return true
            }
            guard let controller, controller.hasUnsavedDraft else { return true }
            guard !isPresentingCloseAlert else { return false }

            isPresentingCloseAlert = true
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "Save changes before closing?")
            alert.informativeText = String(localized: "Your edited transcript has unsaved changes.")
            alert.addButton(withTitle: String(localized: "Save"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.addButton(withTitle: String(localized: "Discard Changes"))
            alert.beginSheetModal(for: sender) { [weak self, weak sender] response in
                Task { @MainActor in
                    guard let self, let sender else { return }
                    self.isPresentingCloseAlert = false
                    switch response {
                    case .alertFirstButtonReturn:
                        guard await controller.saveDraft() else { return }
                        self.allowNextClose = true
                        sender.performClose(nil)
                    case .alertThirdButtonReturn:
                        controller.discardDraft()
                        self.allowNextClose = true
                        sender.performClose(nil)
                    default:
                        break
                    }
                }
            }
            return false
        }
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

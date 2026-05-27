import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let container = AppContainer()
    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        container.start()
        menuBarController = MenuBarController(container: container)
    }

    func applicationWillTerminate(_ notification: Notification) {
        container.shutdown()
    }
}

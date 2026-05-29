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
        // First launch: walk the user through permissions, model download, and a quick tour.
        // The menu bar is already up, so onboarding is purely additive.
        if !container.onboardingState.isCompleted {
            container.openOnboarding()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        container.shutdown()
    }
}

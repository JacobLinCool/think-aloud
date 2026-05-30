import SwiftUI

@main
struct ThinkAloudApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The real Settings window is an AppKit NSWindow driven by SettingsWindowController
        // (opened from the menu bar / popup). Under LSUIElement there is no app menu to surface
        // this SwiftUI `Settings` scene, so it is inert — but it must not be allowed to present a
        // second, unbounded Settings window, hence EmptyView rather than the live SettingsScene.
        Settings {
            EmptyView()
        }
    }
}

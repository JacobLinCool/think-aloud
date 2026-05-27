import SwiftUI

@main
struct ThinkAloudApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsScene()
                .environment(appDelegate.container)
        }
    }
}

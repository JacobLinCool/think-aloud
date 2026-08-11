import SwiftUI

@main
struct ThinkAloudApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button(String(localized: "Settings…")) {
                    appDelegate.openSettingsFromMainMenu(nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

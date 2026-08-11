import AppKit
import SwiftUI

enum AppBootstrapPolicy {
    private static let unitTestEnvironmentKeys = [
        "XCTestConfigurationFilePath",
        "XCTestBundlePath",
        "XCInjectBundleInto"
    ]

    static func shouldBootstrap(
        arguments: [String],
        environment: [String: String]
    ) -> Bool {
        // UI tests launch a separate app process and intentionally exercise the full bootstrap.
        if arguments.contains("--ui-testing") {
            return true
        }
        // Hosted unit tests load the test bundle into the app executable. They must never touch
        // real user data, bind hotkeys, or present modal startup UI.
        return !unitTestEnvironmentKeys.contains { environment[$0] != nil }
    }
}

enum AppStartupErrorPresentation {
    static func message(for error: Error) -> String {
        switch error {
        case let error as SavedSettingsError:
            return error.localizedDescription
        case let error as AppContainer.StartupError:
            return error.localizedDescription
        case let error as AppPaths.StartupError:
            return error.localizedDescription
        default:
            return String(
                localized: "ThinkAloud encountered an unexpected startup problem. Quit and reopen the app; if the problem continues, check for an update."
            )
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var container: AppContainer?
    private var menuBarController: MenuBarController?
    private var settingsKeyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard AppBootstrapPolicy.shouldBootstrap(
            arguments: ProcessInfo.processInfo.arguments,
            environment: ProcessInfo.processInfo.environment
        ) else {
            return
        }
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.bootstrap()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let settingsKeyMonitor {
            NSEvent.removeMonitor(settingsKeyMonitor)
            self.settingsKeyMonitor = nil
        }
        container?.shutdown()
    }

    private func bootstrap() async {
        while true {
            do {
                let pendingContainer = try AppContainer()
                try await pendingContainer.start()
                NSApp.setActivationPolicy(.accessory)
                container = pendingContainer
                menuBarController = MenuBarController(container: pendingContainer)
                configureSettingsMenuItem()
                installSettingsKeyMonitor()
                presentInitialSurface(using: pendingContainer)
                return
            } catch {
                guard presentCriticalStartupFailure(error) else {
                    NSApp.terminate(nil)
                    return
                }
            }
        }
    }

    private func presentInitialSurface(using container: AppContainer) {
        #if DEBUG
        if let surface = container.runtimeConfiguration.uiTestSurface {
            switch surface {
            case .onboarding:
                container.openOnboarding()
            case .settings:
                container.openSettings()
            case .dataset:
                container.openDatasetBrowser()
            }
            return
        }
        #endif
        // First launch: walk the user through permissions, model download, and a quick tour.
        // The menu bar is already up, so onboarding is purely additive.
        if !container.onboardingState.isCompleted {
            container.openOnboarding()
        }
    }

    /// SwiftUI creates the native app-menu item, while AppKit owns its canonical action and key
    /// equivalent. Explicit wiring is required for an accessory/menu-bar app: relying on the
    /// generated Settings scene command leaves ⌘, visible in intent but inert at runtime.
    private func configureSettingsMenuItem() {
        let title = String(localized: "Settings…")
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu,
              let settingsItem = appMenu.items.first(where: { $0.title == title }) else {
            assertionFailure("ThinkAloud app menu is missing its Settings item")
            return
        }
        settingsItem.target = self
        settingsItem.action = #selector(openSettingsFromMainMenu(_:))
        settingsItem.keyEquivalent = ","
        settingsItem.keyEquivalentModifierMask = [.command]
    }

    private func installSettingsKeyMonitor() {
        guard settingsKeyMonitor == nil else { return }
        settingsKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let shortcutModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard shortcutModifiers == .command,
                  event.charactersIgnoringModifiers == "," else {
                return event
            }
            self?.openSettingsFromMainMenu(nil)
            return nil
        }
    }

    @objc func openSettingsFromMainMenu(_ sender: Any?) {
        guard let container else {
            NSSound.beep()
            return
        }
        container.openSettings()
    }

    /// Returns true when the user asks to retry after correcting the underlying storage issue.
    private func presentCriticalStartupFailure(_ error: Error) -> Bool {
        NSLog("ThinkAloud: startup failed: \(error)")
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(localized: "ThinkAloud Couldn’t Start")
        alert.informativeText = AppStartupErrorPresentation.message(for: error)

        if let settingsError = error as? SavedSettingsError,
           let preferenceKey = settingsError.invalidPreferenceKey {
            alert.addButton(withTitle: String(localized: "Reset Invalid Setting"))
            alert.addButton(withTitle: String(localized: "Retry"))
            alert.addButton(withTitle: String(localized: "Quit"))
            alert.buttons.last?.keyEquivalent = "\u{1b}"

            switch alert.runModal() {
            case .alertFirstButtonReturn:
                // Explicit, scoped recovery: remove only the canonical key identified by the typed
                // startup error. The next bootstrap then treats that key as genuinely unset.
                UserDefaults.standard.removeObject(forKey: preferenceKey)
                NSLog("ThinkAloud: user reset invalid saved setting \(preferenceKey)")
                return true
            case .alertSecondButtonReturn:
                return true
            default:
                return false
            }
        }

        alert.addButton(withTitle: String(localized: "Retry"))
        alert.addButton(withTitle: String(localized: "Quit"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}

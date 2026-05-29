import AppKit

@MainActor
final class MenuBarController: NSObject {
    private let container: AppContainer
    private let statusItem: NSStatusItem

    init(container: AppContainer) {
        self.container = container
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureStatusItem()
        rebuildMenu()
    }

    private func configureStatusItem() {
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "ThinkAloud")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "ThinkAloud"
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        // SF Symbols mirror the matching Settings tabs so the menu reads consistently with the
        // Settings window (Dataset → tray.full, Updates → arrow.down.circle, Settings → gearshape).
        menu.addItem(makeItem(title: String(localized: "Start Voice Input"), action: #selector(invokePopup), keyEquivalent: "", systemImage: "mic.fill"))
        menu.addItem(.separator())
        menu.addItem(makeItem(title: String(localized: "Browse Dataset…"), action: #selector(openDatasetBrowser), keyEquivalent: "d", systemImage: "tray.full"))
        menu.addItem(makeItem(title: String(localized: "Settings…"), action: #selector(openSettings), keyEquivalent: ",", systemImage: "gearshape"))
        menu.addItem(makeItem(title: String(localized: "Check for Updates…"), action: #selector(checkForUpdates), keyEquivalent: "", systemImage: "arrow.down.circle"))
        menu.addItem(.separator())
        menu.addItem(makeItem(title: String(localized: "Quit ThinkAloud"), action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func makeItem(title: String, action: Selector, keyEquivalent: String, systemImage: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        if let systemImage {
            let image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
            image?.isTemplate = true
            item.image = image
        }
        return item
    }

    @objc private func invokePopup() {
        container.coordinator.invoke()
    }

    @objc private func openSettings() {
        container.openSettings()
    }

    @objc private func openDatasetBrowser() {
        container.openDatasetBrowser()
    }

    @objc private func checkForUpdates() {
        container.updater.checkForUpdates()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension MenuBarController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        // Grey out "Check for Updates…" while a check/download is already in flight.
        if menuItem.action == #selector(checkForUpdates) {
            return container.updater.canCheckForUpdates
        }
        return true
    }
}

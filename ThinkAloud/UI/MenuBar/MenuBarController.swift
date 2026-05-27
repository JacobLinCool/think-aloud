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
        menu.addItem(makeItem(title: String(localized: "Start Voice Input"), action: #selector(invokePopup), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(makeItem(title: String(localized: "Browse Dataset…"), action: #selector(openDatasetBrowser), keyEquivalent: "d"))
        menu.addItem(makeItem(title: String(localized: "Settings…"), action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(makeItem(title: String(localized: "Quit ThinkAloud"), action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func makeItem(title: String, action: Selector, keyEquivalent: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
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

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

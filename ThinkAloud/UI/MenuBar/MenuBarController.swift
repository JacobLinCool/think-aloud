import AppKit

struct PopupMenuPresentation: Equatable {
    let title: String
    let systemImage: String
    let toolTip: String
    let isEnabled: Bool

    private init(title: String, systemImage: String, toolTip: String, isEnabled: Bool) {
        self.title = title
        self.systemImage = systemImage
        self.toolTip = toolTip
        self.isEnabled = isEnabled
    }

    init(phase: PopupPhase) {
        switch phase {
        case .idle:
            self = .init(
                title: String(localized: "Start Recording"),
                systemImage: "mic.fill",
                toolTip: String(localized: "ThinkAloud — Ready"),
                isEnabled: true
            )
        case .recording:
            self = .init(
                title: String(localized: "Stop & Transcribe"),
                systemImage: "stop.circle.fill",
                toolTip: String(localized: "ThinkAloud — Recording"),
                isEnabled: true
            )
        case .transcribing:
            self = .init(
                title: String(localized: "Cancel Transcription"),
                systemImage: "waveform",
                toolTip: String(localized: "ThinkAloud — Transcribing"),
                isEnabled: true
            )
        case .inserting:
            self = .init(
                title: String(localized: "Inserting Transcript…"),
                systemImage: "text.cursor",
                toolTip: String(localized: "ThinkAloud — Inserting"),
                isEnabled: false
            )
        case .polishing:
            self = .init(
                title: String(localized: "Insert & Save Now"),
                systemImage: "wand.and.stars",
                toolTip: String(localized: "ThinkAloud — Polishing"),
                isEnabled: true
            )
        case .review:
            self = .init(
                title: String(localized: "Insert & Save"),
                systemImage: "text.cursor",
                toolTip: String(localized: "ThinkAloud — Ready to Insert"),
                isEnabled: true
            )
        case .savingDataset:
            self = .init(
                title: String(localized: "Saving to Dataset…"),
                systemImage: "arrow.down.doc",
                toolTip: String(localized: "ThinkAloud — Saving"),
                isEnabled: false
            )
        case .error(let failure):
            self = .init(
                title: failure.retryTitle,
                systemImage: "exclamationmark.triangle.fill",
                toolTip: failure.kind == .datasetSave
                    ? String(localized: "ThinkAloud — Dataset Save Failed")
                    : String(localized: "ThinkAloud — Needs Attention"),
                isEnabled: true
            )
        }
    }
}

@MainActor
final class MenuBarController: NSObject {
    private let container: AppContainer
    private let statusItem: NSStatusItem
    private var primaryItem: NSMenuItem?

    init(container: AppContainer) {
        self.container = container
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureStatusItem()
        rebuildMenu()
        container.coordinator.viewModel.phaseDidChange = { [weak self] phase in
            self?.updatePresentation(for: phase)
        }
        updatePresentation(for: container.coordinator.viewModel.phase)
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
        let primaryItem = makeItem(
            title: String(localized: "Start Recording"),
            action: #selector(performPrimaryPopupAction),
            keyEquivalent: "",
            systemImage: "mic.fill"
        )
        menu.addItem(primaryItem)
        self.primaryItem = primaryItem
        menu.addItem(.separator())
        menu.addItem(makeItem(title: String(localized: "Insights…"), action: #selector(openInsights), keyEquivalent: "i", systemImage: "chart.bar.xaxis"))
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

    @objc private func performPrimaryPopupAction() {
        switch container.coordinator.viewModel.phase {
        case .idle:
            container.coordinator.invoke()
        case .error(let failure):
            container.coordinator.retry(after: failure)
        case .recording:
            container.coordinator.stopAndTranscribe()
        case .transcribing:
            container.coordinator.cancel()
        case .polishing, .review:
            container.coordinator.insertAndSave()
        case .inserting, .savingDataset:
            break
        }
    }

    private func updatePresentation(for phase: PopupPhase) {
        let presentation = PopupMenuPresentation(phase: phase)
        primaryItem?.title = presentation.title
        primaryItem?.isEnabled = presentation.isEnabled
        primaryItem?.image = NSImage(
            systemSymbolName: presentation.systemImage,
            accessibilityDescription: presentation.title
        )
        statusItem.button?.image = NSImage(
            systemSymbolName: presentation.systemImage,
            accessibilityDescription: presentation.toolTip
        )
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.toolTip = presentation.toolTip
        statusItem.button?.setAccessibilityLabel(presentation.toolTip)
    }

    @objc private func openSettings() {
        container.openSettings()
    }

    @objc private func openDatasetBrowser() {
        container.openDatasetBrowser()
    }

    /// Opens Settings on the Insights home page (stats + achievements).
    @objc private func openInsights() {
        container.openSettings(to: .insights)
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
        if menuItem.action == #selector(performPrimaryPopupAction) {
            return PopupMenuPresentation(phase: container.coordinator.viewModel.phase).isEnabled
        }
        return true
    }
}

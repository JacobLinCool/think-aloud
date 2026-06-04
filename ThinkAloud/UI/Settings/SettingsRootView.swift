import SwiftUI

/// Root of the Settings window: a two-column `NavigationSplitView` (sidebar category list + a
/// scrolling detail pane). Replaces the old fixed-size 6-tab `TabView`. The detail pane owns the
/// window title via `navigationTitle`; the window's static title is only a window-menu / a11y
/// fallback (see `SettingsWindowController`).
struct SettingsRootView: View {
    let router: SettingsRouter

    var body: some View {
        NavigationSplitView {
            List(selection: Binding<SettingsCategory?>(
                get: { router.selection },
                set: { if let new = $0 { router.selection = new } }
            )) {
                ForEach(SettingsCategory.allCases) { category in
                    Label(category.title, systemImage: category.symbol)
                        .tag(category)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 215, max: 240)
            // Fixed System-Settings feel: the sidebar is always visible, never collapsible.
            .toolbar(removing: .sidebarToggle)
        } detail: {
            SettingsDetail(category: router.selection)
                .navigationSplitViewColumnWidth(min: 460, ideal: 480)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 680, idealWidth: 760, minHeight: 480, idealHeight: 580)
    }
}

/// Renders the pane for the selected category and owns the window title. Milestone A hosts the
/// existing pane bodies verbatim; later phases swap in the re-sliced panes.
private struct SettingsDetail: View {
    let category: SettingsCategory

    var body: some View {
        content
            .navigationTitle(category.title)
    }

    @ViewBuilder
    private var content: some View {
        switch category {
        case .insights: InsightsPane()
        case .startup: StartupPane()
        case .shortcuts: ShortcutsPane()
        case .permissions: PermissionsPane()
        case .softwareUpdate: UpdatesPane()
        case .model: ModelPane()
        case .output: OutputPane()
        case .dataset: DatasetPane()
        case .advanced: AdvancedPane()
        }
    }
}

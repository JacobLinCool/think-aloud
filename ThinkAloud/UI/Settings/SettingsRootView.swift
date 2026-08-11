import SwiftUI

/// Root of the Settings window. Keep the system navigation container so macOS supplies the native
/// sidebar material, row treatment, title placement, divider, resizing, and accessibility roles.
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
            .frame(minWidth: 215)
            .navigationSplitViewColumnWidth(min: 215, ideal: 230, max: 260)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            SettingsDetail(category: router.selection)
                .navigationSplitViewColumnWidth(min: 460, ideal: 500)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 680, idealWidth: 760, minHeight: 480, idealHeight: 580)
    }
}

/// The selected pane owns the system navigation title. Avoid a second, hand-built title bar inside
/// the content; AppKit already presents the correct hierarchy in the window chrome.
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
        case .refine: RefinePane()
        case .dataset: DatasetPane()
        case .advanced: AdvancedPane()
        }
    }
}

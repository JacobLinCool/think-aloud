import SwiftUI

struct DatasetBrowserView: View {
    @Bindable var controller: DatasetBrowserController
    let player: AudioPlayerController
    @Bindable var pushController: HFPushController
    @Bindable var tokenStore: HFTokenStore

    var body: some View {
        // Plain HStack — not NavigationSplitView — so SwiftUI doesn't column-anchor our toolbar
        // items. The trade-off is losing the drag-to-resize divider; the sidebar is fixed-width.
        HStack(spacing: 0) {
            if !controller.sidebarHidden {
                sidebarContainer
                    .frame(width: 320)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                Divider()
            }
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.easeInOut(duration: 0.18), value: controller.sidebarHidden)
        .frame(minWidth: 760, minHeight: 480)
        .toolbar { toolbarContent }
        .sheet(isPresented: $controller.requestPushSheet) {
            HFPushView(controller: pushController)
        }
        .task {
            if controller.records.isEmpty {
                await controller.reload()
            }
        }
        .confirmationDialog(
            deleteDialogTitle,
            isPresented: deleteDialogBinding,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Delete"), role: .destructive) {
                let toDelete = controller.pendingDeleteRequestIDs
                controller.pendingDeleteRequestIDs = []
                Task { await controller.deleteAll(ids: toDelete) }
            }
            Button(String(localized: "Cancel"), role: .cancel) {
                controller.pendingDeleteRequestIDs = []
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                controller.toggleSidebar()
            } label: {
                Image(systemName: "sidebar.left")
            }
            .help(String(localized: "Toggle Sidebar"))
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                Task { await controller.reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help(String(localized: "Refresh"))

            Button {
                controller.requestPush()
            } label: {
                Image(systemName: "icloud.and.arrow.up")
            }
            .help(pushHelpText)
            .disabled(!canPush)

            Button(role: .destructive) {
                controller.requestDeleteSelected()
            } label: {
                Image(systemName: "trash")
            }
            .keyboardShortcut(.delete, modifiers: [.command])
            .disabled(controller.selectedIDs.isEmpty)
            .help(String(localized: "Delete selected (⌘⌫)"))
        }
    }

    private var canPush: Bool {
        tokenStore.hasToken && !controller.records.isEmpty
    }

    private var pushHelpText: String {
        if !tokenStore.hasToken {
            return String(localized: "Set an HF token in Settings → Advanced first.")
        }
        if controller.records.isEmpty {
            return String(localized: "No records to push.")
        }
        return String(localized: "Push to Hugging Face Hub")
    }

    // MARK: - Dialog plumbing

    private var deleteDialogTitle: String {
        let n = controller.pendingDeleteRequestIDs.count
        if n <= 1 {
            return String(localized: "Delete this record? The audio file is removed too. This cannot be undone.")
        }
        return String(localized: "Delete \(n) records and their audio files? This cannot be undone.")
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding(
            get: { !controller.pendingDeleteRequestIDs.isEmpty },
            set: { newValue in if !newValue { controller.pendingDeleteRequestIDs = [] } }
        )
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebarContainer: some View {
        VStack(spacing: 0) {
            sidebarList
            Divider()
            statusBar
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
    }

    @ViewBuilder
    private var sidebarList: some View {
        List(selection: $controller.selectedIDs) {
            ForEach(controller.records) { record in
                RecordRowView(record: record)
                    .tag(record.id)
                    .contextMenu {
                        Button(role: .destructive) {
                            controller.requestDelete(id: record.id)
                        } label: {
                            Label(String(localized: "Delete"), systemImage: "trash")
                        }
                    }
                    .onAppear {
                        if record.id == controller.records.last?.id {
                            Task { await controller.loadMore() }
                        }
                    }
            }
            if controller.isLoading {
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Spacer()
                }
                .padding(.vertical, 8)
            }
            if controller.records.isEmpty && !controller.isLoading {
                emptyState
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var statusBar: some View {
        HStack(spacing: 8) {
            Text(recordsCountLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            if controller.totalDurationMs > 0 {
                Text("·")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text(totalDurationLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !controller.selectedIDs.isEmpty {
                Text("\(controller.selectedIDs.count) selected")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.05))
    }

    private var recordsCountLabel: String {
        let n = controller.records.count
        return String(localized: "\(n) records")
    }

    private var totalDurationLabel: String {
        let totalSeconds = controller.totalDurationMs / 1000
        let m = totalSeconds / 60
        let s = totalSeconds % 60
        if m >= 60 {
            let h = m / 60
            let mm = m % 60
            return String(format: "%dh %02dm", h, mm)
        }
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Empty / detail

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("No records yet")
                .font(.headline)
            Text("Press ⌥Space, dictate, then choose Insert & save to add the first record.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .listRowBackground(Color.clear)
    }

    @ViewBuilder
    private var detail: some View {
        if let record = controller.selectedRecord {
            RecordDetailView(record: record, controller: controller, player: player)
        } else if controller.selectedIDs.count > 1 {
            VStack(spacing: 6) {
                Image(systemName: "rectangle.stack")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text("\(controller.selectedIDs.count) records selected")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("Use ⌘⌫ to delete the selection.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "text.quote")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text("Select a record")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

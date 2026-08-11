import SwiftUI
import KeyboardShortcuts

struct DatasetBrowserView: View {
    @Environment(AppContainer.self) private var container
    @Bindable var controller: DatasetBrowserController
    let player: AudioPlayerController
    @Bindable var pushController: HFPushController
    @Bindable var tokenStore: HFTokenStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            if !controller.sidebarHidden {
                sidebarContainer
                    .frame(width: 320)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(String(localized: "Records"))
                    .transition(.move(edge: .leading).combined(with: .opacity))
                Divider()
            }
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(String(localized: "Dataset Browser"))
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: controller.sidebarHidden)
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
        .confirmationDialog(
            String(localized: "Save changes before changing selection?"),
            isPresented: draftSelectionDialogBinding,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Save")) {
                guard let selection = controller.pendingSelectionIDs else { return }
                Task { await controller.saveAndApplyPendingSelection(selection) }
            }
            Button(String(localized: "Discard Changes"), role: .destructive) {
                guard let selection = controller.pendingSelectionIDs else { return }
                controller.discardAndApplyPendingSelection(selection)
            }
            Button(String(localized: "Cancel"), role: .cancel) {
                controller.cancelPendingSelection()
            }
        } message: {
            Text("Your edited transcript has unsaved changes.")
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
            .accessibilityLabel(
                controller.sidebarHidden
                    ? String(localized: "Show Sidebar")
                    : String(localized: "Hide Sidebar")
            )
            .help(
                controller.sidebarHidden
                    ? String(localized: "Show Sidebar")
                    : String(localized: "Hide Sidebar")
            )
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                Task { await controller.reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .accessibilityLabel(String(localized: "Refresh Records"))
            .help(String(localized: "Refresh"))
            .disabled(controller.hasUnsavedDraft)

            Button {
                controller.requestPush()
            } label: {
                Image(systemName: "icloud.and.arrow.up")
            }
            .accessibilityLabel(String(localized: "Push Dataset to Hugging Face"))
            .help(pushHelpText)
            .disabled(!canPush)

            Button(role: .destructive) {
                controller.requestDeleteSelected()
            } label: {
                Image(systemName: "trash")
            }
            .accessibilityLabel(String(localized: "Delete Selected Records"))
            .keyboardShortcut(.delete, modifiers: [.command])
            .disabled(controller.selectedIDs.isEmpty || controller.hasUnsavedDraft || controller.isDeleting)
            .help(String(localized: "Delete selected (⌘⌫)"))
        }
    }

    private var canPush: Bool {
        tokenStore.hasToken && controller.totalDatasetRecords > 0
    }

    private var pushHelpText: String {
        if let accessError = tokenStore.accessError {
            return accessError
        }
        if !tokenStore.hasToken {
            return String(localized: "Set a Hugging Face token in Settings → Dataset first.")
        }
        if controller.totalDatasetRecords == 0 {
            return String(localized: "No records to push.")
        }
        return String(localized: "Push to Hugging Face Hub")
    }

    // MARK: - Dialog plumbing

    private var deleteDialogTitle: String {
        let n = controller.pendingDeleteRequestIDs.count
        if n <= 1 {
            return String(localized: "Delete this record and its audio file? This cannot be undone.")
        }
        return String(localized: "Delete \(n) records and their audio files? This cannot be undone.")
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding(
            get: { !controller.pendingDeleteRequestIDs.isEmpty },
            set: { newValue in if !newValue { controller.pendingDeleteRequestIDs = [] } }
        )
    }

    private var draftSelectionDialogBinding: Binding<Bool> {
        Binding(
            get: { controller.isAwaitingSelectionDecision },
            set: { if !$0 { controller.cancelPendingSelection() } }
        )
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebarContainer: some View {
        VStack(spacing: 0) {
            if controller.isDeleting {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Deleting selected records… This operation can’t be cancelled.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let error = controller.loadErrorMessage {
                errorBanner(error, retry: { Task { await controller.loadMore() } })
            } else if let error = controller.actionErrorMessage {
                errorBanner(error, retry: nil)
            } else if let message = controller.actionMessage {
                Label(message, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            sidebarList
            Divider()
            statusBar
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
    }

    @ViewBuilder
    private var sidebarList: some View {
        List(selection: selectionBinding) {
            ForEach(controller.filteredRecords) { record in
                RecordRowView(record: record)
                    .tag(record.id)
                    .contextMenu {
                        Button(role: .destructive) {
                            controller.requestDelete(id: record.id)
                        } label: {
                            Label(String(localized: "Delete"), systemImage: "trash")
                        }
                        .disabled(
                            controller.isDeleting
                                || (controller.editingRecordID == record.id && controller.hasUnsavedDraft)
                        )
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
            if controller.records.isEmpty && !controller.isLoading && controller.loadErrorMessage == nil {
                if controller.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    emptyState
                } else {
                    ContentUnavailableView.search(text: controller.searchText)
                        .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(
            text: Binding(
                get: { controller.searchText },
                set: { controller.scheduleSearch($0) }
            ),
            placement: .sidebar,
            prompt: Text("Search transcripts, apps, or IDs")
        )
    }

    private var selectionBinding: Binding<Set<String>> {
        Binding(
            get: { controller.selectedIDs },
            set: { controller.requestSelection($0) }
        )
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
                Text(loadedDurationLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !controller.selectedIDs.isEmpty {
                Text("\(controller.selectedIDs.count.formatted()) selected")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.05))
    }

    private var recordsCountLabel: String {
        let loaded = controller.records.count
        let total = controller.totalMatchingRecords
        if loaded < total {
            return String(localized: "Showing \(loaded.formatted()) of \(total.formatted()) records")
        }
        return String(localized: "\(total.formatted()) records")
    }

    private var loadedDurationLabel: String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = controller.totalDurationMs >= 3_600_000 ? [.hour, .minute] : [.minute, .second]
        formatter.maximumUnitCount = 2
        guard let duration = formatter.string(from: Double(controller.totalDurationMs) / 1000) else {
            return String(localized: "Loaded audio duration unavailable")
        }
        return String(localized: "Loaded audio: \(duration)")
    }

    // MARK: - Empty / detail

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.title)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("No records yet")
                .font(.headline)
            if let dictationShortcut {
                Text("Press \(dictationShortcut), dictate, then choose Insert & save to add the first record.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Set a Start Recording shortcut before creating your first record.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button(String(localized: "Open Shortcuts Settings…")) {
                    container.openSettings(to: .shortcuts)
                }
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .listRowBackground(Color.clear)
    }

    private var dictationShortcut: String? {
        KeyboardShortcuts.getShortcut(for: .startRecording).map(String.init(describing:))
    }

    @ViewBuilder
    private func errorBanner(_ message: String, retry: (() -> Void)?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let retry {
                Button(String(localized: "Retry"), action: retry)
                    .controlSize(.small)
            }
        }
        .padding(8)
        .background(Color.red.opacity(0.08))
        .accessibilityElement(children: .combine)
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
                    .accessibilityHidden(true)
                Text("\(controller.selectedIDs.count.formatted()) records selected")
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
                    .accessibilityHidden(true)
                Text("Select a record")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

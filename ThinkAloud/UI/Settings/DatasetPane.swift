import AppKit
import KeyboardShortcuts
import SwiftUI

struct DatasetPane: View {
    @Environment(AppContainer.self) private var container

    @State private var recordCount: Int = 0
    @State private var totalAudioBytes: Int64 = 0
    @State private var isLoading = true
    @State private var isRefreshing = false
    @State private var loadError: String?
    @State private var status: ActionStatus?
    @State private var lastExportURL: URL?
    @State private var showClearConfirm = false
    @State private var pendingClearRecordIDs: Set<String> = []
    @State private var pendingClearAudioBytes: Int64 = 0
    @State private var isPreparingClear = false
    @State private var isClearing = false
    @State private var isExporting = false
    @State private var startRecordingShortcut: String?

    // Hugging Face token — moved here from Advanced because its only job is pushing the dataset.
    @State private var hfTokenDraft: String = ""
    @State private var hfStatus: HFStatus = .idle
    @State private var hfTestTask: Task<Void, Never>?

    enum HFStatus: Equatable {
        case idle
        case testing
        case verified(String)
        case failed(String)
    }

    enum ActionStatus: Equatable {
        case success(String)
        case warning(String)
        case failure(String)
    }

    var body: some View {
        Form {
            if isLoading {
                loadingSection
            } else if let loadError {
                loadErrorSection(loadError)
            } else if recordCount == 0 {
                emptyStateSection
            } else {
                storageSection
            }
            actionsSection
            syncSection
        }
        .formStyle(.grouped)
        .task { await refresh() }
        .onAppear {
            // Don't pre-fill the actual token — show empty field so a fresh save replaces it.
            hfTokenDraft = ""
            if container.hfTokenStore.hasToken,
               container.hfTokenStore.accessError == nil,
               let v = container.hfTokenStore.verifiedUsername {
                hfStatus = .verified(v)
            } else {
                hfStatus = .idle
            }
            startRecordingShortcut = KeyboardShortcuts
                .getShortcut(for: .startRecording)
                .map(String.init(describing:))
        }
        .onDisappear {
            hfTestTask?.cancel()
            hfTestTask = nil
        }
        .confirmationDialog(
            String(
                localized: "Permanently delete \(pendingClearRecordIDs.count.formatted()) captured records and \(formatBytes(pendingClearAudioBytes)) of audio? Records created after this confirmation will be kept. This cannot be undone."
            ),
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Clear all"), role: .destructive) { clearAll() }
            Button(String(localized: "Cancel"), role: .cancel) {
                pendingClearRecordIDs = []
                pendingClearAudioBytes = 0
            }
        }
    }

    private var loadingSection: some View {
        Section {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading dataset storage…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 16)
        }
    }

    private func loadErrorSection(_ message: String) -> some View {
        Section {
            VStack(spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Button(String(localized: "Try again")) {
                    Task { await refresh() }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
    }

    private var emptyStateSection: some View {
        Section {
            VStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.title)
                    .foregroundStyle(.secondary)
                Text("No records yet")
                    .font(.headline)
                if let startRecordingShortcut {
                    Text("Press \(startRecordingShortcut), dictate, then choose Insert & Save to add the first record.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else {
                    Text("Set a Start Recording shortcut before creating your first record.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button(String(localized: "Open Shortcuts Settings…")) {
                        container.openSettings(to: .shortcuts)
                    }
                    .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
    }

    private var storageSection: some View {
        Section {
            InfoRow("Record count", value: recordCount.formatted())
            InfoRow("Audio size", value: formatBytes(totalAudioBytes))
            InfoRow(label: "Database") {
                HStack(spacing: 6) {
                    Text(container.datasetStore.databaseFileURL.lastPathComponent)
                        .foregroundStyle(.secondary)
                    RevealInFinderButton(url: container.datasetStore.databaseFileURL)
                }
            }
        } header: {
            HStack {
                Text("Storage")
                Spacer()
                if isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    RefreshButton { Task { await refresh() } }
                        .disabled(isActionBusy)
                }
            }
        }
    }

    private var actionsSection: some View {
        Section {
            HStack {
                Button {
                    container.openDatasetBrowser()
                } label: {
                    Label(String(localized: "Browse records"), systemImage: "list.bullet.rectangle")
                }
                .disabled(recordCount == 0 || isLoading || isActionBusy)

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([container.applicationSupportDirectory])
                } label: {
                    Label(String(localized: "Open folder"), systemImage: "folder")
                }

                Button {
                    exportJSONL()
                } label: {
                    if isExporting {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(String(localized: "Exporting dataset…"))
                    } else {
                        Label(
                            String(localized: "Export JSONL…"),
                            systemImage: "square.and.arrow.up"
                        )
                    }
                }
                .disabled(recordCount == 0 || isLoading || isActionBusy)
            }

            if let lastExportURL {
                HStack(spacing: 6) {
                    Text("Last export: \(lastExportURL.lastPathComponent)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    RevealInFinderButton(url: lastExportURL)
                }
            }
            if let status {
                Label(statusText(status), systemImage: statusIcon(status))
                    .font(.caption)
                    .foregroundStyle(statusColor(status))
                    .textSelection(.enabled)
            }

            // Destructive action isolated at the foot of the section, away from everything else.
            HStack {
                Spacer()
                if isPreparingClear {
                    ProgressView().controlSize(.small)
                    Text("Preparing deletion…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if isClearing {
                    ProgressView().controlSize(.small)
                    Text("Deleting captured records… This operation can’t be cancelled.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button(role: .destructive) {
                        prepareClearAll()
                    } label: {
                        Text("Clear all…")
                    }
                    .disabled(recordCount == 0 || isLoading || isActionBusy)
                }
            }
        } header: {
            Text("Actions")
        }
    }

    // MARK: - Sync / Upload

    private var syncSection: some View {
        Section {
            HStack {
                Text("Token")
                Spacer()
                if container.hfTokenStore.accessError != nil {
                    StatusBadge(tone: .error, text: String(localized: "Unavailable"))
                } else if container.hfTokenStore.hasToken {
                    StatusBadge(tone: .ok, text: String(localized: "Saved"))
                } else {
                    StatusBadge(tone: .neutral, text: String(localized: "Not set"))
                }
            }
            if let accessError = container.hfTokenStore.accessError {
                Label(accessError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            SecureField(String(localized: "hf_… (paste here, then Save)"), text: $hfTokenDraft)
                .textFieldStyle(.roundedBorder)
                .disabled(isHFTesting)
            if container.hfTokenStore.hasToken {
                Text("A token is saved. Paste a new one to replace it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button(String(localized: "Save token")) {
                    saveToken()
                }
                .disabled(
                    hfTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || isHFTesting
                )
                Button(String(localized: "Test connection")) {
                    testConnection()
                }
                .disabled(!container.hfTokenStore.hasToken || isHFTesting)
                Spacer()
                if container.hfTokenStore.hasToken {
                    DestructiveButton(
                        "Clear…",
                        confirmMessage: "Remove the saved Hugging Face token from the macOS Keychain?",
                        confirmLabel: "Clear"
                    ) {
                        clearToken()
                    }
                    .controlSize(.small)
                    .disabled(isHFTesting)
                }
            }
            switch hfStatus {
            case .idle:
                EmptyView()
            case .testing:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Testing…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .verified(let user):
                Text("Signed in as **\(user)**")
                    .font(.caption)
                    .foregroundStyle(.green)
            case .failed(let msg):
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        } header: {
            Text("Sync / Upload")
        } footer: {
            Text("A Hugging Face token lets you push the dataset from the browser window. It is stored in the macOS Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func refresh() async {
        if !isLoading { isRefreshing = true }
        defer {
            isLoading = false
            isRefreshing = false
        }
        do {
            let count = try await container.datasetStore.count()
            let audioRoot = await container.audioFileStore.root
            let bytes = try await container.datasetStore.totalAudioBytes(rootDirectory: audioRoot)
            self.recordCount = count
            self.totalAudioBytes = bytes
            self.loadError = nil
        } catch {
            NSLog("ThinkAloud: Dataset settings storage load failed: \(error)")
            self.loadError = String(
                localized: "ThinkAloud couldn’t load dataset storage. Check available storage and try again."
            )
        }
    }

    private func exportJSONL() {
        guard !isActionBusy else { return }
        isExporting = true
        status = nil
        Task { @MainActor in
            defer { isExporting = false }
            do {
                let records = try await container.datasetStore.all()
                guard let url = await chooseExportURL() else { return }
                try await Task.detached {
                    try JSONLExporter.export(records: records, to: url)
                }.value
                self.lastExportURL = url
                self.status = .success(String(localized: "Exported \(records.count) records."))
            } catch {
                NSLog("ThinkAloud: dataset export failed: \(error)")
                self.status = .failure(
                    String(
                        localized: "ThinkAloud couldn’t export the dataset. Choose a writable folder and try again."
                    )
                )
            }
        }
    }

    private var isDeleteBusy: Bool {
        isPreparingClear || isClearing
    }

    private var isActionBusy: Bool {
        isDeleteBusy || isExporting
    }

    private var isHFTesting: Bool {
        if case .testing = hfStatus { return true }
        return false
    }

    private func prepareClearAll() {
        guard !isActionBusy else { return }
        isPreparingClear = true
        status = nil
        Task { @MainActor in
            defer { isPreparingClear = false }
            do {
                let records = try await container.datasetStore.all()
                let ids = Set(records.map(\.id))
                guard !ids.isEmpty else {
                    status = .warning(String(localized: "There are no records to delete."))
                    await refresh()
                    return
                }
                let audioRoot = await container.audioFileStore.root
                let audioBytes = try await container.datasetStore.totalAudioBytes(
                    rootDirectory: audioRoot
                )
                pendingClearRecordIDs = ids
                pendingClearAudioBytes = audioBytes
                showClearConfirm = true
            } catch {
                NSLog("ThinkAloud: dataset deletion preparation failed: \(error)")
                status = .failure(
                    String(
                        localized: "ThinkAloud couldn’t prepare the deletion. Refresh the dataset and try again."
                    )
                )
            }
        }
    }

    private func clearAll() {
        guard !isActionBusy, !pendingClearRecordIDs.isEmpty else { return }
        let capturedIDs = pendingClearRecordIDs
        pendingClearRecordIDs = []
        pendingClearAudioBytes = 0
        isClearing = true
        status = nil
        Task { @MainActor in
            defer { isClearing = false }
            do {
                let report = try await container.datasetDeletionService.delete(ids: capturedIDs)
                if report.hasWarnings {
                    self.status = .warning(
                        String(
                            localized: "Deleted \(report.deletedCount) records. \(report.missingAudioPaths.count) audio file(s) were already missing."
                        )
                    )
                } else {
                    self.status = .success(
                        String(localized: "Deleted \(report.deletedCount) records.")
                    )
                }
                await refresh()
            } catch {
                NSLog("ThinkAloud: dataset deletion failed from Settings: \(error)")
                if let deletionError = error as? DatasetDeletionService.DeletionError {
                    // Recovery errors deliberately retain the exact directory the user must preserve.
                    self.status = .failure(deletionError.localizedDescription)
                } else {
                    self.status = .failure(
                        String(
                            localized: "ThinkAloud couldn’t delete the captured records. Refresh the dataset and try again."
                        )
                    )
                }
                await refresh()
            }
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }

    // MARK: - Hugging Face token

    private func saveToken() {
        do {
            let token = hfTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { return }
            try container.hfTokenStore.save(token: token)
            hfTokenDraft = ""
            hfStatus = .idle
        } catch {
            NSLog("ThinkAloud: Hugging Face token save failed: \(error)")
            hfStatus = .failed(
                String(
                    localized: "ThinkAloud couldn’t save the token in Keychain. Check Keychain access and try again."
                )
            )
        }
    }

    @MainActor
    private func chooseExportURL() async -> URL? {
        let panel = NSSavePanel()
        panel.title = String(localized: "Export Dataset")
        panel.prompt = String(localized: "Export")
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = JSONLExporter
            .makeDefaultExportURL(in: URL(fileURLWithPath: "/"))
            .lastPathComponent
        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow {
            response = await withCheckedContinuation { continuation in
                panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } else {
            response = panel.runModal()
        }
        return response == .OK ? panel.url : nil
    }

    private func statusText(_ status: ActionStatus) -> String {
        switch status {
        case .success(let message), .warning(let message), .failure(let message):
            return message
        }
    }

    private func statusIcon(_ status: ActionStatus) -> String {
        switch status {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failure: return "xmark.octagon.fill"
        }
    }

    private func statusColor(_ status: ActionStatus) -> Color {
        switch status {
        case .success: return .green
        case .warning: return .orange
        case .failure: return .red
        }
    }

    private func clearToken() {
        do {
            try container.hfTokenStore.clear()
            hfTokenDraft = ""
            hfStatus = .idle
        } catch {
            NSLog("ThinkAloud: Hugging Face token clear failed: \(error)")
            hfStatus = .failed(
                String(
                    localized: "ThinkAloud couldn’t clear the token from Keychain. Check Keychain access and try again."
                )
            )
        }
    }

    private func testConnection() {
        guard !isHFTesting, let token = container.hfTokenStore.token else { return }
        hfStatus = .testing
        hfTestTask = Task { @MainActor in
            defer { hfTestTask = nil }
            let client = HFHubClient(token: token)
            do {
                let me = try await client.whoami()
                try Task.checkCancellation()
                container.hfTokenStore.verifiedUsername = me.name
                hfStatus = .verified(me.name)
            } catch is CancellationError {
                hfStatus = .idle
            } catch {
                NSLog("ThinkAloud: Hugging Face connection test failed: \(error)")
                if let hubError = error as? HFHubClient.HFError {
                    hfStatus = .failed(hubError.localizedDescription)
                } else {
                    hfStatus = .failed(
                        String(
                            localized: "ThinkAloud couldn’t connect to Hugging Face. Check your connection and token, then try again."
                        )
                    )
                }
            }
        }
    }
}

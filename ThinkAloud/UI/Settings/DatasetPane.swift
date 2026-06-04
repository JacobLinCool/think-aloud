import AppKit
import SwiftUI

struct DatasetPane: View {
    @Environment(AppContainer.self) private var container

    @State private var recordCount: Int = 0
    @State private var totalAudioBytes: Int64 = 0
    @State private var stats: DatasetStatistics?
    @State private var statusMessage: String?
    @State private var lastExportURL: URL?
    @State private var showClearConfirm = false

    // Hugging Face token — moved here from Advanced because its only job is pushing the dataset.
    @State private var hfTokenDraft: String = ""
    @State private var hfStatus: HFStatus = .idle

    enum HFStatus: Equatable {
        case idle
        case testing
        case verified(String)
        case failed(String)
    }

    var body: some View {
        Form {
            if recordCount == 0 {
                emptyStateSection
            } else {
                insightsSection
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
            if let v = container.hfTokenStore.verifiedUsername {
                hfStatus = .verified(v)
            }
        }
        .confirmationDialog(
            String(localized: "Delete all \(recordCount) records and \(formatBytes(totalAudioBytes)) of audio? This cannot be undone."),
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Clear all"), role: .destructive) { clearAll() }
            Button(String(localized: "Cancel"), role: .cancel) {}
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
                Text("Press ⌥Space, dictate, then choose Insert & save to add the first record.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
    }

    private var insightsSection: some View {
        Section {
            if let stats, !stats.isEmpty {
                InfoRow("Dictated", value: String(localized: "\(StatFmt.count(stats.text.totalEditedChars)) characters"))
                if stats.editing.eligibleCount > 0 {
                    InfoRow("Came out clean", value: StatFmt.percent(stats.editing.cleanRate))
                }
                InfoRow("Time saved", value: "~\(StatFmt.duration(seconds: stats.productivity.timeSavedSeconds))")
            }
            Button {
                container.openDatasetBrowser()
            } label: {
                Label(String(localized: "View insights"), systemImage: "chart.bar.xaxis")
            }
        } header: {
            Text("Insights")
        } footer: {
            Text("Your time saved, accuracy, and dataset shape — open the dataset window for the full breakdown.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var storageSection: some View {
        Section {
            InfoRow("Record count", value: "\(recordCount)")
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
                RefreshButton { Task { await refresh() } }
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
                .disabled(recordCount == 0)

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([AppPaths.applicationSupportDirectory()])
                } label: {
                    Label(String(localized: "Open folder"), systemImage: "folder")
                }

                Button {
                    exportJSONL()
                } label: {
                    Label(String(localized: "Export JSONL"), systemImage: "square.and.arrow.up")
                }
                .disabled(recordCount == 0)
            }

            if let lastExportURL {
                HStack(spacing: 6) {
                    Text("Last export: \(lastExportURL.path)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    RevealInFinderButton(url: lastExportURL)
                }
            }
            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Destructive action isolated at the foot of the section, away from everything else.
            HStack {
                Spacer()
                Button(role: .destructive) {
                    showClearConfirm = true
                } label: {
                    Text("Clear all")
                }
                .disabled(recordCount == 0)
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
                if container.hfTokenStore.hasToken {
                    StatusBadge(tone: .ok, text: String(localized: "Saved"))
                } else {
                    StatusBadge(tone: .neutral, text: String(localized: "Not set"))
                }
            }
            SecureField(String(localized: "hf_… (paste here, then Save)"), text: $hfTokenDraft)
                .textFieldStyle(.roundedBorder)
            if container.hfTokenStore.hasToken {
                Text("A token is saved. Paste a new one to replace it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button(String(localized: "Save token")) {
                    saveToken()
                }
                .disabled(hfTokenDraft.isEmpty)
                Button(String(localized: "Test connection")) {
                    testConnection()
                }
                .disabled(!container.hfTokenStore.hasToken)
                Spacer()
                if container.hfTokenStore.hasToken {
                    DestructiveButton(
                        "Clear",
                        confirmMessage: "Remove the saved Hugging Face token from the macOS Keychain?",
                        confirmLabel: "Clear"
                    ) {
                        clearToken()
                    }
                    .controlSize(.small)
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
        do {
            let count = try await container.datasetStore.count()
            let audioRoot = await container.audioFileStore.root
            let bytes = await container.datasetStore.totalAudioBytes(rootDirectory: audioRoot)
            self.recordCount = count
            self.totalAudioBytes = bytes
            if count > 0 {
                self.stats = try? await container.datasetStore.computeStatistics()
            } else {
                self.stats = nil
            }
        } catch {
            self.statusMessage = String(localized: "Refresh failed: \(error.localizedDescription)")
        }
    }

    private func exportJSONL() {
        Task { @MainActor in
            do {
                let records = try await container.datasetStore.all()
                let exportsDir = AppPaths.applicationSupportDirectory().appendingPathComponent("exports", isDirectory: true)
                try FileManager.default.createDirectory(at: exportsDir, withIntermediateDirectories: true)
                let url = JSONLExporter.makeDefaultExportURL(in: exportsDir)
                try JSONLExporter.export(records: records, to: url)
                self.lastExportURL = url
                self.statusMessage = String(localized: "Exported \(records.count) records.")
            } catch {
                self.statusMessage = String(localized: "Export failed: \(error.localizedDescription)")
            }
        }
    }

    private func clearAll() {
        Task { @MainActor in
            do {
                try await container.datasetStore.deleteAll()
                self.statusMessage = String(localized: "All records deleted.")
                await refresh()
            } catch {
                self.statusMessage = String(localized: "Delete failed: \(error.localizedDescription)")
            }
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    // MARK: - Hugging Face token

    private func saveToken() {
        do {
            try container.hfTokenStore.save(token: hfTokenDraft)
            hfTokenDraft = ""
            hfStatus = .idle
        } catch {
            hfStatus = .failed(String(localized: "Keychain save failed: \(error.localizedDescription)"))
        }
    }

    private func clearToken() {
        do {
            try container.hfTokenStore.clear()
            hfTokenDraft = ""
            hfStatus = .idle
        } catch {
            hfStatus = .failed(String(localized: "Keychain clear failed: \(error.localizedDescription)"))
        }
    }

    private func testConnection() {
        guard let token = container.hfTokenStore.token else { return }
        hfStatus = .testing
        Task { @MainActor in
            let client = HFHubClient(token: token)
            do {
                let me = try await client.whoami()
                container.hfTokenStore.verifiedUsername = me.name
                hfStatus = .verified(me.name)
            } catch {
                hfStatus = .failed(String(localized: "Connection failed: \(error.localizedDescription)"))
            }
        }
    }
}

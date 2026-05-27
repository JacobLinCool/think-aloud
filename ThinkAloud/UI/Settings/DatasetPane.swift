import AppKit
import SwiftUI

struct DatasetPane: View {
    @Environment(AppContainer.self) private var container

    @State private var recordCount: Int = 0
    @State private var totalAudioBytes: Int64 = 0
    @State private var statusMessage: String?
    @State private var lastExportURL: URL?

    var body: some View {
        Form {
            if recordCount == 0 {
                emptyStateSection
            } else {
                storageSection
            }
            actionsSection
        }
        .formStyle(.grouped)
        .padding(.horizontal)
        .task { await refresh() }
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
            Text("Storage")
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
                .buttonStyle(.borderedProminent)
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

                Spacer()

                Button {
                    Task { await refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Refresh status"))

                DestructiveButton(
                    "Clear all",
                    confirmMessage: "Delete all dataset records and their audio files? This cannot be undone.",
                    confirmLabel: "Clear all"
                ) {
                    clearAll()
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
        } header: {
            Text("Actions")
        }
    }

    private func refresh() async {
        do {
            let count = try await container.datasetStore.count()
            let audioRoot = await container.audioFileStore.root
            let bytes = await container.datasetStore.totalAudioBytes(rootDirectory: audioRoot)
            self.recordCount = count
            self.totalAudioBytes = bytes
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
}

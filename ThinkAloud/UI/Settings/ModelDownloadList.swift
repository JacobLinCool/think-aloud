import AppKit
import SwiftUI

/// The unified Model section: one per-profile list where tapping a row selects the active engine
/// (stages it via `setProfile` — no auto-download), shows the full model ID, download state / size,
/// and a per-row Download / Remove. The active row additionally reflects the live runtime readiness.
///
/// This absorbs the download/remove/low-disk machinery that used to live in the Advanced pane —
/// moved INTACT (inflight tracking, the `refreshToken` re-read trick, the low-disk guard, and the
/// per-profile download-progress poll) so downloads keep their progress and the disk guard.
struct ModelDownloadList: View {
    @Environment(AppContainer.self) private var container

    @State private var inflightDownloads: Set<ModelProfile> = []
    @State private var inflightRemovals: Set<ModelProfile> = []
    @State private var error: String?
    @State private var refreshToken = 0  // bumped to force re-read of cacheSize after mutations

    @State private var lowDiskPrompt: ModelProfile?
    @State private var availableBytes: Int64 = 0

    /// Trigger the low-disk confirmation when free space on the models volume drops below this.
    private let lowDiskThresholdBytes: Int64 = 5 * 1_000_000_000

    var body: some View {
        Section {
            ForEach(ModelProfile.allCases) { profile in
                modelRow(profile)
            }
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            HStack {
                Text("Model")
                Spacer()
                RevealInFinderButton(url: container.modelManager.modelCacheURL)
            }
        } footer: {
            Text("Pick the transcription engine — tap a model to make it active. Larger models are more accurate but slower and bigger on disk. The active model downloads on first use; download or remove variants here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .id(refreshToken)  // Bumps after a download/remove so cacheSize and isDownloaded re-read from disk.
        .alert(
            String(localized: "Disk space low"),
            isPresented: Binding(
                get: { lowDiskPrompt != nil },
                set: { if !$0 { lowDiskPrompt = nil } }
            ),
            presenting: lowDiskPrompt
        ) { profile in
            Button(String(localized: "Download anyway"), role: .destructive) {
                performDownload(profile)
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: { _ in
            Text("Only \(formatBytes(availableBytes)) free on the models volume. Continue downloading?")
        }
    }

    @ViewBuilder
    private func modelRow(_ profile: ModelProfile) -> some View {
        let isCurrent = container.modelManager.profile == profile
        let downloaded = container.modelManager.isDownloaded(profile)
        let size = container.modelManager.cacheSize(for: profile)
        let isDownloading = inflightDownloads.contains(profile)
        let isRemoving = inflightRemovals.contains(profile)

        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isCurrent ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                .imageScale(.large)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(profile.shortName).fontWeight(.semibold)
                    if isCurrent {
                        Text("Current")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.18), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(profile.modelID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                statusLine(profile: profile, downloaded: downloaded, size: size, isDownloading: isDownloading, isRemoving: isRemoving, isCurrent: isCurrent)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                if downloaded {
                    DestructiveButton(
                        "Remove",
                        confirmMessage: "Delete this model from disk? It will need to re-download next time you select it.",
                        confirmLabel: "Remove"
                    ) {
                        remove(profile)
                    }
                    .controlSize(.small)
                    .disabled(isRemoving)
                } else {
                    Button(String(localized: "Download")) {
                        download(profile)
                    }
                    .controlSize(.small)
                    .disabled(isDownloading)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { container.modelManager.setProfile(profile) }
    }

    @ViewBuilder
    private func statusLine(profile: ModelProfile, downloaded: Bool, size: Int64, isDownloading: Bool, isRemoving: Bool, isCurrent: Bool) -> some View {
        if isDownloading {
            // `displayLabel` reads "Downloading X% (dn / tot)" once the per-profile poller has a
            // known total, else "Downloading… (dn)".
            let status = container.modelManager.profileDownloadStatus[profile]
            Text(status?.displayLabel ?? String(localized: "Downloading…"))
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if isRemoving {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Removing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if isCurrent {
            // The active model: show its live runtime readiness (Loaded / Loading / Downloading…).
            HStack(spacing: 6) {
                StatusBadge(tone: container.modelManager.runtimeStatus.badge,
                            text: container.modelManager.runtimeStatus.displayLabel)
                if downloaded {
                    Text("· \(formatBytes(size))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let progress = container.modelManager.runtimeStatus.downloadProgress {
                ProgressView(value: progress)
            } else if container.modelManager.runtimeStatus.isLoading {
                ProgressView()
            }
        } else if downloaded {
            Text("Downloaded · \(formatBytes(size))")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("Not downloaded")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func download(_ profile: ModelProfile) {
        let free = freeSpaceAtModelsVolume()
        if free < lowDiskThresholdBytes {
            availableBytes = free
            lowDiskPrompt = profile
            return
        }
        performDownload(profile)
    }

    private func performDownload(_ profile: ModelProfile) {
        inflightDownloads.insert(profile)
        error = nil
        Task { @MainActor in
            do {
                try await container.modelManager.downloadProfile(profile)
            } catch {
                self.error = String(localized: "Download failed: \(error.localizedDescription)")
            }
            inflightDownloads.remove(profile)
            refreshToken &+= 1
        }
    }

    /// Free bytes on the volume that hosts the models cache. Uses
    /// `volumeAvailableCapacityForImportantUsageKey` so it accounts for purgeable storage the
    /// system will reclaim under pressure (closer to what Finder shows).
    private func freeSpaceAtModelsVolume() -> Int64 {
        let url = container.modelManager.modelCacheURL
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Int64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    private func remove(_ profile: ModelProfile) {
        inflightRemovals.insert(profile)
        error = nil
        Task { @MainActor in
            do {
                try container.modelManager.removeProfile(profile)
            } catch {
                self.error = String(localized: "Remove failed: \(error.localizedDescription)")
            }
            inflightRemovals.remove(profile)
            refreshToken &+= 1
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useMB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }
}

import AppKit
import SwiftUI

struct ModelDownloadSpaceRequirement: Equatable {
    static let minimumSafetyMarginBytes: Int64 = 500_000_000

    let downloadBytes: Int64

    init(downloadBytes: Int64) {
        precondition(downloadBytes >= 0, "Model download size cannot be negative")
        self.downloadBytes = downloadBytes
    }

    /// The downloader first stores Hugging Face blobs and then installs a separate snapshot copy.
    /// Both can coexist until cleanup, so free-space checks must budget for the peak, not merely the
    /// final model size.
    var peakModelBytes: Int64 {
        let (result, overflow) = downloadBytes.multipliedReportingOverflow(by: 2)
        return overflow ? .max : result
    }

    var safetyMarginBytes: Int64 {
        max(Self.minimumSafetyMarginBytes, downloadBytes / 5)
    }

    var requiredAvailableBytes: Int64 {
        let (result, overflow) = peakModelBytes.addingReportingOverflow(safetyMarginBytes)
        return overflow ? .max : result
    }
}

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
    @State private var downloadTasks: [ModelProfile: Task<Void, Never>] = [:]
    @State private var cancellationRequested: Set<ModelProfile> = []
    @State private var inflightRemovals: Set<ModelProfile> = []
    @State private var error: String?
    @State private var refreshToken = 0  // bumped to force re-read of cacheSize after mutations

    @State private var lowDiskPrompt: ModelProfile?
    @State private var availableBytes: Int64 = 0

    /// Per-profile disk state, cached so the status pollers (which re-render this view ~4×/s during
    /// a download/load) never trigger a synchronous full-tree `directorySize` walk on the main
    /// thread. Recomputed only on appear and whenever `refreshToken` bumps (download/remove done).
    @State private var sizes: [ModelProfile: Int64] = [:]
    @State private var downloadedProfiles: Set<ModelProfile> = []

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
        .onAppear { refreshDiskInfo() }
        .onChange(of: refreshToken) { refreshDiskInfo() }
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
        } message: { profile in
            let required = ModelDownloadSpaceRequirement(
                downloadBytes: profile.estimatedDownloadBytes
            ).requiredAvailableBytes
            Text(
                "This model may need about \(formatBytes(required)) at peak for the temporary Hugging Face blob, installed snapshot, and safety margin, but only \(formatBytes(availableBytes)) is available. Continue downloading?"
            )
        }
    }

    @ViewBuilder
    private func modelRow(_ profile: ModelProfile) -> some View {
        let isCurrent = container.modelManager.profile == profile
        let downloaded = downloadedProfiles.contains(profile)
        let size = sizes[profile] ?? 0
        let isDownloading = inflightDownloads.contains(profile)
        let isRemoving = inflightRemovals.contains(profile)

        HStack(alignment: .top, spacing: 12) {
            Button {
                container.modelManager.setProfile(profile)
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: isCurrent ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                        .imageScale(.large)
                        .padding(.top, 1)
                        .accessibilityHidden(true)
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
                                    .accessibilityHidden(true)
                            }
                        }
                        Text(profile.modelID)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        statusLine(
                            profile: profile,
                            downloaded: downloaded,
                            size: size,
                            isDownloading: isDownloading,
                            isRemoving: isRemoving,
                            isCurrent: isCurrent
                        )
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(String(localized: "Use \(profile.shortName) for transcription"))
            .accessibilityValue(isCurrent ? String(localized: "Selected") : String(localized: "Not selected"))
            .accessibilityAddTraits(isCurrent ? .isSelected : [])
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
                    .accessibilityLabel(String(localized: "Remove \(profile.shortName)"))
                } else if isDownloading {
                    Button(
                        cancellationRequested.contains(profile)
                            ? String(localized: "Canceling…")
                            : String(localized: "Cancel Download")
                    ) {
                        cancellationRequested.insert(profile)
                        downloadTasks[profile]?.cancel()
                    }
                    .controlSize(.small)
                    .disabled(cancellationRequested.contains(profile))
                    .accessibilityLabel(String(localized: "Cancel \(profile.shortName) Download"))
                } else {
                    Button(String(localized: "Download")) {
                        download(profile)
                    }
                    .controlSize(.small)
                    .disabled(isDownloading)
                    .accessibilityLabel(String(localized: "Download \(profile.shortName)"))
                }
            }
        }
        .padding(.vertical, 4)
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
            if cancellationRequested.contains(profile) {
                Text("Cancellation requested. The download stops when the server responds.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
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
        do {
            let free = try freeSpaceAtModelsVolume()
            let requirement = ModelDownloadSpaceRequirement(downloadBytes: profile.estimatedDownloadBytes)
            if free < requirement.requiredAvailableBytes {
                availableBytes = free
                lowDiskPrompt = profile
                return
            }
            performDownload(profile)
        } catch {
            NSLog("ThinkAloud: model download disk-space check failed: \(error)")
            self.error = String(
                localized: "ThinkAloud couldn’t check available storage. Check storage access and try again."
            )
        }
    }

    private func performDownload(_ profile: ModelProfile) {
        inflightDownloads.insert(profile)
        error = nil
        let task = Task { @MainActor in
            do {
                try await container.modelManager.downloadProfile(profile)
            } catch {
                if !Task.isCancelled {
                    NSLog("ThinkAloud: model download failed for \(profile.modelID): \(error)")
                    self.error = String(
                        localized: "The model couldn’t be downloaded. Check your connection and available storage, then try again."
                    )
                }
            }
            downloadTasks[profile] = nil
            cancellationRequested.remove(profile)
            inflightDownloads.remove(profile)
            refreshToken &+= 1
        }
        downloadTasks[profile] = task
    }

    /// Free bytes on the volume that hosts the models cache. Uses
    /// `volumeAvailableCapacityForImportantUsageKey` so it accounts for purgeable storage the
    /// system will reclaim under pressure (closer to what Finder shows).
    private func freeSpaceAtModelsVolume() throws -> Int64 {
        let url = container.modelManager.modelCacheURL
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let capacity = values.volumeAvailableCapacityForImportantUsage else {
            throw CocoaError(.fileReadUnknown)
        }
        return Int64(capacity)
    }

    private func remove(_ profile: ModelProfile) {
        inflightRemovals.insert(profile)
        error = nil
        Task { @MainActor in
            do {
                try container.modelManager.removeProfile(profile)
            } catch {
                NSLog("ThinkAloud: model removal failed for \(profile.modelID): \(error)")
                self.error = String(
                    localized: "The downloaded model couldn’t be removed. Check storage access and try again."
                )
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

    /// Stat the disk for every profile ONCE (on appear / after a download or remove), caching the
    /// result so per-render reads in `modelRow` never touch the filesystem.
    private func refreshDiskInfo() {
        var newSizes: [ModelProfile: Int64] = [:]
        var newDownloaded: Set<ModelProfile> = []
        for profile in ModelProfile.allCases where container.modelManager.isDownloaded(profile) {
            newDownloaded.insert(profile)
            newSizes[profile] = container.modelManager.cacheSize(for: profile)
        }
        sizes = newSizes
        downloadedProfiles = newDownloaded
    }
}

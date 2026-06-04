import Foundation
import Observation

/// Drives the dataset browser window: paged list, multi-selection, edit, delete.
@MainActor
@Observable
final class DatasetBrowserController {
    private let datasetStore: DatasetStore
    private let audioFileStore: AudioFileStore

    private(set) var records: [DatasetRecord] = []
    private(set) var hasMore: Bool = true
    private(set) var isLoading: Bool = false
    private(set) var errorMessage: String?

    /// Aggregate statistics for the overview pane. Computed over ALL saved records (not just the
    /// loaded page) on a background task, then cached here — never recomputed per render.
    private(set) var statistics: DatasetStatistics?
    private(set) var statisticsLoading: Bool = false
    /// One-shot indicator pulses for ~1.5s after a successful edit save. Lets the detail view
    /// show "已儲存 ✓" briefly without us threading a separate callback.
    private(set) var lastSaveTick: Date?

    /// Multi-selection set bound to the SwiftUI List. Detail panel renders only when exactly
    /// one row is selected; bulk delete uses the full set.
    var selectedIDs: Set<String> = []

    /// Plain Bool — the layout is a HStack, not NavigationSplitView, so we don't need the
    /// three-state NavigationSplitViewVisibility. Toggled by the toolbar sidebar button.
    var sidebarHidden: Bool = false
    /// Toolbar push button sets true → SwiftUI .sheet displays HFPushView and resets to false.
    var requestPushSheet: Bool = false
    /// Toolbar delete button populates this → SwiftUI .confirmationDialog handles it.
    var pendingDeleteRequestIDs: Set<String> = []

    private let pageSize: Int = 50

    init(datasetStore: DatasetStore, audioFileStore: AudioFileStore) {
        self.datasetStore = datasetStore
        self.audioFileStore = audioFileStore
    }

    /// Returns the unique selected record, or nil when 0 or >1 are selected.
    var selectedRecord: DatasetRecord? {
        guard selectedIDs.count == 1, let id = selectedIDs.first else { return nil }
        return records.first(where: { $0.id == id })
    }

    /// Aggregate stats for the footer/status bar — total record count and combined audio size.
    var totalDurationMs: Int {
        records.reduce(0) { $0 + ($1.durationMs ?? 0) }
    }

    /// Resets to first page. Call when window opens or after a destructive change.
    func reload() async {
        records = []
        hasMore = true
        selectedIDs = []
        errorMessage = nil
        await loadMore()
        await loadStatistics()
    }

    /// Recomputes the overview statistics over all saved records (background compute, cached).
    /// Idempotent-ish: safe to call on appear and after mutations; skips if already in flight.
    func loadStatistics() async {
        if statisticsLoading { return }
        statisticsLoading = true
        defer { statisticsLoading = false }
        do {
            statistics = try await datasetStore.computeStatistics()
        } catch {
            errorMessage = String(localized: "Failed to compute statistics: \(error.localizedDescription)")
        }
    }

    /// Loads the next page. Idempotent if already loading or no more data.
    func loadMore() async {
        if isLoading || !hasMore { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await datasetStore.page(offset: records.count, limit: pageSize)
            records.append(contentsOf: page)
            if page.count < pageSize {
                hasMore = false
            }
        } catch {
            errorMessage = String(localized: "Failed to load records: \(error.localizedDescription)")
        }
    }

    /// Deletes one record and its audio file.
    func delete(id: String) async {
        await deleteAll(ids: [id])
    }

    /// Bulk delete: removes each record's row from the DB, its audio file, and drops the id
    /// from the selection set.
    func deleteAll(ids: Set<String>) async {
        errorMessage = nil
        for id in ids {
            do {
                let record = try await datasetStore.fetch(id: id)
                try await datasetStore.delete(id: id)
                if let record {
                    try? await audioFileStore.delete(relativePath: record.audioPath)
                }
                records.removeAll { $0.id == id }
                selectedIDs.remove(id)
            } catch {
                errorMessage = String(localized: "Delete failed: \(error.localizedDescription)")
                return
            }
        }
        await loadStatistics()
    }

    /// Overwrites just the edited transcript. raw is preserved.
    func updateEdited(id: String, text: String) async {
        errorMessage = nil
        do {
            try await datasetStore.update(id: id, editedTranscript: text)
            if let i = records.firstIndex(where: { $0.id == id }) {
                let r = records[i]
                records[i] = DatasetRecord(
                    id: r.id,
                    createdAt: r.createdAt,
                    audioPath: r.audioPath,
                    durationMs: r.durationMs,
                    sampleRate: r.sampleRate,
                    channels: r.channels,
                    sourceAppBundleID: r.sourceAppBundleID,
                    sourceAppName: r.sourceAppName,
                    asrProvider: r.asrProvider,
                    asrModel: r.asrModel,
                    asrRuntime: r.asrRuntime,
                    asrConfigJSON: r.asrConfigJSON,
                    rawTranscript: r.rawTranscript,
                    editedTranscript: text,
                    inserted: r.inserted,
                    savedToDataset: r.savedToDataset,
                    language: r.language,
                    metadataJSON: r.metadataJSON,
                    autoEditedTranscript: r.autoEditedTranscript
                )
            }
            lastSaveTick = Date()
        } catch {
            errorMessage = String(localized: "Save failed: \(error.localizedDescription)")
        }
    }

    /// Resolves the absolute on-disk URL for a record's audio file.
    func audioURL(for record: DatasetRecord) async -> URL {
        await audioFileStore.absoluteURL(for: record.audioPath)
    }

    // MARK: - Toolbar-driven actions

    func toggleSidebar() {
        sidebarHidden.toggle()
    }

    func requestPush() {
        requestPushSheet = true
    }

    func requestDeleteSelected() {
        guard !selectedIDs.isEmpty else { return }
        pendingDeleteRequestIDs = selectedIDs
    }

    func requestDelete(id: String) {
        pendingDeleteRequestIDs = [id]
    }
}

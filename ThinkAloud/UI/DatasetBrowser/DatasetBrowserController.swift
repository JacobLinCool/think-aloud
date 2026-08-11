import Foundation
import Observation

/// Drives the dataset browser window: paged list, multi-selection, edit, delete.
@MainActor
@Observable
final class DatasetBrowserController {
    private let datasetStore: DatasetStore
    private let audioFileStore: AudioFileStore
    private let deletionService: DatasetDeletionService

    private(set) var records: [DatasetRecord] = []
    private(set) var totalMatchingRecords: Int = 0
    private(set) var totalDatasetRecords: Int = 0
    private(set) var hasMore: Bool = true
    private(set) var isLoading: Bool = false
    private(set) var isDeleting: Bool = false
    private(set) var loadErrorMessage: String?
    private(set) var actionMessage: String?
    private(set) var actionErrorMessage: String?
    /// One-shot indicator pulses for ~1.5s after a successful edit save. Lets the detail view
    /// show "已儲存 ✓" briefly without us threading a separate callback.
    private(set) var lastSaveTick: Date?

    /// Multi-selection set bound to the SwiftUI List. Detail panel renders only when exactly
    /// one row is selected; bulk delete uses the full set.
    var selectedIDs: Set<String> = []
    var searchText: String = ""

    // Editing is owned by the window controller rather than RecordDetailView so selection,
    // mode switches, and window close all observe the same draft transaction.
    private(set) var editingRecordID: String?
    var editDraft: String = ""
    private(set) var editOriginal: String = ""
    private(set) var isSavingDraft: Bool = false
    private(set) var editErrorMessage: String?
    private(set) var pendingSelectionIDs: Set<String>?
    private var searchGeneration: Int = 0
    private var searchTask: Task<Void, Never>?

    /// HSplitView sidebar visibility, toggled by the toolbar sidebar button.
    var sidebarHidden: Bool = false
    /// Toolbar push button sets true → SwiftUI .sheet displays HFPushView and resets to false.
    var requestPushSheet: Bool = false
    /// Toolbar delete button populates this → SwiftUI .confirmationDialog handles it.
    var pendingDeleteRequestIDs: Set<String> = []

    private let pageSize: Int = 50

    init(
        datasetStore: DatasetStore,
        audioFileStore: AudioFileStore,
        deletionService: DatasetDeletionService
    ) {
        self.datasetStore = datasetStore
        self.audioFileStore = audioFileStore
        self.deletionService = deletionService
    }

    /// Returns the unique selected record, or nil when 0 or >1 are selected.
    var selectedRecord: DatasetRecord? {
        guard selectedIDs.count == 1, let id = selectedIDs.first else { return nil }
        return records.first(where: { $0.id == id })
    }

    var filteredRecords: [DatasetRecord] {
        records
    }

    var hasUnsavedDraft: Bool {
        editingRecordID != nil && editDraft != editOriginal
    }

    var isEditing: Bool { editingRecordID != nil }
    var isAwaitingSelectionDecision: Bool { pendingSelectionIDs != nil }

    /// Aggregate stats for the footer/status bar — total record count and combined audio size.
    var totalDurationMs: Int {
        records.reduce(0) { $0 + ($1.durationMs ?? 0) }
    }

    /// Resets to first page. Call when window opens or after a destructive change.
    func reload() async {
        guard !hasUnsavedDraft else {
            actionErrorMessage = String(localized: "Save or discard transcript changes before refreshing.")
            return
        }
        if isEditing {
            discardDraft()
        }
        actionMessage = nil
        actionErrorMessage = nil
        selectedIDs = []
        loadErrorMessage = nil
        searchTask?.cancel()
        searchGeneration += 1
        await loadPage(
            reset: true,
            query: searchText,
            generation: searchGeneration
        )
    }

    /// Loads the next page. Idempotent if already loading or no more data.
    func loadMore() async {
        if isLoading || !hasMore { return }
        await loadPage(
            reset: false,
            query: searchText,
            generation: searchGeneration
        )
    }

    func scheduleSearch(_ query: String) {
        guard !hasUnsavedDraft else {
            actionErrorMessage = String(localized: "Save or discard transcript changes before searching.")
            return
        }
        if isEditing {
            discardDraft()
        }
        searchText = query
        selectedIDs = []
        searchTask?.cancel()
        searchGeneration += 1
        let generation = searchGeneration
        records = []
        totalMatchingRecords = 0
        hasMore = true
        loadErrorMessage = nil
        isLoading = true
        searchTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            guard let self, generation == self.searchGeneration else { return }
            await self.loadPage(reset: true, query: query, generation: generation)
        }
    }

    /// Immediate variant used by explicit refreshes and deterministic tests.
    func applySearch(_ query: String) async {
        guard !hasUnsavedDraft else { return }
        if isEditing {
            discardDraft()
        }
        searchText = query
        selectedIDs = []
        searchTask?.cancel()
        searchGeneration += 1
        await loadPage(reset: true, query: query, generation: searchGeneration)
    }

    private func loadPage(reset: Bool, query: String, generation: Int) async {
        if reset {
            records = []
            totalMatchingRecords = 0
            hasMore = true
        }
        isLoading = true
        defer {
            if generation == searchGeneration {
                isLoading = false
            }
        }
        do {
            let offset = reset ? 0 : records.count
            let page = try await datasetStore.search(query: query, offset: offset, limit: pageSize)
            let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let datasetCount = normalizedQuery.isEmpty
                ? page.totalCount
                : (reset ? try await datasetStore.count() : totalDatasetRecords)
            guard generation == searchGeneration, !Task.isCancelled else { return }
            if reset {
                records = page.records
                if !hasUnsavedDraft {
                    selectedIDs.formIntersection(Set(page.records.map(\.id)))
                }
            } else {
                records.append(contentsOf: page.records)
            }
            totalMatchingRecords = page.totalCount
            totalDatasetRecords = datasetCount
            loadErrorMessage = nil
            hasMore = page.hasMore
        } catch {
            guard generation == searchGeneration, !Task.isCancelled else { return }
            NSLog("ThinkAloud: dataset browser load failed: \(error)")
            loadErrorMessage = String(
                localized: "ThinkAloud couldn’t load the dataset. Retry; if the problem continues, check Dataset settings and available storage."
            )
        }
    }

    /// Deletes one record and its audio file.
    func delete(id: String) async {
        await deleteAll(ids: [id])
    }

    /// Bulk delete: removes each record's row from the DB, its audio file, and drops the id
    /// from the selection set.
    func deleteAll(ids: Set<String>) async {
        guard !isDeleting, !ids.isEmpty else { return }
        isDeleting = true
        defer { isDeleting = false }
        actionMessage = nil
        actionErrorMessage = nil
        do {
            let report = try await deletionService.delete(ids: ids)
            let deletedIDs = Set(report.deletedRecordIDs)
            let visibleDeletedCount = records.lazy.filter { deletedIDs.contains($0.id) }.count
            records.removeAll { deletedIDs.contains($0.id) }
            totalMatchingRecords = max(0, totalMatchingRecords - visibleDeletedCount)
            totalDatasetRecords = max(0, totalDatasetRecords - report.deletedCount)
            selectedIDs.subtract(deletedIDs)
            if report.hasWarnings {
                actionErrorMessage = String(
                    localized: "Deleted \(report.deletedCount) records, but \(report.missingAudioPaths.count) audio files were already missing."
                )
            } else {
                actionMessage = String(localized: "Deleted \(report.deletedCount) records.")
            }
        } catch {
            NSLog("ThinkAloud: dataset browser deletion failed: \(error)")
            if case DatasetDeletionService.DeletionError.purgeFailed = error {
                searchTask?.cancel()
                searchGeneration += 1
                await loadPage(
                    reset: true,
                    query: searchText,
                    generation: searchGeneration
                )
            }
            if let deletionError = error as? DatasetDeletionService.DeletionError {
                // These typed errors carry the exact recovery state/path users must preserve.
                actionErrorMessage = deletionError.localizedDescription
            } else {
                actionErrorMessage = String(
                    localized: "ThinkAloud couldn’t delete the selected records. Refresh the dataset and try again."
                )
            }
        }
    }

    /// Overwrites just the edited transcript. raw is preserved.
    @discardableResult
    func updateEdited(id: String, text: String) async -> Bool {
        editErrorMessage = nil
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
                    language: r.language,
                    metadataJSON: r.metadataJSON,
                    autoEditedTranscript: r.autoEditedTranscript,
                    llmEditedTranscript: r.llmEditedTranscript
                )
            }
            lastSaveTick = Date()
            return true
        } catch {
            NSLog("ThinkAloud: transcript edit save failed: \(error)")
            editErrorMessage = String(
                localized: "ThinkAloud couldn’t save the transcript edit. Refresh the record and try again."
            )
            return false
        }
    }

    // MARK: - Draft transaction

    func beginEditing(_ record: DatasetRecord) {
        editingRecordID = record.id
        editOriginal = record.editedTranscript
        editDraft = record.editedTranscript
        editErrorMessage = nil
    }

    func discardDraft() {
        editDraft = editOriginal
        editingRecordID = nil
        editOriginal = ""
        editErrorMessage = nil
    }

    @discardableResult
    func saveDraft() async -> Bool {
        guard let id = editingRecordID else { return true }
        guard hasUnsavedDraft else {
            discardDraft()
            return true
        }
        isSavingDraft = true
        defer { isSavingDraft = false }
        let saved = await updateEdited(id: id, text: editDraft)
        if saved {
            editOriginal = editDraft
            editingRecordID = nil
            editOriginal = ""
        }
        return saved
    }

    /// List selection changes are transactional while a dirty editor is open. The view presents
    /// the decision dialog and calls one of the resolution methods below.
    func requestSelection(_ ids: Set<String>) {
        if isEditing, !hasUnsavedDraft, !ids.contains(editingRecordID ?? "") {
            discardDraft()
        }
        guard hasUnsavedDraft, ids != selectedIDs else {
            selectedIDs = ids
            return
        }
        pendingSelectionIDs = ids
    }

    func saveAndApplyPendingSelection(_ selection: Set<String>) async {
        if await saveDraft() {
            self.pendingSelectionIDs = nil
            selectedIDs = selection
        }
    }

    func discardAndApplyPendingSelection(_ selection: Set<String>) {
        discardDraft()
        self.pendingSelectionIDs = nil
        selectedIDs = selection
    }

    func cancelPendingSelection() {
        pendingSelectionIDs = nil
    }

    /// Resolves the absolute on-disk URL for a record's audio file.
    func audioURL(for record: DatasetRecord) async throws -> URL {
        guard try await audioFileStore.fileExists(relativePath: record.audioPath) else {
            throw AudioFileStore.StoreError.sourceMissing(record.audioPath)
        }
        return try await audioFileStore.validatedAbsoluteURL(for: record.audioPath)
    }

    // MARK: - Toolbar-driven actions

    func toggleSidebar() {
        sidebarHidden.toggle()
    }

    func requestPush() {
        requestPushSheet = true
    }

    func requestDeleteSelected() {
        guard !isDeleting, !selectedIDs.isEmpty else { return }
        pendingDeleteRequestIDs = selectedIDs
    }

    func requestDelete(id: String) {
        guard !isDeleting else { return }
        pendingDeleteRequestIDs = [id]
    }
}

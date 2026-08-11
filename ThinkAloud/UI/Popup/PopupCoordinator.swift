import AppKit
import Foundation
import Observation

struct PendingDatasetSaveRecoveryState: Equatable, Sendable {
    private(set) var manifest: DatasetSaveRecoveryManifest?
    private(set) var audioWasPersisted: Bool

    init(
        manifest: DatasetSaveRecoveryManifest? = nil,
        audioWasPersisted: Bool = false
    ) {
        self.manifest = manifest
        self.audioWasPersisted = audioWasPersisted
    }

    mutating func retain(_ manifest: DatasetSaveRecoveryManifest) {
        self.manifest = manifest
        audioWasPersisted = false
    }

    mutating func markAudioPersisted() {
        precondition(manifest != nil, "A durable manifest must precede audio persistence")
        audioWasPersisted = true
    }

    mutating func clear() {
        manifest = nil
        audioWasPersisted = false
    }

    /// Used by Close as well as save-failure rollback. State is cleared only after the service
    /// proves that the exact audio is gone or belongs to a committed database row.
    mutating func abandon(
        using service: any DatasetSaveRecoveryManaging
    ) async throws -> DatasetSaveRecoveryResolution? {
        guard let manifest else { return nil }
        let resolution = try await service.discard(manifest)
        if resolution.state == .discarded, resolution.hasPendingManifestCleanup {
            // The audio is gone, but Retry Save must reuse this durable identity: preparing a new
            // manifest would correctly collide with the one that startup still needs to reconcile.
            audioWasPersisted = false
        } else {
            clear()
        }
        return resolution
    }
}

@MainActor
@Observable
final class PopupCoordinator {
    private let permissions: PermissionsService
    private let modelManager: ModelManager
    private let llmManager: LLMManager
    private let recorder: AudioRecorder
    private let insertion: any TextInserting
    private let datasetStore: any DatasetRecordWriting
    private let historyStore: any DictationHistoryWriting
    private let audioFileStore: AudioFileStore
    private let datasetSaveRecovery: any DatasetSaveRecoveryManaging

    let viewModel = PopupViewModel()
    private let windowController: any PopupWindowPresenting

    private var elapsedTimerTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var recordingStartedAt: Date?
    private var lastResult: ASRResult?
    private var lastRecording: RecordingResult?
    /// The Auto-Post-Edit output captured at the end of the ASR stream, before the user has had a
    /// chance to manually edit. Persisted as `autoEditedTranscript` so stats can separate automatic
    /// formatting from human corrections. Snapshotted in `performInsert` alongside the other state.
    private var lastAutoEditedTranscript: String?
    /// The AI Refine output captured at the end of the polishing stage (before manual edits). nil when
    /// no LLM stage ran. Persisted as `llmEditedTranscript`.
    private var lastLLMEditedTranscript: String?
    /// The in-flight refine, so ⌥Space-insert / cancel can abort it and insert what's shown.
    private var polishingTask: Task<Void, Never>?
    private var currentSessionID: String?
    private var activeSessionSnapshot: DictationSession?
    private var datasetCommittedForActiveSession = false
    private var pendingHistorySession: DictationSession?
    private var pendingDatasetSave: PendingDatasetSave?
    /// Bumped on every new invocation / cancel. The polishing task captures the value at start and
    /// stops writing to the shared view model if it changes — so a stale refine from a previous
    /// dictation can never clobber a new session's text or its saved `llmEditedTranscript`.
    private var generation: Int = 0

    private struct PendingDatasetSave {
        let recordID: String
        let editedText: String
        let rawText: String
        let autoEditedText: String
        let llmEditedText: String?
        let focus: FocusContext?
        let recording: RecordingResult
        let result: ASRResult
        let inserted: Bool
        let insertionMessage: String
        var recovery = PendingDatasetSaveRecoveryState()
    }

    init(
        permissions: PermissionsService,
        modelManager: ModelManager,
        llmManager: LLMManager,
        recorder: AudioRecorder,
        insertion: any TextInserting,
        datasetStore: any DatasetRecordWriting,
        historyStore: any DictationHistoryWriting,
        audioFileStore: AudioFileStore,
        datasetSaveRecovery: any DatasetSaveRecoveryManaging,
        windowController: any PopupWindowPresenting = PopupWindowController()
    ) {
        self.permissions = permissions
        self.modelManager = modelManager
        self.llmManager = llmManager
        self.recorder = recorder
        self.insertion = insertion
        self.datasetStore = datasetStore
        self.historyStore = historyStore
        self.audioFileStore = audioFileStore
        self.datasetSaveRecovery = datasetSaveRecovery
        self.windowController = windowController
    }

    func invoke() {
        NSLog("ThinkAloud: invoke() phase=\(viewModel.phase)")
        // Review/polishing are handled by the sibling insert hotkey. A dataset-save error is also
        // intentionally non-startable because `pendingDatasetSave` must survive until Retry Save.
        guard viewModel.phase.allowsNewRecordingInvocation else { return }
        modelManager.recordActivity()
        viewModel.reset()
        // New session: invalidate (and stop) any refine still running from a previous dictation so it
        // can't write into this session's transcript.
        generation += 1
        polishingTask?.cancel()
        polishingTask = nil
        currentSessionID = nil
        activeSessionSnapshot = nil
        datasetCommittedForActiveSession = false
        pendingHistorySession = nil
        pendingDatasetSave = nil
        lastAutoEditedTranscript = nil
        lastLLMEditedTranscript = nil

        let focus = FocusContext.capture()
        viewModel.focusContext = focus

        windowController.show(viewModel: viewModel, coordinator: self, modelManager: modelManager)
        NSLog("ThinkAloud: popup shown, focus=\(focus.appName ?? "?")")

        startupTask = Task { @MainActor in
            await self.startRecording()
            self.startupTask = nil
        }
        modelManager.preloadNow()
        // Warm up the refine model during recording when this app will use it, so the .polishing stage
        // doesn't pay a multi-GB cold load.
        if let profile = llmManager.effectiveConfig(for: focus), profile.backend == .mlx {
            llmManager.preloadNow()
        }
    }

    func stopAndTranscribe() {
        // Only meaningful from .recording. Guard so spurious calls (e.g. duplicated hotkey) don't
        // try to stop a recorder that isn't running.
        guard case .recording = viewModel.phase else { return }
        transcriptionTask = Task { @MainActor in
            await self.finishRecordingAndTranscribe()
            self.transcriptionTask = nil
        }
    }

    func cancel() {
        // Stop the task that can create a recording before awaiting the recorder actor. Otherwise a
        // permission prompt/start race can begin a hidden recording after the popup has closed.
        startupTask?.cancel()
        startupTask = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
        elapsedTimerTask?.cancel()
        elapsedTimerTask = nil
        generation += 1
        polishingTask?.cancel()
        polishingTask = nil

        Task { @MainActor in
            await self.recorder.cancel()
            if var pending = self.pendingDatasetSave {
                do {
                    let resolution = try await pending.recovery.abandon(
                        using: self.datasetSaveRecovery
                    )
                    self.pendingDatasetSave = pending
                    if resolution?.hasPendingManifestCleanup == true {
                        NSLog(
                            "ThinkAloud: pending-save audio is safe; durable manifest cleanup "
                                + "will retry at startup"
                        )
                    }
                } catch {
                    // Keep both the pending snapshot and popup open. Close is itself a recovery
                    // action here; claiming completion would strand private audio without an
                    // in-memory retry path.
                    self.pendingDatasetSave = pending
                    NSLog("ThinkAloud: Close could not resolve pending dataset audio: \(error)")
                    self.viewModel.phase = .error(
                        .datasetSave(
                            inserted: pending.inserted,
                            cleanupFailed: true,
                            insertionMessage: pending.insertionMessage
                        )
                    )
                    return
                }
            }
            // Supersede + stop any in-flight refine (generation guard makes its late writes no-ops).
            self.recordingStartedAt = nil
            self.lastRecording = nil
            self.lastResult = nil
            self.lastAutoEditedTranscript = nil
            self.lastLLMEditedTranscript = nil
            self.currentSessionID = nil
            self.activeSessionSnapshot = nil
            self.datasetCommittedForActiveSession = false
            self.pendingHistorySession = nil
            self.pendingDatasetSave = nil
            self.viewModel.reset()
            self.windowController.close()
        }
    }

    func insertOnly() {
        Task { @MainActor in
            await self.cancelPolishingIfNeeded()
            guard self.canInsertCurrentTranscript else { return }
            await self.performInsert(save: false)
        }
    }

    func insertAndSave() {
        Task { @MainActor in
            await self.cancelPolishingIfNeeded()
            guard self.canSaveCurrentTranscript else { return }
            await self.performInsert(save: true)
        }
    }

    func retry(after failure: PopupFailure) {
        switch failure.kind {
        case .historySave, .datasetSave, .historyAndDatasetSave:
            guard pendingHistorySession != nil || pendingDatasetSave != nil else { return }
            Task { @MainActor in
                self.viewModel.savingIncludesDataset = self.pendingDatasetSave != nil
                self.viewModel.phase = .savingDataset
                await self.retryPendingPersistence()
            }
        case .microphonePermission, .recording, .denoise, .audioProcessing, .transcription,
             .noSpeech, .canonicalData:
            invoke()
        }
    }

    /// If the AI Refine stage is mid-flight, abort it and let it finalize (it settles `editedTranscript`
    /// to the partial rewrite and moves to `.review`) so the insert that follows uses what's on screen.
    private func cancelPolishingIfNeeded() async {
        guard case .polishing = viewModel.phase else { return }
        polishingTask?.cancel()
        await polishingTask?.value
        polishingTask = nil
    }

    var settingsOpener: ((SettingsCategory?) -> Void)?
    /// Fired after a usage session is committed, so Insights and achievements can refresh.
    var onSessionSaved: (() -> Void)?

    func openSettings(_ category: SettingsCategory? = nil) {
        settingsOpener?(category)
    }

    var canInsertCurrentTranscript: Bool {
        guard case .review = viewModel.phase else { return false }
        if viewModel.isStreaming { return false }
        if viewModel.editedTranscript.isEmpty { return false }
        return activeSessionSnapshot != nil
            || (lastRecording != nil
                && lastResult != nil
                && lastAutoEditedTranscript != nil)
    }

    var isDeliveryRetry: Bool { activeSessionSnapshot != nil }

    var canSaveCurrentTranscript: Bool {
        let actionablePhase: Bool
        switch viewModel.phase {
        case .polishing, .review: actionablePhase = true
        default: actionablePhase = false
        }
        return actionablePhase
            && !viewModel.isStreaming
            && !viewModel.editedTranscript.isEmpty
            && lastRecording != nil
            && lastResult != nil
            && lastAutoEditedTranscript != nil
    }

    // MARK: - Internals

    private func startRecording() async {
        NSLog("ThinkAloud: startRecording entry, mic=\(permissions.microphoneStatus)")
        guard !Task.isCancelled else { return }
        guard permissions.microphoneStatus != .denied else {
            viewModel.phase = .error(.microphonePermission)
            return
        }
        if permissions.microphoneStatus == .notDetermined {
            NSLog("ThinkAloud: requesting microphone permission")
            await permissions.requestMicrophone()
            NSLog("ThinkAloud: mic permission now \(permissions.microphoneStatus)")
        }
        guard !Task.isCancelled else { return }
        guard permissions.microphoneStatus == .granted else {
            viewModel.phase = .error(.microphonePermission)
            return
        }

        do {
            try Task.checkCancellation()
            try await recorder.start()
            try Task.checkCancellation()
        } catch is CancellationError {
            await recorder.cancel()
            return
        } catch {
            NSLog("ThinkAloud: recorder start failed: \(error)")
            viewModel.phase = .error(.recording(error))
            return
        }
        // Anchor elapsed time on the MainActor so the display loop never has to hop into the
        // recorder actor (busy ingesting audio buffers) just to read the clock.
        recordingStartedAt = Date()
        NSLog("ThinkAloud: recording started")
        viewModel.phase = .recording
        startElapsedTimer()
    }

    /// Single ~15Hz MainActor loop that drives both the elapsed clock and level meter. Elapsed is
    /// computed locally; the level is pulled from the recorder once per tick.
    private func startElapsedTimer() {
        elapsedTimerTask?.cancel()
        let recorder = recorder
        let start = recordingStartedAt ?? Date()
        elapsedTimerTask = Task { @MainActor [weak self] in
            var lastActivitySecond = -1
            while !Task.isCancelled {
                let elapsed = Date().timeIntervalSince(start)
                let level = await recorder.currentLevel
                guard let self else { return }
                self.viewModel.elapsedSeconds = elapsed
                self.viewModel.levelRMS = level.rms
                self.viewModel.levelPeak = level.peak
                // Tick recordActivity on each whole-second crossing so the idle-eviction timer in
                // ModelManager never tries to unload weights while we're actively recording.
                let whole = Int(elapsed)
                if whole != lastActivitySecond {
                    lastActivitySecond = whole
                    self.modelManager.recordActivity()
                }
                try? await Task.sleep(nanoseconds: 66_000_000)
            }
        }
    }

    private func finishRecordingAndTranscribe() async {
        let sessionGeneration = generation
        elapsedTimerTask?.cancel()
        elapsedTimerTask = nil

        let recordingResult: RecordingResult
        do {
            recordingResult = try await recorder.stop()
        } catch {
            viewModel.phase = .error(.recording(error))
            return
        }
        lastRecording = recordingResult
        currentSessionID = DictationSession.generateID()
        guard !Task.isCancelled, generation == sessionGeneration else { return }

        viewModel.phase = .transcribing

        // Streaming transcription: switch to .review as soon as the first token arrives so
        // the user sees tokens appear in the editor live.
        let runtime = modelManager.runtime
        let postEdit = modelManager.postEdit
        // Compile the user dictionary once here, not per streaming token.
        let compiledDict = CompiledDictionary(postEdit.dictionary)
        viewModel.rawTranscript = ""
        viewModel.editedTranscript = ""
        viewModel.isStreaming = true
        var accumulated = ""
        var receivedAny = false
        var finalResult: ASRResult?

        // Auto Pre-Edit: optionally denoise (DeepFilterNet, 48 kHz), then resample to the 16 kHz
        // the ASR runtimes require. Dataset save still uses the original `recordingResult` (48 kHz raw).
        var asrSamples = recordingResult.samples
        var asrSampleRate = recordingResult.sampleRate
        let shouldDenoise: Bool
        switch modelManager.preEdit.denoise {
        case .off:
            shouldDenoise = false
        case .on:
            shouldDenoise = true
        case .auto:
            // Inspect the raw 48 kHz clip; only denoise when it looks noisy enough to benefit.
            let decision = DenoiseHeuristic.analyze(asrSamples, sampleRate: asrSampleRate)
            NSLog("ThinkAloud: Auto denoise \(decision.logLine)")
            shouldDenoise = decision.shouldDenoise
        }
        if shouldDenoise {
            do {
                asrSamples = try await modelManager.denoise(asrSamples)
            } catch {
                switch modelManager.preEdit.denoise {
                case .on:
                    viewModel.isStreaming = false
                    viewModel.phase = .error(.denoise(error))
                    return
                case .auto:
                    NSLog("ThinkAloud: automatic denoise failed; explicitly using original audio: \(error)")
                    viewModel.notice = PopupNotice(
                        kind: .denoiseBypassed,
                        message: String(
                            localized: "Automatic audio cleanup failed, so this recording was transcribed without cleanup. Review Audio cleanup settings if this continues."
                        )
                    )
                case .off:
                    break
                }
            }
            guard !Task.isCancelled, generation == sessionGeneration else { return }
        }
        if asrSampleRate != 16000 {
            do {
                asrSamples = try AudioRecorder.resample(asrSamples, from: asrSampleRate, to: 16000)
                asrSampleRate = 16000
            } catch {
                // Never feed source-rate audio to the 16 kHz-only runtimes — abort instead.
                viewModel.isStreaming = false
                viewModel.phase = .error(.audioProcessing(error))
                return
            }
        }

        do {
            for try await event in runtime.transcribeStream(samples: asrSamples, sampleRate: asrSampleRate, options: ASROptions(language: nil)) {
                guard !Task.isCancelled, generation == sessionGeneration else { return }
                switch event {
                case .token(let token):
                    accumulated += token
                    if !receivedAny {
                        receivedAny = true
                        viewModel.phase = .review
                    }
                    viewModel.rawTranscript = accumulated
                    viewModel.editedTranscript = TranscriptPostProcessor.apply(postEdit, dictionary: compiledDict, to: accumulated)
                case .result(let r):
                    finalResult = r
                    viewModel.rawTranscript = r.text
                    viewModel.editedTranscript = TranscriptPostProcessor.apply(postEdit, dictionary: compiledDict, to: r.text)
                    viewModel.transcribeDurationMs = r.durationMs
                    viewModel.asrModelID = r.modelID
                    viewModel.phase = .review
                }
            }
            guard !Task.isCancelled, generation == sessionGeneration else { return }
            viewModel.isStreaming = false
            modelManager.recordActivity()
            let terminalTextIsUsable = !viewModel.rawTranscript
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
                && !viewModel.editedTranscript
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            if (!receivedAny && finalResult == nil) || (finalResult != nil && !terminalTextIsUsable) {
                viewModel.phase = .error(.noSpeech)
            } else if finalResult == nil {
                viewModel.phase = .error(.canonicalData)
            } else if let finalResult {
                acceptTerminalResult(
                    recording: recordingResult,
                    result: finalResult,
                    rawTranscript: viewModel.rawTranscript,
                    autoEditedTranscript: viewModel.editedTranscript
                )
                await runPolishingStageIfEnabled()
            }
        } catch {
            guard !Task.isCancelled, generation == sessionGeneration else { return }
            viewModel.isStreaming = false
            modelManager.recordActivity()
            viewModel.phase = .error(.transcription(error))
        }
    }

    /// The AI Refine (LLM) stage: a ONE-SHOT async rewrite of the deterministic transcript, keyed on
    /// the source app's per-app profile. Runs only when a profile is enabled and its backend is ready.
    /// Streams the rewrite into `editedTranscript` live; fails OPEN — any error/refusal/empty output
    /// keeps the deterministic Auto-Post-Edit text as the floor. Cancellable via `cancelPolishingIfNeeded`.
    private func runPolishingStageIfEnabled() async {
        guard let profile = llmManager.effectiveConfig(for: viewModel.focusContext),
              llmManager.isRefineReady(for: viewModel.focusContext) else { return }
        let base = viewModel.editedTranscript
        guard !base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let gen = generation
        viewModel.phase = .polishing
        let stream = llmManager.refine(base, using: profile)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            var accumulated = ""
            var refinementFailed = false
            do {
                for try await chunk in stream {
                    accumulated += chunk
                    // A newer dictation superseded this refine — stop touching the shared view model.
                    guard self.generation == gen else { return }
                    self.viewModel.editedTranscript = LLMText.stripReasoning(accumulated)
                }
            } catch {
                // A clean cancel (⌥Space-insert) keeps the partial; a real error fails open to base.
                if !Task.isCancelled { refinementFailed = true }
                NSLog("ThinkAloud: AI Refine error: \(error)")
            }
            guard self.generation == gen else { return }
            let cleaned = LLMText.stripReasoning(accumulated).trimmingCharacters(in: .whitespacesAndNewlines)
            if refinementFailed || cleaned.isEmpty {
                self.viewModel.editedTranscript = base
                self.lastLLMEditedTranscript = nil
                if refinementFailed {
                    self.setRefineFailureNotice(
                        String(localized: "AI refinement failed. The unrefined transcript is shown; verify the selected refinement engine and try again.")
                    )
                } else if !Task.isCancelled {
                    self.setRefineFailureNotice(
                        String(localized: "AI refinement returned no usable text. The unrefined transcript is shown.")
                    )
                }
            } else {
                self.viewModel.editedTranscript = cleaned
                self.lastLLMEditedTranscript = cleaned
            }
            if case .polishing = self.viewModel.phase { self.viewModel.phase = .review }
            self.modelManager.recordActivity()
        }
        polishingTask = task
        await task.value
        polishingTask = nil
    }

    /// Preserve an earlier Auto-denoise bypass disclosure if AI refinement also fails. The popup
    /// has one notice slot, so replacing it outright would hide the fact that raw audio was used.
    private func setRefineFailureNotice(_ message: String) {
        let combined: String
        if let existing = viewModel.notice, existing.kind == .denoiseBypassed {
            combined = "\(existing.message) \(message)"
        } else {
            combined = message
        }
        viewModel.notice = PopupNotice(kind: .refineFailed, message: combined)
    }

    /// Installs the complete terminal ASR result as the only deliverable state. The streaming path
    /// calls this after receiving `.result`; non-UI integration tests call the same boundary with a
    /// deterministic recording. Token-only streams never reach it and therefore cannot be saved.
    func acceptTerminalResult(
        recording: RecordingResult,
        result: ASRResult,
        rawTranscript: String,
        autoEditedTranscript: String
    ) {
        precondition(!rawTranscript.isEmpty, "A terminal ASR result must contain raw text")
        precondition(!autoEditedTranscript.isEmpty, "Auto Post-Edit text must be complete")
        currentSessionID = currentSessionID ?? DictationSession.generateID()
        lastRecording = recording
        lastResult = result
        lastAutoEditedTranscript = autoEditedTranscript
        lastLLMEditedTranscript = nil
        viewModel.rawTranscript = rawTranscript
        viewModel.editedTranscript = autoEditedTranscript
        viewModel.transcribeDurationMs = result.durationMs
        viewModel.asrModelID = result.modelID
        viewModel.isStreaming = false
        viewModel.phase = .review
    }

    /// Performs exactly one user-requested delivery attempt, then persists its immutable snapshot.
    /// Persistence retries use `retryPendingPersistence()` and never enter this method.
    func performInsert(save: Bool) async {
        let focus = viewModel.focusContext
        let initialCanonicalData: (
            sessionID: String,
            recording: RecordingResult,
            result: ASRResult,
            autoEditedText: String
        )?
        if activeSessionSnapshot == nil {
            guard let sessionID = currentSessionID,
                  let recording = lastRecording,
                  let result = lastResult,
                  let autoEditedText = lastAutoEditedTranscript else {
                NSLog(
                    "ThinkAloud: canonical session invariant failed before insertion "
                        + "(sessionID=\(currentSessionID != nil), recording=\(lastRecording != nil), "
                        + "result=\(lastResult != nil), autoEdited=\(lastAutoEditedTranscript != nil))"
                )
                viewModel.phase = .error(.canonicalData)
                return
            }
            initialCanonicalData = (sessionID, recording, result, autoEditedText)
        } else {
            // A delivery retry reuses the immutable first-attempt snapshot and its stable ID. It may
            // update only the delivery outcome; text, action, and recording metadata remain locked.
            initialCanonicalData = nil
        }

        let textToInsert = activeSessionSnapshot?.finalTranscript ?? viewModel.editedTranscript
        // Close popup FIRST — otherwise the popup window holds keyboard focus and our
        // simulated Cmd+V lands in the popup's own TextEditor instead of the source app.
        viewModel.savingIncludesDataset = save
        viewModel.phase = save ? .savingDataset : .inserting
        windowController.close()

        // Give the OS a brief moment to transfer keyboard focus back to the source app
        // after our nonactivating panel goes away.
        try? await Task.sleep(nanoseconds: 120_000_000)

        let outcome = await insertion.insert(textToInsert, into: focus)
        NSLog("ThinkAloud: insertion outcome inserted=\(outcome.inserted) clipboard=\(outcome.copiedToClipboard) msg=\(outcome.message)")
        if outcome.inserted {
            // Non-inserted outcomes reopen the popup below, so they remain visible even when
            // notification authorization is denied.
            InsertionFeedback.notifyIfNeeded(outcome: outcome)
        } else {
            viewModel.lastInsertionMessage = outcome.message
        }
        // Persistence retries read this message but never repeat the delivery attempt.
        viewModel.lastInsertionMessage = outcome.message

        let deliveryOutcome: DictationDeliveryOutcome
        if outcome.inserted {
            deliveryOutcome = .inserted
        } else if outcome.copiedToClipboard {
            deliveryOutcome = .clipboard
        } else {
            deliveryOutcome = .failed
        }

        let session: DictationSession
        if var existing = activeSessionSnapshot {
            existing.deliveryOutcome = deliveryOutcome
            session = existing
        } else if let canonical = initialCanonicalData {
            session = DictationSession(
                id: canonical.sessionID,
                createdAt: ISO8601DateFormatter().string(from: canonical.recording.startedAt),
                durationMs: canonical.recording.durationMs,
                sampleRate: canonical.recording.sampleRate,
                channels: canonical.recording.channels,
                sourceAppBundleID: focus?.appBundleID,
                sourceAppName: focus?.appName,
                asrProvider: "mlx-audio-swift",
                asrModel: canonical.result.modelID,
                asrRuntime: canonical.result.runtimeID,
                language: canonical.result.language,
                transcriptionDurationMs: canonical.result.durationMs,
                rawTranscript: viewModel.rawTranscript,
                autoEditedTranscript: canonical.autoEditedText,
                llmEditedTranscript: lastLLMEditedTranscript,
                finalTranscript: viewModel.editedTranscript,
                action: save ? .insertAndSave : .insert,
                deliveryOutcome: deliveryOutcome
            )
        } else {
            preconditionFailure("Canonical session data disappeared during insertion")
        }
        activeSessionSnapshot = session
        pendingHistorySession = session

        if save, pendingDatasetSave == nil, !datasetCommittedForActiveSession,
           let canonical = initialCanonicalData {
            let recording = canonical.recording
            let result = canonical.result
            viewModel.insertionSucceededForDatasetSave = outcome.inserted
            pendingDatasetSave = PendingDatasetSave(
                recordID: DatasetRecord.generateID(date: recording.startedAt),
                editedText: session.finalTranscript,
                rawText: session.rawTranscript,
                autoEditedText: session.autoEditedTranscript,
                llmEditedText: session.llmEditedTranscript,
                focus: focus,
                recording: recording,
                result: result,
                inserted: outcome.inserted,
                insertionMessage: outcome.message
            )
        }

        let historySaved = await savePendingHistorySession()
        let datasetNeeded = pendingDatasetSave != nil
        let datasetSaved = datasetNeeded ? await savePendingDatasetRecord() : true
        let datasetFailure: PopupFailure? = {
            guard !datasetSaved, case .error(let failure) = viewModel.phase else { return nil }
            return failure
        }()

        if datasetSaved, datasetNeeded {
            finishDatasetSave()
        } else if !save {
            releaseHeavyRecordingState()
        }

        guard historySaved, datasetSaved else {
            viewModel.rawTranscript = session.rawTranscript
            viewModel.editedTranscript = session.finalTranscript
            viewModel.focusContext = focus
            if !historySaved, let datasetFailure {
                viewModel.phase = .error(.historyAndDatasetSave(datasetFailure: datasetFailure))
            } else if !historySaved {
                viewModel.phase = .error(
                    .historySave(inserted: outcome.inserted, insertionMessage: outcome.message)
                )
            }
            windowController.show(viewModel: viewModel, coordinator: self, modelManager: modelManager)
            return
        }

        finishCompletedPersistence(
            inserted: outcome.inserted,
            insertionMessage: outcome.message,
            datasetWasSaved: session.action == .insertAndSave
        )
    }

    private func savePendingHistorySession() async -> Bool {
        guard let pendingHistorySession else { return true }
        do {
            try await historyStore.save(pendingHistorySession)
            self.pendingHistorySession = nil
            onSessionSaved?()
            return true
        } catch {
            NSLog("ThinkAloud: dictation history save failed: \(error)")
            return false
        }
    }

    /// Retries only missing persistence branches. The insertion call is intentionally absent.
    func retryPendingPersistence() async {
        let historySaved = await savePendingHistorySession()
        let datasetNeeded = pendingDatasetSave != nil
        let datasetSaved = datasetNeeded ? await savePendingDatasetRecord() : true
        let datasetFailure: PopupFailure? = {
            guard !datasetSaved, case .error(let failure) = viewModel.phase else { return nil }
            return failure
        }()

        if datasetSaved, datasetNeeded {
            finishDatasetSave()
        }

        guard historySaved, datasetSaved else {
            if !historySaved, let datasetFailure {
                viewModel.phase = .error(.historyAndDatasetSave(datasetFailure: datasetFailure))
            } else if !historySaved {
                let inserted = activeSessionSnapshot?.deliveryOutcome == .inserted
                viewModel.phase = .error(
                    .historySave(
                        inserted: inserted,
                        insertionMessage: viewModel.lastInsertionMessage
                    )
                )
            }
            return
        }

        let inserted = activeSessionSnapshot?.deliveryOutcome == .inserted
        finishCompletedPersistence(
            inserted: inserted,
            insertionMessage: viewModel.lastInsertionMessage,
            datasetWasSaved: datasetCommittedForActiveSession
        )
    }

    private func finishCompletedPersistence(
        inserted: Bool,
        insertionMessage: String,
        datasetWasSaved: Bool
    ) {
        if inserted {
            clearActiveSessionState()
            windowController.close()
            viewModel.reset()
        } else {
            presentInsertionRecovery(
                message: insertionMessage,
                datasetWasSaved: datasetWasSaved
            )
        }
    }

    private func releaseHeavyRecordingState() {
        lastRecording = nil
        lastResult = nil
        lastAutoEditedTranscript = nil
        lastLLMEditedTranscript = nil
    }

    private func clearActiveSessionState() {
        releaseHeavyRecordingState()
        currentSessionID = nil
        activeSessionSnapshot = nil
        datasetCommittedForActiveSession = false
        pendingHistorySession = nil
        pendingDatasetSave = nil
    }

    private func presentInsertionRecovery(message: String, datasetWasSaved: Bool) {
        viewModel.lastInsertionMessage = datasetWasSaved
            ? String(localized: "Saved to Dataset, but the transcript wasn’t inserted. \(message)")
            : message
        viewModel.phase = .review
        windowController.show(viewModel: viewModel, coordinator: self, modelManager: modelManager)
    }

    private func savePendingDatasetRecord() async -> Bool {
        guard var pending = pendingDatasetSave else { return false }
        do {
            let recording = pending.recording
            let result = pending.result

            if pending.recovery.manifest == nil {
                let manifest = try await datasetSaveRecovery.prepare(
                    recordID: pending.recordID,
                    recordingStartedAt: recording.startedAt
                )
                pending.recovery.retain(manifest)
                // Publish the durable identity before the next suspension point. A failed persist,
                // Close, or retry must all operate on this exact path.
                pendingDatasetSave = pending
            }
            guard let manifest = pending.recovery.manifest else {
                preconditionFailure("Dataset save recovery manifest was not retained")
            }

            let persistedAudioStillExists: Bool
            if pending.recovery.audioWasPersisted {
                persistedAudioStillExists = try await audioFileStore.fileExists(
                    relativePath: manifest.audioPath
                )
            } else {
                persistedAudioStillExists = false
            }
            if !persistedAudioStillExists {
                let stored = try await audioFileStore.persist(
                    samples: recording.samples,
                    sampleRate: Double(recording.sampleRate),
                    recordID: pending.recordID,
                    at: recording.startedAt
                )
                guard stored.relativePath == manifest.audioPath else {
                    throw AudioFileStore.StoreError.invalidRelativePath(stored.relativePath)
                }
                pending.recovery.markAudioPersisted()
                pendingDatasetSave = pending
            }

            let record = DatasetRecord(
                id: pending.recordID,
                createdAt: ISO8601DateFormatter().string(from: recording.startedAt),
                audioPath: manifest.audioPath,
                durationMs: recording.durationMs,
                sampleRate: recording.sampleRate,
                channels: recording.channels,
                sourceAppBundleID: pending.focus?.appBundleID,
                sourceAppName: pending.focus?.appName,
                asrProvider: "mlx-audio-swift",
                asrModel: result.modelID,
                asrRuntime: result.runtimeID,
                asrConfigJSON: nil,
                rawTranscript: pending.rawText,
                editedTranscript: pending.editedText,
                inserted: pending.inserted,
                language: result.language,
                metadataJSON: nil,
                autoEditedTranscript: pending.autoEditedText,
                llmEditedTranscript: pending.llmEditedText
            )
            try await datasetStore.save(record)

            // The row and audio are committed even if only the manifest cleanup fails. Never turn
            // that safe state into a false save error (which would invite duplicate retries).
            do {
                let resolution = try await datasetSaveRecovery.complete(manifest)
                pending.recovery.clear()
                pendingDatasetSave = pending
                if resolution.hasPendingManifestCleanup {
                    NSLog(
                        "ThinkAloud: dataset save committed; durable manifest cleanup "
                            + "will retry at startup"
                    )
                }
            } catch {
                NSLog(
                    "ThinkAloud: dataset save committed; recovery manifest remains for startup: "
                        + "\(error)"
                )
            }
            return true
        } catch {
            NSLog("ThinkAloud: dataset save failed: \(error)")
            var cleanupFailed = false
            if var recoveryPending = pendingDatasetSave {
                do {
                    let resolution = try await recoveryPending.recovery.abandon(
                        using: datasetSaveRecovery
                    )
                    pendingDatasetSave = recoveryPending
                    if resolution?.state == .committedRecordPreserved {
                        if resolution?.hasPendingManifestCleanup == true {
                            NSLog(
                                "ThinkAloud: database save returned an error after commit; "
                                    + "manifest cleanup will retry at startup"
                            )
                        }
                        return true
                    }
                    if resolution?.hasPendingManifestCleanup == true {
                        NSLog(
                            "ThinkAloud: unsaved audio removed; manifest cleanup will retry at startup"
                        )
                    }
                } catch {
                    cleanupFailed = true
                    pendingDatasetSave = recoveryPending
                    NSLog("ThinkAloud: unsaved audio recovery failed: \(error)")
                }
            }
            let current = pendingDatasetSave ?? pending
            viewModel.phase = .error(
                .datasetSave(
                    inserted: current.inserted,
                    cleanupFailed: cleanupFailed,
                    insertionMessage: current.insertionMessage
                )
            )
            return false
        }
    }

    private func finishDatasetSave() {
        datasetCommittedForActiveSession = true
        pendingDatasetSave = nil
        releaseHeavyRecordingState()
    }
}

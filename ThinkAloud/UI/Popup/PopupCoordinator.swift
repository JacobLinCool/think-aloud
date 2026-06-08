import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class PopupCoordinator {
    private let permissions: PermissionsService
    private let modelManager: ModelManager
    private let llmManager: LLMManager
    private let recorder: AudioRecorder
    private let insertion: TextInsertionManager
    private let datasetStore: DatasetStore
    private let audioFileStore: AudioFileStore

    let viewModel = PopupViewModel()
    private let windowController = PopupWindowController()

    private var elapsedTimerTask: Task<Void, Never>?
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
    /// Bumped on every new invocation / cancel. The polishing task captures the value at start and
    /// stops writing to the shared view model if it changes — so a stale refine from a previous
    /// dictation can never clobber a new session's text or its saved `llmEditedTranscript`.
    private var generation: Int = 0

    init(
        permissions: PermissionsService,
        modelManager: ModelManager,
        llmManager: LLMManager,
        recorder: AudioRecorder,
        insertion: TextInsertionManager,
        datasetStore: DatasetStore,
        audioFileStore: AudioFileStore
    ) {
        self.permissions = permissions
        self.modelManager = modelManager
        self.llmManager = llmManager
        self.recorder = recorder
        self.insertion = insertion
        self.datasetStore = datasetStore
        self.audioFileStore = audioFileStore
    }

    func invoke() {
        NSLog("ThinkAloud: invoke() phase=\(viewModel.phase)")
        switch viewModel.phase {
        case .recording, .transcribing, .polishing, .review:
            // .review/.polishing must early-return so that ⌥Space goes to insertAndSave (the sibling
            // handler) — which, during .polishing, cancels the refine and inserts what's shown —
            // rather than restarting recording and discarding the transcript.
            return
        case .idle, .error:
            break
        }
        modelManager.recordActivity()
        viewModel.reset()
        // New session: invalidate (and stop) any refine still running from a previous dictation so it
        // can't write into this session's transcript.
        generation += 1
        polishingTask?.cancel()
        polishingTask = nil
        lastLLMEditedTranscript = nil

        let focus = FocusContext.capture()
        viewModel.focusContext = focus

        windowController.show(viewModel: viewModel, coordinator: self, modelManager: modelManager)
        NSLog("ThinkAloud: popup shown, focus=\(focus.appName ?? "?")")

        Task { @MainActor in
            await self.startRecording()
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
        Task { @MainActor in
            await self.finishRecordingAndTranscribe()
        }
    }

    func cancel() {
        Task { @MainActor in
            await self.recorder.cancel()
            self.elapsedTimerTask?.cancel()
            self.elapsedTimerTask = nil
            // Supersede + stop any in-flight refine (generation guard makes its late writes no-ops).
            self.generation += 1
            self.polishingTask?.cancel()
            self.polishingTask = nil
            self.recordingStartedAt = nil
            self.lastRecording = nil
            self.lastResult = nil
            self.lastAutoEditedTranscript = nil
            self.lastLLMEditedTranscript = nil
            self.viewModel.reset()
            self.windowController.close()
        }
    }

    func insertOnly() {
        Task { @MainActor in
            await self.cancelPolishingIfNeeded()
            guard self.canInsertNow else { return }
            await self.performInsert(save: false)
        }
    }

    func insertAndSave() {
        Task { @MainActor in
            await self.cancelPolishingIfNeeded()
            guard self.canInsertNow else { return }
            await self.performInsert(save: true)
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
    /// Fired after a record is successfully saved to the dataset, so achievements can re-evaluate
    /// (and a newly-earned milestone can notify) as the user dictates.
    var onRecordSaved: (() -> Void)?

    func openSettings(_ category: SettingsCategory? = nil) {
        settingsOpener?(category)
    }

    private var canInsertNow: Bool {
        guard case .review = viewModel.phase else { return false }
        if viewModel.isStreaming { return false }
        if viewModel.editedTranscript.isEmpty { return false }
        return true
    }

    // MARK: - Internals

    private func startRecording() async {
        NSLog("ThinkAloud: startRecording entry, mic=\(permissions.microphoneStatus)")
        guard permissions.microphoneStatus != .denied else {
            viewModel.phase = .error(String(localized: "Microphone permission is required. Open Settings to grant access, then try again."))
            return
        }
        if permissions.microphoneStatus == .notDetermined {
            NSLog("ThinkAloud: requesting microphone permission")
            await permissions.requestMicrophone()
            NSLog("ThinkAloud: mic permission now \(permissions.microphoneStatus)")
        }
        guard permissions.microphoneStatus == .granted else {
            viewModel.phase = .error(String(localized: "Microphone permission is required. Open Settings to grant access, then try again."))
            return
        }

        do {
            try await recorder.start()
        } catch {
            NSLog("ThinkAloud: recorder start failed: \(error)")
            viewModel.phase = .error(String(describing: error))
            return
        }
        // Anchor elapsed time on the MainActor so the display loop never has to hop into the
        // recorder actor (busy ingesting audio buffers) just to read the clock.
        recordingStartedAt = Date()
        NSLog("ThinkAloud: recording started")
        viewModel.phase = .recording
        startElapsedTimer()
    }

    /// Single ~15Hz MainActor loop that drives BOTH the elapsed clock and the level meter.
    /// Elapsed is computed locally (no actor hop); the level is pulled from the recorder once
    /// per tick. This replaces the old split of a 100ms elapsed poll + a per-buffer (~47/s)
    /// level-callback push, which together flooded the MainActor and made the timer tick
    /// unevenly while re-rendering the whole popup.
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
        elapsedTimerTask?.cancel()
        elapsedTimerTask = nil

        let recordingResult: RecordingResult
        do {
            recordingResult = try await recorder.stop()
        } catch {
            viewModel.phase = .error(String(describing: error))
            return
        }
        lastRecording = recordingResult

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
                NSLog("ThinkAloud: denoise failed, using original audio: \(error)")
            }
        }
        if asrSampleRate != 16000 {
            do {
                asrSamples = try AudioRecorder.resample(asrSamples, from: asrSampleRate, to: 16000)
                asrSampleRate = 16000
            } catch {
                // Never feed source-rate audio to the 16 kHz-only runtimes — abort instead.
                viewModel.isStreaming = false
                viewModel.phase = .error(String(describing: error))
                return
            }
        }

        do {
            for try await event in runtime.transcribeStream(samples: asrSamples, sampleRate: asrSampleRate, options: ASROptions(language: nil)) {
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
            viewModel.isStreaming = false
            lastResult = finalResult
            // The editor now shows the pure Auto-Post-Edit output; the user hasn't touched it yet.
            // Capture it before manual edits so we can later attribute the raw→edited delta to
            // automatic formatting vs human correction.
            lastAutoEditedTranscript = viewModel.editedTranscript
            modelManager.recordActivity()
            if !receivedAny && finalResult == nil {
                viewModel.phase = .error(String(localized: "No transcription produced."))
            } else {
                await runPolishingStageIfEnabled()
            }
        } catch {
            viewModel.isStreaming = false
            modelManager.recordActivity()
            viewModel.phase = .error(String(describing: error))
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
            var threw = false
            do {
                for try await chunk in stream {
                    accumulated += chunk
                    // A newer dictation superseded this refine — stop touching the shared view model.
                    guard self.generation == gen else { return }
                    self.viewModel.editedTranscript = LLMText.stripReasoning(accumulated)
                }
            } catch {
                // A clean cancel (⌥Space-insert) keeps the partial; a real error fails open to base.
                if !Task.isCancelled { threw = true }
                NSLog("ThinkAloud: AI Refine error: \(error)")
            }
            guard self.generation == gen else { return }
            let cleaned = LLMText.stripReasoning(accumulated).trimmingCharacters(in: .whitespacesAndNewlines)
            if threw || cleaned.isEmpty {
                // Fail open: refusal / error / empty / unclosed reasoning → keep the deterministic output.
                self.viewModel.editedTranscript = base
                self.lastLLMEditedTranscript = nil
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

    private func performInsert(save: Bool) async {
        // Snapshot everything we need from the view model BEFORE closing the popup, since
        // closing the popup will reset state.
        let editedText = viewModel.editedTranscript
        let rawText = viewModel.rawTranscript
        let autoEditedText = lastAutoEditedTranscript
        let llmEditedText = lastLLMEditedTranscript
        let focus = viewModel.focusContext
        let recording = lastRecording
        let result = lastResult
        let saveFlag = save

        // Close popup FIRST — otherwise the popup window holds keyboard focus and our
        // simulated Cmd+V lands in the popup's own TextEditor instead of the source app.
        windowController.close()
        viewModel.reset()

        // Give the OS a brief moment to transfer keyboard focus back to the source app
        // after our nonactivating panel goes away.
        try? await Task.sleep(nanoseconds: 120_000_000)

        let outcome = await insertion.insert(editedText, into: focus)
        NSLog("ThinkAloud: insertion outcome inserted=\(outcome.inserted) clipboard=\(outcome.copiedToClipboard) msg=\(outcome.message)")
        InsertionFeedback.notifyIfNeeded(outcome: outcome)

        if saveFlag, let recording, let result {
            do {
                let recordID = DatasetRecord.generateID(date: recording.startedAt)
                let stored = try await audioFileStore.persist(samples: recording.samples, sampleRate: Double(recording.sampleRate), recordID: recordID, at: recording.startedAt)
                let createdAt = ISO8601DateFormatter().string(from: recording.startedAt)
                let record = DatasetRecord(
                    id: recordID,
                    createdAt: createdAt,
                    audioPath: stored.relativePath,
                    durationMs: recording.durationMs,
                    sampleRate: recording.sampleRate,
                    channels: recording.channels,
                    sourceAppBundleID: focus?.appBundleID,
                    sourceAppName: focus?.appName,
                    asrProvider: "mlx-audio-swift",
                    asrModel: result.modelID,
                    asrRuntime: result.runtimeID,
                    asrConfigJSON: nil,
                    rawTranscript: rawText,
                    editedTranscript: editedText,
                    inserted: outcome.inserted,
                    savedToDataset: true,
                    language: result.language,
                    metadataJSON: nil,
                    autoEditedTranscript: autoEditedText,
                    llmEditedTranscript: llmEditedText
                )
                try await datasetStore.save(record)
                onRecordSaved?()
            } catch {
                NSLog("ThinkAloud: dataset save failed: \(error)")
            }
        }

        lastRecording = nil
        lastResult = nil
        lastAutoEditedTranscript = nil
        lastLLMEditedTranscript = nil
    }
}

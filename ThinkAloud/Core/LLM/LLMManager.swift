import Foundation
import HuggingFace
import Observation

/// Owns the AI Refine stage: the per-app configuration, the globally-selected MLX model, its runtime
/// (download / idle-unload, mirroring `ModelManager`), and backend routing (downloaded Qwen vs Apple
/// Intelligence). A sibling of `ModelManager` owned by `AppContainer` — kept separate so neither
/// bloats the other. Weights live in a dedicated `<appSupport>/llm/` cache so the ASR HF-cache prune
/// never touches them.
@MainActor
@Observable
final class LLMManager {
    private let cacheDirectory: URL

    private let modelKey = "ThinkAloud.llmModelProfile"
    /// The globally-selected MLX model (one warm model serves every app; per-app varies only prompt).
    private(set) var selectedModel: LLMModelProfile {
        didSet {
            UserDefaults.standard.set(selectedModel.rawValue, forKey: modelKey)
            if selectedModel != oldValue { rebuildRuntime() }
        }
    }

    private let configKey = "ThinkAloud.llmPostEditConfig"
    var config: LLMPostEditConfig {
        didSet {
            if let data = try? JSONEncoder().encode(config) {
                UserDefaults.standard.set(data, forKey: configKey)
            }
        }
    }

    // Shares the user's existing idle-unload setting (set in Settings → Model) — no new control.
    private let idleTimeoutKey = "ThinkAloud.idleTimeout"
    private var idleTimeout: IdleTimeout {
        UserDefaults.standard.string(forKey: idleTimeoutKey).flatMap(IdleTimeout.init(rawValue:)) ?? .tenMinutes
    }

    private(set) var runtimeStatus: ASRRuntimeStatus = .unloaded
    private(set) var profileDownloadStatus: [LLMModelProfile: ASRRuntimeStatus] = [:]
    private(set) var lastActivityAt: Date = .distantPast

    private var runtimeRef: MLXLLMRuntime
    private var appleRuntime: (any LLMRuntime)?
    private var statusPollingTask: Task<Void, Never>?
    private var idleEvictionTask: Task<Void, Never>?

    init(cacheDirectory: URL) {
        self.cacheDirectory = cacheDirectory
        let model = UserDefaults.standard.string(forKey: modelKey).flatMap(LLMModelProfile.init(rawValue:)) ?? .recommended
        self.selectedModel = model
        if let data = UserDefaults.standard.data(forKey: configKey),
           let cfg = try? JSONDecoder().decode(LLMPostEditConfig.self, from: data) {
            self.config = cfg
        } else {
            self.config = .default
        }
        self.runtimeRef = MLXLLMRuntime(modelID: model.modelID, cacheDirectory: cacheDirectory)
    }

    func setModel(_ new: LLMModelProfile) { selectedModel = new }

    // MARK: - Resolution

    /// The effective profile for a dictation's source app (per-app override > default; nil if off).
    func effectiveConfig(for focus: FocusContext?) -> LLMProfileConfig? {
        config.effectiveConfig(for: focus)
    }

    /// Whether refine can actually run for `focus`: a profile is enabled AND its backend is usable
    /// (the MLX model is downloaded, or Apple Intelligence is available).
    func isRefineReady(for focus: FocusContext?) -> Bool {
        guard let profile = effectiveConfig(for: focus) else { return false }
        switch profile.backend {
        case .mlx: return isDownloaded(selectedModel)
        case .appleFoundation: return AppleFoundationAvailability.isAvailable
        }
    }

    // MARK: - Refine

    /// Streams a refined rewrite using the profile's backend. The caller falls back to the
    /// deterministic transcript on any thrown error.
    func refine(_ transcript: String, using profile: LLMProfileConfig) -> AsyncThrowingStream<String, Error> {
        recordActivity()
        let params = LLMGenerateParams(temperature: Float(profile.temperature))
        switch profile.backend {
        case .mlx:
            return runtimeRef.refine(transcript, instructions: profile.systemPrompt, params: params)
        case .appleFoundation:
            let runtime = appleFoundationRuntime()
            return runtime.refine(transcript, instructions: profile.systemPrompt, params: params)
        }
    }

    private func appleFoundationRuntime() -> any LLMRuntime {
        if let appleRuntime { return appleRuntime }
        let r = AppleFoundationAvailability.makeRuntime()
        appleRuntime = r
        return r
    }

    // MARK: - Activity / idle eviction (mirrors ModelManager)

    func recordActivity() {
        lastActivityAt = Date()
        scheduleIdleEvictionIfNeeded()
    }

    func preloadNow() {
        let runtime = runtimeRef
        startStatusPolling()
        Task { @MainActor in
            do {
                try await runtime.preload()
                self.recordActivity()
            } catch {
                NSLog("ThinkAloud: LLM preload failed: \(error)")
            }
            await self.stopStatusPollingAndSync()
        }
    }

    func unloadNow() {
        idleEvictionTask?.cancel()
        idleEvictionTask = nil
        let runtime = runtimeRef
        Task { @MainActor in
            await runtime.unload()
            self.runtimeStatus = await runtime.status()
        }
    }

    private func rebuildRuntime() {
        idleEvictionTask?.cancel()
        idleEvictionTask = nil
        let old = runtimeRef
        Task { await old.unload() }
        runtimeRef = MLXLLMRuntime(modelID: selectedModel.modelID, cacheDirectory: cacheDirectory)
        runtimeStatus = .unloaded
        lastActivityAt = .distantPast
    }

    private func startStatusPolling() {
        statusPollingTask?.cancel()
        let runtime = runtimeRef
        statusPollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let s = await runtime.status()
                self?.runtimeStatus = s
                if s.isReady || s.isFailed { return }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func stopStatusPollingAndSync() async {
        statusPollingTask?.cancel()
        statusPollingTask = nil
        runtimeStatus = await runtimeRef.status()
    }

    private func scheduleIdleEvictionIfNeeded() {
        idleEvictionTask?.cancel()
        guard let timeout = idleTimeout.seconds else { return }
        let runtime = runtimeRef
        let activityAt = lastActivityAt
        idleEvictionTask = Task { @MainActor [weak self] in
            let remaining = max(timeout - Date().timeIntervalSince(activityAt), 0)
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            if Task.isCancelled { return }
            guard let self, self.lastActivityAt == activityAt else { return }
            if await runtime.status().isReady {
                await runtime.unload()
                self.runtimeStatus = await runtime.status()
                NSLog("ThinkAloud: LLM auto-unloaded after idle timeout=\(timeout)s")
            }
        }
    }

    // MARK: - Per-model download management (mirrors ModelManager)

    var modelCacheURL: URL { cacheDirectory }
    private var cache: HubCache { HubCache(cacheDirectory: cacheDirectory) }

    func isDownloaded(_ profile: LLMModelProfile) -> Bool {
        LLMModelPaths.hasModelFiles(for: profile.modelID, cache: cache)
    }

    func cacheSize(for profile: LLMModelProfile) -> Int64 {
        LLMModelPaths.directorySize(LLMModelPaths.repoDirectory(for: profile.modelID, cache: cache))
    }

    /// Downloads a model's weights. For the active model this reuses the live runtime (stays loaded);
    /// for others it spins up a transient runtime, fetches, then unloads.
    func downloadModel(_ profile: LLMModelProfile) async throws {
        if profile == selectedModel {
            let poll = startModelDownloadPolling(profile: profile, runtime: runtimeRef)
            defer { poll.cancel(); profileDownloadStatus[profile] = nil }
            try await runtimeRef.preload()
            return
        }
        let transient = MLXLLMRuntime(modelID: profile.modelID, cacheDirectory: cacheDirectory)
        let poll = startModelDownloadPolling(profile: profile, runtime: transient)
        defer { poll.cancel(); profileDownloadStatus[profile] = nil }
        try await transient.preload()
        await transient.unload()
    }

    private func startModelDownloadPolling(profile: LLMModelProfile, runtime: MLXLLMRuntime) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let s = await runtime.status()
                if Task.isCancelled { return }
                self?.profileDownloadStatus[profile] = s
                if s.isReady || s.isFailed { return }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    func removeModel(_ profile: LLMModelProfile) throws {
        if profile == selectedModel { unloadNow() }
        try LLMModelPaths.remove(modelID: profile.modelID, cache: cache)
    }
}

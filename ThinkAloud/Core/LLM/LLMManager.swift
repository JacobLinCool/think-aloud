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
    private let defaults: UserDefaults

    private static let modelKey = SavedSettingsError.Field.refineModel.preferenceKey
    /// The globally-selected MLX model (one warm model serves every app; per-app varies only prompt).
    private(set) var selectedModel: LLMModelProfile {
        didSet {
            defaults.set(selectedModel.rawValue, forKey: Self.modelKey)
            if selectedModel != oldValue { rebuildRuntime() }
        }
    }

    private static let configKey = SavedSettingsError.Field.refineConfiguration.preferenceKey
    var config: LLMPostEditConfig {
        didSet {
            persist(config, forKey: Self.configKey, field: .refineConfiguration)
        }
    }

    // Shares the user's existing idle-unload setting (set in Settings → Model) — no new control.
    private static let idleTimeoutKey = SavedSettingsError.Field.idleTimeout.preferenceKey

    private(set) var runtimeStatus: ASRRuntimeStatus = .unloaded
    private(set) var settingsError: SavedSettingsError?
    private(set) var profileDownloadStatus: [LLMModelProfile: ASRRuntimeStatus] = [:]
    /// Cached as observable state so removing or downloading a non-selected profile redraws its
    /// row immediately. A computed filesystem lookup alone does not emit an Observation change.
    private(set) var downloadedProfiles: Set<LLMModelProfile>
    private(set) var lastActivityAt: Date = .distantPast

    private var runtimeRef: MLXLLMRuntime
    private var appleRuntime: (any LLMRuntime)?
    private var statusPollingTask: Task<Void, Never>?
    private var idleEvictionTask: Task<Void, Never>?

    init(cacheDirectory: URL, defaults: UserDefaults = .standard) throws {
        let model = try SavedSettingsReader.enumValue(
            LLMModelProfile.self,
            defaults: defaults,
            key: Self.modelKey,
            field: .refineModel
        ) ?? .recommended
        let storedConfig = try SavedSettingsReader.decodableValue(
            LLMPostEditConfig.self,
            defaults: defaults,
            key: Self.configKey,
            field: .refineConfiguration
        ) ?? .default
        _ = try SavedSettingsReader.enumValue(
            IdleTimeout.self,
            defaults: defaults,
            key: Self.idleTimeoutKey,
            field: .idleTimeout
        )

        self.cacheDirectory = cacheDirectory
        self.defaults = defaults
        self.selectedModel = model
        self.config = storedConfig
        let cache = HubCache(cacheDirectory: cacheDirectory)
        self.downloadedProfiles = Set(
            LLMModelProfile.allCases.filter {
                LLMModelPaths.hasModelFiles(for: $0.modelID, cache: cache)
            }
        )
        self.runtimeRef = MLXLLMRuntime(modelID: model.modelID, cacheDirectory: cacheDirectory)
    }

    func setModel(_ new: LLMModelProfile) { selectedModel = new }

    private func persist<Value: Encodable>(
        _ value: Value,
        forKey key: String,
        field: SavedSettingsError.Field
    ) {
        do {
            defaults.set(try JSONEncoder().encode(value), forKey: key)
            settingsError = nil
        } catch {
            NSLog("ThinkAloud: failed to encode saved setting for key \(key): \(error)")
            settingsError = .encodingFailed(field)
        }
    }

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
        let profile = selectedModel
        startStatusPolling()
        Task { @MainActor in
            do {
                try await runtime.preload()
                self.downloadedProfiles.insert(profile)
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
        let idleTimeout: IdleTimeout
        do {
            idleTimeout = try SavedSettingsReader.enumValue(
                IdleTimeout.self,
                defaults: defaults,
                key: Self.idleTimeoutKey,
                field: .idleTimeout
            ) ?? .tenMinutes
        } catch let error as SavedSettingsError {
            settingsError = error
            return
        } catch {
            assertionFailure("SavedSettingsReader threw an unexpected error: \(error)")
            return
        }
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
        downloadedProfiles.contains(profile)
    }

    func cacheSize(for profile: LLMModelProfile) -> Int64 {
        LLMModelPaths.directorySize(LLMModelPaths.repoDirectory(for: profile.modelID, cache: cache))
    }

    /// Downloads a model's weights. For the active model this reuses the live runtime (stays loaded);
    /// for others it spins up a transient runtime, fetches, then unloads.
    func downloadModel(_ profile: LLMModelProfile) async throws {
        try Task.checkCancellation()
        if profile == selectedModel {
            let poll = startModelDownloadPolling(profile: profile, runtime: runtimeRef)
            defer { poll.cancel(); profileDownloadStatus[profile] = nil }
            let runtime = runtimeRef
            try await withTaskCancellationHandler {
                try await runtime.preload()
                try Task.checkCancellation()
            } onCancel: {
                Task { await runtime.unload() }
            }
            downloadedProfiles.insert(profile)
            return
        }
        let transient = MLXLLMRuntime(modelID: profile.modelID, cacheDirectory: cacheDirectory)
        let poll = startModelDownloadPolling(profile: profile, runtime: transient)
        defer { poll.cancel(); profileDownloadStatus[profile] = nil }
        try await withTaskCancellationHandler {
            try await transient.preload()
            try Task.checkCancellation()
        } onCancel: {
            Task { await transient.unload() }
        }
        downloadedProfiles.insert(profile)
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
        downloadedProfiles.remove(profile)
    }
}

import Foundation
import HuggingFace
import Observation

enum SavedSettingsError: Error, LocalizedError, Equatable, Sendable {
    enum Field: Equatable, Sendable {
        case speechModel
        case postEdit
        case preEdit
        case idleTimeout
        case refineModel
        case refineConfiguration

        var preferenceKey: String {
            switch self {
            case .speechModel: return "ThinkAloud.modelProfile"
            case .postEdit: return "ThinkAloud.postEditConfig"
            case .preEdit: return "ThinkAloud.preEditConfig"
            case .idleTimeout: return "ThinkAloud.idleTimeout"
            case .refineModel: return "ThinkAloud.llmModelProfile"
            case .refineConfiguration: return "ThinkAloud.llmPostEditConfig"
            }
        }
    }

    case invalidSavedValue(Field)
    case encodingFailed(Field)

    var errorDescription: String? {
        switch self {
        case .invalidSavedValue(.speechModel):
            return String(localized: "The saved speech model setting is invalid. Reset it, then retry.")
        case .invalidSavedValue(.postEdit):
            return String(localized: "The saved transcript editing settings are invalid. Reset them, then retry.")
        case .invalidSavedValue(.preEdit):
            return String(localized: "The saved audio cleanup settings are invalid. Reset them, then retry.")
        case .invalidSavedValue(.idleTimeout):
            return String(localized: "The saved model idle-time setting is invalid. Reset it, then retry.")
        case .invalidSavedValue(.refineModel):
            return String(localized: "The saved AI refinement model setting is invalid. Reset it, then retry.")
        case .invalidSavedValue(.refineConfiguration):
            return String(localized: "The saved AI refinement settings are invalid. Reset them, then retry.")
        case .encodingFailed(.speechModel):
            return String(localized: "ThinkAloud couldn’t save the speech model setting. Try again.")
        case .encodingFailed(.postEdit):
            return String(localized: "ThinkAloud couldn’t save the transcript editing settings. Try again.")
        case .encodingFailed(.preEdit):
            return String(localized: "ThinkAloud couldn’t save the audio cleanup settings. Try again.")
        case .encodingFailed(.idleTimeout):
            return String(localized: "ThinkAloud couldn’t save the model idle-time setting. Try again.")
        case .encodingFailed(.refineModel):
            return String(localized: "ThinkAloud couldn’t save the AI refinement model setting. Try again.")
        case .encodingFailed(.refineConfiguration):
            return String(localized: "ThinkAloud couldn’t save the AI refinement settings. Try again.")
        }
    }

    var invalidPreferenceKey: String? {
        guard case .invalidSavedValue(let field) = self else { return nil }
        return field.preferenceKey
    }
}

enum SavedSettingsReader {
    static func enumValue<Value>(
        _ type: Value.Type,
        defaults: UserDefaults,
        key: String,
        field: SavedSettingsError.Field
    ) throws -> Value? where Value: RawRepresentable, Value.RawValue == String {
        guard let object = defaults.object(forKey: key) else { return nil }
        guard let rawValue = object as? String,
              let value = Value(rawValue: rawValue) else {
            NSLog("ThinkAloud: invalid saved enum setting for key \(key)")
            throw SavedSettingsError.invalidSavedValue(field)
        }
        return value
    }

    static func decodableValue<Value: Decodable>(
        _ type: Value.Type,
        defaults: UserDefaults,
        key: String,
        field: SavedSettingsError.Field
    ) throws -> Value? {
        guard let object = defaults.object(forKey: key) else { return nil }
        guard let data = object as? Data else {
            NSLog("ThinkAloud: saved setting for key \(key) is not data")
            throw SavedSettingsError.invalidSavedValue(field)
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            NSLog("ThinkAloud: failed to decode saved setting for key \(key): \(error)")
            throw SavedSettingsError.invalidSavedValue(field)
        }
    }
}

enum IdleTimeout: String, CaseIterable, Identifiable, Sendable {
    case never
    case fiveMinutes
    case tenMinutes
    case thirtyMinutes
    case oneHour

    var id: String { rawValue }

    var seconds: TimeInterval? {
        switch self {
        case .never: return nil
        case .fiveMinutes: return 5 * 60
        case .tenMinutes: return 10 * 60
        case .thirtyMinutes: return 30 * 60
        case .oneHour: return 60 * 60
        }
    }

    var displayName: String {
        switch self {
        case .never: return String(localized: "Never (keep loaded)")
        case .fiveMinutes: return String(localized: "5 minutes")
        case .tenMinutes: return String(localized: "10 minutes")
        case .thirtyMinutes: return String(localized: "30 minutes")
        case .oneHour: return String(localized: "1 hour")
        }
    }
}

@MainActor
@Observable
final class ModelManager {
    private let modelsDirectory: URL
    private let defaults: UserDefaults
    private static let defaultsKey = SavedSettingsError.Field.speechModel.preferenceKey

    private(set) var profile: ModelProfile {
        didSet {
            defaults.set(profile.rawValue, forKey: Self.defaultsKey)
            if profile != oldValue {
                rebuildRuntime()
            }
        }
    }

    private static let postEditKey = SavedSettingsError.Field.postEdit.preferenceKey
    /// Auto Post-Edit configuration (Chinese conversion + CJK/Latin spacing, …).
    var postEdit: PostEditConfig {
        didSet {
            persist(postEdit, forKey: Self.postEditKey, field: .postEdit)
        }
    }

    private static let preEditKey = SavedSettingsError.Field.preEdit.preferenceKey
    /// Auto Pre-Edit configuration (audio denoise before ASR, …).
    var preEdit: PreEditConfig {
        didSet {
            persist(preEdit, forKey: Self.preEditKey, field: .preEdit)
        }
    }

    private static let idleTimeoutKey = SavedSettingsError.Field.idleTimeout.preferenceKey
    var idleTimeout: IdleTimeout {
        didSet {
            defaults.set(idleTimeout.rawValue, forKey: Self.idleTimeoutKey)
            scheduleIdleEvictionIfNeeded()
        }
    }

    private(set) var runtimeStatus: ASRRuntimeStatus = .unloaded
    private(set) var lastError: String?
    private(set) var settingsError: SavedSettingsError?
    private(set) var lastActivityAt: Date = .distantPast

    /// Live download status keyed by profile, used by the Advanced pane to show a percentage +
    /// progress bar while ANY model downloads — including profiles other than the active one,
    /// whose status never reaches `runtimeStatus`. Populated during `downloadProfile`, cleared
    /// when it finishes.
    private(set) var profileDownloadStatus: [ModelProfile: ASRRuntimeStatus] = [:]

    private var runtimeRef: any ASRRuntime
    private var statusPollingTask: Task<Void, Never>?
    private var idleEvictionTask: Task<Void, Never>?
    private var preloadTask: Task<Void, Never>?
    private(set) var preloadIsRunning = false
    private(set) var preloadCancellationRequested = false

    /// Auto Pre-Edit denoiser (DeepFilterNet). Lazily loaded on first use, freed on idle/unload
    /// alongside the ASR model. `dfnStatus` mirrors its state for the Settings UI.
    private let dfnRuntimeRef: DeepFilterNetRuntime
    private(set) var dfnStatus: ASRRuntimeStatus = .unloaded

    init(modelsDirectory: URL, defaults: UserDefaults = .standard) throws {
        let storedProfile = try SavedSettingsReader.enumValue(
            ModelProfile.self,
            defaults: defaults,
            key: Self.defaultsKey,
            field: .speechModel
        ) ?? .accurate
        let storedPostEdit = try SavedSettingsReader.decodableValue(
            PostEditConfig.self,
            defaults: defaults,
            key: Self.postEditKey,
            field: .postEdit
        ) ?? .default
        let storedPreEdit = try SavedSettingsReader.decodableValue(
            PreEditConfig.self,
            defaults: defaults,
            key: Self.preEditKey,
            field: .preEdit
        ) ?? .default
        let storedIdleTimeout = try SavedSettingsReader.enumValue(
            IdleTimeout.self,
            defaults: defaults,
            key: Self.idleTimeoutKey,
            field: .idleTimeout
        ) ?? .tenMinutes

        self.modelsDirectory = modelsDirectory
        self.defaults = defaults
        self.profile = storedProfile
        self.postEdit = storedPostEdit
        self.preEdit = storedPreEdit
        self.idleTimeout = storedIdleTimeout
        self.runtimeRef = ASRRuntimeFactory.make(profile: storedProfile, cacheDirectory: modelsDirectory)
        self.dfnRuntimeRef = DeepFilterNetRuntime(modelsDirectory: modelsDirectory)
    }

    var modelID: String { profile.modelID }

    var runtime: any ASRRuntime { runtimeRef }

    func setProfile(_ new: ModelProfile) {
        profile = new
    }

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

    /// Mark the model as actively in use. Resets the idle-eviction countdown.
    func recordActivity() {
        lastActivityAt = Date()
        scheduleIdleEvictionIfNeeded()
    }

    func preloadNow() {
        guard preloadTask == nil else { return }
        let runtime = runtimeRef
        preloadIsRunning = true
        preloadCancellationRequested = false
        lastError = nil
        startStatusPolling()
        preloadTask = Task { @MainActor in
            var userFacingFailure: String?
            defer {
                self.preloadTask = nil
                self.preloadIsRunning = false
                self.preloadCancellationRequested = false
            }
            do {
                try await runtime.preload()
                try Task.checkCancellation()
                self.recordActivity()
                self.pruneRedundantHFCache()
            } catch is CancellationError {
                await runtime.unload()
                self.lastError = nil
            } catch {
                NSLog("ThinkAloud: speech model preload failed: \(error)")
                let message = String(
                    localized: "Speech model failed to load. Retry or open Model settings."
                )
                userFacingFailure = message
                self.lastError = message
            }
            await self.stopStatusPollingAndSync()
            if let userFacingFailure {
                // Runtime errors can contain framework diagnostics. Keep those in the log and
                // expose only a concise, actionable, localizable status to Settings/onboarding.
                self.runtimeStatus = .failed(userFacingFailure)
            }
        }
    }

    func cancelPreload() {
        guard let preloadTask else { return }
        preloadCancellationRequested = true
        preloadTask.cancel()
    }

    func refreshStatus() {
        let runtime = runtimeRef
        Task { @MainActor in
            self.runtimeStatus = await runtime.status()
        }
    }

    /// Manual unload — clears in-memory weights immediately. Cached files on disk are kept.
    func unloadNow() {
        idleEvictionTask?.cancel()
        idleEvictionTask = nil
        preloadTask?.cancel()
        let runtime = runtimeRef
        let dfn = dfnRuntimeRef
        Task { @MainActor in
            await runtime.unload()
            self.runtimeStatus = await runtime.status()
            await dfn.unload()
            self.dfnStatus = .unloaded
            NSLog("ThinkAloud: model unloaded manually")
        }
    }

    // MARK: - Auto Pre-Edit (denoiser)

    /// Runs the DeepFilterNet denoiser on a 48 kHz mono clip, lazily loading it on first use.
    /// Updates `dfnStatus` for the Settings UI. Throws if loading/inference fails (callers should
    /// fall back to the original audio).
    func denoise(_ samples: [Float]) async throws -> [Float] {
        let dfn = dfnRuntimeRef
        let loaded = await dfn.isLoaded
        if !loaded { dfnStatus = .loading }
        do {
            let out = try await dfn.enhance(samples)
            dfnStatus = .ready
            recordActivity()
            return out
        } catch {
            NSLog("ThinkAloud: audio cleanup failed: \(error)")
            dfnStatus = .failed(
                String(localized: "Audio cleanup failed. Retry or choose Auto/Off in Output settings.")
            )
            throw error
        }
    }

    /// Eagerly downloads + loads the denoiser (Settings "Load denoiser" button).
    func preloadDFN() {
        let dfn = dfnRuntimeRef
        dfnStatus = .loading
        Task { @MainActor in
            do {
                try await dfn.preload()
                self.dfnStatus = await dfn.status
                self.recordActivity()
            } catch {
                NSLog("ThinkAloud: audio cleanup model preload failed: \(error)")
                self.dfnStatus = .failed(
                    String(localized: "Audio cleanup failed. Retry or choose Auto/Off in Output settings.")
                )
            }
        }
    }

    /// Manually frees the denoiser weights from memory.
    func unloadDFNNow() {
        let dfn = dfnRuntimeRef
        Task { @MainActor in
            await dfn.unload()
            self.dfnStatus = .unloaded
        }
    }

    private func startStatusPolling() {
        statusPollingTask?.cancel()
        let runtime = runtimeRef
        statusPollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let s = await runtime.status()
                self?.runtimeStatus = s
                if case .ready = s { return }
                if case .failed = s { return }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func stopStatusPollingAndSync() async {
        statusPollingTask?.cancel()
        statusPollingTask = nil
        runtimeStatus = await runtimeRef.status()
    }

    private func rebuildRuntime() {
        idleEvictionTask?.cancel()
        idleEvictionTask = nil
        preloadTask?.cancel()
        preloadTask = nil
        preloadIsRunning = false
        preloadCancellationRequested = false
        runtimeRef = ASRRuntimeFactory.make(profile: profile, cacheDirectory: modelsDirectory)
        runtimeStatus = .unloaded
        lastError = nil
        lastActivityAt = .distantPast
    }

    private func scheduleIdleEvictionIfNeeded() {
        idleEvictionTask?.cancel()
        guard let timeout = idleTimeout.seconds else { return }
        let runtime = runtimeRef
        let dfn = dfnRuntimeRef
        let activityAt = lastActivityAt
        idleEvictionTask = Task { @MainActor [weak self] in
            // Sleep until the timeout has elapsed since the recorded activity.
            let now = Date()
            let elapsed = now.timeIntervalSince(activityAt)
            let remaining = max(timeout - elapsed, 0)
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            if Task.isCancelled { return }
            guard let self else { return }
            // Confirm still idle: lastActivityAt must not have moved.
            if self.lastActivityAt != activityAt { return }
            // Only unload if currently ready.
            if case .ready = await runtime.status() {
                await runtime.unload()
                self.runtimeStatus = await runtime.status()
                NSLog("ThinkAloud: model auto-unloaded after idle timeout=\(timeout)s")
            }
            // Free the denoiser too, on the same idle policy.
            if await dfn.isLoaded {
                await dfn.unload()
                self.dfnStatus = .unloaded
                NSLog("ThinkAloud: denoiser auto-unloaded after idle timeout=\(timeout)s")
            }
        }
    }

    var modelCacheURL: URL { modelsDirectory }

    // MARK: - Per-profile management (Advanced pane)

    /// Resolves the on-disk snapshot directory for any profile (matches mlx-audio's layout).
    func snapshotURL(for profile: ModelProfile) -> URL {
        let cache = HubCache(cacheDirectory: modelsDirectory)
        return ASRRuntimeFactory.snapshotDirectory(for: profile.modelID, cache: cache)
    }

    func cacheSize(for profile: ModelProfile) -> Int64 {
        directorySize(snapshotURL(for: profile))
    }

    func isDownloaded(_ profile: ModelProfile) -> Bool {
        ASRRuntimeFactory.hasModelFiles(in: snapshotURL(for: profile))
    }

    /// Downloads a profile's weights to disk. For the active profile this just calls preload();
    /// for non-active profiles it spins up a transient runtime, fetches, then unloads its weights.
    func downloadProfile(_ profile: ModelProfile) async throws {
        try Task.checkCancellation()
        if profile == self.profile {
            // Active profile: reuse the live runtime so its weights stay loaded afterwards.
            let poll = startProfileDownloadPolling(profile: profile, runtime: runtimeRef)
            defer {
                poll.cancel()
                profileDownloadStatus[profile] = nil
            }
            try await runtimeRef.preload()
            try Task.checkCancellation()
            return
        }
        let transient = ASRRuntimeFactory.make(profile: profile, cacheDirectory: modelsDirectory)
        let poll = startProfileDownloadPolling(profile: profile, runtime: transient)
        defer {
            poll.cancel()
            profileDownloadStatus[profile] = nil
        }
        try await transient.preload()
        try Task.checkCancellation()
        await transient.unload()
        pruneRedundantHFCache()
    }

    /// Polls a (possibly transient) runtime's status into `profileDownloadStatus[profile]` at 4Hz
    /// so the Advanced pane can render a live percentage/bar during download. Stops on
    /// ready/failed; the caller also cancels it via `defer` once `preload()` returns.
    private func startProfileDownloadPolling(profile: ModelProfile, runtime: any ASRRuntime) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let s = await runtime.status()
                if Task.isCancelled { return }
                self?.profileDownloadStatus[profile] = s
                if case .ready = s { return }
                if case .failed = s { return }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    /// Removes a profile's snapshot directory and its parallel HF blob cache. If it's the
    /// currently-selected profile, the active runtime is unloaded first to release file handles.
    func removeProfile(_ profile: ModelProfile) throws {
        if profile == self.profile {
            unloadNow()
        }
        let snapshot = snapshotURL(for: profile)
        if FileManager.default.fileExists(atPath: snapshot.path) {
            try FileManager.default.removeItem(at: snapshot)
        }
        // Also clear the HF-style cache if it's still around (parallel layout from huggingface-swift).
        let parts = profile.modelID.split(separator: "/")
        if parts.count == 2 {
            let hfFolder = "models--\(parts[0])--\(parts[1])"
            let hfDir = modelsDirectory.appendingPathComponent(hfFolder)
            if FileManager.default.fileExists(atPath: hfDir.path) {
                try FileManager.default.removeItem(at: hfDir)
            }
        }
    }

    /// mlx-audio-swift loads from `<models>/mlx-audio/<id>/` (flat copies). The downloader
    /// also leaves a parallel HF-style cache at `<models>/models--org--repo/` (snapshots +
    /// blobs). Once mlx-audio has the flat copy it never reads the HF cache again, so the
    /// HF directory is redundant and can be safely removed to reclaim ~half the disk usage.
    @discardableResult
    func pruneRedundantHFCache() -> Int64 {
        let fm = FileManager.default
        var freed: Int64 = 0
        let entries = (try? fm.contentsOfDirectory(at: modelsDirectory, includingPropertiesForKeys: nil)) ?? []
        for url in entries where url.lastPathComponent.hasPrefix("models--") {
            let size = directorySize(url)
            do {
                try fm.removeItem(at: url)
                freed += size
                NSLog("ThinkAloud: pruned redundant HF cache \(url.lastPathComponent) freed=\(size)B")
            } catch {
                NSLog("ThinkAloud: failed to prune \(url.lastPathComponent): \(error)")
            }
        }
        return freed
    }

    private func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let entry as URL in enumerator {
            let values = try? entry.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }

    func cacheSizeBytes() -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: modelsDirectory, includingPropertiesForKeys: [.fileSizeKey, .totalFileAllocatedSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }
}

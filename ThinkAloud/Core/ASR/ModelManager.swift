import Foundation
import HuggingFace
import Observation

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
    private let defaultsKey = "ThinkAloud.modelProfile"

    private(set) var profile: ModelProfile {
        didSet {
            UserDefaults.standard.set(profile.rawValue, forKey: defaultsKey)
            if profile != oldValue {
                rebuildRuntime()
            }
        }
    }

    /// Legacy key from when post-processing was Chinese-conversion only. Read once at launch to
    /// migrate into `postEdit`; no longer written.
    private let chinesePreferenceKey = "ThinkAloud.chinesePreference"
    private let postEditKey = "ThinkAloud.postEditConfig"
    /// Auto Post-Edit configuration (Chinese conversion + CJK/Latin spacing, …).
    var postEdit: PostEditConfig {
        didSet {
            if let data = try? JSONEncoder().encode(postEdit) {
                UserDefaults.standard.set(data, forKey: postEditKey)
            }
        }
    }

    private let idleTimeoutKey = "ThinkAloud.idleTimeout"
    var idleTimeout: IdleTimeout {
        didSet {
            UserDefaults.standard.set(idleTimeout.rawValue, forKey: idleTimeoutKey)
            scheduleIdleEvictionIfNeeded()
        }
    }

    private(set) var runtimeStatus: ASRRuntimeStatus = .unloaded
    private(set) var lastError: String?
    private(set) var lastActivityAt: Date = .distantPast

    /// Live download status keyed by profile, used by the Advanced pane to show a percentage +
    /// progress bar while ANY model downloads — including profiles other than the active one,
    /// whose status never reaches `runtimeStatus`. Populated during `downloadProfile`, cleared
    /// when it finishes.
    private(set) var profileDownloadStatus: [ModelProfile: ASRRuntimeStatus] = [:]

    private var runtimeRef: any ASRRuntime
    private var statusPollingTask: Task<Void, Never>?
    private var idleEvictionTask: Task<Void, Never>?

    init(modelsDirectory: URL) {
        self.modelsDirectory = modelsDirectory
        let stored = UserDefaults.standard.string(forKey: defaultsKey).flatMap(ModelProfile.init(rawValue:)) ?? .accurate
        self.profile = stored
        if let data = UserDefaults.standard.data(forKey: postEditKey),
           let cfg = try? JSONDecoder().decode(PostEditConfig.self, from: data) {
            self.postEdit = cfg
        } else {
            // Migrate the legacy Chinese-preference-only setting into the new pipeline config.
            let legacy = UserDefaults.standard.string(forKey: chinesePreferenceKey).flatMap(ChinesePreference.init(rawValue:)) ?? .model
            self.postEdit = PostEditConfig(chinese: legacy)
        }
        let storedTimeout = UserDefaults.standard.string(forKey: idleTimeoutKey).flatMap(IdleTimeout.init(rawValue:)) ?? .tenMinutes
        self.idleTimeout = storedTimeout
        self.runtimeRef = ASRRuntimeFactory.make(profile: stored, cacheDirectory: modelsDirectory)
    }

    var modelID: String { profile.modelID }

    var runtime: any ASRRuntime { runtimeRef }

    func setProfile(_ new: ModelProfile) {
        profile = new
    }

    /// Mark the model as actively in use. Resets the idle-eviction countdown.
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
                self.pruneRedundantHFCache()
            } catch {
                self.lastError = String(describing: error)
            }
            await self.stopStatusPollingAndSync()
        }
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
        let runtime = runtimeRef
        Task { @MainActor in
            await runtime.unload()
            self.runtimeStatus = await runtime.status()
            NSLog("ThinkAloud: model unloaded manually")
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
        runtimeRef = ASRRuntimeFactory.make(profile: profile, cacheDirectory: modelsDirectory)
        runtimeStatus = .unloaded
        lastError = nil
        lastActivityAt = .distantPast
    }

    private func scheduleIdleEvictionIfNeeded() {
        idleEvictionTask?.cancel()
        guard let timeout = idleTimeout.seconds else { return }
        let runtime = runtimeRef
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
        if profile == self.profile {
            // Active profile: reuse the live runtime so its weights stay loaded afterwards.
            let poll = startProfileDownloadPolling(profile: profile, runtime: runtimeRef)
            defer {
                poll.cancel()
                profileDownloadStatus[profile] = nil
            }
            try await runtimeRef.preload()
            return
        }
        let transient = ASRRuntimeFactory.make(profile: profile, cacheDirectory: modelsDirectory)
        let poll = startProfileDownloadPolling(profile: profile, runtime: transient)
        defer {
            poll.cancel()
            profileDownloadStatus[profile] = nil
        }
        try await transient.preload()
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
                try? FileManager.default.removeItem(at: hfDir)
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

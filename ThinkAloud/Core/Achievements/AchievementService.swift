import Foundation
import Observation
@preconcurrency import UserNotifications

/// Owns achievement state: recomputes statistics, unlocks newly-earned milestones, persists the
/// unlocked set, and fires a system notification when something new is earned. Also the shared
/// statistics source for the Insights pane (the dashboard reads `stats`), so opening Insights or
/// saving a record both refresh the numbers and the badges in one pass.
@MainActor
@Observable
final class AchievementService {
    private let datasetStore: DatasetStore

    /// Latest computed statistics (also drives the Insights dashboard). `.empty` until first refresh.
    private(set) var stats: DatasetStatistics = .empty
    /// True once `refresh()` has completed at least once — lets the UI show a loading state instead of
    /// flashing the empty state before the first compute lands.
    private(set) var hasLoaded: Bool = false
    /// Ids of unlocked achievements.
    private(set) var unlockedIDs: Set<String> = []

    private static let unlockedKey = "ThinkAloud.achievements.unlocked"
    private static let baselineKey = "ThinkAloud.achievements.baselineEstablished"

    private var didRequestAuth = false
    private var refreshInFlight = false
    private var refreshPending = false
    /// Injection seam so tests can observe notifications without touching UNUserNotificationCenter.
    /// Takes the whole batch unlocked in one pass so a single auth round-trip covers all of them.
    var notifier: ([Achievement]) -> Void

    init(datasetStore: DatasetStore) {
        self.datasetStore = datasetStore
        self.notifier = { _ in }
        self.notifier = { [weak self] in self?.postSystemNotifications($0) }
        if let saved = UserDefaults.standard.array(forKey: Self.unlockedKey) as? [String] {
            unlockedIDs = Set(saved)
        }
    }

    /// Recompute statistics and reconcile achievements. Coalesces concurrent callers (Insights `.task`
    /// + the after-save trigger) onto one compute, with a single trailing re-run if a save lands
    /// mid-compute — so an open Insights window + a save don't kick off two full Levenshtein passes.
    func refresh() async {
        if refreshInFlight { refreshPending = true; return }
        refreshInFlight = true
        defer { refreshInFlight = false }
        repeat {
            refreshPending = false
            if let s = try? await datasetStore.computeStatistics() {
                stats = s
                hasLoaded = true
                reconcile(with: s)
            }
        } while refreshPending
    }

    /// Pure reconciliation: on the FIRST evaluation (no baseline yet) every already-satisfied
    /// milestone is unlocked SILENTLY — an app update must not spam banners for retroactive
    /// achievements. Afterwards, only milestones crossed *since* the baseline fire a notification.
    /// Earned achievements never re-lock (union), so deleting records can't revoke a badge.
    nonisolated static func reconcile(satisfied: Set<String>, unlocked: Set<String>, baselineEstablished: Bool) -> (unlocked: Set<String>, notify: [String]) {
        guard baselineEstablished else { return (satisfied, []) }
        let newly = satisfied.subtracting(unlocked)
        return (unlocked.union(satisfied), Array(newly))
    }

    private func reconcile(with s: DatasetStatistics) {
        let satisfied = Achievement.satisfied(by: s)
        let baselineEstablished = UserDefaults.standard.bool(forKey: Self.baselineKey)
        let result = Self.reconcile(satisfied: satisfied, unlocked: unlockedIDs, baselineEstablished: baselineEstablished)
        unlockedIDs = result.unlocked
        UserDefaults.standard.set(Array(unlockedIDs), forKey: Self.unlockedKey)
        if !baselineEstablished {
            UserDefaults.standard.set(true, forKey: Self.baselineKey)
            return
        }
        // Notify in catalogue order for a stable sequence when several land at once.
        let newly = Achievement.all.filter { result.notify.contains($0.id) }
        if !newly.isEmpty { notifier(newly) }
    }

    // MARK: - System notification

    /// Posts banners for a batch of freshly-unlocked achievements. The `add()` calls run INSIDE the
    /// authorization callback (mirroring `InsertionFeedback`) so the very first unlock on a fresh
    /// install isn't dropped by racing the still-`.notDetermined` auth prompt — and one auth
    /// round-trip covers the whole batch.
    private func postSystemNotifications(_ achievements: [Achievement]) {
        guard !achievements.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        ensureAuthorized(center) { granted in
            guard granted else {
                NSLog("ThinkAloud: achievement notification skipped — not authorized (\(achievements.count) queued)")
                return
            }
            for a in achievements {
                let content = UNMutableNotificationContent()
                content.title = String(localized: "Achievement unlocked 🎉")
                content.body = "\(a.title) — \(a.detail)"
                content.sound = .default
                center.add(UNNotificationRequest(identifier: "achievement.\(a.id)", content: content, trigger: nil)) { error in
                    if let error { NSLog("ThinkAloud: achievement notification add failed: \(error)") }
                }
            }
        }
    }

    /// Resolve authorization, then call back with the verdict. First call prompts (lazily — at the
    /// first celebration, not at launch); later calls just read the current setting.
    private func ensureAuthorized(_ center: UNUserNotificationCenter, completion: @escaping @Sendable (Bool) -> Void) {
        if didRequestAuth {
            center.getNotificationSettings { settings in
                completion(settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional)
            }
            return
        }
        didRequestAuth = true
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in completion(granted) }
    }
}

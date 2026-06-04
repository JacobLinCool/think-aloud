import Foundation
import Observation
import UserNotifications

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
    /// Injection seam so tests can observe notifications without touching UNUserNotificationCenter.
    var notifier: (Achievement) -> Void

    init(datasetStore: DatasetStore) {
        self.datasetStore = datasetStore
        self.notifier = { _ in }
        self.notifier = { [weak self] in self?.postSystemNotification($0) }
        if let saved = UserDefaults.standard.array(forKey: Self.unlockedKey) as? [String] {
            unlockedIDs = Set(saved)
        }
    }

    /// Recompute statistics and reconcile achievements. Cheap to call repeatedly (the heavy compute
    /// is the same one the Insights dashboard already needs).
    func refresh() async {
        guard let s = try? await datasetStore.computeStatistics() else { return }
        stats = s
        hasLoaded = true
        reconcile(with: s)
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
        // Notify in catalogue order for a stable, sensible sequence when several land at once.
        for a in Achievement.all where result.notify.contains(a.id) {
            notifier(a)
        }
    }

    // MARK: - System notification

    private func postSystemNotification(_ a: Achievement) {
        let center = UNUserNotificationCenter.current()
        requestAuthIfNeeded(center)
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Achievement unlocked 🎉")
        content.body = "\(a.title) — \(a.detail)"
        content.sound = .default
        center.add(UNNotificationRequest(identifier: "achievement.\(a.id)", content: content, trigger: nil))
    }

    /// Ask once, lazily — at the moment we'd first celebrate something, not at launch.
    private func requestAuthIfNeeded(_ center: UNUserNotificationCenter) {
        guard !didRequestAuth else { return }
        didRequestAuth = true
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}

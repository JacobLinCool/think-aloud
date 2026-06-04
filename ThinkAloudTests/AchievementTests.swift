import XCTest
@testable import ThinkAloud

final class AchievementTests: XCTestCase {

    func testSatisfactionTiers() {
        var s = DatasetStatistics.empty
        s.recordCount = 120
        s.audio.totalDurationMs = 40 * 60_000        // 40 minutes
        s.text.totalEditedChars = 1_500
        s.longestDayStreak = 5

        let ids = Achievement.satisfied(by: s)
        XCTAssertTrue(ids.contains("sessions.10"))
        XCTAssertTrue(ids.contains("sessions.100"))
        XCTAssertFalse(ids.contains("sessions.1000"))
        XCTAssertTrue(ids.contains("time.30"))
        XCTAssertFalse(ids.contains("time.180"))
        XCTAssertTrue(ids.contains("chars.1000"))
        XCTAssertFalse(ids.contains("chars.25000"))
        XCTAssertTrue(ids.contains("streak.3"))
        XCTAssertFalse(ids.contains("streak.7"))
    }

    func testEmptyStatsUnlockNothing() {
        XCTAssertTrue(Achievement.satisfied(by: .empty).isEmpty)
    }

    func testPolishedCountsEditedEligibleRecords() {
        var s = DatasetStatistics.empty
        s.editing.eligibleCount = 60
        s.editing.cleanCount = 8           // 52 polished
        XCTAssertTrue(Achievement.satisfied(by: s).contains("polished.50"))
    }

    func testReconcileSilentBaselineThenNotifiesNewOnly() {
        // First evaluation (no baseline): everything already satisfied unlocks SILENTLY.
        let r1 = AchievementService.reconcile(satisfied: ["a", "b"], unlocked: [], baselineEstablished: false)
        XCTAssertEqual(r1.unlocked, ["a", "b"])
        XCTAssertTrue(r1.notify.isEmpty, "retroactive unlocks must not notify")

        // After the baseline, only the newly-crossed milestone fires.
        let r2 = AchievementService.reconcile(satisfied: ["a", "b", "c"], unlocked: ["a", "b"], baselineEstablished: true)
        XCTAssertEqual(r2.unlocked, ["a", "b", "c"])
        XCTAssertEqual(r2.notify, ["c"])
    }

    func testReconcileNeverRelocksOnDataDeletion() {
        // Records deleted → fewer satisfied, but earned badges stay and nothing re-notifies.
        let r = AchievementService.reconcile(satisfied: ["a"], unlocked: ["a", "b", "c"], baselineEstablished: true)
        XCTAssertEqual(r.unlocked, ["a", "b", "c"])
        XCTAssertTrue(r.notify.isEmpty)
    }

    func testAllIDsAreUnique() {
        let ids = Achievement.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "achievement ids must be unique (they're persisted)")
    }
}

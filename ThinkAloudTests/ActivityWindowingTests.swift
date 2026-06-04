import XCTest
@testable import ThinkAloud

/// Pins the overview's date windowing to the engine's UTC day keys, regardless of the machine's
/// timezone — guards against the reintroduced "Calendar defaults to TimeZone.current" off-by-one.
final class ActivityWindowingTests: XCTestCase {

    private static let utc: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f
    }()

    private func stats(onDays days: [String]) -> DatasetStatistics {
        let records = days.enumerated().map { i, day in
            DatasetRecord(
                id: "r\(i)", createdAt: "\(day)T08:00:00Z",
                audioPath: "audio/\(day)/r\(i).wav",
                durationMs: 4000, sampleRate: 16000, channels: 1,
                sourceAppBundleID: nil, sourceAppName: nil,
                asrProvider: "p", asrModel: "m", asrRuntime: "rt", asrConfigJSON: nil,
                rawTranscript: "x", editedTranscript: "x",
                inserted: true, savedToDataset: true, language: "en", metadataJSON: nil
            )
        }
        return DatasetStatistics.compute(from: records)
    }

    func testWeeklyWindowsAreSevenDaysEachInUTC() throws {
        // now = 2026-06-15 12:00 UTC. this week = 06-09…06-15, last week = 06-02…06-08.
        let now = try XCTUnwrap(Self.utc.date(from: "2026-06-15T12:00:00Z"))
        let s = stats(onDays: ["2026-06-15", "2026-06-09", "2026-06-08", "2026-06-02", "2026-06-01"])
        let w = WeeklyActivity(stats: s, now: now)
        XCTAssertEqual(w.thisWeek, 2, "06-15 (today) + 06-09 (today-6 boundary)")
        XCTAssertEqual(w.lastWeek, 2, "06-08 (today-7) + 06-02 (today-13 boundary)")
        XCTAssertTrue(w.up, "2 >= 2")
    }

    func testCurrentStreakCountsBackFromTodayOrYesterday() throws {
        let now = try XCTUnwrap(Self.utc.date(from: "2026-06-15T12:00:00Z"))
        // Ending today.
        XCTAssertEqual(CurrentStreak(stats: stats(onDays: ["2026-06-13", "2026-06-14", "2026-06-15"]), now: now).days, 3)
        // Ending yesterday (grace day — not yet dictated today).
        XCTAssertEqual(CurrentStreak(stats: stats(onDays: ["2026-06-12", "2026-06-13", "2026-06-14"]), now: now).days, 3)
        // Most recent active day older than yesterday → no live streak.
        XCTAssertEqual(CurrentStreak(stats: stats(onDays: ["2026-06-10", "2026-06-11"]), now: now).days, 0)
        // A gap right before today → streak is just today.
        XCTAssertEqual(CurrentStreak(stats: stats(onDays: ["2026-06-12", "2026-06-13", "2026-06-15"]), now: now).days, 1)
    }

    func testActivitySeriesIsDenseAndUTCAligned() throws {
        let now = try XCTUnwrap(Self.utc.date(from: "2026-06-15T12:00:00Z"))
        let s = stats(onDays: ["2026-06-15", "2026-06-09", "2026-06-08", "2026-06-02", "2026-06-01"])
        let series = ActivitySeries(stats: s, days: 30, now: now)
        XCTAssertEqual(series.points.count, 30, "one point per day, gaps filled with 0")
        XCTAssertEqual(series.points.map(\.count).reduce(0, +), 5, "all 5 days fall within the last 30")
        // The rightmost point is today (UTC) and carries today's single session.
        XCTAssertEqual(series.points.last?.count, 1)
    }
}

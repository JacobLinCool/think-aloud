import XCTest
@testable import ThinkAloud

/// Locks the pinned statistics contract: scalar counting unit, eligibility-gated edit metrics,
/// well-formed empty/degenerate output, nearest-rank quantiles, honest productivity, and the
/// privacy projection.
final class DatasetStatisticsTests: XCTestCase {

    // MARK: - Factory

    private func rec(
        id: String,
        createdAt: String = "2026-06-05T10:00:00Z",
        durationMs: Int? = 4_000,
        raw: String,
        edited: String,
        autoEdited: String? = nil,
        inserted: Bool = true,
        language: String? = "zh",
        model: String = "mlx-community/Qwen3-ASR-1.7B-4bit",
        appBundle: String? = "com.apple.Safari",
        appName: String? = "Safari"
    ) -> DatasetRecord {
        DatasetRecord(
            id: id, createdAt: createdAt,
            audioPath: "audio/2026-06-05/\(id).wav",
            durationMs: durationMs, sampleRate: 16000, channels: 1,
            sourceAppBundleID: appBundle, sourceAppName: appName,
            asrProvider: "mlx-audio-swift", asrModel: model, asrRuntime: "rt", asrConfigJSON: nil,
            rawTranscript: raw, editedTranscript: edited,
            inserted: inserted, savedToDataset: true,
            language: language, metadataJSON: nil,
            autoEditedTranscript: autoEdited
        )
    }

    // MARK: - Empty / degenerate

    func testEmptyDatasetIsAllZerosNoNaN() {
        let s = DatasetStatistics.compute(from: [])
        XCTAssertEqual(s, .empty)
        XCTAssertTrue(s.isEmpty)
        XCTAssertEqual(s.editing.cleanRate, 0)
        XCTAssertEqual(s.productivity.timeSavedSeconds, 0)
        XCTAssertEqual(s.activityByHourUTC.count, 24)
        XCTAssertEqual(s.activityByWeekday.count, 7)
    }

    func testEmptyStringRecordProducesFiniteValues() {
        // Whisper produced nothing, user inserted nothing, autoEdited captured as empty.
        let s = DatasetStatistics.compute(from: [
            rec(id: "r0", durationMs: 1_000, raw: "", edited: "", autoEdited: "")
        ])
        XCTAssertEqual(s.editing.eligibleCount, 1)
        XCTAssertEqual(s.editing.cleanCount, 1, "empty==empty is clean")
        XCTAssertEqual(s.editing.cleanRate, 1)
        XCTAssertEqual(s.editing.meanEditRate, 0, "empty ref + empty edited → rate 0, not NaN")
        XCTAssertTrue(s.productivity.timeSavedSeconds.isFinite)
        XCTAssertFalse(s.productivity.charsPerMinute.isNaN)
    }

    // MARK: - Counting unit = scalars

    func testCountingUnitIsUnicodeScalars() {
        // "é" as base 'e' + combining acute (U+0301) is 2 scalars / 1 grapheme; an emoji is 1 scalar.
        let combining = "e\u{0301}"          // é decomposed
        let emoji = "🎤"
        let text = combining + emoji          // 2 + 1 = 3 scalars
        let s = DatasetStatistics.compute(from: [rec(id: "r", raw: text, edited: text, autoEdited: text)])
        XCTAssertEqual(s.text.totalEditedChars, 3, "scalar count, not grapheme count (which would be 2)")
        XCTAssertEqual(s.editing.totalManualEditDistance, 0)
        XCTAssertEqual(s.editing.cleanCount, 1)
    }

    // MARK: - Eligibility gating (the headline blocker)

    func testHistoricalRecordsExcludedFromEditMetrics() {
        // A pre-v0.4.0 Traditional-Chinese record: raw is Simplified, edited is Traditional (auto S→T).
        // Without the captured intermediate we must NOT count it as edited — it has no autoEdited.
        let historical = rec(id: "old", raw: "简体输出", edited: "簡體輸出", autoEdited: nil)
        let s = DatasetStatistics.compute(from: [historical])
        XCTAssertEqual(s.recordCount, 1)
        XCTAssertEqual(s.editing.eligibleCount, 0, "no captured intermediate → not eligible")
        XCTAssertEqual(s.editing.cleanCount, 0)
        XCTAssertEqual(s.editing.cleanRate, 0)
        XCTAssertEqual(s.editing.totalManualEditDistance, 0, "must NOT charge the S→T delta as a human edit")
    }

    func testAutoFormatNotCountedAsHumanEdit() {
        // v0.4.0 record: raw Simplified → auto-edited Traditional → user kept it verbatim.
        let r = rec(id: "new", raw: "简体输出", edited: "簡體輸出", autoEdited: "簡體輸出")
        let s = DatasetStatistics.compute(from: [r])
        XCTAssertEqual(s.editing.eligibleCount, 1)
        XCTAssertEqual(s.editing.cleanCount, 1, "human changed nothing past the auto-format → clean")
        XCTAssertEqual(s.editing.cleanRate, 1)
        XCTAssertEqual(s.editing.totalManualEditDistance, 0)
        XCTAssertGreaterThan(s.editing.totalAutoFormatDistance, 0, "the S→T delta IS counted, as auto-format")
    }

    func testCleanIffManualDistanceZeroEvenWithTrailingWhitespace() {
        // Only difference is a trailing space → normalized-equal → clean, distance 0.
        let r = rec(id: "ws", raw: "hello", edited: "hello ", autoEdited: "hello")
        let s = DatasetStatistics.compute(from: [r])
        XCTAssertEqual(s.editing.cleanCount, 1)
        XCTAssertEqual(s.editing.totalManualEditDistance, 0)
    }

    func testManualEditDistanceCountsRealEdits() {
        let r = rec(id: "edit", raw: "teh cat", edited: "the cat", autoEdited: "teh cat")
        let s = DatasetStatistics.compute(from: [r])
        XCTAssertEqual(s.editing.eligibleCount, 1)
        XCTAssertEqual(s.editing.cleanCount, 0)
        XCTAssertEqual(s.editing.totalManualEditDistance, 2, "swap e↔h = 2 substitutions")
    }

    // MARK: - Micro vs macro edit rate

    func testMicroVsMacroEditRate() {
        // One short heavily-edited row + one long clean row. Macro (per-record mean) weights them
        // equally; micro (length-weighted) is dominated by the long clean row.
        let short = rec(id: "s", raw: "ab", edited: "xy", autoEdited: "ab")       // dist 2 / ref 2 = 1.0
        let long = rec(id: "l", raw: String(repeating: "a", count: 100),
                       edited: String(repeating: "a", count: 100),
                       autoEdited: String(repeating: "a", count: 100))            // dist 0 / ref 100 = 0
        let s = DatasetStatistics.compute(from: [short, long])
        XCTAssertEqual(s.editing.meanEditRate, 0.5, accuracy: 1e-9, "macro = (1.0 + 0)/2")
        XCTAssertEqual(s.editing.microEditRate, 2.0 / 102.0, accuracy: 1e-9, "micro = 2/(2+100)")
    }

    // MARK: - Quantiles (nearest-rank R-1)

    func testQuantilesExactForKnownN() {
        func p90(_ ms: [Int]) -> Int {
            DatasetStatistics.compute(from: ms.enumerated().map { rec(id: "r\($0.0)", durationMs: $0.1, raw: "x", edited: "x") }).audio.p90Ms
        }
        XCTAssertEqual(p90([5_000]), 5_000)                                  // N=1
        XCTAssertEqual(p90([1_000, 2_000]), 2_000)                           // N=2 → ceil(1.8)-1=1
        XCTAssertEqual(p90([1_000, 2_000, 3_000]), 3_000)                    // N=3 → ceil(2.7)-1=2
        // N=10 sorted 1000..10000 → ceil(9)-1 = index 8 → 9000
        XCTAssertEqual(p90((1...10).map { $0 * 1_000 }), 9_000)
    }

    func testMedianEvenAndOdd() {
        func med(_ ms: [Int]) -> Int {
            DatasetStatistics.compute(from: ms.enumerated().map { rec(id: "r\($0.0)", durationMs: $0.1, raw: "x", edited: "x") }).audio.medianMs
        }
        XCTAssertEqual(med([1_000, 3_000, 5_000]), 3_000)                    // odd
        XCTAssertEqual(med([1_000, 3_000]), 2_000)                           // even → avg
    }

    // MARK: - Duration histogram + invalid durations

    func testDurationHistogramEdgesAndOverflow() {
        let records = [
            rec(id: "a", durationMs: 0, raw: "x", edited: "x"),         // invalid (0) → excluded
            rec(id: "b", durationMs: 2_000, raw: "x", edited: "x"),     // on edge → [2–5s)
            rec(id: "c", durationMs: 1_999, raw: "x", edited: "x"),     // [0–2s)
            rec(id: "d", durationMs: 90_000, raw: "x", edited: "x"),    // 60s+ overflow
            rec(id: "e", durationMs: 7_200_000, raw: "x", edited: "x"), // > 1h → corrupt, excluded
        ]
        let s = DatasetStatistics.compute(from: records)
        XCTAssertEqual(s.audio.recordsWithDuration, 3, "0 and >1h excluded")
        let h = Dictionary(uniqueKeysWithValues: s.audio.histogram.map { ($0.label, $0.count) })
        XCTAssertEqual(h["0–2s"], 1)
        XCTAssertEqual(h["2–5s"], 1, "2000ms lands in [2–5s), not [0–2s)")
        XCTAssertEqual(h["60s+"], 1)
    }

    func testMissingDurationCountedSeparately() {
        let s = DatasetStatistics.compute(from: [
            rec(id: "ok", durationMs: 5_000, raw: "hello world", edited: "hello world", autoEdited: "hello world"),
            rec(id: "nil", durationMs: nil, raw: "x", edited: "x", autoEdited: "x"),
        ])
        XCTAssertEqual(s.productivity.recordCount, 1)
        XCTAssertEqual(s.productivity.missingDurationCount, 1)
        XCTAssertEqual(s.recordCount, 2, "still counted in the corpus total")
    }

    // MARK: - Productivity

    func testTimeSavedPositiveForFastDictation() {
        // 200 Latin chars dictated in 10s. Typing 200 chars at 160 cpm ≈ 75s. Saved ≈ 65s, no fix.
        let text = String(repeating: "a", count: 200)
        let s = DatasetStatistics.compute(from: [rec(id: "r", durationMs: 10_000, raw: text, edited: text, autoEdited: text)])
        XCTAssertGreaterThan(s.productivity.timeSavedSeconds, 50)
        XCTAssertEqual(s.productivity.estimatedFixSeconds, 0)
        XCTAssertGreaterThan(s.productivity.charsPerMinute, 0)
    }

    func testTimeSavedTotalFlooredButPerRecordNotClamped() {
        // A tiny clip where typing would be faster than the (artificially long) dictation → net loss.
        let r = rec(id: "loss", durationMs: 60_000, raw: "hi", edited: "hi", autoEdited: "hi")
        let s = DatasetStatistics.compute(from: [r])
        XCTAssertEqual(s.productivity.timeSavedSeconds, 0, "displayed total floored at 0")
        XCTAssertLessThan(s.productivity.medianSavingSeconds, 0, "per-record saving honestly negative")
    }

    // MARK: - Breakdowns

    func testBreakdownsSortedByCountThenKey() {
        let s = DatasetStatistics.compute(from: [
            rec(id: "1", raw: "x", edited: "x", language: "en"),
            rec(id: "2", raw: "x", edited: "x", language: "zh"),
            rec(id: "3", raw: "x", edited: "x", language: "zh"),
        ])
        XCTAssertEqual(s.byLanguage.map(\.key), ["zh", "en"])
        XCTAssertEqual(s.byLanguage.first?.count, 2)
    }

    func testModelDisplayNameIsShortened() {
        let s = DatasetStatistics.compute(from: [rec(id: "1", raw: "x", edited: "x")])
        XCTAssertEqual(s.byModel.first?.displayName, "Qwen3-ASR-1.7B-4bit")
    }

    // MARK: - Activity (weekday / hour)

    func testWeekdayAndHourActivity() {
        // 2026-06-05 is a Friday (weekday index 5, 0=Sunday); hour 14 UTC.
        let s = DatasetStatistics.compute(from: [
            rec(id: "r", createdAt: "2026-06-05T14:30:00Z", raw: "x", edited: "x")
        ])
        XCTAssertEqual(s.activityByWeekday[5], 1)
        XCTAssertEqual(s.activityByWeekday.reduce(0, +), 1)
        XCTAssertEqual(s.activityByHourUTC[14], 1)
        XCTAssertEqual(s.activeDayCount, 1)
        XCTAssertEqual(s.activityByDay.first?.day, "2026-06-05")
    }

    // MARK: - Privacy projection

    func testPublicProjectionDropsAppAndDatedActivity() {
        let s = DatasetStatistics.compute(from: [
            rec(id: "r", createdAt: "2026-06-05T14:30:00Z", raw: "x", edited: "x", appBundle: "com.acme.secret", appName: "Secret")
        ])
        XCTAssertFalse(s.byApp.isEmpty, "local stats keep the app breakdown")
        let pub = s.publicProjection()
        XCTAssertTrue(pub.byApp.isEmpty, "public projection drops source-app breakdown")
        XCTAssertTrue(pub.activityByDay.isEmpty, "public projection drops the dated calendar")
        XCTAssertEqual(pub.firstRecordAt, "2026-06-05", "only the date, not the timestamp")
        XCTAssertEqual(pub.activityByWeekday[5], 1, "coarse weekday histogram survives")
    }
}

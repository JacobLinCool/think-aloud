import Foundation

/// Pure, deterministic statistics over saved dataset records.
///
/// Computed off the main thread and **cached** by callers — never recompute per render (edit-distance
/// is O(n·m) per record). The struct serves two audiences from the same numbers:
///   • the app user — the Dataset overview ("you saved time, the model is accurate").
///   • the dataset consumer — the Hugging Face card + `statistics.json` (`publicProjection()`).
///
/// ## Contract (pinned so the numbers are reproducible by third parties)
/// - **Counting unit = Unicode scalars** for char counts, the per-script split, and edit distance,
///   matching `TextMetrics.isCJK` / `wordTokens`. One CJK ideograph = one scalar = one "char".
/// - **Edit metrics are eligibility-gated.** "Clean" / manual-edit numbers count only records that
///   captured `autoEditedTranscript` (v0.4.0+). We never fall back to `rawTranscript`: for a
///   Traditional/Simplified user the Auto Post-Edit S↔T conversion makes raw≠edited on *every* row,
///   so a raw baseline would report ~0% clean — the opposite of the truth. `eligibleCount` is
///   surfaced so the UI can say "since v0.4.0".
/// - **No hidden clock.** Same records in → same struct out. Recency windows are the UI's job.
/// - **Well-formed on empty / degenerate input** — every rate is finite (no NaN/Inf), so Swift Charts
///   axis scaling never breaks. Empty reference follows the `TextMetrics.cer` convention.
/// - **Quantiles** use nearest-rank (type R-1): for ascending `x[0..<N]`, the p-quantile is
///   `x[clamp(ceil(p·N) − 1, 0, N−1)]`; median averages the two middle order statistics for even N.
struct DatasetStatistics: Sendable, Equatable, Codable {
    var recordCount: Int
    var insertedCount: Int
    /// Earliest / latest `createdAt` (ISO8601), nil when there are no records.
    var firstRecordAt: String?
    var lastRecordAt: String?
    /// Distinct UTC calendar days (the `yyyy-MM-dd` prefix of `createdAt`) with ≥1 record.
    var activeDayCount: Int
    /// Longest run of consecutive active UTC days. Clock-free (derived purely from the records), so
    /// it powers the "N-day streak" achievement deterministically.
    var longestDayStreak: Int

    var audio: AudioSummary
    var text: TextSummary
    var editing: EditSummary
    var productivity: ProductivitySummary

    var byLanguage: [Breakdown]
    var byModel: [Breakdown]
    /// Source-app breakdown. **Local only** — `publicProjection()` drops it so we never leak which
    /// apps the user dictates into to a (possibly public) dataset.
    var byApp: [Breakdown]
    /// Per-UTC-day counts, ascending. **Local only** — a dated calendar of when the user works is a
    /// behavioral fingerprint; `publicProjection()` drops it in favour of the coarse weekday/hour
    /// histograms below.
    var activityByDay: [DayBucket]
    /// Records per UTC hour-of-day (24 entries, index = hour). Coarse enough to publish.
    var activityByHourUTC: [Int]
    /// Records per weekday (7 entries, index 0 = Sunday). Coarse enough to publish.
    var activityByWeekday: [Int]

    static let empty = DatasetStatistics(
        recordCount: 0, insertedCount: 0, firstRecordAt: nil, lastRecordAt: nil, activeDayCount: 0,
        longestDayStreak: 0,
        audio: .empty, text: .empty, editing: .empty, productivity: .empty,
        byLanguage: [], byModel: [], byApp: [], activityByDay: [],
        activityByHourUTC: Array(repeating: 0, count: 24),
        activityByWeekday: Array(repeating: 0, count: 7)
    )

    var isEmpty: Bool { recordCount == 0 }

    /// First/last record as bare UTC dates (no time-of-day) — the only date granularity safe to publish.
    var firstRecordDay: String? { firstRecordAt.map { String($0.prefix(10)) } }
    var lastRecordDay: String? { lastRecordAt.map { String($0.prefix(10)) } }

    // MARK: - Nested summaries

    struct AudioSummary: Sendable, Equatable, Codable {
        var totalDurationMs: Int
        var meanMs: Int
        var medianMs: Int
        var minMs: Int
        var maxMs: Int
        var p90Ms: Int
        /// Records with a *valid* duration (0 < d ≤ 1h). Denominator for the averages + histogram, so
        /// nil / zero / corrupt durations never skew them. The UI suppresses p90 when this is < 10.
        var recordsWithDuration: Int
        var histogram: [DurationBucket]

        static let empty = AudioSummary(
            totalDurationMs: 0, meanMs: 0, medianMs: 0, minMs: 0, maxMs: 0, p90Ms: 0,
            recordsWithDuration: 0, histogram: []
        )
    }

    /// Half-open `[lowerMs, upperMs)` duration bucket; the final bucket has `upperMs == nil` (overflow).
    struct DurationBucket: Sendable, Equatable, Codable {
        var label: String
        var lowerMs: Int
        var upperMs: Int?
        var count: Int
    }

    struct TextSummary: Sendable, Equatable, Codable {
        /// Scalar counts (one CJK ideograph and one Latin letter each count as 1).
        var totalRawChars: Int
        var totalEditedChars: Int
        /// `TextMetrics.wordTokens` count of the edited text. Each CJK ideograph is its own token, so
        /// this runs ~3–4× a layperson's "word" count for CJK — it exists for WER consistency and the
        /// dataset's `token_count`, NOT as the user-facing "words" headline (that uses chars).
        var totalTokens: Int
        /// CJK ideographs/kana within the edited text — lets the card show the script mix.
        var totalCJKChars: Int
        var meanCharsPerRecord: Int

        static let empty = TextSummary(
            totalRawChars: 0, totalEditedChars: 0, totalTokens: 0, totalCJKChars: 0, meanCharsPerRecord: 0
        )
    }

    struct EditSummary: Sendable, Equatable, Codable {
        /// Records eligible for edit metrics: those that captured the Auto-Post-Edit intermediate
        /// (`autoEditedTranscript != nil`, i.e. saved on v0.4.0+). All rates below are over this set.
        var eligibleCount: Int
        /// Eligible records the user inserted without changing a single character (after light
        /// whitespace normalization). The headline "came out clean" accuracy proxy.
        var cleanCount: Int
        var cleanRate: Double
        /// Macro: mean of per-record edit rates, in `[0, 1]`.
        var meanEditRate: Double
        /// Micro: Σ manual edit distance ÷ Σ reference length — length-weighted, robust to short rows.
        var microEditRate: Double
        /// Σ scalar edit-distance the *human* applied on top of the auto-formatted text (eligible only).
        var totalManualEditDistance: Int
        /// Σ scalar edit-distance the *Auto Post-Edit* pipeline applied (raw → auto), eligible only.
        /// NOTE: not additive with `totalManualEditDistance` — they are baselined on different
        /// references (raw vs auto), so never present their sum as a total.
        var totalAutoFormatDistance: Int
        var editRateHistogram: [EditRateBucket]

        static let empty = EditSummary(
            eligibleCount: 0, cleanCount: 0, cleanRate: 0, meanEditRate: 0, microEditRate: 0,
            totalManualEditDistance: 0, totalAutoFormatDistance: 0, editRateHistogram: []
        )
    }

    struct EditRateBucket: Sendable, Equatable, Codable {
        var label: String
        var count: Int
    }

    struct ProductivitySummary: Sendable, Equatable, Codable {
        /// Records included in the estimate (valid duration only).
        var recordCount: Int
        /// Records excluded because their duration was nil / zero / corrupt.
        var missingDurationCount: Int
        /// Time actually spent dictating (Σ audio duration over included records).
        var spokenSeconds: Double
        /// Estimated time to TYPE the final text from scratch (per-script model, included records).
        var estimatedTypingSeconds: Double
        /// Estimated time spent fixing the auto-formatted text (manual edit distance × the record's
        /// own per-char typing speed; 0 when the record has no captured intermediate).
        var estimatedFixSeconds: Double
        /// `max(0, Σ(typing − spoken − fix))`. The honest "time saved": typing from scratch vs.
        /// (speaking + correcting). Per-record values are NOT clamped (losing sessions count); only
        /// this displayed grand total is floored at 0.
        var timeSavedSeconds: Double
        /// Median per-record saving (unclamped) — a robustness check against a few huge outliers.
        var medianSavingSeconds: Double
        /// Dictation speed = chars ÷ minutes spoken.
        var charsPerMinute: Double

        static let empty = ProductivitySummary(
            recordCount: 0, missingDurationCount: 0, spokenSeconds: 0, estimatedTypingSeconds: 0,
            estimatedFixSeconds: 0, timeSavedSeconds: 0, medianSavingSeconds: 0, charsPerMinute: 0
        )
    }

    struct Breakdown: Sendable, Equatable, Codable, Identifiable {
        var key: String
        var displayName: String
        var count: Int
        var totalDurationMs: Int
        var id: String { key }
    }

    struct DayBucket: Sendable, Equatable, Codable, Identifiable {
        var day: String          // "yyyy-MM-dd" (UTC)
        var count: Int
        var totalDurationMs: Int
        var id: String { day }
    }
}

// MARK: - Typing model

/// Per-script typing speeds used to estimate "time saved". Conservative, transparent constants on a
/// single axis — **net output characters per minute, whitespace excluded** — so Latin and CJK are
/// comparable. The UI surfaces this assumption ("How is this estimated?") so the number never reads
/// as an unfalsifiable claim. CJK is slower because IME composition usually needs a candidate
/// selection per word.
struct TypingModel: Sendable, Equatable {
    /// ~160 net chars/min ≈ 40 WPM of English prose — an average touch-typist.
    var latinCharsPerSecond: Double
    /// ~120 hanzi/min — average Chinese input-method throughput.
    var cjkCharsPerSecond: Double

    static let `default` = TypingModel(
        latinCharsPerSecond: 160.0 / 60.0,
        cjkCharsPerSecond: 120.0 / 60.0
    )

    /// Human-readable assumption string for the "How is this estimated?" disclosure.
    var assumptionDescription: String {
        let latin = Int((latinCharsPerSecond * 60).rounded())
        let cjk = Int((cjkCharsPerSecond * 60).rounded())
        return "Assumes typing ≈ \(latin) Latin / \(cjk) CJK characters per minute."
    }

    /// Estimated seconds to type `text`, splitting per script. Whitespace isn't charged. Operates on
    /// unicode scalars — the same axis as every other stat.
    func typingSeconds(for text: String) -> Double {
        var cjk = 0
        var other = 0
        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
            if TextMetrics.isCJK(scalar) { cjk += 1 } else { other += 1 }
        }
        return Double(cjk) / cjkCharsPerSecond + Double(other) / latinCharsPerSecond
    }

    /// Effective average seconds-per-character for a text's script mix — prices the manual fix at the
    /// SAME rate as `typingSeconds`.
    func secondsPerChar(forTextLike text: String) -> Double {
        let chars = text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count
        guard chars > 0 else { return 1.0 / latinCharsPerSecond }
        return typingSeconds(for: text) / Double(chars)
    }
}

// MARK: - Compute

extension DatasetStatistics {
    /// A duration ms is usable iff strictly positive and ≤ 1 hour (longer is corrupt for a dictation).
    static func isValidDuration(_ ms: Int) -> Bool { ms > 0 && ms <= 3_600_000 }

    /// Fixed half-open duration histogram edges (ms). `nil` upper = open-ended overflow bin.
    static let durationEdges: [(label: String, lower: Int, upper: Int?)] = [
        ("0–2s", 0, 2_000),
        ("2–5s", 2_000, 5_000),
        ("5–10s", 5_000, 10_000),
        ("10–20s", 10_000, 20_000),
        ("20–30s", 20_000, 30_000),
        ("30–60s", 30_000, 60_000),
        ("60s+", 60_000, nil),
    ]

    private static let editRateEdges: [(label: String, upper: Double)] = [
        ("0% (clean)", 0),     // exactly clean (index 0)
        ("≤5%", 0.05),
        ("5–15%", 0.15),
        ("15–30%", 0.30),
        ("30%+", 1.01),
    ]

    /// Build statistics from records. Pure — same input, same output.
    static func compute(from records: [DatasetRecord], typingModel: TypingModel = .default) -> DatasetStatistics {
        guard !records.isEmpty else { return .empty }

        var insertedCount = 0
        var durations: [Int] = []
        var durationHistogram = durationEdges.map { DurationBucket(label: $0.label, lowerMs: $0.lower, upperMs: $0.upper, count: 0) }

        var totalRawChars = 0
        var totalEditedChars = 0
        var totalTokens = 0
        var totalCJKChars = 0

        // Edit metrics — eligible (autoEdited captured) records only.
        var eligibleCount = 0
        var cleanCount = 0
        var sumEditRate = 0.0
        var sumManualDistance = 0
        var sumReferenceLen = 0
        var sumAutoFormatDistance = 0
        var editRateBuckets = editRateEdges.map { EditRateBucket(label: $0.label, count: 0) }

        // Productivity — valid-duration records only.
        var prodCount = 0
        var missingDurationCount = 0
        var spokenSeconds = 0.0
        var typingSeconds = 0.0
        var fixSeconds = 0.0
        var perRecordSavings: [Double] = []
        var prodChars = 0

        var langAgg: [String: (display: String, count: Int, ms: Int)] = [:]
        var modelAgg: [String: (display: String, count: Int, ms: Int)] = [:]
        var appAgg: [String: (display: String, count: Int, ms: Int)] = [:]
        var dayAgg: [String: (count: Int, ms: Int)] = [:]
        var hourHist = Array(repeating: 0, count: 24)
        var weekdayHist = Array(repeating: 0, count: 7)

        var firstAt = records[0].createdAt
        var lastAt = records[0].createdAt

        for r in records {
            if r.inserted { insertedCount += 1 }
            if r.createdAt < firstAt { firstAt = r.createdAt }
            if r.createdAt > lastAt { lastAt = r.createdAt }

            let valid = r.durationMs.map(isValidDuration) ?? false
            let durMs = valid ? (r.durationMs ?? 0) : 0
            if valid {
                durations.append(durMs)
                if let i = bucketIndex(forMs: durMs) { durationHistogram[i].count += 1 }
            }

            // Text volume — scalar counts, over ALL records (volume is real regardless of duration).
            totalRawChars += r.rawTranscript.unicodeScalars.count
            let editedChars = r.editedTranscript.unicodeScalars.count
            totalEditedChars += editedChars
            totalTokens += TextMetrics.wordTokens(r.editedTranscript).count
            totalCJKChars += r.editedTranscript.unicodeScalars.reduce(0) { TextMetrics.isCJK($1) ? $0 + 1 : $0 }

            // Edit decomposition — eligible records only, normalized (light) both sides so trailing
            // whitespace never reads as an edit and clean ⇔ distance == 0 holds exactly.
            var manualDistance = 0
            var hasManual = false
            if let auto = r.autoEditedTranscript {
                eligibleCount += 1
                hasManual = true
                let baseN = TextMetrics.normalize(auto, mode: .light)
                let editedN = TextMetrics.normalize(r.editedTranscript, mode: .light)
                manualDistance = TextMetrics.editDistanceScalars(baseN, editedN)
                let refLen = baseN.unicodeScalars.count
                sumManualDistance += manualDistance
                sumReferenceLen += refLen
                if manualDistance == 0 { cleanCount += 1 }
                // Empty-reference follows the cer() convention: 0 if edited also empty, else 1.
                let rate: Double = refLen == 0
                    ? (editedN.unicodeScalars.isEmpty ? 0 : 1)
                    : min(1.0, Double(manualDistance) / Double(refLen))
                sumEditRate += rate
                editRateBuckets[editRateBucketIndex(for: rate, clean: manualDistance == 0)].count += 1

                sumAutoFormatDistance += TextMetrics.editDistanceScalars(
                    TextMetrics.normalize(r.rawTranscript, mode: .light), baseN
                )
            }

            // Productivity — valid-duration records only (typing-from-scratch vs speak+fix).
            if valid {
                prodCount += 1
                let typeSec = typingModel.typingSeconds(for: r.editedTranscript)
                let spokenSec = Double(durMs) / 1000.0
                let fixSec = hasManual ? Double(manualDistance) * typingModel.secondsPerChar(forTextLike: r.editedTranscript) : 0
                spokenSeconds += spokenSec
                typingSeconds += typeSec
                fixSeconds += fixSec
                perRecordSavings.append(typeSec - spokenSec - fixSec)
                prodChars += editedChars
            } else {
                missingDurationCount += 1
            }

            // Breakdowns.
            let lang = r.language ?? "unknown"
            accumulate(&langAgg, key: lang, display: lang, ms: durMs)
            accumulate(&modelAgg, key: r.asrModel, display: shortModelName(r.asrModel), ms: durMs)
            if let appKey = r.sourceAppBundleID ?? r.sourceAppName {
                accumulate(&appAgg, key: appKey, display: r.sourceAppName ?? appKey, ms: durMs)
            }
            let day = String(r.createdAt.prefix(10))
            let prior = dayAgg[day] ?? (0, 0)
            dayAgg[day] = (prior.count + 1, prior.ms + durMs)
            if let h = utcHour(of: r.createdAt) { hourHist[h] += 1 }
            if let w = weekday(ofDay: day) { weekdayHist[w] += 1 }
        }

        let n = records.count
        let sortedDur = durations.sorted()
        let audio = AudioSummary(
            totalDurationMs: durations.reduce(0, +),
            meanMs: durations.isEmpty ? 0 : durations.reduce(0, +) / durations.count,
            medianMs: median(sortedDur),
            minMs: sortedDur.first ?? 0,
            maxMs: sortedDur.last ?? 0,
            p90Ms: percentile(sortedDur, 0.90),
            recordsWithDuration: durations.count,
            histogram: durationHistogram
        )

        let text = TextSummary(
            totalRawChars: totalRawChars,
            totalEditedChars: totalEditedChars,
            totalTokens: totalTokens,
            totalCJKChars: totalCJKChars,
            meanCharsPerRecord: totalEditedChars / n
        )

        let editing = EditSummary(
            eligibleCount: eligibleCount,
            cleanCount: cleanCount,
            cleanRate: eligibleCount > 0 ? Double(cleanCount) / Double(eligibleCount) : 0,
            meanEditRate: eligibleCount > 0 ? sumEditRate / Double(eligibleCount) : 0,
            microEditRate: sumReferenceLen > 0 ? Double(sumManualDistance) / Double(sumReferenceLen) : 0,
            totalManualEditDistance: sumManualDistance,
            totalAutoFormatDistance: sumAutoFormatDistance,
            editRateHistogram: editRateBuckets
        )

        let rawTimeSaved = perRecordSavings.reduce(0, +)
        let productivity = ProductivitySummary(
            recordCount: prodCount,
            missingDurationCount: missingDurationCount,
            spokenSeconds: spokenSeconds,
            estimatedTypingSeconds: typingSeconds,
            estimatedFixSeconds: fixSeconds,
            timeSavedSeconds: max(0, rawTimeSaved),
            medianSavingSeconds: medianDouble(perRecordSavings.sorted()),
            charsPerMinute: spokenSeconds > 0 ? Double(prodChars) / (spokenSeconds / 60.0) : 0
        )

        return DatasetStatistics(
            recordCount: n,
            insertedCount: insertedCount,
            firstRecordAt: firstAt,
            lastRecordAt: lastAt,
            activeDayCount: dayAgg.count,
            longestDayStreak: longestStreak(days: Array(dayAgg.keys)),
            audio: audio,
            text: text,
            editing: editing,
            productivity: productivity,
            byLanguage: sortedBreakdowns(langAgg),
            byModel: sortedBreakdowns(modelAgg),
            byApp: sortedBreakdowns(appAgg),
            activityByDay: dayAgg.map { DayBucket(day: $0.key, count: $0.value.count, totalDurationMs: $0.value.ms) }
                .sorted { $0.day < $1.day },
            activityByHourUTC: hourHist,
            activityByWeekday: weekdayHist
        )
    }

    /// A privacy-safe projection for the uploaded `statistics.json` / dataset card. Drops the
    /// source-app breakdown and the dated per-day activity (both behavioral fingerprints); the coarse
    /// weekday/hour histograms + date range stay.
    func publicProjection() -> DatasetStatistics {
        var copy = self
        copy.byApp = []
        copy.activityByDay = []
        // Keep only the date (not time) of the first/last record.
        copy.firstRecordAt = firstRecordDay
        copy.lastRecordAt = lastRecordDay
        return copy
    }

    // MARK: - Helpers

    private static func bucketIndex(forMs ms: Int) -> Int? {
        for (i, e) in durationEdges.enumerated() {
            if ms >= e.lower, e.upper == nil || ms < e.upper! { return i }
        }
        return nil
    }

    private static func editRateBucketIndex(for rate: Double, clean: Bool) -> Int {
        if clean { return 0 }
        for i in 1..<editRateEdges.count where rate <= editRateEdges[i].upper + 1e-9 { return i }
        return editRateEdges.count - 1
    }

    private static func accumulate(_ agg: inout [String: (display: String, count: Int, ms: Int)], key: String, display: String, ms: Int) {
        let prior = agg[key] ?? (display, 0, 0)
        agg[key] = (prior.display, prior.count + 1, prior.ms + ms)
    }

    private static func sortedBreakdowns(_ agg: [String: (display: String, count: Int, ms: Int)]) -> [Breakdown] {
        agg.map { Breakdown(key: $0.key, displayName: $0.value.display, count: $0.value.count, totalDurationMs: $0.value.ms) }
            // Count desc, then key asc for a stable, deterministic order on ties.
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.key < $1.key }
    }

    /// Last path component of a HF model id (`mlx-community/Qwen3-ASR-1.7B-4bit` → `Qwen3-ASR-1.7B-4bit`).
    private static func shortModelName(_ id: String) -> String {
        id.split(separator: "/").last.map(String.init) ?? id
    }

    /// UTC hour-of-day from an ISO8601 `yyyy-MM-ddTHH:...` string, or nil if unparseable.
    private static func utcHour(of createdAt: String) -> Int? {
        let chars = Array(createdAt)
        guard chars.count >= 13, chars[10] == "T" else { return nil }
        guard let h = Int(String(chars[11...12])), (0...23).contains(h) else { return nil }
        return h
    }

    /// Longest run of consecutive calendar days in a set of `yyyy-MM-dd` keys. Converts each day to a
    /// Julian-day ordinal (pure integer math), sorts the distinct ordinals, and walks for the longest
    /// `+1` run.
    private static func longestStreak(days: [String]) -> Int {
        let ordinals = Set(days.compactMap(julianDay)).sorted()
        guard !ordinals.isEmpty else { return 0 }
        var longest = 1, run = 1
        for i in 1..<ordinals.count {
            run = ordinals[i] == ordinals[i - 1] + 1 ? run + 1 : 1
            if run > longest { longest = run }
        }
        return longest
    }

    /// Julian Day Number for a `yyyy-MM-dd` date — a monotonic integer day ordinal, so consecutive
    /// calendar days differ by exactly 1 across month/year boundaries. Pure integer math.
    private static func julianDay(_ day: String) -> Int? {
        let parts = day.split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        let a = (14 - m) / 12
        let yy = y + 4800 - a
        let mm = m + 12 * a - 3
        return d + (153 * mm + 2) / 5 + 365 * yy + yy / 4 - yy / 100 + yy / 400 - 32045
    }

    /// Weekday (0 = Sunday … 6 = Saturday) for a `yyyy-MM-dd` date via Sakamoto's algorithm. Pure
    /// integer math — deterministic and timezone-free (the date is already UTC).
    private static func weekday(ofDay day: String) -> Int? {
        let parts = day.split(separator: "-")
        guard parts.count == 3, var y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        let t = [0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4]
        if m < 3 { y -= 1 }
        return ((y + y / 4 - y / 100 + y / 400 + t[m - 1] + d) % 7 + 7) % 7
    }

    /// Median of a pre-sorted ascending Int array (average of the two middles for even N).
    private static func median(_ sorted: [Int]) -> Int {
        guard !sorted.isEmpty else { return 0 }
        let n = sorted.count
        return n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }

    private static func medianDouble(_ sorted: [Double]) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let n = sorted.count
        return n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }

    /// Nearest-rank percentile (type R-1) of a pre-sorted ascending array. `p` in `[0, 1]`.
    private static func percentile(_ sorted: [Int], _ p: Double) -> Int {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((p * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank - 1, 0), sorted.count - 1)]
    }
}

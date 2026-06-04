import SwiftUI
import Charts

/// The Settings home page (first sidebar item, default landing): a motivational dashboard + the
/// achievement wall. Reads the shared `AchievementService` — which is both the cached statistics
/// source and the unlock state — so opening here refreshes the numbers and the badges in one pass.
struct InsightsPane: View {
    @Environment(AppContainer.self) private var container
    @State private var showTimeSavedInfo = false

    var body: some View {
        let svc = container.achievements
        ScrollView {
            Group {
                if !svc.hasLoaded {
                    loadingState
                } else if svc.stats.isEmpty {
                    emptyState
                } else {
                    dashboard(svc.stats, svc)
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(20)
        }
        .frame(maxWidth: .infinity)
        .task { await svc.refresh() }
    }

    // MARK: - Dashboard

    @ViewBuilder
    private func dashboard(_ s: DatasetStatistics, _ svc: AchievementService) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            header(s)
            heroTrio(s)
            retentionHook(s)
            achievementsSection(s, svc)
            activitySection(s)
            lengthSection(s)
            modelsSection(s)
            appsSection(s)
        }
    }

    @ViewBuilder
    private func header(_ s: DatasetStatistics) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Your dictation")
                .font(.system(.title2, design: .rounded).weight(.bold))
            Text(rangeSubtitle(s))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func rangeSubtitle(_ s: DatasetStatistics) -> String {
        let sessions = String(localized: "\(s.recordCount) sessions")
        guard let first = s.firstRecordDay, let last = s.lastRecordDay else { return sessions }
        let span = first == last ? StatFmt.prettyDay(first) : "\(StatFmt.prettyDay(first)) – \(StatFmt.prettyDay(last))"
        return "\(span) · \(sessions) · \(String(localized: "\(s.activeDayCount) active days"))"
    }

    // MARK: - Hero trio (measured facts first, estimate last)

    @ViewBuilder
    private func heroTrio(_ s: DatasetStatistics) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 14)], spacing: 14) {
            HeroCard(tone: .accent, value: StatFmt.count(s.text.totalEditedChars),
                     title: String(localized: "characters dictated"),
                     caption: String(localized: "~\(StatFmt.count(s.text.totalTokens)) tokens"))
            cleanCard(s)
            timeSavedCard(s)
        }
    }

    @ViewBuilder
    private func cleanCard(_ s: DatasetStatistics) -> some View {
        // Plain description — no version note.
        if s.editing.eligibleCount == 0 {
            HeroCard(tone: .neutral, value: "—",
                     title: String(localized: "came out clean"),
                     caption: String(localized: "inserted with no manual edits"))
        } else {
            HeroCard(tone: .good, value: StatFmt.percent(s.editing.cleanRate),
                     title: String(localized: "came out clean"),
                     caption: String(localized: "\(s.editing.cleanCount) of \(s.editing.eligibleCount) inserted with no edits"))
        }
    }

    @ViewBuilder
    private func timeSavedCard(_ s: DatasetStatistics) -> some View {
        HeroCard(tone: .plain, value: "~\(StatFmt.duration(seconds: s.productivity.timeSavedSeconds))",
                 title: String(localized: "time saved"),
                 caption: String(localized: "estimated vs. typing"),
                 accessory: {
            Button { showTimeSavedInfo = true } label: {
                Image(systemName: "info.circle").imageScale(.small).foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .popover(isPresented: $showTimeSavedInfo, arrowEdge: .bottom) { timeSavedExplanation(s) }
        })
    }

    @ViewBuilder
    private func timeSavedExplanation(_ s: DatasetStatistics) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How is this estimated?").font(.headline)
            Text("We compare the time it would take to **type** your final text against the time you actually spent **speaking**, minus the time spent fixing the transcript.")
                .font(.callout)
            Text(TypingModel.default.assumptionDescription).font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("Based on \(s.productivity.recordCount) recordings with a measured length.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 320)
    }

    // MARK: - Retention hook

    @ViewBuilder
    private func retentionHook(_ s: DatasetStatistics) -> some View {
        let weekly = WeeklyActivity(stats: s)
        let streak = CurrentStreak(stats: s)
        let milestone = StatFmt.nextMilestone(after: s.recordCount)
        HStack(spacing: 14) {
            Label {
                Text("This week: \(weekly.thisWeek) sessions")
                if let arrow = weekly.deltaArrow {
                    Text(arrow).foregroundStyle(weekly.up ? Color.green : Color.secondary)
                }
            } icon: { Image(systemName: "calendar") }
            // Live current streak only (consecutive days ending today/yesterday) — not the all-time
            // best, which would glow even after the user stopped dictating weeks ago.
            if streak.days >= 2 {
                Divider().frame(height: 14)
                Label("\(streak.days)-day streak", systemImage: "flame.fill")
                    .foregroundStyle(.orange)
            }
            if let milestone {
                Divider().frame(height: 14)
                Label("\(milestone - s.recordCount) to \(StatFmt.count(milestone)) sessions", systemImage: "flag.checkered")
            }
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.vertical, 10).padding(.horizontal, 14)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Achievements

    @ViewBuilder
    private func achievementsSection(_ s: DatasetStatistics, _ svc: AchievementService) -> some View {
        let unlocked = svc.unlockedIDs
        OverviewCard(title: String(localized: "Achievements"),
                     subtitle: "\(unlocked.count) / \(Achievement.all.count)") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 165), spacing: 10)], spacing: 10) {
                ForEach(Achievement.all) { a in
                    AchievementBadge(achievement: a, stats: s, unlocked: unlocked.contains(a.id))
                }
            }
        }
    }

    // MARK: - Activity

    @ViewBuilder
    private func activitySection(_ s: DatasetStatistics) -> some View {
        let series = ActivitySeries(stats: s, days: 30)
        OverviewCard(title: String(localized: "Activity"), subtitle: String(localized: "last 30 days")) {
            if series.points.allSatisfy({ $0.count == 0 }) {
                Text("No sessions in the last 30 days.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Chart(series.points) { p in
                    BarMark(x: .value("Day", p.date, unit: .day), y: .value("Sessions", p.count))
                        .foregroundStyle(Color.accentColor.gradient)
                        .cornerRadius(2)
                }
                .chartYAxis { AxisMarks(position: .leading) }
                .frame(height: 120)
            }
        }
    }

    // MARK: - Recording length (Total + Median only)

    @ViewBuilder
    private func lengthSection(_ s: DatasetStatistics) -> some View {
        OverviewCard(title: String(localized: "Recording length"), subtitle: lengthSubtitle(s)) {
            VStack(alignment: .leading, spacing: 12) {
                if s.audio.recordsWithDuration > 0 {
                    Chart(s.audio.histogram, id: \.label) { b in
                        BarMark(x: .value("Range", b.label), y: .value("Count", b.count))
                            .foregroundStyle(Color.teal.gradient)
                            .cornerRadius(3)
                    }
                    .chartYAxis { AxisMarks(position: .leading) }
                    .frame(height: 130)
                }
                HStack(spacing: 18) {
                    MiniStat(label: String(localized: "Total"), value: StatFmt.duration(seconds: Double(s.audio.totalDurationMs) / 1000))
                    MiniStat(label: String(localized: "Median"), value: StatFmt.durationMs(s.audio.medianMs))
                }
            }
        }
    }

    private func lengthSubtitle(_ s: DatasetStatistics) -> String {
        s.productivity.missingDurationCount > 0
            ? String(localized: "\(s.audio.recordsWithDuration) timed · \(s.productivity.missingDurationCount) without a length")
            : String(localized: "\(s.audio.recordsWithDuration) recordings")
    }

    // MARK: - Models

    @ViewBuilder
    private func modelsSection(_ s: DatasetStatistics) -> some View {
        let models = Array(s.byModel.prefix(5))
        if !models.isEmpty {
            OverviewCard(title: String(localized: "Models")) {
                BreakdownBars(items: models, total: s.recordCount, tint: .purple)
            }
        }
    }

    // MARK: - Apps (no privacy subtitle — this whole surface is local)

    @ViewBuilder
    private func appsSection(_ s: DatasetStatistics) -> some View {
        let apps = Array(s.byApp.prefix(6))
        if !apps.isEmpty {
            OverviewCard(title: String(localized: "Where you dictate")) {
                VStack(spacing: 8) {
                    ForEach(apps) { app in
                        HStack(spacing: 10) {
                            if let icon = AppIcons.icon(forBundleID: app.key) {
                                Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                            } else {
                                Image(systemName: "app.dashed").foregroundStyle(.tertiary).frame(width: 18, height: 18)
                            }
                            Text(app.displayName).font(.callout).lineLimit(1)
                            Spacer()
                            Text("\(app.count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Empty / loading

    @ViewBuilder
    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Crunching your numbers…").font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.bar.xaxis").font(.system(size: 34)).foregroundStyle(.tertiary)
            Text("Your insights appear after your first save").font(.headline)
            Text("Press the hotkey, dictate, then choose Insert & save. Your time saved, accuracy, and dataset shape show up here.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
        .padding(24)
    }
}

// MARK: - Reusable components

private struct HeroCard<Accessory: View>: View {
    enum Tone { case accent, good, plain, neutral }
    let tone: Tone
    let value: String
    let title: String
    let caption: String
    @ViewBuilder var accessory: () -> Accessory

    init(tone: Tone, value: String, title: String, caption: String,
         @ViewBuilder accessory: @escaping () -> Accessory) {
        self.tone = tone; self.value = value; self.title = title; self.caption = caption; self.accessory = accessory
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                Text(value)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(valueColor).minimumScaleFactor(0.5).lineLimit(1)
                Spacer()
                accessory()
            }
            Text(title).font(.subheadline.weight(.semibold))
            Text(caption).font(.caption).foregroundStyle(.secondary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .padding(14)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }

    private var valueColor: Color {
        switch tone {
        case .accent: return .accentColor
        case .good: return .green
        case .plain: return .primary
        case .neutral: return .secondary
        }
    }
}

extension HeroCard where Accessory == EmptyView {
    /// No-accessory convenience — an explicit overload (rather than a defaulted closure) so the
    /// generic `Accessory` is inferred cleanly (the default-expression form warns as a future error).
    init(tone: Tone, value: String, title: String, caption: String) {
        self.init(tone: tone, value: value, title: title, caption: caption, accessory: { EmptyView() })
    }
}

private struct OverviewCard<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder let content: () -> Content

    init(title: String, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.subtitle = subtitle; self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(.headline)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct MiniStat: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.weight(.semibold).monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct BreakdownBars: View {
    let items: [DatasetStatistics.Breakdown]
    let total: Int
    let tint: Color

    var body: some View {
        VStack(spacing: 8) {
            ForEach(items) { item in
                let frac = total > 0 ? Double(item.count) / Double(total) : 0
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(item.displayName).font(.callout).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text("\(item.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.15))
                            Capsule().fill(tint.gradient).frame(width: max(3, geo.size.width * frac))
                        }
                    }
                    .frame(height: 5)
                }
            }
        }
    }
}

private struct AchievementBadge: View {
    let achievement: Achievement
    let stats: DatasetStatistics
    let unlocked: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(unlocked ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.1))
                    .frame(width: 38, height: 38)
                Image(systemName: achievement.symbol)
                    .foregroundStyle(unlocked ? Color.accentColor : Color.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(achievement.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(unlocked ? .primary : .secondary)
                    .lineLimit(1)
                if unlocked {
                    Text(achievement.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    ProgressView(value: achievement.progress(stats)).controlSize(.mini)
                    Text(verbatim: "\(StatFmt.count(achievement.current(stats))) / \(StatFmt.count(achievement.target))")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(Color.secondary.opacity(unlocked ? 0.09 : 0.03), in: RoundedRectangle(cornerRadius: 10))
        .opacity(unlocked ? 1 : 0.9)
        .help(unlocked ? achievement.detail : "")
    }
}

// MARK: - View-side derived helpers (live clock; cheap)

/// "This week vs last" using UTC day strings so it lines up with the engine's day bucketing.
/// Internal (not private) so the UTC-windowing contract can be regression-tested.
struct WeeklyActivity {
    let thisWeek: Int
    let lastWeek: Int

    init(stats: DatasetStatistics, now: Date = Date()) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        func dayString(_ date: Date) -> String { Self.fmt.string(from: date) }
        let today = cal.startOfDay(for: now)
        let thisWeekStart = cal.date(byAdding: .day, value: -6, to: today) ?? today
        let lastWeekStart = cal.date(byAdding: .day, value: -13, to: today) ?? today
        let thisLo = dayString(thisWeekStart), lastLo = dayString(lastWeekStart)
        var tw = 0, lw = 0
        for d in stats.activityByDay {
            if d.day >= thisLo { tw += d.count }
            else if d.day >= lastLo { lw += d.count }
        }
        self.thisWeek = tw
        self.lastWeek = lw
    }

    var up: Bool { thisWeek >= lastWeek }
    var deltaArrow: String? {
        guard lastWeek > 0 || thisWeek > 0, thisWeek != lastWeek else { return nil }
        return thisWeek > lastWeek ? "▲" : "▼"
    }

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

/// The user's CURRENT consecutive-day run, counted back from today (or yesterday, as a grace day so
/// the streak doesn't read as broken before today's first dictation). 0 when the most recent active
/// day is older than that. Internal so it can be unit-tested. UTC to match the engine's day keys.
struct CurrentStreak {
    let days: Int

    init(stats: DatasetStatistics, now: Date = Date()) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let active = Set(stats.activityByDay.map(\.day))
        func key(_ d: Date) -> String { Self.fmt.string(from: d) }
        let today = cal.startOfDay(for: now)
        let yesterday = cal.date(byAdding: .day, value: -1, to: today) ?? today

        let anchor: Date
        if active.contains(key(today)) { anchor = today }
        else if active.contains(key(yesterday)) { anchor = yesterday }
        else { self.days = 0; return }

        var count = 0
        var cursor = anchor
        while active.contains(key(cursor)) {
            count += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        self.days = count
    }

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

/// Dense daily series for the activity chart — fills gaps with 0 so the axis is continuous.
/// Internal (not private) so the UTC-windowing contract can be regression-tested.
struct ActivitySeries {
    struct Point: Identifiable { let date: Date; let count: Int; var id: Date { date } }
    let points: [Point]

    init(stats: DatasetStatistics, days: Int, now: Date = Date()) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let counts = Dictionary(uniqueKeysWithValues: stats.activityByDay.map { ($0.day, $0.count) })
        let today = cal.startOfDay(for: now)
        var pts: [Point] = []
        for offset in stride(from: days - 1, through: 0, by: -1) {
            guard let date = cal.date(byAdding: .day, value: -offset, to: today) else { continue }
            pts.append(Point(date: date, count: counts[Self.fmt.string(from: date)] ?? 0))
        }
        self.points = pts
    }

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

// MARK: - Formatting

enum StatFmt {
    static func count(_ n: Int) -> String { grouping.string(from: NSNumber(value: n)) ?? "\(n)" }

    static func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }

    static func duration(seconds: Double) -> String {
        if seconds < 1 { return String(localized: "0 sec") }
        if seconds < 90 { return String(localized: "\(Int(seconds.rounded())) sec") }
        let minutes = seconds / 60
        if minutes < 90 { return String(localized: "\(Int(minutes.rounded())) min") }
        return String(format: "%.1f ", minutes / 60) + String(localized: "hr")
    }

    static func durationMs(_ ms: Int) -> String {
        let seconds = Double(ms) / 1000
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let m = Int(seconds) / 60, s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }

    static func prettyDay(_ yyyymmdd: String) -> String {
        guard let date = isoDay.date(from: yyyymmdd) else { return yyyymmdd }
        return medium.string(from: date)
    }

    static func nextMilestone(after n: Int) -> Int? {
        [10, 25, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000].first { $0 > n }
    }

    private static let grouping: NumberFormatter = {
        let f = NumberFormatter(); f.numberStyle = .decimal; return f
    }()
    private static let isoDay: DateFormatter = {
        let f = DateFormatter(); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    private static let medium: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none
        f.timeZone = TimeZone(secondsFromGMT: 0); return f
    }()
}

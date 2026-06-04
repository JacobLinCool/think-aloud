import SwiftUI
import Charts

/// The dataset window's overview — shown in the detail pane when no record is selected. One surface,
/// two audiences: a motivational top (characters dictated, "came out clean", estimated time saved)
/// for the app user, and the dataset's shape (duration distribution, breakdowns, cadence) for the
/// dataset consumer. Reads the cached `controller.statistics`; never computes during render.
struct DatasetOverviewView: View {
    let controller: DatasetBrowserController

    @State private var showTimeSavedInfo = false

    private let contentMaxWidth: CGFloat = 720

    var body: some View {
        Group {
            if let stats = controller.statistics, !stats.isEmpty {
                ScrollView {
                    dashboard(stats)
                        .frame(maxWidth: contentMaxWidth, alignment: .leading)
                        .padding(24)
                }
                .frame(maxWidth: .infinity)
            } else if controller.statistics == nil && controller.statisticsLoading {
                loadingState
            } else {
                emptyState
            }
        }
        .task {
            if controller.statistics == nil { await controller.loadStatistics() }
        }
    }

    // MARK: - Dashboard

    @ViewBuilder
    private func dashboard(_ s: DatasetStatistics) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            header(s)
            heroTrio(s)
            retentionHook(s)
            activitySection(s)
            datasetShapeSection(s)
            breakdownsSection(s)
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
        let days = String(localized: "\(s.activeDayCount) active days")
        return "\(span) · \(sessions) · \(days)"
    }

    // MARK: - Hero trio (credibility order: measured facts first, estimate last)

    @ViewBuilder
    private func heroTrio(_ s: DatasetStatistics) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 14)], spacing: 14) {
            // 1. Unimpeachable: characters dictated.
            HeroCard(
                tone: .accent,
                value: StatFmt.count(s.text.totalEditedChars),
                title: String(localized: "characters dictated"),
                caption: String(localized: "~\(StatFmt.count(s.text.totalTokens)) tokens")
            )
            // 2. Measured accuracy proxy: came out clean.
            cleanCard(s)
            // 3. Estimated, clearly labelled, with disclosure.
            timeSavedCard(s)
        }
    }

    @ViewBuilder
    private func cleanCard(_ s: DatasetStatistics) -> some View {
        if s.editing.eligibleCount == 0 {
            HeroCard(
                tone: .neutral,
                value: "—",
                title: String(localized: "came out clean"),
                caption: String(localized: "Shown for recordings made in v0.4.0+")
            )
        } else {
            HeroCard(
                tone: .good,
                value: StatFmt.percent(s.editing.cleanRate),
                title: String(localized: "came out clean"),
                caption: String(localized: "\(s.editing.cleanCount) of \(s.editing.eligibleCount) inserted with no edits")
            )
        }
    }

    @ViewBuilder
    private func timeSavedCard(_ s: DatasetStatistics) -> some View {
        HeroCard(
            tone: .plain,
            value: "~\(StatFmt.duration(seconds: s.productivity.timeSavedSeconds))",
            title: String(localized: "time saved"),
            caption: String(localized: "estimated vs. typing"),
            accessory: {
                Button {
                    showTimeSavedInfo = true
                } label: {
                    Image(systemName: "info.circle")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .popover(isPresented: $showTimeSavedInfo, arrowEdge: .bottom) {
                    timeSavedExplanation(s)
                }
            }
        )
    }

    @ViewBuilder
    private func timeSavedExplanation(_ s: DatasetStatistics) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How is this estimated?")
                .font(.headline)
            Text("We compare the time it would take to **type** your final text against the time you actually spent **speaking**, minus the time spent fixing the transcript.")
                .font(.callout)
            Text(TypingModel.default.assumptionDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            Text("Based on \(s.productivity.recordCount) recordings with a measured length.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 320)
    }

    // MARK: - Retention hook (one line, no gamification)

    @ViewBuilder
    private func retentionHook(_ s: DatasetStatistics) -> some View {
        let weekly = WeeklyActivity(stats: s)
        let milestone = StatFmt.nextMilestone(after: s.recordCount)
        HStack(spacing: 14) {
            Label {
                Text("This week: \(weekly.thisWeek) sessions")
                if let arrow = weekly.deltaArrow {
                    Text(arrow).foregroundStyle(weekly.up ? Color.green : Color.secondary)
                }
            } icon: {
                Image(systemName: "calendar")
            }
            if let milestone {
                Divider().frame(height: 14)
                Label("\(milestone - s.recordCount) to \(StatFmt.count(milestone)) sessions", systemImage: "flag.checkered")
            }
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Activity (local, dated 30-day)

    @ViewBuilder
    private func activitySection(_ s: DatasetStatistics) -> some View {
        let series = ActivitySeries(stats: s, days: 30)
        OverviewCard(title: String(localized: "Activity"), subtitle: String(localized: "last 30 days")) {
            if series.points.allSatisfy({ $0.count == 0 }) {
                Text("No sessions in the last 30 days.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Chart(series.points) { p in
                    BarMark(
                        x: .value("Day", p.date, unit: .day),
                        y: .value("Sessions", p.count)
                    )
                    .foregroundStyle(Color.accentColor.gradient)
                    .cornerRadius(2)
                }
                .chartYAxis { AxisMarks(position: .leading) }
                .frame(height: 120)
            }
        }
    }

    // MARK: - Dataset shape (audience B)

    @ViewBuilder
    private func datasetShapeSection(_ s: DatasetStatistics) -> some View {
        OverviewCard(title: String(localized: "Recording length"), subtitle: lengthSubtitle(s)) {
            VStack(alignment: .leading, spacing: 12) {
                if s.audio.recordsWithDuration > 0 {
                    Chart(s.audio.histogram, id: \.label) { b in
                        BarMark(
                            x: .value("Range", b.label),
                            y: .value("Count", b.count)
                        )
                        .foregroundStyle(Color.teal.gradient)
                        .cornerRadius(3)
                    }
                    .chartYAxis { AxisMarks(position: .leading) }
                    .frame(height: 130)
                }
                HStack(spacing: 18) {
                    MiniStat(label: String(localized: "Total"), value: StatFmt.duration(seconds: Double(s.audio.totalDurationMs) / 1000))
                    MiniStat(label: String(localized: "Median"), value: StatFmt.durationMs(s.audio.medianMs))
                    // p90 is meaningless on a handful of samples — show it only at scale.
                    if s.audio.recordsWithDuration >= 10 {
                        MiniStat(label: String(localized: "90th pct"), value: StatFmt.durationMs(s.audio.p90Ms))
                    } else {
                        MiniStat(label: String(localized: "Longest"), value: StatFmt.durationMs(s.audio.maxMs))
                    }
                    if s.text.totalEditedChars > 0 {
                        MiniStat(label: String(localized: "Chinese"), value: StatFmt.percent(Double(s.text.totalCJKChars) / Double(s.text.totalEditedChars)))
                    }
                }
            }
        }
    }

    private func lengthSubtitle(_ s: DatasetStatistics) -> String {
        s.productivity.missingDurationCount > 0
            ? String(localized: "\(s.audio.recordsWithDuration) timed · \(s.productivity.missingDurationCount) without a length")
            : String(localized: "\(s.audio.recordsWithDuration) recordings")
    }

    // MARK: - Breakdowns

    @ViewBuilder
    private func breakdownsSection(_ s: DatasetStatistics) -> some View {
        let langs = Array(s.byLanguage.prefix(5))
        let models = Array(s.byModel.prefix(5))
        if !langs.isEmpty || !models.isEmpty {
            HStack(alignment: .top, spacing: 14) {
                if !langs.isEmpty {
                    OverviewCard(title: String(localized: "Languages")) {
                        BreakdownBars(items: langs, total: s.recordCount, tint: .blue)
                    }
                }
                if !models.isEmpty {
                    OverviewCard(title: String(localized: "Models")) {
                        BreakdownBars(items: models, total: s.recordCount, tint: .purple)
                    }
                }
            }
        }
    }

    // MARK: - Apps (local only)

    @ViewBuilder
    private func appsSection(_ s: DatasetStatistics) -> some View {
        let apps = Array(s.byApp.prefix(6))
        if !apps.isEmpty {
            OverviewCard(
                title: String(localized: "Where you dictate"),
                subtitle: String(localized: "On this Mac only · never uploaded")
            ) {
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
            Text("Crunching your numbers…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("Your insights appear after your first save")
                .font(.headline)
            Text("Press the hotkey, dictate, then choose Insert & save. Your time saved, accuracy, and dataset shape show up here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

// MARK: - Reusable components

/// Big single-stat card. `tone` tints the value.
private struct HeroCard<Accessory: View>: View {
    enum Tone { case accent, good, plain, neutral }
    let tone: Tone
    let value: String
    // Already-localized strings (call sites use String(localized:) / computed text). Text renders
    // them verbatim, which is correct since they're resolved upstream.
    let title: String
    let caption: String
    @ViewBuilder var accessory: () -> Accessory

    init(tone: Tone, value: String, title: String, caption: String,
         @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }) {
        self.tone = tone
        self.value = value
        self.title = title
        self.caption = caption
        self.accessory = accessory
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                Text(value)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(valueColor)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                Spacer()
                accessory()
            }
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
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

/// Titled rounded container for a chart or list.
private struct OverviewCard<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder let content: () -> Content

    init(title: String, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(.headline)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
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

/// Horizontal proportion bars for a breakdown (language / model).
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

// MARK: - View-side derived helpers (use the live clock; cheap, computed in body)

/// "This week vs last" using UTC day strings so it lines up with the engine's day bucketing.
private struct WeeklyActivity {
    let thisWeek: Int
    let lastWeek: Int

    init(stats: DatasetStatistics, now: Date = Date()) {
        let cal = Calendar(identifier: .gregorian)
        func dayString(_ date: Date) -> String { Self.fmt.string(from: date) }
        let today = cal.startOfDay(for: now)
        let weekAgo = cal.date(byAdding: .day, value: -7, to: today) ?? today
        let twoWeeksAgo = cal.date(byAdding: .day, value: -14, to: today) ?? today
        let thisLo = dayString(weekAgo), lastLo = dayString(twoWeeksAgo), lastHi = dayString(weekAgo)
        var tw = 0, lw = 0
        for d in stats.activityByDay {
            if d.day >= thisLo { tw += d.count }
            else if d.day >= lastLo && d.day < lastHi { lw += d.count }
        }
        self.thisWeek = tw
        self.lastWeek = lw
    }

    var up: Bool { thisWeek >= lastWeek }
    var deltaArrow: String? {
        guard lastWeek > 0 || thisWeek > 0 else { return nil }
        if thisWeek == lastWeek { return nil }
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

/// Dense daily series for the activity chart — fills gaps with 0 so the axis is continuous.
private struct ActivitySeries {
    struct Point: Identifiable { let date: Date; let count: Int; var id: Date { date } }
    let points: [Point]

    init(stats: DatasetStatistics, days: Int, now: Date = Date()) {
        let cal = Calendar(identifier: .gregorian)
        let counts = Dictionary(uniqueKeysWithValues: stats.activityByDay.map { ($0.day, $0.count) })
        let today = cal.startOfDay(for: now)
        var pts: [Point] = []
        for offset in stride(from: days - 1, through: 0, by: -1) {
            guard let date = cal.date(byAdding: .day, value: -offset, to: today) else { continue }
            let key = Self.fmt.string(from: date)
            pts.append(Point(date: date, count: counts[key] ?? 0))
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
    static func count(_ n: Int) -> String {
        Self.grouping.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    static func percent(_ fraction: Double) -> String {
        let pct = (fraction * 100).rounded()
        return "\(Int(pct))%"
    }

    /// Human duration from seconds: "~2.4 hr", "18 min", "45 sec".
    static func duration(seconds: Double) -> String {
        if seconds < 1 { return String(localized: "0 sec") }
        if seconds < 90 { return String(localized: "\(Int(seconds.rounded())) sec") }
        let minutes = seconds / 60
        if minutes < 90 { return String(localized: "\(Int(minutes.rounded())) min") }
        let hours = minutes / 60
        return String(format: "%.1f ", hours) + String(localized: "hr")
    }

    /// Compact length for a single recording: "3.2s" or "1:05".
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
        let milestones = [10, 25, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000]
        return milestones.first { $0 > n }
    }

    private static let grouping: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()
    private static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private static let medium: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
}

import AppKit
import SwiftUI

struct RecordRowView: View {
    let record: DatasetRecord

    var body: some View {
        // Parse the ISO timestamp ONCE per body eval and feed both labels. Previously each label
        // re-parsed it (two parses) AND constructed a fresh formatter — heavy per-row-per-frame
        // work that dropped frames while scrolling.
        let date = Self.iso.date(from: record.createdAt)
        HStack(alignment: .top, spacing: 10) {
            iconView
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(relativeTimeLabel(for: date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(shortClockLabel(for: date))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    if let app = record.sourceAppName {
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text(app)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(durationLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Text(snippet)
                    .font(.body)
                    .lineLimit(2)
                    .foregroundStyle(.primary)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var iconView: some View {
        if let icon = AppIcons.icon(forBundleID: record.sourceAppBundleID) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 20, height: 20)
        } else {
            Image(systemName: "app.dashed")
                .resizable()
                .frame(width: 18, height: 18)
                .foregroundStyle(.tertiary)
        }
    }

    private var snippet: String {
        let text = record.editedTranscript.isEmpty ? record.rawTranscript : record.editedTranscript
        return text.isEmpty ? String(localized: "(empty)") : text
    }

    private var durationLabel: String {
        guard let ms = record.durationMs else { return "—" }
        let seconds = Double(ms) / 1000.0
        if seconds < 60 {
            return String(format: "%.1fs", seconds)
        }
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }

    private func relativeTimeLabel(for date: Date?) -> String {
        guard let date else { return record.createdAt }
        return Self.relative.localizedString(for: date, relativeTo: Date())
    }

    /// "HH:mm" for same-day records, "M/d HH:mm" for older entries. Lets users locate a record
    /// without hovering for the tooltip.
    private func shortClockLabel(for date: Date?) -> String {
        guard let date else { return "" }
        // Two pre-built formatters instead of mutating one shared `dateFormat` per call.
        let formatter = Calendar.current.isDateInToday(date) ? Self.clockToday : Self.clockOther
        return formatter.string(from: date)
    }

    // Formatters are expensive to construct (each builds an ICU backing object). Build them once
    // and reuse across every row + every re-render. Accessed only from SwiftUI body (MainActor).
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private static let clockToday: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let clockOther: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = "M/d HH:mm"
        return f
    }()
}

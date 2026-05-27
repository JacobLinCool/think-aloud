import AppKit
import SwiftUI

struct RecordRowView: View {
    let record: DatasetRecord

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            iconView
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(relativeTimeLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(shortClockLabel)
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

    private var relativeTimeLabel: String {
        guard let date = Self.iso.date(from: record.createdAt) else { return record.createdAt }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }

    /// "HH:mm" for same-day records, "M/d HH:mm" for older entries. Lets users locate a record
    /// without hovering for the tooltip.
    private var shortClockLabel: String {
        guard let date = Self.iso.date(from: record.createdAt) else { return "" }
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = .current
        if cal.isDateInToday(date) {
            f.dateFormat = "HH:mm"
        } else {
            f.dateFormat = "M/d HH:mm"
        }
        return f.string(from: date)
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

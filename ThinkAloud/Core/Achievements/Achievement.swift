import Foundation

/// A single unlockable milestone, evaluated from `DatasetStatistics`. A curated set — tasteful, not
/// exhaustive — spanning the dimensions a dictation habit naturally grows along: how often, how long,
/// how much, how consistently, and how broadly you use the app.
struct Achievement: Identifiable, Sendable {
    /// Tags each achievement's dimension (metadata; the badge wall renders a flat grid).
    enum Dimension: String, Sendable {
        case sessions, recordingTime, characters, streak, models, apps, polished
    }

    let id: String
    let dimension: Dimension
    let symbol: String
    let title: String
    let detail: String
    let target: Int
    /// The user's current running total for this achievement's dimension. `@Sendable` (the closures
    /// capture nothing) so the static catalogue is concurrency-safe under Swift 6.
    let value: @Sendable (DatasetStatistics) -> Int

    func current(_ s: DatasetStatistics) -> Int { value(s) }
    func isUnlocked(_ s: DatasetStatistics) -> Bool { value(s) >= target }
    func progress(_ s: DatasetStatistics) -> Double {
        target > 0 ? min(1, Double(value(s)) / Double(target)) : 1
    }

    /// The set of achievement ids currently satisfied by `stats` (pure).
    static func satisfied(by stats: DatasetStatistics) -> Set<String> {
        Set(all.filter { $0.isUnlocked(stats) }.map(\.id))
    }

    /// Curated catalogue. IDs are stable tokens (persisted), so never renumber an existing one.
    static let all: [Achievement] = [
        // Sessions — how often you dictate.
        Achievement(id: "sessions.10", dimension: .sessions, symbol: "mic.fill",
                    title: String(localized: "First Words"), detail: String(localized: "Dictate 10 times"),
                    target: 10, value: { $0.recordCount }),
        Achievement(id: "sessions.100", dimension: .sessions, symbol: "waveform",
                    title: String(localized: "Finding Your Voice"), detail: String(localized: "Dictate 100 times"),
                    target: 100, value: { $0.recordCount }),
        Achievement(id: "sessions.1000", dimension: .sessions, symbol: "medal.fill",
                    title: String(localized: "Voice Veteran"), detail: String(localized: "Dictate 1,000 times"),
                    target: 1000, value: { $0.recordCount }),

        // Recording time — minutes of speech.
        Achievement(id: "time.30", dimension: .recordingTime, symbol: "clock.fill",
                    title: String(localized: "Warmed Up"), detail: String(localized: "Record 30 minutes"),
                    target: 30, value: { $0.audio.totalDurationMs / 60_000 }),
        Achievement(id: "time.180", dimension: .recordingTime, symbol: "clock.badge.checkmark.fill",
                    title: String(localized: "In the Flow"), detail: String(localized: "Record 3 hours"),
                    target: 180, value: { $0.audio.totalDurationMs / 60_000 }),
        Achievement(id: "time.720", dimension: .recordingTime, symbol: "hourglass",
                    title: String(localized: "Marathon Speaker"), detail: String(localized: "Record 12 hours"),
                    target: 720, value: { $0.audio.totalDurationMs / 60_000 }),

        // Characters — volume of text.
        Achievement(id: "chars.1000", dimension: .characters, symbol: "textformat",
                    title: String(localized: "Wordsmith"), detail: String(localized: "Dictate 1,000 characters"),
                    target: 1_000, value: { $0.text.totalEditedChars }),
        Achievement(id: "chars.25000", dimension: .characters, symbol: "text.book.closed.fill",
                    title: String(localized: "Novelist"), detail: String(localized: "Dictate 25,000 characters"),
                    target: 25_000, value: { $0.text.totalEditedChars }),
        Achievement(id: "chars.250000", dimension: .characters, symbol: "books.vertical.fill",
                    title: String(localized: "Prolific"), detail: String(localized: "Dictate 250,000 characters"),
                    target: 250_000, value: { $0.text.totalEditedChars }),

        // Streaks — consecutive days.
        Achievement(id: "streak.3", dimension: .streak, symbol: "flame",
                    title: String(localized: "Habit Forming"), detail: String(localized: "Use 3 days in a row"),
                    target: 3, value: { $0.longestDayStreak }),
        Achievement(id: "streak.7", dimension: .streak, symbol: "flame.fill",
                    title: String(localized: "Weeklong"), detail: String(localized: "Use 7 days in a row"),
                    target: 7, value: { $0.longestDayStreak }),
        Achievement(id: "streak.30", dimension: .streak, symbol: "flame.circle.fill",
                    title: String(localized: "Unstoppable"), detail: String(localized: "Use 30 days in a row"),
                    target: 30, value: { $0.longestDayStreak }),

        // Breadth.
        Achievement(id: "models.3", dimension: .models, symbol: "cpu",
                    title: String(localized: "Explorer"), detail: String(localized: "Try 3 different models"),
                    target: 3, value: { $0.byModel.count }),
        Achievement(id: "apps.5", dimension: .apps, symbol: "square.grid.2x2.fill",
                    title: String(localized: "Everywhere"), detail: String(localized: "Dictate into 5 different apps"),
                    target: 5, value: { $0.byApp.count }),

        // Editing — transcripts you refined.
        Achievement(id: "polished.50", dimension: .polished, symbol: "pencil.and.outline",
                    title: String(localized: "Editor"), detail: String(localized: "Polish 50 transcripts"),
                    target: 50, value: { max(0, $0.editing.eligibleCount - $0.editing.cleanCount) }),
    ]
}

import Foundation
import Observation

enum PopupPhase: Equatable {
    case idle
    case recording
    case transcribing
    /// The AI Refine (LLM) stage is rewriting the transcript — it streams into `editedTranscript`
    /// live. Cancellable: ⌥Space / insert aborts it and inserts what's shown.
    case polishing
    case review
    case error(String)
}

@MainActor
@Observable
final class PopupViewModel {
    var phase: PopupPhase = .idle
    var elapsedSeconds: TimeInterval = 0
    var levelRMS: Float = 0
    var levelPeak: Float = 0

    var rawTranscript: String = ""
    var editedTranscript: String = ""
    var transcribeDurationMs: Int = 0
    var asrModelID: String = ""
    var isStreaming: Bool = false

    var focusContext: FocusContext?

    var lastInsertionMessage: String = ""

    func reset() {
        phase = .idle
        elapsedSeconds = 0
        levelRMS = 0
        levelPeak = 0
        rawTranscript = ""
        editedTranscript = ""
        transcribeDurationMs = 0
        asrModelID = ""
        isStreaming = false
        focusContext = nil
        lastInsertionMessage = ""
    }
}

extension ASRRuntimeStatus {
    var displayLabel: String {
        switch self {
        case .unloaded:
            return String(localized: "Not loaded")
        case .downloading(let progress, let downloaded, let total):
            let dn = ByteCountFormatter.string(fromByteCount: downloaded, countStyle: .file)
            if let total {
                let tot = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
                let pct = progress.map { Int($0 * 100) } ?? Int(Double(downloaded) / Double(max(total, 1)) * 100)
                return String(localized: "Downloading \(pct)% (\(dn) / \(tot))")
            } else {
                return String(localized: "Downloading… (\(dn))")
            }
        case .loading:
            return String(localized: "Loading model")
        case .ready:
            return String(localized: "Loaded")
        case .failed(let msg):
            let trimmed = String(msg.prefix(60))
            return String(localized: "Error: \(trimmed)")
        }
    }

    var downloadProgress: Double? {
        switch self {
        case .downloading(let progress, let downloaded, let total):
            if let progress { return progress }
            if let total, total > 0 { return Double(downloaded) / Double(total) }
            return nil
        default:
            return nil
        }
    }

    var badge: StatusBadge.Tone {
        switch self {
        case .unloaded: return .neutral
        case .downloading, .loading: return .warn
        case .ready: return .ok
        case .failed: return .error
        }
    }
}

extension PermissionsService.Status {
    var badge: StatusBadge.Tone {
        switch self {
        case .granted: return .ok
        case .denied: return .error
        case .notDetermined: return .warn
        case .unknown: return .neutral
        }
    }
}

import Foundation
import Observation

struct PopupFailure: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case microphonePermission
        case recording
        case denoise
        case audioProcessing
        case transcription
        case noSpeech
        case canonicalData
        case historySave
        case datasetSave
        case historyAndDatasetSave
    }

    enum RecoveryDestination: Equatable, Sendable {
        case permissions
        case audioCleanup
        case speechModel
        case dataset

        var settingsCategory: SettingsCategory {
            switch self {
            case .permissions: return .permissions
            case .audioCleanup: return .output
            case .speechModel: return .model
            case .dataset: return .dataset
            }
        }

        var buttonTitle: String {
            switch self {
            case .permissions: return String(localized: "Open Permissions Settings…")
            case .audioCleanup: return String(localized: "Open Audio Cleanup Settings…")
            case .speechModel: return String(localized: "Open Model Settings…")
            case .dataset: return String(localized: "Open Dataset Settings…")
            }
        }
    }

    let kind: Kind
    let title: String
    let message: String
    let retryTitle: String
    let destination: RecoveryDestination?

    static var microphonePermission: PopupFailure {
        return PopupFailure(
            kind: .microphonePermission,
            title: String(localized: "Microphone access is required"),
            message: String(localized: "Grant microphone access in Settings, then try recording again."),
            retryTitle: String(localized: "Try Again"),
            destination: .permissions
        )
    }

    static func recording(_: Error) -> PopupFailure {
        PopupFailure(
            kind: .recording,
            title: String(localized: "Recording failed"),
            message: String(
                localized: "ThinkAloud couldn’t use the microphone. Confirm microphone access and the selected input device, then try again."
            ),
            retryTitle: String(localized: "Record Again"),
            destination: .permissions
        )
    }

    static func denoise(_: Error) -> PopupFailure {
        PopupFailure(
            kind: .denoise,
            title: String(localized: "Audio cleanup failed"),
            message: String(
                localized: "Audio cleanup is set to On, so ThinkAloud stopped instead of transcribing uncleaned audio. Retry, or change Audio cleanup to Auto or Off."
            ),
            retryTitle: String(localized: "Record Again"),
            destination: .audioCleanup
        )
    }

    static func audioProcessing(_: Error) -> PopupFailure {
        PopupFailure(
            kind: .audioProcessing,
            title: String(localized: "Audio preparation failed"),
            message: String(
                localized: "ThinkAloud couldn’t prepare this recording for the speech model. Record again; if the problem continues, review Audio cleanup settings."
            ),
            retryTitle: String(localized: "Record Again"),
            destination: .audioCleanup
        )
    }

    static func transcription(_: Error) -> PopupFailure {
        PopupFailure(
            kind: .transcription,
            title: String(localized: "Transcription failed"),
            message: String(
                localized: "The speech model couldn’t transcribe this recording. Verify that the selected model is downloaded and ready, then record again."
            ),
            retryTitle: String(localized: "Record Again"),
            destination: .speechModel
        )
    }

    static var noSpeech: PopupFailure {
        PopupFailure(
            kind: .noSpeech,
            title: String(localized: "No speech was detected"),
            message: String(localized: "Check the microphone input and record again."),
            retryTitle: String(localized: "Record Again"),
            destination: .permissions
        )
    }

    static var canonicalData: PopupFailure {
        PopupFailure(
            kind: .canonicalData,
            title: String(localized: "Recording data is incomplete"),
            message: String(
                localized: "ThinkAloud stopped before inserting or saving because the speech model didn’t return a complete final result. Record again to create a complete session."
            ),
            retryTitle: String(localized: "Record Again"),
            destination: nil
        )
    }

    static func datasetSave(
        inserted: Bool,
        cleanupFailed: Bool = false,
        insertionMessage: String? = nil
    ) -> PopupFailure {
        let insertionFailure = insertionMessage?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let insertionContext: String?
        if !inserted {
            if let insertionFailure, !insertionFailure.isEmpty {
                insertionContext = insertionFailure
            } else {
                insertionContext = String(
                    localized: "The transcript was copied for manual paste instead of being inserted."
                )
            }
        } else {
            insertionContext = nil
        }

        let message: String
        if let insertionContext, cleanupFailed {
            message = String(
                localized: "\(insertionContext) ThinkAloud also couldn’t save the recording to the local dataset or remove its temporary audio. This recovery remains open: choose Retry Save, or check Dataset settings, file permissions, and available disk space before choosing Close again."
            )
        } else if let insertionContext {
            message = String(
                localized: "\(insertionContext) ThinkAloud also couldn’t save the recording to the local dataset. Check Dataset settings and available disk space, then retry."
            )
        } else if cleanupFailed {
            message = String(
                localized: "ThinkAloud couldn’t save the recording to the local dataset or remove its temporary audio. This recovery remains open: choose Retry Save, or check Dataset settings, file permissions, and available disk space before choosing Close again."
            )
        } else {
            message = String(
                localized: "ThinkAloud couldn’t save the recording to the local dataset. Check Dataset settings and available disk space, then retry."
            )
        }
        return PopupFailure(
            kind: .datasetSave,
            title: inserted
                ? String(localized: "Text inserted, but save failed")
                : String(localized: "Text wasn’t inserted, and save failed"),
            message: message,
            retryTitle: String(localized: "Retry Save"),
            destination: .dataset
        )
    }

    static func historySave(inserted: Bool, insertionMessage: String? = nil) -> PopupFailure {
        let deliveryContext = inserted
            ? String(localized: "The transcript was already inserted.")
            : (insertionMessage ?? String(localized: "The insertion attempt is complete."))
        return PopupFailure(
            kind: .historySave,
            title: String(localized: "Usage history wasn’t saved"),
            message: String(
                localized: "\(deliveryContext) ThinkAloud couldn’t save this session to local Insights history. Retry saves only the history and will not insert the text again. Closing discards this session from Insights."
            ),
            retryTitle: String(localized: "Retry History Save"),
            destination: nil
        )
    }

    static func historyAndDatasetSave(datasetFailure: PopupFailure) -> PopupFailure {
        PopupFailure(
            kind: .historyAndDatasetSave,
            title: String(localized: "Local saves need attention"),
            message: String(
                localized: "ThinkAloud couldn’t save this session to Insights history. \(datasetFailure.message) Retry saves only the missing local data and will not insert the text again. Closing discards the missing Insights session."
            ),
            retryTitle: String(localized: "Retry Saves"),
            destination: .dataset
        )
    }
}

struct PopupNotice: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case refineFailed
        case denoiseBypassed
    }

    let kind: Kind
    let message: String
}

enum PopupPhase: Equatable {
    case idle
    case recording
    case transcribing
    case inserting
    /// The AI Refine (LLM) stage is rewriting the transcript — it streams into `editedTranscript`
    /// live. Cancellable: ⌥Space / insert aborts it and inserts what's shown.
    case polishing
    case review
    case savingDataset
    case error(PopupFailure)

    var allowsNewRecordingInvocation: Bool {
        switch self {
        case .idle:
            return true
        case .error(let failure):
            // Persistence failures own a complete pending snapshot. Starting a new recording here
            // would discard the only retry path after the delivery attempt already completed.
            switch failure.kind {
            case .historySave, .datasetSave, .historyAndDatasetSave:
                return false
            default:
                return true
            }
        case .recording, .transcribing, .inserting, .polishing, .review, .savingDataset:
            return false
        }
    }
}

@MainActor
@Observable
final class PopupViewModel {
    var phase: PopupPhase = .idle {
        didSet { phaseDidChange?(phase) }
    }
    @ObservationIgnored var phaseDidChange: ((PopupPhase) -> Void)?
    var elapsedSeconds: TimeInterval = 0
    var levelRMS: Float = 0
    var levelPeak: Float = 0

    var rawTranscript: String = ""
    var editedTranscript: String = ""
    var transcribeDurationMs: Int = 0
    var asrModelID: String = ""
    var isStreaming: Bool = false
    var insertionSucceededForDatasetSave = true
    var savingIncludesDataset = false

    var focusContext: FocusContext?

    var lastInsertionMessage: String = ""
    var notice: PopupNotice?

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
        insertionSucceededForDatasetSave = true
        savingIncludesDataset = false
        focusContext = nil
        lastInsertionMessage = ""
        notice = nil
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
        case .failed:
            return String(localized: "Model unavailable")
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

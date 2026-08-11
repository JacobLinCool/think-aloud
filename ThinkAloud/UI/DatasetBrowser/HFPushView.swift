import AppKit
import SwiftUI

struct HFPushView: View {
    @Bindable var controller: HFPushController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            form
            Divider()
            statusArea
            footer
        }
        .padding(20)
        .frame(width: 520)
        .interactiveDismissDisabled(controller.isRunning)
        .task { await controller.prepareForPresentation() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "icloud.and.arrow.up")
                .font(.title2)
            Text("Push to Hugging Face Hub")
                .font(.headline)
            Spacer()
        }
    }

    @ViewBuilder
    private var form: some View {
        Form {
            LabeledContent(String(localized: "Organization")) {
                TextField(String(localized: "(your namespace)"), text: $controller.organization)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent(String(localized: "Repository")) {
                TextField(String(localized: "repo-name"), text: $controller.repoName)
                    .textFieldStyle(.roundedBorder)
            }
            if let validationMessage = controller.validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Toggle(String(localized: "Private"), isOn: $controller.isPrivate)
            Text("ThinkAloud applies the selected visibility to new or existing repositories and verifies it before uploading files.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle(String(localized: "Include audio files"), isOn: $controller.includeAudio)
            Toggle(String(localized: "Include source-app names"), isOn: $controller.includeSourceApp)
        }
        .disabled(controller.isRunning)
    }

    @ViewBuilder
    private var statusArea: some View {
        if let result = controller.result {
            VStack(alignment: .leading, spacing: 6) {
                Label(String(localized: "Push complete"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Uploaded \(result.uploadedFileCount) file(s) to \(result.repoID).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let warning = result.cleanupWarning {
                    Label {
                        Text(
                            "The commit succeeded, but temporary local files remain at \(warning.directory.path). Remove this folder manually."
                        )
                        .textSelection(.enabled)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
                Button {
                    if let url = URL(string: result.pageURL) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label(String(localized: "Open in browser"), systemImage: "arrow.up.right.square")
                }
            }
        } else if let err = controller.errorMessage {
            Text(err)
                .font(.caption)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if controller.isRunning {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(controller.isCancelling ? String(localized: "Cancelling…") : stageLabel)
                        .font(.callout.weight(.medium))
                }
                if controller.stageTotal > 0 {
                    ProgressView(value: Double(controller.stageCompleted), total: Double(controller.stageTotal))
                        .progressViewStyle(.linear)
                    HStack {
                        Text("\(controller.stageCompleted) / \(controller.stageTotal)")
                            .font(.caption.monospacedDigit())
                        Spacer()
                        if !controller.currentLabel.isEmpty {
                            Text(controller.currentLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
        } else if controller.wasCancelled {
            Label(
                String(
                    localized: "Upload cancelled before commit. The repository or uploaded LFS objects may remain on Hugging Face."
                ),
                systemImage: "xmark.circle"
            )
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            consentSummary
        }
    }

    /// Pre-push consent block: what the upload will contain, so nothing is a surprise.
    @ViewBuilder
    private var consentSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch controller.summaryState {
            case .idle, .loading:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading upload summary…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .failed(let message):
                VStack(alignment: .leading, spacing: 6) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                    Button(String(localized: "Try again")) {
                        Task { await controller.loadSummary() }
                    }
                    .controlSize(.small)
                }
            case .loaded(let s) where s.isEmpty:
                Label(String(localized: "There are no saved records to upload."), systemImage: "tray")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .loaded(let s):
                HStack(spacing: 14) {
                    summaryStat(String(localized: "Recordings"), s.recordCount.formatted())
                    summaryStat(
                        String(localized: "Speech"),
                        Self.formattedSpeechDuration(milliseconds: s.audio.totalDurationMs)
                    )
                    summaryStat(String(localized: "Languages"), s.byLanguage.count.formatted())
                }
            }
            Text("This push writes:")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                bullet(String(localized: "README.md + statistics.json (aggregate stats)"))
                bullet(String(localized: "metadata.jsonl — one row per recording, with transcripts + derived counts"))
                if controller.includeAudio {
                    bullet(String(localized: "audio/… — your saved WAV recordings (LFS when required)"))
                }
            }
            Label {
                Text(controller.includeSourceApp
                     ? String(localized: "Source-app names are included.")
                     : String(localized: "Source-app names are not included."))
            } icon: {
                Image(systemName: controller.includeSourceApp ? "info.circle" : "checkmark.shield")
            }
            .font(.caption)
            .foregroundStyle(controller.includeSourceApp ? Color.secondary : Color.green)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func summaryStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.title3.weight(.semibold).monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•").foregroundStyle(.secondary)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            if controller.canCancel {
                Button(role: .destructive) {
                    controller.cancel()
                } label: {
                    Text(String(localized: "Cancel"))
                }
            } else if controller.isRunning {
                Label(
                    controller.isCancelling
                        ? String(localized: "Cancellation requested…")
                        : String(localized: "Commit in progress—this can’t be cancelled."),
                    systemImage: controller.isCancelling ? "xmark.circle" : "clock"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Button(String(localized: "Close")) { dismiss() }
            }
            Spacer()
            if controller.result == nil {
                Button {
                    controller.push()
                } label: {
                    Label(String(localized: "Push now"), systemImage: "arrow.up.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!controller.canPush)
            }
        }
    }

    static func formattedSpeechDuration(milliseconds: Int) -> String {
        let seconds = Double(milliseconds) / 1_000
        let measurement: Measurement<UnitDuration>
        if seconds < 60 {
            measurement = Measurement(value: seconds, unit: .seconds)
        } else if seconds < 3_600 {
            measurement = Measurement(value: seconds / 60, unit: .minutes)
        } else {
            measurement = Measurement(value: seconds / 3_600, unit: .hours)
        }
        return measurement.formatted(
            .measurement(
                width: .abbreviated,
                usage: .asProvided,
                numberFormatStyle: .number.precision(.fractionLength(0...1))
            )
        )
    }

    private var stageLabel: String {
        switch controller.stage {
        case .prepare:    return String(localized: "Preparing files…")
        case .createRepo: return String(localized: "Creating repository…")
        case .preupload:  return String(localized: "Checking which files need LFS…")
        case .lfsUpload:  return String(localized: "Uploading large files…")
        case .commit:     return String(localized: "Finishing commit—this can’t be cancelled…")
        case .done:       return String(localized: "Done.")
        }
    }
}

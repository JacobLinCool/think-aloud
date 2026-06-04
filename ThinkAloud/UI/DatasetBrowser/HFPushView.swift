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
            Toggle(String(localized: "Private"), isOn: $controller.isPrivate)
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
                    Text(stageLabel)
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
        } else {
            consentSummary
        }
    }

    /// Pre-push consent block: what the upload will contain, so nothing is a surprise.
    @ViewBuilder
    private var consentSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let s = controller.summary, !s.isEmpty {
                HStack(spacing: 14) {
                    summaryStat(String(localized: "Recordings"), "\(s.recordCount)")
                    summaryStat(String(localized: "Speech"), String(format: "%.1f h", Double(s.audio.totalDurationMs) / 3_600_000))
                    summaryStat(String(localized: "Languages"), "\(s.byLanguage.count)")
                }
            }
            Text("This push writes:")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                bullet(String(localized: "README.md + statistics.json (aggregate stats)"))
                bullet(String(localized: "metadata.jsonl — one row per recording, with transcripts + derived counts"))
                if controller.includeAudio {
                    bullet(String(localized: "audio/… — your 16 kHz recordings (LFS)"))
                }
            }
            Label {
                Text(controller.includeSourceApp
                     ? String(localized: "Source-app names **are** included.")
                     : String(localized: "Source-app names are **not** included."))
            } icon: {
                Image(systemName: controller.includeSourceApp ? "info.circle" : "checkmark.shield")
            }
            .font(.caption)
            .foregroundStyle(controller.includeSourceApp ? Color.secondary : Color.green)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await controller.loadSummary() }
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
            if controller.isRunning {
                Button(role: .destructive) {
                    controller.cancel()
                } label: {
                    Text(String(localized: "Cancel"))
                }
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

    private var stageLabel: String {
        switch controller.stage {
        case .prepare:    return String(localized: "Preparing files…")
        case .createRepo: return String(localized: "Creating repository…")
        case .preupload:  return String(localized: "Checking which files need LFS…")
        case .lfsUpload:  return String(localized: "Uploading large files…")
        case .commit:     return String(localized: "Committing…")
        case .done:       return String(localized: "Done.")
        }
    }
}

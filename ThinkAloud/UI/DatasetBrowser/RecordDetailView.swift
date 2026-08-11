import AppKit
import SwiftUI

struct RecordDetailView: View {
    let record: DatasetRecord
    let controller: DatasetBrowserController
    let player: AudioPlayerController

    @State private var audioURL: URL?
    @State private var showSavedTick: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Caps text-block readable width so long Chinese paragraphs don't run the full
    /// (potentially full-screen) detail width.
    private let contentMaxWidth: CGFloat = 720

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                playerSection
                metadataSection
                rawSection
                editedSection
            }
            .frame(maxWidth: contentMaxWidth, alignment: .leading)
            .padding(20)
        }
        .frame(maxWidth: .infinity)
        .task(id: record.id) {
            player.beginLoading(id: record.id)
            do {
                let url = try await controller.audioURL(for: record)
                audioURL = url
                // Pre-load the player so the Slider/duration are accurate before the user presses ▶.
                player.prepare(url: url, id: record.id)
            } catch {
                audioURL = nil
                player.reportLoadError(error, id: record.id)
            }
            showSavedTick = false
        }
        .onChange(of: controller.lastSaveTick) { _, _ in
            // Brief "saved" pulse after a successful updateEdited.
            showSavedTick = true
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await MainActor.run { showSavedTick = false }
            }
        }
        .navigationTitle(Text(verbatim: ""))
    }

    // MARK: - Player (scrubbable)

    @ViewBuilder
    private var playerSection: some View {
        let displayDuration = player.playingID == record.id && player.duration > 0
            ? player.duration
            : Double(record.durationMs ?? 0) / 1000.0
        let displayTime = player.playingID == record.id ? player.currentTime : 0

        HStack(spacing: 12) {
            Button {
                guard let url = audioURL else { return }
                player.toggle(url: url, id: record.id)
            } label: {
                Image(systemName: isThisPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .disabled(audioURL == nil || player.loadState == .loading || isAudioUnavailable)
            .accessibilityLabel(isThisPlaying ? String(localized: "Pause audio") : String(localized: "Play audio"))
            .accessibilityHint(String(localized: "Plays or pauses the selected recording."))

            VStack(alignment: .leading, spacing: 4) {
                Slider(
                    value: Binding(
                        get: { displayTime },
                        set: { newValue in
                            // Slider drives this player's time; if this isn't currently the
                            // loaded clip, ignore (toggle will load it first).
                            guard player.playingID == record.id else { return }
                            player.seek(to: newValue)
                        }
                    ),
                    in: 0...max(displayDuration, 0.001),
                    onEditingChanged: { editing in
                        guard player.playingID == record.id else { return }
                        player.isScrubbing = editing
                    }
                )
                .controlSize(.small)
                .disabled(player.playingID != record.id || displayDuration <= 0)
                .accessibilityLabel(String(localized: "Playback position"))
                .accessibilityValue("\(timeLabel(displayTime)) of \(timeLabel(displayDuration))")
                .accessibilityHint(String(localized: "Adjust the current position in the recording."))

                HStack {
                    Text(timeLabel(displayTime))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(timeLabel(displayDuration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if player.loadState == .loading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(String(localized: "Loading audio"))
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .bottomLeading) {
            if case .error(let message) = player.loadState {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .offset(y: 18)
                    .accessibilityLabel(String(localized: "Audio error: \(message)"))
            }
        }
    }

    // MARK: - Metadata

    @ViewBuilder
    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            metaRow("Source") {
                let name = record.sourceAppName ?? "—"
                HStack(spacing: 4) {
                    Text(name)
                        .foregroundStyle(.primary)
                        .help(record.sourceAppBundleID ?? "")
                }
            }
            metaRow("Model") {
                Text(record.asrModel)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if let lang = record.language {
                metaRow("Language") {
                    Text(Locale.current.localizedString(forLanguageCode: lang) ?? lang)
                        .foregroundStyle(.primary)
                        .help(lang)
                }
            }
            metaRow("Created") {
                Text(createdLabel)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }
            metaRow("ID") {
                HStack(spacing: 4) {
                    Text(record.id)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button {
                        copyID()
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .imageScale(.small)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(String(localized: "Copy Record ID"))
                    .help(String(localized: "Copy ID"))
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func metaRow<Value: View>(_ key: LocalizedStringKey, @ViewBuilder _ value: () -> Value) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key)
                .frame(width: 70, alignment: .leading)
            value()
            Spacer()
        }
    }

    // MARK: - Raw

    @ViewBuilder
    private var rawSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Raw")
            Text(record.rawTranscript.isEmpty ? String(localized: "(empty)") : record.rawTranscript)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Edited

    @ViewBuilder
    private var editedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionHeader("Edited")
                if showSavedTick {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark.circle.fill").imageScale(.small)
                        Text("Saved")
                    }
                    .font(.caption)
                    .foregroundStyle(.green)
                    .transition(.opacity)
                }
                Spacer()
                if !isEditingThisRecord {
                    Button(String(localized: "Edit")) { controller.beginEditing(record) }
                        .controlSize(.small)
                        .keyboardShortcut("e", modifiers: [.command])
                        .help(String(localized: "Edit (⌘E)"))
                }
            }
            if isEditingThisRecord {
                TextEditor(text: Binding(
                    get: { controller.editDraft },
                    set: { controller.editDraft = $0 }
                ))
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 120)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                HStack {
                    if let error = controller.editErrorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .accessibilityLabel(String(localized: "Save error: \(error)"))
                        Button(String(localized: "Retry")) { saveEdit() }
                            .controlSize(.small)
                            .disabled(controller.isSavingDraft)
                    }
                    Spacer()
                    if controller.isSavingDraft {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(String(localized: "Saving changes"))
                    }
                    Button(String(localized: "Cancel")) { controller.discardDraft() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(controller.isSavingDraft)
                    Button(String(localized: "Save")) { saveEdit() }
                        .keyboardShortcut("s", modifiers: [.command])
                        .buttonStyle(.borderedProminent)
                        .disabled(!controller.hasUnsavedDraft || controller.isSavingDraft)
                }
            } else {
                Text(record.editedTranscript.isEmpty ? String(localized: "(empty)") : record.editedTranscript)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: showSavedTick)
    }

    @ViewBuilder
    private func sectionHeader(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    // MARK: - Helpers

    private var isThisPlaying: Bool {
        player.playingID == record.id && player.isPlaying
    }

    private var isAudioUnavailable: Bool {
        if case .error = player.loadState { return true }
        return false
    }

    private var isEditingThisRecord: Bool {
        controller.editingRecordID == record.id
    }

    private func timeLabel(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .positional
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        formatter.zeroFormattingBehavior = .pad
        return formatter.string(from: max(0, seconds)) ?? "0:00"
    }

    private var createdLabel: String {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        guard let date = fractional.date(from: record.createdAt)
                ?? standard.date(from: record.createdAt)
        else {
            return String(localized: "Invalid recording date")
        }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f.string(from: date)
    }

    private func copyID() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(record.id, forType: .string)
    }

    // MARK: - Edit lifecycle

    private func saveEdit() {
        Task {
            _ = await controller.saveDraft()
        }
    }
}

import AppKit
import SwiftUI

struct RecordDetailView: View {
    let record: DatasetRecord
    let controller: DatasetBrowserController
    let player: AudioPlayerController

    @State private var editing: Bool = false
    @State private var draft: String = ""
    @State private var audioURL: URL?
    @State private var showSavedTick: Bool = false

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
            let url = await controller.audioURL(for: record)
            audioURL = url
            // Pre-load the player so the Slider/duration are accurate before the user presses ▶.
            player.prepare(url: url, id: record.id)
            editing = false
            draft = record.editedTranscript
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
        .navigationTitle("")
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
            .disabled(audioURL == nil)

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
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
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
                    Text(lang).foregroundStyle(.primary)
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
                if !editing {
                    Button(String(localized: "Edit")) { beginEdit() }
                        .controlSize(.small)
                        .keyboardShortcut("e", modifiers: [.command])
                        .help(String(localized: "Edit (⌘E)"))
                }
            }
            if editing {
                TextEditor(text: $draft)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 120)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                HStack {
                    Spacer()
                    Button(String(localized: "Cancel")) { cancelEdit() }
                        .keyboardShortcut(.cancelAction)
                    Button(String(localized: "Save")) { saveEdit() }
                        .keyboardShortcut("s", modifiers: [.command])
                        .buttonStyle(.borderedProminent)
                        .disabled(draft == record.editedTranscript)
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
        .animation(.easeOut(duration: 0.2), value: showSavedTick)
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

    private func timeLabel(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private var createdLabel: String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        guard let date = iso.date(from: record.createdAt) else { return record.createdAt }
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

    private func beginEdit() {
        draft = record.editedTranscript
        editing = true
    }

    private func cancelEdit() {
        draft = record.editedTranscript
        editing = false
    }

    private func saveEdit() {
        let snapshot = draft
        editing = false
        Task {
            await controller.updateEdited(id: record.id, text: snapshot)
        }
    }
}

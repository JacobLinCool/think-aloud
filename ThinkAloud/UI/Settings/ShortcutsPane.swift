import KeyboardShortcuts
import SwiftUI

/// Settings → Shortcuts: all three dictation hotkeys in one place, with one explicit reset scope.
struct ShortcutsPane: View {
    @State private var showResetConfirm = false

    var body: some View {
        Form {
            Section {
                KeyboardShortcuts.Recorder(String(localized: "Start recording"), name: .startRecording)
                KeyboardShortcuts.Recorder(String(localized: "Stop & transcribe"), name: .stopAndTranscribe)
                KeyboardShortcuts.Recorder(String(localized: "Insert & save"), name: .insertAndSave)

                HStack {
                    Spacer()
                    Button(String(localized: "Reset all 3 shortcuts")) {
                        showResetConfirm = true
                    }
                    .controlSize(.small)
                }
            } header: {
                Text("Shortcuts")
            } footer: {
                Text("Start recording fires from anywhere to open the popup. Stop & transcribe and Insert & save both default to ⌥Space — the popup phase decides which one fires.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            String(localized: "Reset Start recording, Stop & transcribe, and Insert & save to ⌥Space?"),
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Reset all 3 shortcuts"), role: .destructive) {
                KeyboardShortcuts.reset(.startRecording, .stopAndTranscribe, .insertAndSave)
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        }
    }
}

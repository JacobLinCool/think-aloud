import KeyboardShortcuts
import SwiftUI

struct GeneralPane: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        Form {
            Section {
                KeyboardShortcuts.Recorder(String(localized: "Start recording"), name: .startRecording)
            } header: {
                Text("Global")
            } footer: {
                Text("Fires from anywhere to open the popup and start recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                KeyboardShortcuts.Recorder(String(localized: "Stop & transcribe"), name: .stopAndTranscribe)
                KeyboardShortcuts.Recorder(String(localized: "Insert & save"), name: .insertAndSave)
            } header: {
                Text("Popup")
            } footer: {
                HStack(alignment: .firstTextBaseline) {
                    Text("Both default to ⌥Space — popup phase decides which fires.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    // Label says "全部 (all)" to signal that this clears every shortcut, including
                    // the Global one above — even though the button visually sits in the Popup section.
                    Button(String(localized: "Reset all hotkeys")) {
                        KeyboardShortcuts.reset(.startRecording, .stopAndTranscribe, .insertAndSave)
                    }
                    .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal)
    }
}

import SwiftUI

struct PermissionsPane: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        Form {
            Section {
                micRow
            } header: {
                Text("Microphone")
            } footer: {
                Text("Required to record your voice for local transcription.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                accessibilityRow
            } header: {
                Text("Accessibility")
            } footer: {
                Text("Required to paste the transcription into the focused app. macOS doesn't allow in-app prompts — grant it in System Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Spacer()
                    Button {
                        container.permissions.refresh()
                    } label: {
                        Label(String(localized: "Refresh status"), systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { container.permissions.refresh() }
    }

    @ViewBuilder
    private var micRow: some View {
        let status = container.permissions.microphoneStatus
        HStack(spacing: 12) {
            StatusBadge(tone: status.badge, text: status.label)
            Spacer()
            switch status {
            case .granted:
                EmptyView()
            case .notDetermined:
                Button(String(localized: "Request access")) {
                    Task { await container.permissions.requestMicrophone() }
                }
            case .denied, .unknown:
                Button(String(localized: "Open System Settings")) {
                    container.permissions.openMicrophoneSettings()
                }
            }
        }
    }

    @ViewBuilder
    private var accessibilityRow: some View {
        let status = container.permissions.accessibilityStatus
        HStack(spacing: 12) {
            StatusBadge(tone: status.badge, text: status.label)
            Spacer()
            if status != .granted {
                Button(String(localized: "Open System Settings")) {
                    container.permissions.openAccessibilitySettings()
                }
            }
        }
    }
}

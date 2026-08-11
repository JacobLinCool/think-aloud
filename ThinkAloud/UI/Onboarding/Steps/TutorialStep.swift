import KeyboardShortcuts
import SwiftUI

struct TutorialStep: View {
    private var startShortcut: String { shortcutText(for: .startRecording) }
    private var stopShortcut: String { shortcutText(for: .stopAndTranscribe) }
    private var insertShortcut: String { shortcutText(for: .insertAndSave) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                OnboardingHeader(
                    title: "How to use ThinkAloud",
                    subtitle: "These are your current global shortcuts. They may share one key because each acts in a different popup state."
                )

                OnboardingCard {
                    VStack(spacing: 12) {
                        stepRow(
                            number: 1,
                            icon: "mic.fill",
                            title: "Press \(startShortcut) to start recording",
                            detail: "A small popup appears. Start talking."
                        )
                        Divider().padding(.leading, 44)
                        stepRow(
                            number: 2,
                            icon: "waveform",
                            title: "Press \(stopShortcut) to stop & transcribe",
                            detail: "Your speech is transcribed on-device. Review and edit if needed."
                        )
                        Divider().padding(.leading, 44)
                        stepRow(
                            number: 3,
                            icon: "text.cursor",
                            title: "Press \(insertShortcut) to insert & save",
                            detail: "The text is pasted into whatever app had focus."
                        )
                    }
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("Without Accessibility access, ThinkAloud copies the text to your clipboard instead of pasting it — just press ⌘V.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
            }
            .padding(32)
        }
    }

    private func shortcutText(for name: KeyboardShortcuts.Name) -> String {
        KeyboardShortcuts.getShortcut(for: name).map(String.init(describing:))
            ?? String(localized: "Not set")
    }

    private func stepRow(
        number: Int,
        icon: String,
        title: LocalizedStringKey,
        detail: LocalizedStringKey
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: 28, height: 28)
                .background(Color.accentColor.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Label(title, systemImage: icon)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

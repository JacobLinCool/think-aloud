import KeyboardShortcuts
import SwiftUI

struct TutorialStep: View {
    @Environment(AppContainer.self) private var container

    /// Live binding to the user's actual shortcut (defaults to ⌥Space), so the tutorial
    /// stays correct even if they've rebound it in Settings.
    private var shortcut: String {
        KeyboardShortcuts.getShortcut(for: .startRecording).map { "\($0)" } ?? "⌥Space"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                OnboardingHeader(
                    title: "How to use ThinkAloud",
                    subtitle: "One shortcut does everything. Press it three times in a row:"
                )

                stepRow(
                    number: 1,
                    icon: "mic.fill",
                    title: "Press \(shortcut) to start recording",
                    detail: "A small popup appears. Start talking."
                ) {
                    HStack(spacing: 8) {
                        KeyboardShortcuts.Recorder("", name: .startRecording)
                        Text("Change it if it clashes with another app.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
                stepRow(
                    number: 2,
                    icon: "waveform",
                    title: "Press \(shortcut) again to stop & transcribe",
                    detail: "Your speech is transcribed on-device. Review and edit if needed."
                )
                stepRow(
                    number: 3,
                    icon: "text.cursor",
                    title: "Press \(shortcut) once more to insert",
                    detail: "The text is pasted into whatever app had focus."
                )

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
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

    private func stepRow<Accessory: View>(
        number: Int,
        icon: String,
        title: LocalizedStringKey,
        detail: LocalizedStringKey,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() }
    ) -> some View {
        OnboardingCard {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle().fill(Color.accentColor.opacity(0.15)).frame(width: 34, height: 34)
                    Text("\(number)").font(.headline).foregroundStyle(.tint)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Label(title, systemImage: icon)
                        .font(.headline)
                        .labelStyle(.titleAndIcon)
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    accessory()
                }
                Spacer(minLength: 0)
            }
        }
    }
}

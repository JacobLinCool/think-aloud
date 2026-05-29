import KeyboardShortcuts
import SwiftUI

struct FinishStep: View {
    @Environment(AppContainer.self) private var container

    private struct Pending: Identifiable {
        let id: Int
        let label: String
        let step: OnboardingStep
    }

    private var shortcut: String {
        KeyboardShortcuts.getShortcut(for: .startRecording).map { "\($0)" } ?? "⌥Space"
    }

    private var pending: [Pending] {
        var items: [Pending] = []
        if container.permissions.microphoneStatus != .granted {
            items.append(.init(id: 0, label: String(localized: "Microphone access not granted"), step: .permissions))
        }
        if container.permissions.accessibilityStatus != .granted {
            items.append(.init(id: 1, label: String(localized: "Accessibility off — text will be copied to the clipboard"), step: .permissions))
        }
        let manager = container.modelManager
        if !(manager.isDownloaded(manager.profile) || manager.runtimeStatus.isReady) {
            items.append(.init(id: 2, label: String(localized: "Speech model not downloaded yet"), step: .model))
        }
        return items
    }

    var body: some View {
        VStack(spacing: 18) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)

            VStack(spacing: 6) {
                Text("You're all set")
                    .font(.largeTitle.bold())
                Text("Press \(shortcut) anywhere to start talking. ThinkAloud lives in your menu bar.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 440)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !pending.isEmpty {
                OnboardingCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("A few things are still pending — you can finish them now or later in Settings.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(pending) { item in
                            HStack {
                                StatusBadge(tone: .warn, text: item.label)
                                Spacer()
                                Button(String(localized: "Fix")) {
                                    container.onboardingState.go(to: item.step)
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }
                .frame(maxWidth: 460)
            }

            Spacer()
        }
        .padding(32)
        .onAppear { container.permissions.refresh() }
    }
}

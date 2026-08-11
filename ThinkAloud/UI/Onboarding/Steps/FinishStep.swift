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
        KeyboardShortcuts.getShortcut(for: .startRecording).map(String.init(describing:))
            ?? String(localized: "Not set")
    }

    private var pendingOptional: [Pending] {
        var items: [Pending] = []
        if container.permissions.accessibilityStatus != .granted {
            items.append(.init(id: 1, label: String(localized: "Accessibility off — text will be copied to the clipboard"), step: .permissions))
        }
        return items
    }

    private var readiness: OnboardingReadiness {
        let manager = container.modelManager
        return OnboardingReadiness(
            microphoneGranted: container.permissions.microphoneStatus == .granted,
            modelReady: manager.isDownloaded(manager.profile) || manager.runtimeStatus.isReady
        )
    }

    var body: some View {
        VStack(spacing: 18) {
            Spacer()

            Image(systemName: readiness.canFinish ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 64))
                .foregroundStyle(readiness.canFinish ? .green : .orange)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text(
                    readiness.canFinish
                        ? String(localized: "You’re ready")
                        : String(localized: "Setup is not complete")
                )
                    .font(.largeTitle.bold())
                Text(
                    readiness.canFinish
                        ? String(
                            localized: "Press \(shortcut) anywhere to start talking. ThinkAloud lives in your menu bar."
                        )
                        : String(
                            localized: "Grant microphone access and download a speech model before finishing."
                        )
                )
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 440)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !readiness.canFinish {
                OnboardingCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Required")
                            .font(.headline)
                        if !readiness.microphoneGranted {
                            requirementRow(
                                label: String(localized: "Grant microphone access"),
                                step: .permissions
                            )
                        }
                        if !readiness.modelReady {
                            requirementRow(
                                label: String(localized: "Download a speech model"),
                                step: .model
                            )
                        }
                    }
                }
                .frame(maxWidth: 460)
            } else if !pendingOptional.isEmpty {
                OnboardingCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Optional")
                            .font(.headline)
                        Text("You can finish these now or later in Settings.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(pendingOptional) { item in
                            HStack {
                                StatusBadge(tone: .warn, text: item.label)
                                Spacer()
                                Button(String(localized: "Review Accessibility")) {
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

    private func requirementRow(label: String, step: OnboardingStep) -> some View {
        HStack {
            StatusBadge(tone: .error, text: label)
            Spacer()
            Button(String(localized: "Fix")) {
                container.onboardingState.go(to: step)
            }
            .controlSize(.small)
            .accessibilityLabel(String(localized: "Fix \(label)"))
        }
    }
}

import AppKit
import Combine
import SwiftUI

struct PermissionsStep: View {
    @Environment(AppContainer.self) private var container

    /// Light timer fallback: re-check while the step is visible in case neither notification fires.
    @State private var pollTask: Task<Void, Never>?

    /// macOS posts this distributed notification when Accessibility trust changes. It's the signal
    /// that lets an *already-running* process see a newly-granted permission — plain polling of
    /// `AXIsProcessTrusted()` can keep reading a stale cached value until this fires.
    private let axTrustChanged = DistributedNotificationCenter.default()
        .publisher(for: Notification.Name("com.apple.accessibility.api"))

    /// Fired when the user switches back to ThinkAloud (e.g. after toggling the setting in System
    /// Settings); a good moment to re-check both permissions.
    private let appActivated = NotificationCenter.default
        .publisher(for: NSApplication.didBecomeActiveNotification)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                OnboardingHeader(
                    title: "Grant permissions",
                    subtitle: "ThinkAloud needs two macOS permissions. You can change these anytime in System Settings."
                )

                micCard
                accessibilityCard
            }
            .padding(32)
        }
        .onAppear {
            container.permissions.refresh()
            startPolling()
        }
        .onDisappear { pollTask?.cancel() }
        .onReceive(axTrustChanged) { _ in recheckSoon() }
        .onReceive(appActivated) { _ in recheckSoon() }
    }

    // MARK: - Microphone

    private var micCard: some View {
        let status = container.permissions.microphoneStatus
        return OnboardingCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("Microphone", systemImage: "mic.fill")
                    .font(.headline)
                Text("Required to record your voice for local transcription.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    StatusBadge(tone: status.badge, text: status.label)
                    Spacer()
                    switch status {
                    case .granted:
                        EmptyView()
                    case .notDetermined:
                        Button(String(localized: "Request access")) {
                            Task { await container.permissions.requestMicrophone() }
                        }
                        .buttonStyle(.borderedProminent)
                    case .denied, .unknown:
                        Button(String(localized: "Open System Settings")) {
                            container.permissions.openMicrophoneSettings()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Accessibility

    private var accessibilityCard: some View {
        let status = container.permissions.accessibilityStatus
        return OnboardingCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("Accessibility", systemImage: "accessibility")
                    .font(.headline)
                Text("Lets ThinkAloud paste the transcription into the focused app. Optional — without it, text is copied to your clipboard instead.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    StatusBadge(tone: status.badge, text: status.label)
                    Spacer()
                    if status != .granted {
                        Button(String(localized: "Open System Settings")) {
                            container.permissions.openAccessibilitySettings()
                        }
                        Button(String(localized: "Request access")) {
                            container.permissions.promptAccessibility()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                if status != .granted {
                    Text("After you enable it in System Settings, this updates on its own.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Re-check helpers

    /// Refresh immediately, then once more shortly after — the trust DB write can land a beat
    /// after the change notification.
    private func recheckSoon() {
        container.permissions.refresh()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            container.permissions.refresh()
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if Task.isCancelled { return }
                container.permissions.refresh()
            }
        }
    }
}

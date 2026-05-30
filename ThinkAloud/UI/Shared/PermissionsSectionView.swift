import AppKit
import Combine
import SwiftUI

/// The single source of the mic + accessibility permission UI, shared by the Settings Permissions
/// pane and the Onboarding permissions step (which used to duplicate it). The live re-check
/// machinery (the Accessibility-trust distributed notification + app-activation + a light poll) now
/// lives here, so the SETTINGS pane finally auto-updates the moment the user grants access in System
/// Settings — previously only the onboarding copy did.
///
/// `style` switches the chrome: grouped-Form sections in Settings, onboarding cards in the flow.
struct PermissionsSectionView: View {
    enum Style { case settings, onboarding }

    @Environment(AppContainer.self) private var container
    let style: Style

    /// Light timer fallback: re-check while the view is visible in case neither notification fires.
    @State private var pollTask: Task<Void, Never>?

    /// macOS posts this distributed notification when Accessibility trust changes — the signal that
    /// lets an already-running process see a newly-granted permission (plain polling of
    /// `AXIsProcessTrusted()` can keep reading a stale cached value until this fires).
    private let axTrustChanged = DistributedNotificationCenter.default()
        .publisher(for: Notification.Name("com.apple.accessibility.api"))

    /// Fired when the user switches back to ThinkAloud (e.g. after toggling the setting in System
    /// Settings); a good moment to re-check both permissions.
    private let appActivated = NotificationCenter.default
        .publisher(for: NSApplication.didBecomeActiveNotification)

    var body: some View {
        content
            .onAppear {
                container.permissions.refresh()
                startPolling()
            }
            .onDisappear { pollTask?.cancel() }
            .onReceive(axTrustChanged) { _ in recheckSoon() }
            .onReceive(appActivated) { _ in recheckSoon() }
    }

    @ViewBuilder
    private var content: some View {
        switch style {
        case .settings: settingsSections
        case .onboarding: onboardingCards
        }
    }

    // MARK: - Settings chrome (grouped Form sections)

    @ViewBuilder
    private var settingsSections: some View {
        let mic = container.permissions.microphoneStatus
        let ax = container.permissions.accessibilityStatus

        Section {
            HStack(spacing: 12) {
                StatusBadge(tone: mic.badge, text: mic.label)
                Spacer()
                micButtons(prominent: false)
            }
        } header: {
            Text("Microphone")
        } footer: {
            Text("Required to record your voice for local transcription.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section {
            HStack(spacing: 12) {
                StatusBadge(tone: ax.badge, text: ax.label)
                Spacer()
                accessibilityButtons(includeRequest: false, prominent: false)
            }
        } header: {
            Text("Accessibility")
        } footer: {
            Text("Lets ThinkAloud paste the transcription into the focused app. Optional — without it, text is copied to your clipboard instead (press ⌘V). After you enable it in System Settings, this updates on its own.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Onboarding chrome (cards)

    @ViewBuilder
    private var onboardingCards: some View {
        let mic = container.permissions.microphoneStatus
        let ax = container.permissions.accessibilityStatus

        OnboardingCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("Microphone", systemImage: "mic.fill")
                    .font(.headline)
                Text("Required to record your voice for local transcription.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    StatusBadge(tone: mic.badge, text: mic.label)
                    Spacer()
                    micButtons(prominent: true)
                }
            }
        }

        OnboardingCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("Accessibility", systemImage: "accessibility")
                    .font(.headline)
                Text("Lets ThinkAloud paste the transcription into the focused app. Optional — without it, text is copied to your clipboard instead.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    StatusBadge(tone: ax.badge, text: ax.label)
                    Spacer()
                    accessibilityButtons(includeRequest: true, prominent: true)
                }
                if ax != .granted {
                    Text("After you enable it in System Settings, this updates on its own.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Action buttons (shared logic; prominence varies by host)

    @ViewBuilder
    private func micButtons(prominent: Bool) -> some View {
        switch container.permissions.microphoneStatus {
        case .granted:
            EmptyView()
        case .notDetermined:
            let button = Button(String(localized: "Request access")) {
                Task { await container.permissions.requestMicrophone() }
            }
            if prominent { button.buttonStyle(.borderedProminent) } else { button }
        case .denied, .unknown:
            Button(String(localized: "Open System Settings")) {
                container.permissions.openMicrophoneSettings()
            }
        }
    }

    @ViewBuilder
    private func accessibilityButtons(includeRequest: Bool, prominent: Bool) -> some View {
        if container.permissions.accessibilityStatus != .granted {
            Button(String(localized: "Open System Settings")) {
                container.permissions.openAccessibilitySettings()
            }
            if includeRequest {
                let request = Button(String(localized: "Request access")) {
                    container.permissions.promptAccessibility()
                }
                if prominent { request.buttonStyle(.borderedProminent) } else { request }
            }
        }
    }

    // MARK: - Re-check helpers

    /// Refresh immediately, then once more shortly after — the trust DB write can land a beat after
    /// the change notification.
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

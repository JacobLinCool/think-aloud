import SwiftUI

/// Root view of the onboarding window: progress dots on top, the current step in the
/// middle (animated when it changes), and a shared navigation bar at the bottom.
struct OnboardingScene: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            OnboardingStepIndicator(current: container.onboardingState.step)
                .padding(.top, 18)
                .padding(.bottom, 14)

            Divider()

            currentStep
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(container.onboardingState.step)
                .transition(stepTransition)

            Divider()

            OnboardingNavBar()
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .frame(width: 640, height: 600)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: container.onboardingState.step)
    }

    private var stepTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
    }

    @ViewBuilder
    private var currentStep: some View {
        switch container.onboardingState.step {
        case .welcome: WelcomeStep()
        case .permissions: PermissionsStep()
        case .model: ModelStep()
        case .tutorial: TutorialStep()
        case .finish: FinishStep()
        }
    }
}

// MARK: - Progress indicator

/// Horizontal pill row; steps up to and including the current one are tinted, the active
/// one is elongated.
struct OnboardingStepIndicator: View {
    let current: OnboardingStep

    var body: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingStep.allCases) { step in
                Capsule()
                    .fill(step.rawValue <= current.rawValue ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: step == current ? 24 : 8, height: 8)
            }
        }
        .accessibilityRepresentation {
            ProgressView(
                value: Double(current.rawValue + 1),
                total: Double(OnboardingStep.allCases.count)
            ) {
                Text("Setup progress")
            } currentValueLabel: {
                Text("Step \(current.rawValue + 1) of \(OnboardingStep.allCases.count): \(current.title)")
            }
        }
    }
}

// MARK: - Navigation bar

/// Shared bottom bar: Back (when applicable), a "Skip setup" link, and a primary
/// forward button whose label and enabled-state are step-aware.
struct OnboardingNavBar: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        HStack {
            if container.onboardingState.canGoBack {
                Button(String(localized: "Back")) {
                    container.onboardingState.back()
                }
            }
            Spacer()
            if !container.onboardingState.isLastStep {
                Button(String(localized: "Skip setup")) {
                    container.finishOnboarding(as: .skipped)
                }
                .buttonStyle(.link)
            }
            Button(primaryTitle) { advance() }
                .keyboardShortcut(.defaultAction)
                .disabled(primaryDisabled)
        }
    }

    private var primaryTitle: String {
        switch container.onboardingState.step {
        case .welcome: return String(localized: "Get Started")
        case .finish: return String(localized: "Start Using ThinkAloud")
        default: return String(localized: "Continue")
        }
    }

    private var primaryDisabled: Bool {
        switch container.onboardingState.step {
        case .permissions:
            return container.permissions.microphoneStatus != .granted
        case .model:
            return !readiness.modelReady
        case .finish:
            return !readiness.canFinish
        case .welcome, .tutorial:
            return false
        }
    }

    private var readiness: OnboardingReadiness {
        let manager = container.modelManager
        return OnboardingReadiness(
            microphoneGranted: container.permissions.microphoneStatus == .granted,
            modelReady: manager.runtimeStatus.isReady || manager.isDownloaded(manager.profile)
        )
    }

    private func advance() {
        if container.onboardingState.isLastStep {
            container.finishOnboarding(as: .completed)
        } else {
            container.onboardingState.next()
        }
    }
}

// MARK: - Shared step building blocks

/// Title + subtitle header used at the top of most steps.
struct OnboardingHeader: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title2.bold())
            Text(subtitle)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Icon + text bullet used on the Welcome step.
struct OnboardingFeatureRow: View {
    let icon: String
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.tint)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// Rounded container card matching the grouped-form look used elsewhere in the app.
struct OnboardingCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
}

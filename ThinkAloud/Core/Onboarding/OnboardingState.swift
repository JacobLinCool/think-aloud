import Foundation
import Observation

/// Ordered steps of the first-run setup flow. `rawValue` drives ordering and the
/// progress indicator; declaration order is the on-screen order.
enum OnboardingStep: Int, CaseIterable, Identifiable, Sendable {
    case welcome
    case permissions
    case model
    case tutorial
    case finish

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .welcome: return String(localized: "Welcome")
        case .permissions: return String(localized: "Permissions")
        case .model: return String(localized: "Speech model")
        case .tutorial: return String(localized: "Shortcuts")
        case .finish: return String(localized: "Finish")
        }
    }
}

enum OnboardingCompletionOutcome: Sendable {
    case completed
    case skipped
}

struct OnboardingReadiness: Equatable, Sendable {
    let microphoneGranted: Bool
    let modelReady: Bool

    var canFinish: Bool { microphoneGranted && modelReady }
}

/// Drives the onboarding window: which step is showing, and whether the flow has
/// ever been completed (so it only auto-presents on first launch). Completion is a
/// single Bool in UserDefaults — mirrors the persistence style of `ModelManager`.
@MainActor
@Observable
final class OnboardingState {
    private let completedKey = "ThinkAloud.onboardingCompleted"
    @ObservationIgnored private let defaults: UserDefaults

    var step: OnboardingStep = .welcome

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// `true` only after the user explicitly finishes or skips the flow.
    var isCompleted: Bool {
        defaults.bool(forKey: completedKey)
    }

    var canGoBack: Bool { step.rawValue > 0 }
    var isLastStep: Bool { step == OnboardingStep.allCases.last }

    func back() {
        guard let idx = OnboardingStep.allCases.firstIndex(of: step), idx > 0 else { return }
        step = OnboardingStep.allCases[idx - 1]
    }

    func next() {
        guard let idx = OnboardingStep.allCases.firstIndex(of: step),
              idx < OnboardingStep.allCases.count - 1 else { return }
        step = OnboardingStep.allCases[idx + 1]
    }

    func go(to step: OnboardingStep) {
        self.step = step
    }

    /// Rewind to the first step. Called whenever the window opens so re-runs (from the
    /// menu bar / Settings) always start at Welcome.
    func rewind() {
        step = .welcome
    }

    /// Persist explicit completion or skip. Closing the window is deliberately not completion.
    func markCompleted() {
        defaults.set(true, forKey: completedKey)
    }
}

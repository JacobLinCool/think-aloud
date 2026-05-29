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
}

/// Drives the onboarding window: which step is showing, and whether the flow has
/// ever been completed (so it only auto-presents on first launch). Completion is a
/// single Bool in UserDefaults — mirrors the persistence style of `ModelManager`.
@MainActor
@Observable
final class OnboardingState {
    private let completedKey = "ThinkAloud.onboardingCompleted"

    var step: OnboardingStep = .welcome

    /// `true` once the user has finished or dismissed the flow at least once.
    var isCompleted: Bool {
        UserDefaults.standard.bool(forKey: completedKey)
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

    /// Persist that the flow has been seen so it won't auto-present again. Called on any
    /// window close — finishing, skipping, or hitting the red close button all count.
    func markCompleted() {
        UserDefaults.standard.set(true, forKey: completedKey)
    }
}

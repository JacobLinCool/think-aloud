import Foundation
@preconcurrency import UserNotifications

/// Surfaces insertion failures as user-visible notifications. Success is silent — the inserted
/// text in the target app is itself the feedback.
@MainActor
enum InsertionFeedback {
    private static var didRequestAuthorization = false

    static func notifyIfNeeded(outcome: TextInsertionManager.InsertionOutcome) {
        if outcome.inserted { return }
        let title: String
        if outcome.copiedToClipboard {
            title = String(localized: "Copied to clipboard — paste manually")
        } else {
            title = String(localized: "Could not insert text")
        }
        post(title: title, body: outcome.message)
    }

    private static func post(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        ensureAuthorized(center: center) { granted in
            guard granted else {
                NSLog("ThinkAloud: insertion notification skipped — not authorized; msg=\(body)")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = nil
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request) { error in
                if let error {
                    NSLog("ThinkAloud: notification add failed: \(error)")
                }
            }
        }
    }

    private static func ensureAuthorized(center: UNUserNotificationCenter, completion: @escaping @Sendable (Bool) -> Void) {
        if didRequestAuthorization {
            center.getNotificationSettings { settings in
                completion(settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional)
            }
            return
        }
        didRequestAuthorization = true
        center.requestAuthorization(options: [.alert]) { granted, _ in
            completion(granted)
        }
    }
}

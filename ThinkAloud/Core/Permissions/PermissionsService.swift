import AVFoundation
import AppKit
import ApplicationServices
import Foundation
import Observation

@MainActor
@Observable
final class PermissionsService {
    enum Status: Sendable, Equatable {
        case granted
        case denied
        case notDetermined
        case unknown

        var label: String {
            switch self {
            case .granted: return String(localized: "Granted")
            case .denied: return String(localized: "Missing")
            case .notDetermined: return String(localized: "Not requested")
            case .unknown: return String(localized: "Unknown")
            }
        }
    }

    private(set) var microphoneStatus: Status = .unknown
    private(set) var accessibilityStatus: Status = .unknown

    init() {
        refresh()
    }

    func refresh() {
        microphoneStatus = currentMicStatus()
        accessibilityStatus = AXIsProcessTrusted() ? .granted : .denied
    }

    func requestMicrophone() async {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        microphoneStatus = granted ? .granted : .denied
    }

    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Triggers macOS's own "grant Accessibility access" dialog and registers the app in the
    /// Accessibility list. Unlike microphone, there's no async grant callback — the user toggles
    /// it in System Settings — so callers should `refresh()` afterwards (e.g. on a poll / window
    /// focus) to pick up the change. Updates `accessibilityStatus` with the immediate result.
    func promptAccessibility() {
        // The SDK exposes `kAXTrustedCheckOptionPrompt` as a non-Sendable global `var`, which
        // Swift 6 strict concurrency rejects. Its value is the stable string below.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        accessibilityStatus = trusted ? .granted : .denied
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func currentMicStatus() -> Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .unknown
        }
    }
}

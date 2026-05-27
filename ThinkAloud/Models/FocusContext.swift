import AppKit
import Foundation

struct FocusContext: Sendable, Equatable {
    let appBundleID: String?
    let appName: String?
    let processID: pid_t?
    let timestamp: Date

    static func capture() -> FocusContext {
        let frontmost = NSWorkspace.shared.frontmostApplication
        return FocusContext(
            appBundleID: frontmost?.bundleIdentifier,
            appName: frontmost?.localizedName,
            processID: frontmost?.processIdentifier,
            timestamp: Date()
        )
    }
}

import Observation
import ServiceManagement

/// Thin wrapper over `SMAppService.mainApp` for the "Open at login" toggle. Reflects the REAL
/// registration status (never an assumed success) and surfaces errors — e.g. the user disabled the
/// item in System Settings → General → Login Items, which leaves the service in `.requiresApproval`.
///
/// Default is OFF: we never register at first launch. The toggle simply mirrors the OS state.
@MainActor
@Observable
final class LaunchAtLoginService {
    private(set) var status: SMAppService.Status
    /// Last error from a register/unregister attempt, surfaced inline; nil when the last call worked.
    private(set) var lastError: String?

    init() {
        status = SMAppService.mainApp.status
    }

    var isEnabled: Bool { status == .enabled }

    /// macOS marks the item as needing the user's approval in Login Items (e.g. after they toggled
    /// it off there). The toggle can't fix this from inside the app — direct them to System Settings.
    var requiresApproval: Bool { status == .requiresApproval }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                // Unregistering when already not-registered throws; only attempt it when needed.
                if status != .notRegistered {
                    try SMAppService.mainApp.unregister()
                }
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        // Re-read so the toggle reflects what actually happened, not what we asked for.
        refresh()
    }
}

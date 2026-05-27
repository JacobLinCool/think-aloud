import Foundation
import Observation

/// Owns the in-memory HF token state and mirrors it to Keychain. SwiftUI observes this for
/// reactive button enable/disable etc. Persists last verified username for convenience.
@MainActor
@Observable
final class HFTokenStore {
    private(set) var token: String?
    var verifiedUsername: String? {
        didSet {
            if let v = verifiedUsername {
                UserDefaults.standard.set(v, forKey: usernameKey)
            } else {
                UserDefaults.standard.removeObject(forKey: usernameKey)
            }
        }
    }

    private let usernameKey = "ThinkAloud.huggingfaceUsername"

    init() {
        self.token = HFKeychain.get()
        self.verifiedUsername = UserDefaults.standard.string(forKey: usernameKey)
    }

    var hasToken: Bool { (token ?? "").isEmpty == false }

    func save(token raw: String) throws {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try clear()
            return
        }
        try HFKeychain.set(trimmed)
        self.token = trimmed
        // Clear cached username on token change — next test-connection should refresh it.
        self.verifiedUsername = nil
    }

    func clear() throws {
        try HFKeychain.delete()
        self.token = nil
        self.verifiedUsername = nil
    }
}

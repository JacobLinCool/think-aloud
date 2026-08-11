import Foundation
import Observation

@MainActor
protocol HFAuthStore: AnyObject {
    var token: String? { get }
    var verifiedUsername: String? { get set }
    var hasToken: Bool { get }
    var accessError: String? { get }
}

/// Owns the in-memory HF token state and mirrors it to Keychain. SwiftUI observes this for
/// reactive button enable/disable etc. Persists last verified username for convenience.
@MainActor
@Observable
final class HFTokenStore: HFAuthStore {
    private(set) var token: String?
    private(set) var accessError: String?
    var verifiedUsername: String? {
        didSet {
            if let v = verifiedUsername {
                UserDefaults.standard.set(v, forKey: usernameKey)
            } else {
                UserDefaults.standard.removeObject(forKey: usernameKey)
            }
        }
    }

    private let usernameKey: String
    private let keychainService: String
    private let keychainAccount: String

    init(
        keychainService: String = HFKeychain.defaultService,
        keychainAccount: String = HFKeychain.defaultAccount
    ) {
        self.usernameKey = keychainService == HFKeychain.defaultService
            ? "ThinkAloud.huggingfaceUsername"
            : "ThinkAloud.huggingfaceUsername.\(keychainService)"
        self.keychainService = keychainService
        self.keychainAccount = keychainAccount
        do {
            self.token = try HFKeychain.get(
                service: keychainService,
                account: keychainAccount
            )
            self.accessError = nil
        } catch {
            NSLog("ThinkAloud: Hugging Face Keychain read failed: \(error)")
            self.token = nil
            self.accessError = String(
                localized: "ThinkAloud couldn’t access the Hugging Face token in Keychain. Check Keychain access and try again."
            )
        }
        self.verifiedUsername = token == nil || accessError != nil
            ? nil
            : UserDefaults.standard.string(forKey: usernameKey)
    }

    var hasToken: Bool { (token ?? "").isEmpty == false }

    func save(token raw: String) throws {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try clear()
            return
        }
        do {
            try HFKeychain.set(
                trimmed,
                service: keychainService,
                account: keychainAccount
            )
            self.token = trimmed
            self.accessError = nil
            // Clear cached username on token change — next test-connection should refresh it.
            self.verifiedUsername = nil
        } catch {
            NSLog("ThinkAloud: Hugging Face Keychain save failed: \(error)")
            accessError = String(
                localized: "ThinkAloud couldn’t access the Hugging Face token in Keychain. Check Keychain access and try again."
            )
            throw error
        }
    }

    func clear() throws {
        do {
            try HFKeychain.delete(
                service: keychainService,
                account: keychainAccount
            )
            self.token = nil
            self.verifiedUsername = nil
            self.accessError = nil
        } catch {
            NSLog("ThinkAloud: Hugging Face Keychain deletion failed: \(error)")
            accessError = String(
                localized: "ThinkAloud couldn’t access the Hugging Face token in Keychain. Check Keychain access and try again."
            )
            throw error
        }
    }
}

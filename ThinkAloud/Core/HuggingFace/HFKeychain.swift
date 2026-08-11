import Foundation
import Security

/// Minimal Keychain wrapper for the Hugging Face token. We never persist the token in
/// UserDefaults — Keychain only, accessible-after-first-unlock so it survives reboots but
/// stays encrypted at rest.
enum HFKeychain {
    static let defaultService = "com.jacoblincool.thinkaloud.huggingface"
    static let defaultAccount = "token"

    enum KeychainError: Error, LocalizedError {
        case unhandled(OSStatus)
        case invalidTokenData

        var errorDescription: String? {
            switch self {
            case .unhandled:
                return String(
                    localized: "ThinkAloud couldn’t access the Hugging Face token in Keychain. Check Keychain access and try again."
                )
            case .invalidTokenData:
                return String(
                    localized: "The Hugging Face token in Keychain is unreadable. Replace or clear it in Dataset settings."
                )
            }
        }
    }

    static func set(_ value: String, service: String = defaultService, account: String = defaultAccount) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let replacement: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        // Updating preserves the existing credential if Keychain rejects the replacement. A
        // delete-then-add sequence can permanently destroy a valid token on any add failure.
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            replacement as CFDictionary
        )
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var attributes = query
            replacement.forEach { attributes[$0.key] = $0.value }
            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unhandled(addStatus)
            }
        default:
            throw KeychainError.unhandled(updateStatus)
        }
    }

    static func get(
        service: String = defaultService,
        account: String = defaultAccount
    ) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainError.unhandled(status)
        }
        guard let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidTokenData
        }
        return token
    }

    static func delete(service: String = defaultService, account: String = defaultAccount) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError.unhandled(status)
        }
    }
}

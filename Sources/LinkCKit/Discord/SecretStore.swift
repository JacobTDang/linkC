import Foundation
import Security

/// Where linkC keeps a secret it holds itself: only Discord webhook URLs (spec 2026-11-05 §1, §6).
/// The Keychain in the app; an in-memory store in tests.
public protocol SecretStore: Sendable {
    /// The secret, or nil when there is none.
    func secret(service: String, account: String) throws -> String?
    func setSecret(_ value: String, service: String, account: String) throws
    /// Removes the secret; one already gone is fine.
    func deleteSecret(service: String, account: String) throws
}

/// One Keychain generic password per secret, in the user's login keychain.
public struct KeychainSecretStore: SecretStore {
    public struct Failure: Error, CustomStringConvertible {
        public let status: OSStatus

        public var description: String {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
            return "Keychain error \(status): \(message)"
        }
    }

    public init() {}

    private func query(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func secret(service: String, account: String) throws -> String? {
        var query = query(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure(status: status) }
        guard let data = item as? Data, let text = String(data: data, encoding: .utf8) else {
            throw Failure(status: errSecDecode)
        }
        return text
    }

    public func setSecret(_ value: String, service: String, account: String) throws {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(service: service, account: account) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(service: service, account: account)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw Failure(status: added) }
            return
        }
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    public func deleteSecret(service: String, account: String) throws {
        let status = SecItemDelete(query(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }
}

extension KeychainSecretStore.Failure: LocalizedError {
    public var errorDescription: String? { description }
}

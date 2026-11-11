import Foundation
@testable import LinkCKit

/// A `SecretStore` for tests: secrets in memory, never the Keychain. While `failure` is set, every
/// call throws it.
final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]
    private var storedFailure: Error?

    var failure: Error? {
        get { lock.withLock { storedFailure } }
        set { lock.withLock { storedFailure = newValue } }
    }

    var count: Int { lock.withLock { items.count } }

    private func key(_ service: String, _ account: String) -> String { service + "\u{0}" + account }

    func secret(service: String, account: String) throws -> String? {
        try lock.withLock {
            if let storedFailure { throw storedFailure }
            return items[key(service, account)]
        }
    }

    func setSecret(_ value: String, service: String, account: String) throws {
        try lock.withLock {
            if let storedFailure { throw storedFailure }
            items[key(service, account)] = value
        }
    }

    func deleteSecret(service: String, account: String) throws {
        try lock.withLock {
            if let storedFailure { throw storedFailure }
            items[key(service, account)] = nil
        }
    }
}

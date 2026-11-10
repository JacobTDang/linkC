import Foundation
import Observation

/// A webhook URL linkC accepts: `https://` on Discord's own hosts, with the path
/// `/api/webhooks/<numeric id>/<token>` and nothing after it (spec §6).
public struct DiscordWebhookURL: Equatable, Sendable {
    public let url: URL
    /// The webhook's numeric id: what Settings shows, never the URL.
    public let id: String

    public static let hosts: Set<String> = ["discord.com", "discordapp.com", "canary.discord.com", "ptb.discord.com"]

    public struct Refusal: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    public static func parse(_ text: String) -> Result<DiscordWebhookURL, Refusal> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let shape = "a webhook URL looks like https://discord.com/api/webhooks/<id>/<token>"
        guard let components = URLComponents(string: trimmed), URL(string: trimmed) != nil else {
            return .failure(Refusal(description: "that is not a URL: \(shape)"))
        }
        guard components.scheme == "https" else {
            return .failure(Refusal(description: "a webhook URL starts with https://"))
        }
        guard let host = components.host?.lowercased(), hosts.contains(host) else {
            return .failure(Refusal(description: "a webhook URL is on discord.com"))
        }
        guard components.port == nil, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            return .failure(Refusal(description: shape))
        }
        let parts = components.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 5, parts[0].isEmpty, parts[1] == "api", parts[2] == "webhooks" else {
            return .failure(Refusal(description: shape))
        }
        let id = parts[3], token = parts[4]
        guard !id.isEmpty, id.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            return .failure(Refusal(description: "the webhook id is a number: \(shape)"))
        }
        guard !token.isEmpty, token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            return .failure(Refusal(description: "the webhook token is missing or malformed: \(shape)"))
        }
        guard !components.percentEncodedPath.contains("%") else {
            return .failure(Refusal(description: shape))
        }
        guard let normalized = URL(string: "https://\(host)/api/webhooks/\(id)/\(token)") else {
            return .failure(Refusal(description: shape))
        }
        return .success(DiscordWebhookURL(url: normalized, id: id))
    }
}

extension DiscordWebhookURL: CustomStringConvertible {
    /// Its id only: the URL holds the token, which is a secret.
    public var description: String { "webhook \(id)" }
}

extension DiscordWebhookURL.Refusal: LocalizedError {
    public var errorDescription: String? { description }
}

/// One webhook as linkC last read it from the Keychain.
public enum DiscordWebhookState: Equatable, Sendable {
    case notSet
    case set(DiscordWebhookURL)
    /// Listed for a project, but its Keychain item is gone.
    case missing
    /// The Keychain could not be read, or holds something that is not a webhook URL.
    case unreadable(String)
}

/// Where an event goes (spec §3).
public enum DiscordRoute: Equatable, Sendable {
    case webhook(account: String, DiscordWebhookURL)
    /// Not posted: no webhook applies (`reason` nil), or the one that applies can't be used.
    case none(reason: String?)
}

/// The Discord webhooks the user set: a default, and one per project folder (spec §3, §6). Each URL
/// is a Keychain item under `service`, account `defaultAccount` or the canonical folder;
/// `AppPreferences.discordProjects` lists the folders that have one, with no URLs. The Keychain is
/// read when linkC starts and on `reload()`, not for every event.
@MainActor
@Observable
public final class DiscordWebhooks {
    public static let service = "com.linkc.app.discord-webhook"
    public static let defaultAccount = "default"

    @ObservationIgnored private let secrets: SecretStore
    @ObservationIgnored private let preferences: AppPreferences
    private var states: [String: DiscordWebhookState] = [:]

    public init(secrets: SecretStore, preferences: AppPreferences) {
        self.secrets = secrets
        self.preferences = preferences
        reload()
    }

    /// The project folders that have a webhook of their own.
    public var projects: [String] { preferences.discordProjects }

    public func state(for account: String) -> DiscordWebhookState {
        if let state = states[account] { return state }
        return preferences.discordProjects.contains(account) ? .missing : .notSet
    }

    /// Reads the default webhook and every listed project's again.
    public func reload() {
        var loaded: [String: DiscordWebhookState] = [:]
        for account in [Self.defaultAccount] + preferences.discordProjects {
            loaded[account] = read(account, listed: account != Self.defaultAccount)
        }
        states = loaded
    }

    /// Stores `text` for `account` (the default, or a canonical project folder) once it parses.
    @discardableResult
    public func set(_ text: String, for account: String) throws -> DiscordWebhookURL {
        let account = account == Self.defaultAccount ? account : ProjectPath.canonical(account)
        let webhook = try DiscordWebhookURL.parse(text).get()
        try secrets.setSecret(webhook.url.absoluteString, service: Self.service, account: account)
        if account != Self.defaultAccount, !preferences.discordProjects.contains(account) {
            preferences.discordProjects.append(account)
        }
        states[account] = .set(webhook)
        return webhook
    }

    public func remove(_ account: String) throws {
        let account = account == Self.defaultAccount ? account : ProjectPath.canonical(account)
        try secrets.deleteSecret(service: Self.service, account: account)
        preferences.discordProjects.removeAll { $0 == account }
        states[account] = nil
    }

    /// Where `event` goes: its project's webhook when the project has its own entry, else the default.
    /// A project with its own entry never falls back, even when its webhook can't be used.
    public func route(_ event: LinkCEvent) -> DiscordRoute {
        let account = event.project.flatMap { preferences.discordProjects.contains($0) ? $0 : nil }
            ?? Self.defaultAccount
        switch state(for: account) {
        case .set(let webhook): return .webhook(account: account, webhook)
        case .notSet: return .none(reason: nil)
        case .missing: return .none(reason: "this project's webhook is missing — set it again")
        case .unreadable(let reason): return .none(reason: reason)
        }
    }

    private func read(_ account: String, listed: Bool) -> DiscordWebhookState {
        do {
            guard let text = try secrets.secret(service: Self.service, account: account) else {
                return listed ? .missing : .notSet
            }
            switch DiscordWebhookURL.parse(text) {
            case .success(let webhook): return .set(webhook)
            case .failure(let refusal):
                return unreadable(account: account, reason: "the stored webhook is not valid: \(refusal)")
            }
        } catch {
            return unreadable(account: account, reason: "the Keychain could not be read: \(error.localizedDescription)")
        }
    }

    private func unreadable(account: String, reason: String) -> DiscordWebhookState {
        let name = account == Self.defaultAccount ? "default" : URL(fileURLWithPath: account).lastPathComponent
        NSLog("[linkC discord] %@: %@", name, reason)
        return .unreadable(reason)
    }
}

import Foundation
import Observation

/// Why Settings could not act on a webhook.
public enum DiscordNotifierError: Error, LocalizedError, Equatable {
    case noWebhook
    case unusable(String)

    public var errorDescription: String? {
        switch self {
        case .noWebhook: "No webhook is set."
        case .unusable(let reason): reason
        }
    }
}

/// Posts linkC's events to the user's Discord webhooks (spec 2026-11-05). It routes each event (§3),
/// keeps one `WebhookQueue` per webhook URL, passes a global 429 to every queue (§4.1), tells the user
/// once when a webhook stops (§4.4), and keeps each webhook's status for Settings (§6).
@MainActor
@Observable
public final class DiscordNotifier<C: Clock> where C.Duration == Duration {
    public let webhooks: DiscordWebhooks
    /// Each queue's status, by webhook URL.
    private var queueStatus: [String: WebhookStatus] = [:]
    @ObservationIgnored private var queues: [String: WebhookQueue<C>] = [:]
    /// The end of the last global 429's wait, so a queue made during it waits too.
    @ObservationIgnored private var globalPauseUntil: C.Instant?
    @ObservationIgnored private var isShutDown = false
    @ObservationIgnored private let transport: WebhookTransport
    @ObservationIgnored private let clock: C
    @ObservationIgnored private let wallClock: () -> Date
    @ObservationIgnored private let notifyUser: (String, String) -> Void

    /// `notifyUser` posts a macOS notification that is never forwarded to Discord.
    public init(webhooks: DiscordWebhooks, transport: WebhookTransport, clock: C,
                wallClock: @escaping () -> Date = Date.init, notifyUser: @escaping (String, String) -> Void) {
        self.webhooks = webhooks
        self.transport = transport
        self.clock = clock
        self.wallClock = wallClock
        self.notifyUser = notifyUser
    }

    public func post(_ event: LinkCEvent) {
        guard !isShutDown else { return }
        guard case .webhook(let account, let webhook) = webhooks.route(event) else { return }
        queue(for: webhook, account: account).enqueue(event)
    }

    /// Stores a webhook for `account` and starts it fresh, a stopped one included (Settings' Set).
    public func set(_ text: String, for account: String) throws {
        let account = account == DiscordWebhooks.defaultAccount ? account : ProjectPath.canonical(account)
        let previous = webhooks.state(for: account)
        let webhook = try webhooks.set(text, for: account)
        if case .set(let old) = previous, old != webhook {
            retireQueue(for: old)
        }
        _ = liveQueue(for: webhook, account: account)
    }

    public func remove(_ account: String) throws {
        let account = account == DiscordWebhooks.defaultAccount ? account : ProjectPath.canonical(account)
        guard case .set(let webhook) = webhooks.state(for: account) else {
            try webhooks.remove(account)
            return
        }
        try webhooks.remove(account)
        retireQueue(for: webhook)
    }

    /// Settings' Send test: one "linkC is connected" event through the live queue. A test restarts a
    /// stopped webhook (spec §4.4).
    public func sendTest(to account: String) throws {
        let account = account == DiscordWebhooks.defaultAccount ? account : ProjectPath.canonical(account)
        switch webhooks.state(for: account) {
        case .set(let webhook):
            let label = account == DiscordWebhooks.defaultAccount ? "every project without its own webhook" : Self.name(of: account)
            liveQueue(for: webhook, account: account).enqueue(LinkCEvent(
                kind: .alert, tone: .done, title: "linkC is connected",
                body: "Events for \(label) will be posted here.",
                project: account == DiscordWebhooks.defaultAccount ? nil : account, at: wallClock()))
        case .notSet:
            throw DiscordNotifierError.noWebhook
        case .missing:
            throw DiscordNotifierError.unusable("this project's webhook is missing — set it again")
        case .unreadable(let reason):
            throw DiscordNotifierError.unusable(reason)
        }
    }

    /// What Settings shows for `account`'s webhook. `account` is the default or a canonical folder from
    /// `webhooks.projects`: this is read from a view body, so it touches no disk.
    public func status(for account: String) -> WebhookStatus {
        switch webhooks.state(for: account) {
        case .set(let webhook): return queueStatus[webhook.url.absoluteString] ?? .idle
        case .notSet: return .idle
        case .missing: return .missing
        case .unreadable(let reason): return .failed(reason, at: wallClock())
        }
    }

    /// Stops every queue: linkC is quitting.
    public func shutdown() {
        isShutDown = true
        queues.values.forEach { $0.cancel() }
        queues.removeAll()
        queueStatus.removeAll()
    }

    /// "default", or the project folder's name: how logs and notices name a webhook, never by its URL.
    static func name(of account: String) -> String {
        account == DiscordWebhooks.defaultAccount ? "default" : URL(fileURLWithPath: account).lastPathComponent
    }

    private func queue(for webhook: DiscordWebhookURL, account: String) -> WebhookQueue<C> {
        queues[webhook.url.absoluteString] ?? replaceQueue(for: webhook, account: account)
    }

    /// The queue for `webhook`: the live one, or a fresh one when there is none or it stopped (a stopped
    /// webhook restarts only when it is set again or tested, spec §4.4).
    private func liveQueue(for webhook: DiscordWebhookURL, account: String) -> WebhookQueue<C> {
        if let queue = queues[webhook.url.absoluteString], !queue.isStopped { return queue }
        return replaceQueue(for: webhook, account: account)
    }

    /// Retires `webhook`'s queue if no account still uses that URL.
    private func retireQueue(for webhook: DiscordWebhookURL) {
        let stillUsed = ([DiscordWebhooks.defaultAccount] + webhooks.projects).contains {
            webhooks.state(for: $0) == .set(webhook)
        }
        if !stillUsed {
            let key = webhook.url.absoluteString
            queues[key]?.cancel()
            queues[key] = nil
            queueStatus[key] = nil
        }
    }

    @discardableResult
    private func replaceQueue(for webhook: DiscordWebhookURL, account: String) -> WebhookQueue<C> {
        let key = webhook.url.absoluteString
        queues[key]?.cancel()
        let name = Self.name(of: account)
        let queue = WebhookQueue(name: name, url: webhook.url, transport: transport, clock: clock, wallClock: wallClock)
        queue.onStatus = { [weak self] status in self?.queueStatus[key] = status }
        queue.onGlobalLimit = { [weak self] wait in self?.pauseEveryQueue(for: wait) }
        queue.onStopped = { [weak self] status in
            self?.notifyUser("linkC stopped posting to Discord",
                             "The \(name) webhook answered \(status): it was deleted or is no longer valid. "
                                + "Set it again in Settings > Discord.")
        }
        if let globalPauseUntil {
            let now = clock.now
            if now < globalPauseUntil { queue.pause(for: now.duration(to: globalPauseUntil)) }
        }
        queues[key] = queue
        queueStatus[key] = .idle
        return queue
    }

    private func pauseEveryQueue(for wait: Duration) {
        let until = clock.now.advanced(by: wait)
        if let current = globalPauseUntil, until <= current { return }
        globalPauseUntil = until
        queues.values.forEach { $0.pause(for: wait) }
    }
}

extension WebhookStatus {
    /// The status line Settings shows under a webhook (spec §6).
    public func label(now: Date) -> String {
        switch self {
        case .idle:
            return "Not posted yet"
        case .posted(let at):
            let seconds = Int(now.timeIntervalSince(at))
            if seconds < 60 { return "Posted just now" }
            if seconds < 3600 { return "Posted \(seconds / 60)m ago" }
            return "Posted \(seconds / 3600)h ago"
        case .waiting(let until):
            return "Waiting \(max(1, Int(until.timeIntervalSince(now).rounded(.up))))s for Discord"
        case .stopped(let status):
            return status == 404 ? "Stopped: webhook deleted (404)" : "Stopped: webhook not accepted (\(status))"
        case .failed(let message, _):
            return "Failed: \(message)"
        case .missing:
            return "Webhook missing — set it again"
        }
    }
}

import Foundation

/// What Settings shows for a webhook (spec §6).
public enum WebhookStatus: Equatable, Sendable {
    /// Nothing posted since linkC started.
    case idle
    case posted(at: Date)
    /// Holding a message until Discord's limits allow it, or until a retry.
    case waiting(until: Date)
    /// Discord answered 404, 401 or 403: the webhook is deleted or invalid. Nothing more is sent until
    /// its URL is set again or a test succeeds.
    case stopped(status: Int)
    /// The last message could not be posted.
    case failed(String, at: Date)
    /// A project's webhook is listed but its Keychain item is gone.
    case missing
}

/// One webhook's queue (spec §4): events go out oldest first, one request at a time, packed up to
/// Discord's limits, paced by `WebhookPacer`, then resent, dropped or stopped by Discord's answer.
/// `name` is "default" or the project folder's name: logs never carry the URL.
@MainActor
final class WebhookQueue<C: Clock> where C.Duration == Duration {
    static var maxPending: Int { 100 }
    /// The waits before each retry of a message Discord didn't answer: the first attempt plus five.
    static var retryDelays: [Duration] { [.seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(32)] }

    let name: String
    let url: URL
    private let postURL: URL
    private let transport: WebhookTransport
    private let clock: C
    private let wallClock: () -> Date
    private var pacer: WebhookPacer<C.Instant>
    private var pending: [LinkCEvent] = []
    private var dropped = 0
    private var runner: Task<Void, Never>?
    private var cancelled = false

    private(set) var status: WebhookStatus = .idle {
        didSet { if status != oldValue { onStatus?(status) } }
    }

    var onStatus: ((WebhookStatus) -> Void)?
    /// A 429 for Discord's global, per-IP limit: `DiscordNotifier` pauses every queue for this long.
    var onGlobalLimit: ((Duration) -> Void)?
    /// Discord answered 404, 401 or 403: this webhook is done.
    var onStopped: ((Int) -> Void)?

    init(name: String, url: URL, transport: WebhookTransport, clock: C, wallClock: @escaping () -> Date = Date.init) {
        self.name = name
        self.url = url
        self.postURL = DiscordMessage.postURL(for: url)
        self.transport = transport
        self.clock = clock
        self.wallClock = wallClock
        self.pacer = WebhookPacer()
    }

    var isStopped: Bool {
        if case .stopped = status { return true }
        return false
    }

    /// Queues `event` for the next message. A stopped or cancelled webhook takes nothing.
    func enqueue(_ event: LinkCEvent) {
        guard !cancelled, !isStopped else { return }
        pending.append(event)
        if pending.count > Self.maxPending {
            let excess = pending.count - Self.maxPending
            pending.removeFirst(excess)
            dropped += excess
        }
        guard runner == nil else { return }
        runner = Task { [weak self] in await self?.drain() }
    }

    /// Holds the next request for `duration`: Discord's global limit, reported by any queue.
    func pause(for duration: Duration) {
        pacer.block(until: clock.now.advanced(by: duration))
    }

    /// Stops sending, for good: the queue is being replaced, or linkC is quitting. A request still in
    /// flight is answered into nothing: no status, no stop, no global pause.
    func cancel() {
        cancelled = true
        pending.removeAll()
        dropped = 0
        runner?.cancel()
        runner = nil
    }

    private func drain() async {
        defer { runner = nil }
        while !cancelled, !pending.isEmpty, !isStopped, !Task.isCancelled {
            let events = pending
            pending.removeAll()
            let carriedDropped = dropped
            dropped = 0
            let pages: [DiscordMessage.Page]
            do {
                pages = try DiscordMessage.pages(events, dropped: carriedDropped)
            } catch {
                NSLog("[linkC discord] %@: a message could not be built — %@", name, error.localizedDescription)
                status = .failed("a message could not be built: \(error.localizedDescription)", at: wallClock())
                dropped += events.count + carriedDropped
                continue
            }
            for (index, page) in pages.enumerated() {
                guard !cancelled, !isStopped, !Task.isCancelled else { return }
                let carried = page.eventCount + (index == 0 ? carriedDropped : 0)
                let body: Data
                do {
                    body = try DiscordMessage.encode(page.payload)
                } catch {
                    NSLog("[linkC discord] %@: a message could not be built — %@", name, error.localizedDescription)
                    status = .failed("a message could not be built: \(error.localizedDescription)", at: wallClock())
                    dropped += carried
                    continue
                }
                await deliver(body, carrying: carried)
            }
        }
    }

    /// Sends one message until Discord takes it, refuses it, stops the webhook, or the retries run out
    /// (spec §4.4).
    private func deliver(_ body: Data, carrying carried: Int) async {
        var failures = 0
        while !cancelled, !Task.isCancelled {
            await waitForTurn()
            guard !cancelled, !Task.isCancelled else { return }
            pacer.recordSend(at: clock.now)
            let response: WebhookResponse
            do {
                response = try await transport.post(body, to: postURL)
                guard !cancelled else { return }
            } catch {
                guard !cancelled else { return }
                guard !Task.isCancelled, await retry(&failures, because: "no answer: \(error.localizedDescription)") else {
                    if !cancelled { dropped += carried }
                    return
                }
                continue
            }
            let limits = DiscordRateLimit.read(response)
            if let exhausted = limits.exhaustedFor {
                pacer.block(until: clock.now.advanced(by: exhausted))
            }
            if response.savedMessageID != nil {
                status = .posted(at: wallClock())
                return
            }
            switch response.status {
            case 200..<300:
                guard await retry(&failures, because: "Discord answered \(response.status) without saving the message") else {
                    if !cancelled { dropped += carried }
                    return
                }
            case 429:
                let wait = limits.retryAfter ?? DiscordRateLimit.defaultRetryAfter
                pacer.block(until: clock.now.advanced(by: wait))
                if limits.global { onGlobalLimit?(wait) }
            case 401, 403, 404:
                pending.removeAll()
                dropped = 0
                NSLog("[linkC discord] %@: Discord answered %ld, so this webhook is stopped", name, response.status)
                status = .stopped(status: response.status)
                onStopped?(response.status)
                return
            case 300..<400:
                NSLog("[linkC discord] %@: Discord answered %ld, a redirect, which linkC does not follow", name, response.status)
                status = .failed("Discord answered \(response.status), a redirect, which linkC does not follow", at: wallClock())
                dropped += carried
                return
            case 400..<500:
                let text = Self.refusal(for: response)
                NSLog("[linkC discord] %@: %@", name, text)
                status = .failed(text, at: wallClock())
                dropped += carried
                return
            default:
                guard await retry(&failures, because: "Discord answered \(response.status)") else {
                    if !cancelled { dropped += carried }
                    return
                }
            }
        }
    }

    private static func refusal(for response: WebhookResponse) -> String {
        let base = "Discord refused a message (\(response.status))"
        guard let json = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] else {
            return base
        }
        if let code = json["code"], let message = json["message"] as? String {
            return "\(base): code \(code), \(message)"
        }
        return base
    }

    /// Waits out the next retry delay. False once every delay was used: the message is dropped.
    private func retry(_ failures: inout Int, because reason: String) async -> Bool {
        guard failures < Self.retryDelays.count else {
            NSLog("[linkC discord] %@: a message was dropped after %ld retries — %@", name, failures, reason)
            status = .failed("a message was dropped after \(failures) retries: \(reason)", at: wallClock())
            return false
        }
        let delay = Self.retryDelays[failures]
        failures += 1
        status = .waiting(until: wallClock().addingTimeInterval(delay.seconds))
        do {
            try await clock.sleep(for: delay)
        } catch {
            return false
        }
        return true
    }

    /// Sleeps until the pacer lets the next request go. It reads the pacer again after each sleep, as a
    /// global pause can arrive meanwhile.
    private func waitForTurn() async {
        while !Task.isCancelled {
            let now = clock.now
            let ready = pacer.readyAt(now)
            guard now < ready else { return }
            status = .waiting(until: wallClock().addingTimeInterval(now.duration(to: ready).seconds))
            do {
                try await clock.sleep(until: ready, tolerance: nil)
            } catch {
                return
            }
        }
    }
}

extension Duration {
    /// The duration in seconds, for `Date` arithmetic.
    var seconds: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

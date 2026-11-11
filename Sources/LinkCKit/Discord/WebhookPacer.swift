import Foundation

/// When the next request to one webhook may go (spec §4.1): fewer than `limit` requests in the last
/// `window`, and no wait Discord asked for still running. Pure: the queue gives it the clock.
struct WebhookPacer<Instant: InstantProtocol> where Instant.Duration == Duration {
    let limit: Int
    let window: Duration
    /// The send times of the recent requests, oldest first.
    private var sends: [Instant] = []
    private var blockedUntil: Instant?

    init(limit: Int = 5, window: Duration = .seconds(2)) {
        self.limit = limit
        self.window = window
    }

    /// The earliest instant at or after `now` the next request may go.
    func readyAt(_ now: Instant) -> Instant {
        var ready = now
        let recent = sends.filter { now < $0.advanced(by: window) }
        if recent.count >= limit {
            // Once `limit` requests are in the window, the next goes when the oldest of them leaves it.
            ready = max(ready, recent[recent.count - limit].advanced(by: window))
        }
        if let blockedUntil {
            ready = max(ready, blockedUntil)
        }
        return ready
    }

    /// Counts a request, answered or not.
    mutating func recordSend(at instant: Instant) {
        let window = self.window
        sends.removeAll { $0.advanced(by: window) <= instant }
        sends.append(instant)
    }

    /// Holds every request until `instant`. A shorter block never shortens a longer one.
    mutating func block(until instant: Instant) {
        if let blockedUntil, instant <= blockedUntil { return }
        blockedUntil = instant
    }
}

/// What a webhook response says about Discord's rate limits (spec §4.1). Discord says its limits
/// change and must be read, not hard-coded, so these can only make the pacer stricter.
struct DiscordRateLimit: Equatable {
    /// `X-RateLimit-Remaining: 0`: wait `X-RateLimit-Reset-After` before the next request.
    var exhaustedFor: Duration?
    /// A 429: wait this long, then resend.
    var retryAfter: Duration?
    /// A 429 for Discord's global, per-IP limit.
    var global = false

    /// The wait for a 429 that gives none: an odd answer, so a long, safe one.
    static let defaultRetryAfter: Duration = .seconds(5)

    /// The longest wait linkC takes from a response: numbers from the network are untrusted, and an
    /// absurd one would hold the queue for good (or overflow).
    static let longestWait: TimeInterval = 3600

    static func read(_ response: WebhookResponse) -> DiscordRateLimit {
        var limit = DiscordRateLimit()
        if response.headers["x-ratelimit-remaining"] == "0",
           let reset = response.headers["x-ratelimit-reset-after"].flatMap(Double.init) {
            limit.exhaustedFor = duration(seconds: reset)
        }
        guard response.status == 429 else { return limit }
        // A 429 body is JSON; one that isn't leaves the headers to say how long to wait.
        let body = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
        if let seconds = (body?["retry_after"] as? Double) ?? response.headers["retry-after"].flatMap(Double.init) {
            limit.retryAfter = duration(seconds: seconds)
        } else {
            limit.retryAfter = defaultRetryAfter
        }
        limit.global = (body?["global"] as? Bool) == true || response.headers["x-ratelimit-global"]?.lowercased() == "true"
        return limit
    }

    private static func duration(seconds: Double) -> Duration {
        let clamped = seconds.isNaN ? longestWait : min(max(seconds, 0), longestWait)
        return .milliseconds(Int((clamped * 1000).rounded()))
    }
}

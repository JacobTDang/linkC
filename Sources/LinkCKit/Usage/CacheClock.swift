import Foundation

/// When a session's prompt cache goes cold: after that, its next message writes the whole context
/// into the cache again at full price.
public struct CacheExpiry: Equatable, Sendable {
    public let at: Date
    /// Worked out from the provider's cache lifetime and the session's last turn, not reported.
    public let isEstimate: Bool

    public init(at: Date, isEstimate: Bool) {
        self.at = at
        self.isEstimate = isEstimate
    }
}

/// Each session's cache clock, from the best evidence there is and none where there is none.
public enum CacheClock {
    /// GPT-5.6 and later keep a cached prefix at least 30 minutes by default, each read renewing it;
    /// GPT-5.5's only retention (`24h`) typically keeps it about as long (OpenAI's prompt caching guide).
    static let currentRetention: TimeInterval = 30 * 60
    /// Earlier OpenAI models keep an in-memory cache for 5 to 10 idle minutes; the clock counts the shorter.
    static let inMemoryRetention: TimeInterval = 5 * 60

    /// - Parameter reported: the expiry the agent itself reports (Claude's status line), which is
    ///   exact, and shown as it is even while a turn runs.
    /// - Returns: for Codex, an estimate from its model's cache lifetime and the end of its last turn.
    ///   Nil when the agent reports none and its provider publishes no cache lifetime (agy's Gemini,
    ///   Cursor, OpenCode, Kilo, Crush, Grok), when the model is not a GPT model, before any turn
    ///   has run, and while a turn runs or the session is still starting.
    public static func expiry(for session: Session, reported: Date?) -> CacheExpiry? {
        if let reported { return CacheExpiry(at: reported, isEstimate: false) }
        guard session.agentKind == .codex, let model = session.model,
              let lifetime = lifetime(of: model), let turnEnded = session.turnEndedAt else { return nil }
        switch session.state {
        case .working, .starting, .ended: return nil
        case .ready, .waitingPermission, .waitingIdle, .finished, .error: break
        }
        return CacheExpiry(at: turnEnded.addingTimeInterval(lifetime), isEstimate: true)
    }

    /// The cache lifetime of an OpenAI model id such as `gpt-5.6-sol` or `gpt-6-astra`; nil for an
    /// id that names no GPT version.
    static func lifetime(of model: String) -> TimeInterval? {
        guard let match = model.firstMatch(of: /^gpt-(\d+)(?:\.(\d+))?/),
              let major = Int(match.1) else { return nil }
        let minor = match.2.flatMap { Int($0) } ?? 0
        return major > 5 || (major == 5 && minor >= 5) ? currentRetention : inMemoryRetention
    }
}

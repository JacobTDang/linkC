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
    /// GPT-5.5 models support only 24-hour prompt-cache retention.
    static let extendedRetention: TimeInterval = 24 * 3600
    /// Other OpenAI models keep a cached prefix for 5 to 10 idle minutes; the clock counts the shorter.
    static let inMemoryRetention: TimeInterval = 5 * 60

    /// - Parameter reported: the expiry the agent itself reports (Claude's status line), which is exact.
    /// - Returns: nil when the agent reports none and its provider publishes no cache lifetime (agy's
    ///   Gemini, Cursor, OpenCode, Kilo, Crush, Grok), when the model is unknown, and while a turn
    ///   runs or the session is still starting.
    public static func expiry(for session: Session, reported: Date?) -> CacheExpiry? {
        if let reported { return CacheExpiry(at: reported, isEstimate: false) }
        guard session.agentKind == .codex, let model = session.model else { return nil }
        switch session.state {
        case .working, .starting, .ended: return nil
        case .ready, .waitingPermission, .waitingIdle, .finished, .error: break
        }
        let lifetime = model.hasPrefix("gpt-5.5") ? extendedRetention : inMemoryRetention
        return CacheExpiry(at: session.stateChangedAt.addingTimeInterval(lifetime), isEstimate: true)
    }
}

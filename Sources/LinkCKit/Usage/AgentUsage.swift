import Foundation

/// One provider window — 5-hour, weekly — as that provider reports it.
public struct UsageWindow: Sendable, Equatable {
    public let label: String          // "5h", "7d"
    public let usedPercent: Double?   // nil when the provider publishes no limit
    public let tokens: Int?           // nil when the provider reports only a percentage
    public let resetsAt: Date?
    /// True when a read budget ran out before every record inside this window's scan
    /// range was read — `tokens` is then a floor, not the true total. Never inferred from
    /// silence: a reader that stayed within budget must set this false explicitly.
    public let tokensAreLowerBound: Bool

    public init(label: String, usedPercent: Double?, tokens: Int?, resetsAt: Date?,
                tokensAreLowerBound: Bool = false) {
        self.label = label
        self.usedPercent = usedPercent
        self.tokens = tokens
        self.resetsAt = resetsAt
        self.tokensAreLowerBound = tokensAreLowerBound
    }
}

/// What one agent has left, and how fresh that knowledge is.
public struct AgentUsage: Sendable, Equatable {
    public let agent: AgentKind
    public let windows: [UsageWindow]
    public let planType: String?
    /// When the underlying record was written. nil means no source was readable.
    public let observedAt: Date?
    /// Why nothing is known, when `windows` is empty — always a reason, never silence.
    public let unavailableReason: String?

    /// Past this, a delegation warns. Chosen so a warning still leaves room to finish the task.
    public static let warnThreshold: Double = 80
    /// Past this age, a reading is rendered as stale and can never drive a warning — a number
    /// that might no longer be true must not be presented as current.
    public static let staleAfter: TimeInterval = 3600

    public init(
        agent: AgentKind,
        windows: [UsageWindow],
        planType: String?,
        observedAt: Date?,
        unavailableReason: String?
    ) {
        self.agent = agent
        self.windows = windows
        self.planType = planType
        self.observedAt = observedAt
        self.unavailableReason = unavailableReason
    }

    /// A reader that found nothing to report — no windows, no reading, just the reason why.
    public static func unavailable(_ agent: AgentKind, reason: String) -> AgentUsage {
        AgentUsage(agent: agent, windows: [], planType: nil, observedAt: nil, unavailableReason: reason)
    }

    /// True when there is no reading at all, or the reading is older than `staleAfter`.
    public var isStale: Bool {
        guard let observedAt else { return true }
        return Date().timeIntervalSince(observedAt) > Self.staleAfter
    }

    /// The first window at or past `warnThreshold` — nil when the reading is stale or
    /// unavailable, so a delegation warning is never driven by a number that might be wrong.
    /// A window whose `resetsAt` has already passed is skipped too: the window it describes has
    /// moved on, so a reading against it is no longer current even when `observedAt` itself is
    /// still fresh.
    public var windowNeedingWarning: UsageWindow? {
        guard !isStale else { return nil }
        let now = Date()
        return windows.first { window in
            guard let usedPercent = window.usedPercent, usedPercent >= Self.warnThreshold else { return false }
            if let resetsAt = window.resetsAt, resetsAt <= now { return false }
            return true
        }
    }
}

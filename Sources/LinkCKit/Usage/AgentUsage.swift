import Foundation

/// One provider window — 5-hour, weekly — as that provider reports it.
public struct UsageWindow: Sendable, Equatable {
    public let label: String          // "5h", "7d"
    public let usedPercent: Double?   // nil when the provider publishes no limit
    public let tokens: Int?           // nil when the provider reports only a percentage
    public let resetsAt: Date?

    public init(label: String, usedPercent: Double?, tokens: Int?, resetsAt: Date?) {
        self.label = label
        self.usedPercent = usedPercent
        self.tokens = tokens
        self.resetsAt = resetsAt
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

    /// True when there is no reading at all, or the reading is older than `staleAfter`.
    public var isStale: Bool {
        guard let observedAt else { return true }
        return Date().timeIntervalSince(observedAt) > Self.staleAfter
    }

    /// The first window at or past `warnThreshold` — nil when the reading is stale or
    /// unavailable, so a delegation warning is never driven by a number that might be wrong.
    public var windowNeedingWarning: UsageWindow? {
        guard !isStale else { return nil }
        return windows.first { window in
            guard let usedPercent = window.usedPercent else { return false }
            return usedPercent >= Self.warnThreshold
        }
    }
}

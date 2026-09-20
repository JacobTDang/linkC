import Foundation

/// One agent's line in the sidebar's Usage section.
public struct UsageRow: Equatable, Sendable, Identifiable {
    public var id: AgentKind { agent }
    public let agent: AgentKind
    /// What the row says on the right: "68% · resets 1h", "1.2M · resets 2h", "capped · clears 3h".
    public let text: String
    public let isCoral: Bool
    /// The reading may no longer be true: the row dims and can never be coral.
    public let isStale: Bool
    /// The hover text: the other window, the plan, and how old the reading is.
    public let help: String

    public init(agent: AgentKind, text: String, isCoral: Bool, isStale: Bool, help: String) {
        self.agent = agent
        self.text = text
        self.isCoral = isCoral
        self.isStale = isStale
        self.help = help
    }
}

/// An agent with nothing to report, and why — an empty answer is still an answer.
public struct UnknownUsage: Equatable, Sendable, Identifiable {
    public var id: AgentKind { agent }
    public let agent: AgentKind
    public let reason: String

    public init(agent: AgentKind, reason: String) {
        self.agent = agent
        self.reason = reason
    }
}

/// Turns what linkC knows about each agent's quota into the sidebar's Usage section. Pure: every
/// input is a value, and `now` is injected, so every rule below is tested without a clock.
public enum UsageRows {
    public struct Result: Equatable, Sendable {
        public let rows: [UsageRow]
        public let unknown: [UnknownUsage]
        /// The section label's trailing text: the highest live percentage anyone reports.
        public let headline: String?

        public init(rows: [UsageRow], unknown: [UnknownUsage], headline: String?) {
            self.rows = rows
            self.unknown = unknown
            self.headline = headline
        }
    }

    /// Fixed, so the section never reshuffles as numbers change.
    public static let order: [AgentKind] = [.claude, .codex, .cursor, .agy]

    /// Why an agent that publishes nothing locally has no row of its own.
    static func silentSourceReason(_ agent: AgentKind) -> String {
        switch agent {
        case .cursor:
            return "Cursor publishes no quota locally — only a cap linkC sees in its terminal"
        case .agy:
            return "agy keeps its quota on the server — only a cap linkC sees in its terminal"
        default:
            return "no usage source for this agent"
        }
    }

    public static func build(
        claude: WindowUsage?,
        codex: AgentUsage?,
        limits: [AgentKind: AgentLimitStatus],
        now: Date = Date()
    ) -> Result {
        var rows: [UsageRow] = []
        var unknown: [UnknownUsage] = []
        var livePercentages: [Double] = []

        for agent in order {
            // A cap linkC watched happen outranks every other source: it is the hardest fact
            // available, and while it holds the published figures cannot be acted on anyway.
            if let limit = limits[agent], limit.cooldownExpiresAt > now {
                rows.append(UsageRow(
                    agent: agent,
                    text: "capped · clears \(AgeFormat.compact(from: now, to: limit.cooldownExpiresAt))",
                    isCoral: true,
                    isStale: false,
                    help: "\(limit.reason) · seen \(AgeFormat.compact(from: limit.limitedAt, to: now)) ago"))
                continue
            }

            switch agent {
            case .claude:
                guard let claude else {
                    unknown.append(UnknownUsage(agent: agent, reason: "no transcript activity read yet"))
                    continue
                }
                rows.append(UsageRow(
                    agent: agent,
                    text: figure(UsageFormat.tokens(claude.blockTokens), resetsAt: claude.blockResetAt, now: now),
                    // No published limit, so a token count can never be an alarm.
                    isCoral: false,
                    isStale: false,
                    help: "5h \(UsageFormat.tokens(claude.blockTokens)) · 7d \(UsageFormat.tokens(claude.weekTokens))"))
            case .codex:
                guard let codex else {
                    unknown.append(UnknownUsage(agent: agent, reason: "not read yet"))
                    continue
                }
                guard let window = codex.windows.first(where: { $0.label == "5h" }),
                      let percent = window.usedPercent
                else {
                    unknown.append(UnknownUsage(
                        agent: agent, reason: codex.unavailableReason ?? "no 5-hour window reported"))
                    continue
                }
                // Stale two ways: the reading itself is old, or the window it describes has
                // already rolled over. Either way the number might no longer be true.
                let readingAge = codex.observedAt.map { now.timeIntervalSince($0) }
                let windowRolled = window.resetsAt.map { $0 <= now } ?? false
                let isStale = (readingAge.map { $0 > AgentUsage.staleAfter } ?? true) || windowRolled
                if !isStale { livePercentages.append(percent) }
                rows.append(UsageRow(
                    agent: agent,
                    text: figure(percentText(percent), resetsAt: windowRolled ? nil : window.resetsAt, now: now),
                    isCoral: !isStale && percent >= AgentUsage.warnThreshold,
                    isStale: isStale,
                    help: codexHelp(codex, readingAge: readingAge)))
            case .cursor, .agy, .shell:
                unknown.append(UnknownUsage(agent: agent, reason: silentSourceReason(agent)))
            }
        }

        return Result(
            rows: rows,
            unknown: unknown,
            headline: livePercentages.max().map(percentText))
    }

    /// "68% · resets 1h", or the figure alone when no reset time is known.
    private static func figure(_ value: String, resetsAt: Date?, now: Date) -> String {
        guard let resetsAt, resetsAt > now else { return value }
        return "\(value) · resets \(AgeFormat.compact(from: now, to: resetsAt))"
    }

    private static func percentText(_ percent: Double) -> String {
        "\(Int(percent.rounded()))%"
    }

    private static func codexHelp(_ usage: AgentUsage, readingAge: TimeInterval?) -> String {
        var parts: [String] = []
        if let week = usage.windows.first(where: { $0.label == "7d" }), let percent = week.usedPercent {
            parts.append("7d \(percentText(percent))")
        }
        if let plan = usage.planType, !plan.isEmpty { parts.append(plan) }
        if let readingAge { parts.append("read \(AgeFormat.compact(readingAge)) ago") }
        return parts.joined(separator: " · ")
    }
}

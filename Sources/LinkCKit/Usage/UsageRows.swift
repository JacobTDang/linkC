import Foundation

/// One agent's line in the sidebar's Usage section.
public struct UsageRow: Equatable, Sendable, Identifiable {
    public var id: AgentKind { agent }
    public let agent: AgentKind
    /// What the row says on the right: "68% · resets 1h", "1.2M · resets 2h", "capped · retry 3h".
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
        var livePercentages: [Int] = []

        for agent in order {
            // A cap linkC watched happen outranks every other source: it is the hardest fact
            // available, and while it holds the published figures cannot be acted on anyway.
            if let limit = limits[agent], limit.cooldownExpiresAt > now {
                rows.append(UsageRow(
                    agent: agent,
                    text: "capped · retry \(AgeFormat.compact(from: now, to: limit.cooldownExpiresAt))",
                    isCoral: true,
                    isStale: false,
                    help: "\(limit.reason) · seen \(AgeFormat.compact(from: limit.limitedAt, to: now)) ago · retry is linkC's own wait, not the provider's reset"))
                continue
            }

            switch agent {
            case .claude:
                guard let claude else {
                    unknown.append(UnknownUsage(agent: agent, reason: "no transcript activity read yet"))
                    continue
                }
                let isIdleBlock = claude.blockTokens == 0 && claude.blockResetAt == nil
                let blockPart = isIdleBlock ? "no active 5-hour block" : "5h \(UsageFormat.tokens(claude.blockTokens))"
                rows.append(UsageRow(
                    agent: agent,
                    text: figure(UsageFormat.tokens(claude.blockTokens), resetsAt: claude.blockResetAt, now: now),
                    // No published limit, so a token count can never be an alarm.
                    isCoral: false,
                    isStale: false,
                    help: "\(blockPart) · 7d \(UsageFormat.tokens(claude.weekTokens))"
                        + " · no percentage: no per-plan limit is published"))
            case .codex:
                guard let codex else {
                    unknown.append(UnknownUsage(agent: agent, reason: "not read yet"))
                    continue
                }
                // The figure is the 5-hour window when there is one — the window that usually
                // bites first — else whatever window the reading has.
                guard let figureWindow = codex.windows.first(where: { $0.label == "5h" }) ?? codex.windows.first,
                      let percent = figureWindow.usedPercent
                else {
                    unknown.append(UnknownUsage(
                        agent: agent, reason: codex.unavailableReason ?? "no window percentage reported"))
                    continue
                }
                // Stale two ways: the reading itself is old, or the window it describes has
                // already rolled over. Either way the number might no longer be true.
                let readingAge = codex.observedAt.map { now.timeIntervalSince($0) }
                let readingIsFresh = readingAge.map { $0 <= AgentUsage.staleAfter } ?? false
                let windowRolled = figureWindow.resetsAt.map { $0 <= now } ?? false
                let isStale = !readingIsFresh || windowRolled

                // Any window the reading still speaks for can raise the alarm, not just the
                // figure's — a weekly cap blocks work just as hard as an hourly one.
                let liveWindows = codex.windows.filter { candidate in
                    guard readingIsFresh, candidate.usedPercent != nil else { return false }
                    return !(candidate.resetsAt.map { $0 <= now } ?? false)
                }
                let roundedFigure = roundedPercent(percent)
                if let worstLive = liveWindows.compactMap({ $0.usedPercent.map(roundedPercent) }).max() {
                    livePercentages.append(worstLive)
                }
                let worseWindow = liveWindows
                    .filter { roundedPercent($0.usedPercent!) > roundedFigure }
                    .max { roundedPercent($0.usedPercent!) < roundedPercent($1.usedPercent!) }
                let isCoral = liveWindows.contains { roundedPercent($0.usedPercent!) >= Int(AgentUsage.warnThreshold) }

                let text: String
                if let worseWindow {
                    text = "\(percentText(percent)) · \(worseWindow.label) \(percentText(worseWindow.usedPercent!))"
                } else {
                    text = figure(percentText(percent), resetsAt: figureWindow.resetsAt, now: now)
                }

                // Two mutually exclusive facts a dimmed figure can hide: the reset it gave up in
                // favour of a worse window, or that its own window has since moved on and this
                // reading is what came before that.
                let notice: String?
                if windowRolled {
                    notice = "window has since reset; this was the reading before it"
                } else if worseWindow != nil, let resetsAt = figureWindow.resetsAt, resetsAt > now {
                    notice = "\(figureWindow.label) resets \(AgeFormat.compact(from: now, to: resetsAt))"
                } else {
                    notice = nil
                }

                rows.append(UsageRow(
                    agent: agent,
                    text: text,
                    isCoral: isCoral,
                    isStale: isStale,
                    help: codexHelp(codex, readingAge: readingAge, notice: notice)))
            case .cursor, .agy, .shell:
                unknown.append(UnknownUsage(agent: agent, reason: silentSourceReason(agent)))
            }
        }

        return Result(
            rows: rows,
            unknown: unknown,
            headline: livePercentages.max().map { "\($0)%" })
    }

    /// "68% · resets 1h", or the figure alone when no reset time is known.
    private static func figure(_ value: String, resetsAt: Date?, now: Date) -> String {
        guard let resetsAt, resetsAt > now else { return value }
        return "\(value) · resets \(AgeFormat.compact(from: now, to: resetsAt))"
    }

    /// Rounded once, so the figure printed and the figure compared against a threshold always
    /// agree — a value that displays as "80%" must also be treated as 80, never as 79.6.
    private static func roundedPercent(_ percent: Double) -> Int {
        Int(percent.rounded())
    }

    private static func percentText(_ percent: Double) -> String {
        "\(roundedPercent(percent))%"
    }

    private static func codexHelp(_ usage: AgentUsage, readingAge: TimeInterval?, notice: String?) -> String {
        var parts: [String] = []
        if let notice { parts.append(notice) }
        if let week = usage.windows.first(where: { $0.label == "7d" }), let percent = week.usedPercent {
            parts.append("7d \(percentText(percent))")
        }
        if let plan = usage.planType, !plan.isEmpty { parts.append(plan) }
        if let readingAge { parts.append("read \(AgeFormat.compact(readingAge)) ago") }
        return parts.joined(separator: " · ")
    }
}

import Foundation

/// One agent's line in the sidebar's Usage section.
public struct UsageRow: Equatable, Sendable, Identifiable {
    public var id: AgentKind { agent }
    public let agent: AgentKind
    /// What the row says on the right: "37% · resets 2h", "weekly limit hit · resets 3d",
    /// "limit hit · retry 15m".
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
        /// The section label's trailing text: "limit hit" when any row shows one, else the
        /// highest live 5-hour percentage.
        public let headline: String?

        public init(rows: [UsageRow], unknown: [UnknownUsage], headline: String?) {
            self.rows = rows
            self.unknown = unknown
            self.headline = headline
        }
    }

    /// Fixed, so the section never reshuffles as numbers change.
    public static let order: [AgentKind] = [.claude, .codex, .cursor, .agy]

    /// Claude's reason before any of its sessions has reported through the status line.
    public static let claudeNoReadingReason = "no reading yet — a Claude session reports after its first reply"

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
        claude: AgentUsage?,
        codex: AgentUsage?,
        limits: [AgentKind: AgentLimitStatus],
        now: Date = Date()
    ) -> Result {
        var rows: [UsageRow] = []
        var unknown: [UnknownUsage] = []
        var livePercentages: [Int] = []
        var anyLimitHit = false

        for agent in order {
            // A cap linkC watched happen outranks every other source: it is the hardest fact
            // available, and while it holds the published figures cannot be acted on anyway.
            if let limit = limits[agent], limit.cooldownExpiresAt > now {
                anyLimitHit = true
                rows.append(UsageRow(
                    agent: agent,
                    text: "limit hit · retry \(AgeFormat.compact(from: now, to: limit.cooldownExpiresAt))",
                    isCoral: true,
                    isStale: false,
                    help: "\(limit.reason) · seen \(AgeFormat.compact(from: limit.limitedAt, to: now)) ago · retry is linkC's own wait, not the provider's reset"))
                continue
            }

            let usage: AgentUsage?
            let notReadReason: String
            switch agent {
            case .claude:
                usage = claude
                notReadReason = claudeNoReadingReason
            case .codex:
                usage = codex
                notReadReason = "not read yet"
            case .cursor, .agy, .shell:
                unknown.append(UnknownUsage(agent: agent, reason: silentSourceReason(agent)))
                continue
            }
            guard let usage else {
                unknown.append(UnknownUsage(agent: agent, reason: notReadReason))
                continue
            }
            guard let windowRow = windowRow(agent: agent, usage: usage, now: now) else {
                unknown.append(UnknownUsage(
                    agent: agent, reason: usage.unavailableReason ?? "no window percentage reported"))
                continue
            }
            rows.append(windowRow.row)
            if windowRow.isLimitHit { anyLimitHit = true }
            if let percent = windowRow.liveFigurePercent { livePercentages.append(percent) }
        }

        return Result(
            rows: rows,
            unknown: unknown,
            headline: anyLimitHit ? "limit hit" : livePercentages.max().map { "\($0)%" })
    }

    private struct WindowRow {
        let row: UsageRow
        let isLimitHit: Bool
        /// The figure's rounded percentage while its window is live — what the headline compares.
        let liveFigurePercent: Int?
    }

    /// One agent's row from the windows its provider reports — the same rules for every agent.
    /// nil when no window carries a percentage.
    private static func windowRow(agent: AgentKind, usage: AgentUsage, now: Date) -> WindowRow? {
        // The figure is the 5-hour window when there is one — the window that usually bites
        // first — else whatever window the reading has.
        guard let figureWindow = usage.windows.first(where: { $0.label == "5h" }) ?? usage.windows.first,
              let percent = figureWindow.usedPercent
        else { return nil }

        let readingAge = usage.observedAt.map { now.timeIntervalSince($0) }
        let readingIsFresh = readingAge.map { $0 <= AgentUsage.staleAfter } ?? false
        // A window speaks for now only while the reading is fresh and the window has not rolled over.
        func isLive(_ window: UsageWindow) -> Bool {
            readingIsFresh && window.usedPercent != nil && !(window.resetsAt.map { $0 <= now } ?? false)
        }
        func isFull(_ window: UsageWindow) -> Bool {
            isLive(window) && roundedPercent(window.usedPercent!) >= 100
        }
        let liveFigurePercent = isLive(figureWindow) ? roundedPercent(percent) : nil

        // A full weekly window outranks a full 5-hour one: it is the longer wait.
        let hit: (window: UsageWindow, name: String)?
        if let week = usage.windows.first(where: { $0.label == "7d" }), isFull(week) {
            hit = (week, "weekly")
        } else if let session = usage.windows.first(where: { $0.label == "5h" }), isFull(session) {
            hit = (session, "session")
        } else {
            hit = nil
        }

        if let hit {
            return WindowRow(
                row: UsageRow(
                    agent: agent,
                    text: "\(hit.name) limit hit" + resetsSuffix(hit.window.resetsAt, now: now),
                    isCoral: true,
                    isStale: false,
                    help: help(usage, other: usage.windows.first { $0.label != hit.window.label },
                               readingAge: readingAge, notice: nil, now: now)),
                isLimitHit: true,
                liveFigurePercent: liveFigurePercent)
        }

        // Stale two ways: the reading itself is old, or the window it describes has already
        // rolled over. Either way the number might no longer be true.
        let windowRolled = figureWindow.resetsAt.map { $0 <= now } ?? false
        return WindowRow(
            row: UsageRow(
                agent: agent,
                text: percentText(percent) + resetsSuffix(figureWindow.resetsAt, now: now),
                isCoral: liveFigurePercent.map { $0 >= Int(AgentUsage.warnThreshold) } ?? false,
                isStale: !readingIsFresh || windowRolled,
                help: help(usage, other: usage.windows.first { $0.label != figureWindow.label },
                           readingAge: readingAge,
                           notice: windowRolled ? "window has since reset; this was the reading before it" : nil,
                           now: now)),
            isLimitHit: false,
            liveFigurePercent: liveFigurePercent)
    }

    /// " · resets 2h", or nothing when no future reset is known. Under a day the wait reads in
    /// minutes or hours; from a day on, in days, so a weekly reset never reads "72h".
    private static func resetsSuffix(_ resetsAt: Date?, now: Date) -> String {
        guard let resetsAt, resetsAt > now else { return "" }
        let remaining = resetsAt.timeIntervalSince(now)
        let wait = remaining < 86_400 ? AgeFormat.compact(remaining) : AgeFormat.longSpan(remaining)
        return " · resets \(wait)"
    }

    /// Rounded once, so the figure printed and the figure compared against a threshold always
    /// agree — a value that displays as "80%" must also be treated as 80, never as 79.6.
    private static func roundedPercent(_ percent: Double) -> Int {
        Int(percent.rounded())
    }

    private static func percentText(_ percent: Double) -> String {
        "\(roundedPercent(percent))%"
    }

    /// The hover text: a notice when there is one, the window the row is not showing, the plan,
    /// and how old the reading is.
    private static func help(
        _ usage: AgentUsage, other: UsageWindow?, readingAge: TimeInterval?, notice: String?, now: Date
    ) -> String {
        var parts: [String] = []
        if let notice { parts.append(notice) }
        if let other, let percent = other.usedPercent {
            parts.append("\(other.label) \(percentText(percent))" + resetsSuffix(other.resetsAt, now: now))
        }
        if let plan = usage.planType, !plan.isEmpty { parts.append(plan) }
        if let readingAge { parts.append("read \(AgeFormat.compact(readingAge)) ago") }
        return parts.joined(separator: " · ")
    }
}

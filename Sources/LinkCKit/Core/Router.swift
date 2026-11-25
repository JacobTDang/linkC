import Foundation

/// A live rate-limit the router must avoid. `pool` is set for agents with per-pool quotas
/// (`ModelPool`); `nil` means the whole agent is limited.
public struct RouterLimit: Sendable, Equatable {
    public let agent: AgentKind
    public let pool: String?

    public init(agent: AgentKind, pool: String?) {
        self.agent = agent
        self.pool = pool
    }
}

/// What the router picked for a task, and why — one line for the tool result.
public struct RouterDecision: Sendable, Equatable {
    public let agent: AgentKind
    public let tier: ModelTier
    public let effort: ReasoningEffort?
    public let reason: String
    /// What the task is, as `reason` opens with it but without the agent and tier: "implementation",
    /// "web research (browse-capable)".
    public let summary: String
    /// Why each agent that would have come first was passed over, and the tie-break when one decided:
    /// the parts of `reason` between its headline and its effort.
    public let notes: [String]

    public init(
        agent: AgentKind, tier: ModelTier, effort: ReasoningEffort?, reason: String,
        summary: String, notes: [String]
    ) {
        self.agent = agent
        self.tier = tier
        self.effort = effort
        self.reason = reason
        self.summary = summary
        self.notes = notes
    }
}

/// No installed agent can take a task: the tier, and why each agent was skipped. `message` is the
/// refusal itself; the error's description adds the MCP tool's remedy, naming an agent with `to`.
public struct RouterRefusal: LocalizedError, Sendable, Equatable {
    public let tier: ModelTier
    public let message: String

    public var errorDescription: String? { "\(message). Name an agent with `to`." }
}

/// Pure task router: picks an agent, tier and effort from the prompt and live constraints.
/// No I/O — callers gather installed agents, limits and usage, then call `route`.
public enum Router {
    /// Task kinds inferred from an explicit keyword table. A keyword is a whole word or a phrase of
    /// whole words, matched case-insensitively: "information" never matches "format", nor
    /// "browser" "browse". Words that also name ordinary things (format, security, research,
    /// migration) only count inside a phrase. Documented here so the README and the MCP tool
    /// result stay aligned with the code.
    ///
    /// | Kind | Keywords | Tier |
    /// |---|---|---|
    /// | Trivial edit (short prompts only) | rename, typo, bump, reformat, format the file/code, fix the formatting | light |
    /// | Web research | web research, search the web, browse, browsing, scrape, scraping, docs lookup, look up the docs | light when short, else standard (browse-capable agent) |
    /// | Hard work | architecture change/redesign the architecture, hard debugging, security review/audit/vulnerability, database/schema/data migration(s) | deep |
    /// | Everything else | (default) | standard |
    public enum TaskKind: String, Sendable, Equatable {
        case trivialEdit
        case webResearch
        case hard
        case ordinary
    }

    /// A prompt of at most this many words is short enough for the light tier. Delegation briefs
    /// run far longer; a long one that happens to mention a rename is ordinary work.
    public static let shortPromptWordLimit = 25

    private static let trivialKeywords = phrases([
        "rename", "renaming", "typo", "typos", "bump", "reformat",
        "format the file", "format the code", "fix the formatting", "fix formatting"
    ])
    private static let webKeywords = phrases([
        "web research", "research the web", "search the web", "browse", "browsing",
        "scrape", "scraping", "docs lookup", "look up the docs"
    ])
    private static let hardKeywords = phrases([
        "architecture change", "architecture changes", "design the architecture", "redesign the architecture",
        "hard debugging",
        "security review", "security audit", "security vulnerability", "security hole",
        "database migration", "database migrations", "schema migration", "schema migrations",
        "data migration", "data migrations"
    ])
    /// Agents that can browse / research the web; cheapest preferred first (agy light, then a free OpenCode model).
    private static let browseAgents: [AgentKind] = [.agy, .opencode]

    public static func classify(_ prompt: String) -> TaskKind {
        let words = words(of: prompt)
        if matches(words, any: hardKeywords) { return .hard }
        if matches(words, any: webKeywords) { return .webResearch }
        if words.count <= shortPromptWordLimit, matches(words, any: trivialKeywords) { return .trivialEdit }
        return .ordinary
    }

    /// The tier a task of `kind` runs on. Light only for a short prompt: a trivial edit is short by
    /// definition, and long web research runs on standard.
    public static func tier(for kind: TaskKind, prompt: String) -> ModelTier {
        switch kind {
        case .trivialEdit: return .light
        case .webResearch: return words(of: prompt).count <= shortPromptWordLimit ? .light : .standard
        case .ordinary: return .standard
        case .hard: return .deep
        }
    }

    /// The prompt's words, lowercased; anything but a letter or digit separates them.
    private static func words(of text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static func phrases(_ keywords: [String]) -> [[String]] {
        keywords.map(words(of:))
    }

    /// Whether `words` holds any of `phrases` as consecutive whole words.
    private static func matches(_ words: [String], any phrases: [[String]]) -> Bool {
        phrases.contains { phrase in
            guard !phrase.isEmpty, phrase.count <= words.count else { return false }
            return (0...(words.count - phrase.count)).contains { start in
                Array(words[start..<(start + phrase.count)]) == phrase
            }
        }
    }

    /// Picks an agent, tier and effort. `activeInFolder` holds the agents with a session already
    /// open in the folder (the caller's own excluded): a tie goes to one of them. Throws, naming
    /// why each agent was skipped, when no installed agent can take the work.
    public static func route(
        prompt: String,
        installed: [AgentKind],
        settings: AgentModelSettings,
        limits: [RouterLimit],
        usageTight: Set<AgentKind>,
        activeInFolder: Set<AgentKind>,
        refusals: [AgentKind: String] = [:]
    ) throws -> RouterDecision {
        let kind = classify(prompt)
        let tier = tier(for: kind, prompt: prompt)
        let (candidates, skipped) = screen(
            tier: tier, installed: installed, settings: settings, limits: limits, refusals: refusals)
        guard !candidates.isEmpty else {
            let why = skipped.isEmpty
                ? "none of the installed agents can be routed to"
                : skipped.map { "\($0.agent.rawValue) skipped (\($0.why))" }.joined(separator: "; ")
            throw RouterRefusal(
                tier: tier, message: "no installed agent is free to take this task at \(tier.rawValue) — \(why)")
        }

        // Web research goes to a browse-capable agent when one is free; any other task, or research
        // with none free, picks among every candidate.
        let browse = kind == .webResearch ? browseAgents.filter(candidates.contains) : []
        let pool = browse.isEmpty ? candidates : browse
        // Usage headroom first; when every agent in the pool is tight, they all stay in.
        let withHeadroom = pool.filter { !usageTight.contains($0) }
        let picks = withHeadroom.isEmpty ? pool : withHeadroom
        // A tie goes to an agent already open in the folder, else to the first in `installed` order.
        let active = picks.first(where: activeInFolder.contains)
        let chosen = active ?? picks[0]

        let label: String, qualifier: String?
        switch kind {
        case .webResearch where browse.isEmpty: (label, qualifier) = ("web research", "no browse-capable agent free")
        case .webResearch: (label, qualifier) = ("web research", "browse-capable")
        case .trivialEdit: (label, qualifier) = ("trivial edit", nil)
        case .hard: (label, qualifier) = ("hard work", nil)
        case .ordinary: (label, qualifier) = ("implementation", nil)
        }
        let headline = "\(label) → \(chosen.rawValue) \(tier.rawValue)" + (qualifier.map { " (\($0))" } ?? "")
        let summary = label + (qualifier.map { " (\($0))" } ?? "")
        var notes: [String] = []
        // With no browse agent free, research names every skipped browse agent up front, so the
        // passed-over list below leaves them out.
        let namedBrowseSkips = kind == .webResearch && browse.isEmpty
        if namedBrowseSkips {
            for skip in skipped where browseAgents.contains(skip.agent) {
                notes.append("\(skip.agent.rawValue) skipped (\(skip.why))")
            }
        }
        // Why each agent that would have come first was passed over. Cursor is never routed to, so
        // it is not named here.
        let order = browse.isEmpty ? installed : browseAgents.filter(installed.contains)
        for agent in order.prefix(while: { $0 != chosen }) where agent != .cursor {
            if let skip = skipped.first(where: { $0.agent == agent }) {
                if !namedBrowseSkips || !browseAgents.contains(agent) {
                    notes.append("\(agent.rawValue) skipped (\(skip.why))")
                }
            } else if !withHeadroom.isEmpty, usageTight.contains(agent), pool.contains(agent) {
                notes.append("\(agent.rawValue) skipped (usage tight)")
            }
        }
        if active != nil, chosen != picks[0] {
            notes.append("tie → already active in folder")
        }

        let effort = settings.tierEffort(for: chosen, tier: tier)
        let reasonParts = [headline] + notes + (effort.map { ["effort \($0.rawValue)"] } ?? [])
        return RouterDecision(
            agent: chosen, tier: tier, effort: effort,
            reason: reasonParts.joined(separator: "; "), summary: summary, notes: notes)
    }

    /// The agents a task at `tier` could go to, in `installed` order: every installed agent the router
    /// routes to that has a model for the tier, is not limited and was not refused.
    public static func eligible(
        tier: ModelTier,
        installed: [AgentKind],
        settings: AgentModelSettings,
        limits: [RouterLimit],
        refusals: [AgentKind: String] = [:]
    ) -> [AgentKind] {
        screen(tier: tier, installed: installed, settings: settings, limits: limits, refusals: refusals).candidates
    }

    /// Why `agent` cannot take a task at `tier`, as `route` would say it skipped the agent, or nil when
    /// it can.
    public static func skipReason(
        for agent: AgentKind,
        tier: ModelTier,
        settings: AgentModelSettings,
        limits: [RouterLimit],
        refusals: [AgentKind: String] = [:]
    ) -> String? {
        let screened = screen(tier: tier, installed: [agent], settings: settings, limits: limits, refusals: refusals)
        guard !screened.candidates.contains(agent) else { return nil }
        return screened.skipped.first?.why ?? "never routed to"
    }

    /// Splits the installed agents into those that can take a task at `tier` and those skipped, with
    /// why. Every routed task carries a tier. Cursor takes none, so a task routed to it would be
    /// refused at delegation: it is never a candidate. Shell and Freebuff are not routed to.
    private static func screen(
        tier: ModelTier,
        installed: [AgentKind],
        settings: AgentModelSettings,
        limits: [RouterLimit],
        refusals: [AgentKind: String]
    ) -> (candidates: [AgentKind], skipped: [(agent: AgentKind, why: String)]) {
        var candidates: [AgentKind] = []
        var skipped: [(agent: AgentKind, why: String)] = []
        for agent in installed where agent != .shell && agent != .freebuff {
            if let refusal = refusals[agent] {
                skipped.append((agent, refusal))
            } else if agent == .cursor {
                skipped.append((agent, "never routed: it takes no tier"))
            } else if settings.model(for: agent, tier: tier) == nil {
                skipped.append((agent, "no \(tier.rawValue) model"))
            } else if isLimited(agent: agent, tier: tier, settings: settings, limits: limits) {
                skipped.append((agent, "limited"))
            } else {
                candidates.append(agent)
            }
        }
        return (candidates, skipped)
    }

    private static func isLimited(
        agent: AgentKind,
        tier: ModelTier,
        settings: AgentModelSettings,
        limits: [RouterLimit]
    ) -> Bool {
        let model = settings.model(for: agent, tier: tier)
        let modelPool = model.flatMap { ModelPool.pool(of: $0, agent: agent) }
        for limit in limits where limit.agent == agent {
            if limit.pool == nil { return true }
            if let modelPool, limit.pool == modelPool { return true }
        }
        return false
    }
}

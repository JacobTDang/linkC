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

    public init(agent: AgentKind, tier: ModelTier, effort: ReasoningEffort?, reason: String) {
        self.agent = agent
        self.tier = tier
        self.effort = effort
        self.reason = reason
    }
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
    /// | Hard work | architecture, hard debugging, security review/audit/vulnerability, database/schema/data migration(s) | deep |
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
        "architecture", "hard debugging",
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

    /// Picks an agent, tier and effort. Throws when no installed agent can take the work
    /// (every candidate limited, or none installed).
    public static func route(
        prompt: String,
        installed: [AgentKind],
        settings: AgentModelSettings,
        limits: [RouterLimit],
        usageTight: Set<AgentKind>,
        activeInFolder: AgentKind?
    ) throws -> RouterDecision {
        let kind = classify(prompt)
        let tier = tier(for: kind, prompt: prompt)
        // Every routed task carries a tier. Cursor takes none, so a task routed to it would be
        // refused at delegation: it is never a candidate. Shell and Freebuff are not routed to.
        var candidates: [AgentKind] = []
        var skipped: [(agent: AgentKind, why: String)] = []
        for agent in installed where agent != .shell && agent != .freebuff {
            if agent == .cursor {
                skipped.append((agent, "never routed: it takes no tier"))
            } else if settings.model(for: agent, tier: tier) == nil {
                skipped.append((agent, "no \(tier.rawValue) model"))
            } else if isLimited(agent: agent, tier: tier, settings: settings, limits: limits) {
                skipped.append((agent, "limited"))
            } else {
                candidates.append(agent)
            }
        }
        guard !candidates.isEmpty else {
            let why = skipped.isEmpty
                ? "none of the installed agents can be routed to"
                : skipped.map { "\($0.agent.rawValue) skipped (\($0.why))" }.joined(separator: "; ")
            throw LinkCError.process(
                "no installed agent is free to take this task at \(tier.rawValue) — \(why). Name an agent with `to`.")
        }

        let chosen: AgentKind
        var reasonParts: [String] = []
        switch kind {
        case .webResearch:
            let browse = browseAgents.filter { candidates.contains($0) }
            guard let pick = browse.first else {
                // No browse-capable agent free: fall through to the ordinary picker among whoever is left.
                chosen = pickAmong(candidates, usageTight: usageTight, activeInFolder: activeInFolder)
                reasonParts.append("web research → \(tier.rawValue); no browse-capable agent free, picked \(chosen.rawValue)")
                break
            }
            chosen = pick
            reasonParts.append("web research → \(chosen.rawValue) \(tier.rawValue) (browse-capable)")
        case .trivialEdit:
            chosen = pickAmong(candidates, usageTight: usageTight, activeInFolder: activeInFolder)
            reasonParts.append("trivial edit → \(chosen.rawValue) \(tier.rawValue)")
        case .hard:
            chosen = pickAmong(candidates, usageTight: usageTight, activeInFolder: activeInFolder)
            reasonParts.append("hard work → \(chosen.rawValue) \(tier.rawValue)")
        case .ordinary:
            chosen = pickAmong(candidates, usageTight: usageTight, activeInFolder: activeInFolder)
            reasonParts.append("implementation → \(chosen.rawValue) \(tier.rawValue)")
        }

        if usageTight.contains(chosen) == false,
           candidates.contains(where: { usageTight.contains($0) }) {
            // Already preferred headroom in pickAmong; mention it when the active agent was tight.
            if let activeInFolder, usageTight.contains(activeInFolder), chosen != activeInFolder {
                reasonParts.append("avoided tight usage on \(activeInFolder.rawValue)")
            }
        } else if let activeInFolder, chosen == activeInFolder {
            reasonParts.append("tie → already active in folder")
        }

        let effort: ReasoningEffort?
        if case .levels = AgentEffortSupport.forAgent(chosen) {
            effort = settings.effort(for: chosen, tier: tier) ?? ReasoningEffort.default(for: tier)
        } else {
            effort = nil
        }
        if let effort {
            reasonParts.append("effort \(effort.rawValue)")
        }

        return RouterDecision(
            agent: chosen, tier: tier, effort: effort,
            reason: reasonParts.joined(separator: "; "))
    }

    /// Prefer agents with usage headroom; ties go to the agent already active in the folder;
    /// remaining ties keep `installed` / candidate order.
    private static func pickAmong(
        _ candidates: [AgentKind],
        usageTight: Set<AgentKind>,
        activeInFolder: AgentKind?
    ) -> AgentKind {
        let withHeadroom = candidates.filter { !usageTight.contains($0) }
        let pool = withHeadroom.isEmpty ? candidates : withHeadroom
        if let activeInFolder, pool.contains(activeInFolder) {
            return activeInFolder
        }
        return pool[0]
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

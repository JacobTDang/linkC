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
    /// Task kinds inferred from an explicit keyword table (case-insensitive substring match).
    /// Documented here so Settings and the MCP tool result stay aligned with the code.
    ///
    /// | Kind | Keywords | Tier |
    /// |---|---|---|
    /// | Trivial edit | rename, typo, format, bump | light |
    /// | Web research | research, browsing, browse, scraping, scrape, docs lookup, look up the docs | light (browse-capable agent) |
    /// | Hard work | architecture, hard debugging, security, migration, migrations | deep |
    /// | Everything else | (default) | standard |
    public enum TaskKind: String, Sendable, Equatable {
        case trivialEdit
        case webResearch
        case hard
        case ordinary
    }

    private static let trivialKeywords = ["rename", "typo", "format", "bump"]
    private static let webKeywords = [
        "research", "browsing", "browse", "scraping", "scrape", "docs lookup", "look up the docs"
    ]
    private static let hardKeywords = [
        "architecture", "hard debugging", "security", "migrations", "migration"
    ]
    /// Agents that can browse / research the web; cheapest preferred first (agy light, then a free OpenCode model).
    private static let browseAgents: [AgentKind] = [.agy, .opencode]

    public static func classify(_ prompt: String) -> TaskKind {
        let lower = prompt.lowercased()
        if hardKeywords.contains(where: { lower.contains($0) }) { return .hard }
        if webKeywords.contains(where: { lower.contains($0) }) { return .webResearch }
        if trivialKeywords.contains(where: { lower.contains($0) }) { return .trivialEdit }
        return .ordinary
    }

    public static func tier(for kind: TaskKind) -> ModelTier {
        switch kind {
        case .trivialEdit, .webResearch: return .light
        case .ordinary: return .standard
        case .hard: return .deep
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
        let tier = tier(for: kind)
        let candidates = installed.filter { agent in
            guard agent != .shell, agent != .freebuff else { return false }
            guard settings.model(for: agent, tier: tier) != nil || agent == .cursor else { return false }
            return !isLimited(agent: agent, tier: tier, settings: settings, limits: limits)
        }
        guard !candidates.isEmpty else {
            throw LinkCError.process("no installed agent is free to take this task at \(tier.rawValue) — every candidate is limited or has no model for that tier")
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

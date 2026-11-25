import Foundation

/// Where routing reads what it needs beyond the prompt and the settings, for one folder: which agents
/// are installed, their live limits, their usage headroom, and the agents open there. The MCP tool's
/// auto-route and the prompt bar each say where to read these, then route through `TaskRouting`, so the
/// two judge a prompt the same way.
struct RouteInputs: Sendable {
    /// Whether an agent's CLI is installed: a file check, never a run.
    let isInstalled: @Sendable (AgentKind) -> Bool
    /// The live limits the folder's inbox records for an agent.
    let liveLimits: @Sendable (AgentKind) throws -> [AgentLimitStatus]
    /// What each agent has left. An agent with no reader is never tight.
    let usageReaders: [AgentKind: MCPServer.UsageReader]
    /// The agents with a session open in the folder, and why they could not be read when they could not.
    let agentsOpen: @Sendable () -> (agents: Set<AgentKind>, problem: String?)
}

/// What `TaskRouting.gather` read for one prompt: the facts the pure `Router` picks from.
struct RouteContext: Sendable {
    let installed: [AgentKind]
    let limits: [RouterLimit]
    let usageTight: Set<AgentKind>
    let activeInFolder: Set<AgentKind>
    /// Why the folder's open sessions could not be read, when they could not.
    let openProblem: String?
    /// The tier the prompt runs on.
    let tier: ModelTier
    /// Why each agent's model for `tier` cannot take the task, as the free-model rules and the cached
    /// lists judge it.
    let refusals: [AgentKind: String]

    /// The agents the prompt could go to, in installed order.
    func eligible(settings: AgentModelSettings) -> [AgentKind] {
        Router.eligible(tier: tier, installed: installed, settings: settings, limits: limits, refusals: refusals)
    }
}

/// The agent the user picked by hand cannot take the task: `message` names it and says why.
struct HandPickRefusal: LocalizedError, Sendable, Equatable {
    let agent: AgentKind
    let why: String

    var message: String { "\(agent.shortName) can't take this: \(why)" }
    var errorDescription: String? { message }
}

/// The router's pick, and the reason the MCP tool reports for it.
struct RoutedTask: Sendable {
    let decision: RouterDecision
    /// `decision.reason`, and why there was no tie-break when the folder's open sessions could not be read.
    let reason: String
}

/// Routes a prompt from what `RouteInputs` reads. The MCP tool's auto-route and the prompt bar both
/// come here.
enum TaskRouting {
    /// Reads everything routing `prompt` needs except an agent's own model listing: the installed agents,
    /// their live limits and usage, the agents open in the folder, and each tier model checked against the
    /// free-model rules and the cached lists. Runs no agent CLI.
    static func gather(
        prompt: String, settings: AgentModelSettings, sources: TierModelSources, inputs: RouteInputs
    ) throws -> RouteContext {
        let installed = AgentKind.peers.filter { inputs.isInstalled($0) }
        guard !installed.isEmpty else {
            throw LinkCError.process("no agent CLI is installed to route to")
        }
        var limits: [RouterLimit] = []
        for agent in installed {
            for limit in try inputs.liveLimits(agent) {
                limits.append(RouterLimit(agent: limit.agent, pool: limit.pool))
            }
        }
        var tight = Set<AgentKind>()
        for agent in installed {
            if inputs.usageReaders[agent]?().windowNeedingWarning != nil {
                tight.insert(agent)
            }
        }
        let tier = Router.tier(for: Router.classify(prompt), prompt: prompt)
        var refusals: [AgentKind: String] = [:]
        for agent in installed {
            if let refusal = TierModelRefusal.check(
                agent: agent, tier: tier, settings: settings, sources: sources, consultingFolderListing: false) {
                refusals[agent] = refusal.message
            }
        }
        let open = inputs.agentsOpen()
        return RouteContext(
            installed: installed, limits: limits, usageTight: tight, activeInFolder: open.agents,
            openProblem: open.problem, tier: tier, refusals: refusals)
    }

    /// Picks an agent, tier and effort from `context`. `only` is an agent the user picked by hand: it is
    /// judged on its own, its reason is "your pick", and when it cannot take the task a `HandPickRefusal`
    /// says why. With `consultingFolderListing`, the agent picked is checked against what its own CLI
    /// lists in the folder (OpenCode and Kilo have one): when it refuses, the router skips that agent and
    /// picks again, and an agent picked by hand is refused. Without it, no CLI runs.
    static func pick(
        prompt: String,
        context: RouteContext,
        settings: AgentModelSettings,
        sources: TierModelSources,
        only: AgentKind? = nil,
        consultingFolderListing: Bool
    ) throws -> RoutedTask {
        if let only {
            return try pick(
                byHand: only, context: context, settings: settings, sources: sources,
                consultingFolderListing: consultingFolderListing)
        }
        var refusals = context.refusals
        func route() throws -> RouterDecision {
            try Router.route(
                prompt: prompt, installed: context.installed, settings: settings, limits: context.limits,
                usageTight: context.usageTight, activeInFolder: context.activeInFolder, refusals: refusals)
        }
        var decision = try route()
        while consultingFolderListing, let refusal = TierModelRefusal.check(
            agent: decision.agent, tier: decision.tier, settings: settings, sources: sources,
            consultingFolderListing: true) {
            refusals[decision.agent] = refusal.message
            decision = try route()
        }
        let reason = context.openProblem.map {
            "\(decision.reason); no tie-break, the open sessions could not be read: \($0)"
        } ?? decision.reason
        return RoutedTask(decision: decision, reason: reason)
    }

    /// Why `agent`, picked by hand, cannot take the task `context` was read for, as the cached lists and
    /// the free-model rules judge it, or nil when it can.
    static func handPickRefusal(_ agent: AgentKind, context: RouteContext, settings: AgentModelSettings) -> String? {
        guard context.installed.contains(agent) else { return "not installed" }
        return Router.skipReason(
            for: agent, tier: context.tier, settings: settings, limits: context.limits, refusals: context.refusals)
    }

    private static func pick(
        byHand agent: AgentKind, context: RouteContext, settings: AgentModelSettings, sources: TierModelSources,
        consultingFolderListing: Bool
    ) throws -> RoutedTask {
        if let why = handPickRefusal(agent, context: context, settings: settings) {
            throw HandPickRefusal(agent: agent, why: why)
        }
        if consultingFolderListing, let refusal = TierModelRefusal.check(
            agent: agent, tier: context.tier, settings: settings, sources: sources, consultingFolderListing: true) {
            throw HandPickRefusal(agent: agent, why: refusal.message)
        }
        let effort = settings.tierEffort(for: agent, tier: context.tier)
        let summary = "your pick: \(agent.shortName)"
        let reason = ([summary] + (effort.map { ["effort \($0.rawValue)"] } ?? [])).joined(separator: "; ")
        return RoutedTask(
            decision: RouterDecision(
                agent: agent, tier: context.tier, effort: effort, reason: reason, summary: summary, notes: []),
            reason: reason)
    }
}

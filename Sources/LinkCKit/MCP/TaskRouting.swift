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

    /// Picks an agent, tier and effort from `context`; `only` limits the choice to that one agent. With
    /// `consultingFolderListing`, the agent picked is checked against what its own CLI lists in the folder
    /// (OpenCode and Kilo have one): when it refuses, that agent is skipped and the router picks again.
    /// Without it, no CLI runs.
    static func pick(
        prompt: String,
        context: RouteContext,
        settings: AgentModelSettings,
        sources: TierModelSources,
        only: AgentKind? = nil,
        consultingFolderListing: Bool
    ) throws -> RoutedTask {
        let installed = only.map { agent in context.installed.filter { $0 == agent } } ?? context.installed
        var refusals = context.refusals
        func route() throws -> RouterDecision {
            try Router.route(
                prompt: prompt, installed: installed, settings: settings, limits: context.limits,
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
}

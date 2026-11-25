import Foundation

/// Why an agent's configured model for a tier cannot take a task. `message` is the reason, with no
/// closing punctuation: routing reports it for a skipped agent, and delegation opens its error with
/// it and adds `remedy`, when there is one, as the next sentence.
struct TierModelRefusal: Equatable {
    let message: String
    let remedy: String?

    /// The error a delegation answers with.
    var delegationError: String {
        remedy.map { "Error: \(message). \($0)" } ?? "Error: \(message)"
    }
}

extension MCPServer {
    /// Whether `agent`'s model for `tier` is one a task can run on: free where the agent runs free
    /// models only, still offered by the agent's cached list, and still among what its own CLI lists
    /// in `destRoot`. Routing and delegation both ask this, so a model is judged the same way, case
    /// included, whichever path asks. Nil when it is usable or the tier has no model.
    func tierModelRefusal(
        agent: AgentKind,
        tier: ModelTier,
        settings: AgentModelSettings,
        destRoot: String,
        lists: () throws -> [AgentKind: AgentModelList]
    ) -> TierModelRefusal? {
        guard let model = settings.model(for: agent, tier: tier) else { return nil }
        let isFree: ((String) -> Bool)?
        switch agent {
        case .opencode: isFree = OpenCodeFreeModels.isFree
        case .kilo: isFree = KiloFreeModels.isFree
        case .crush: isFree = CrushFreeModels.isFree
        default: isFree = nil
        }
        if let isFree, !isFree(model) {
            return TierModelRefusal(
                message: "\(model) (\(agent.rawValue) tier \(tier.rawValue)) is not free — \(agent.displayName) runs free models only",
                remedy: "Set the tier in linkC settings.")
        }
        if ModelListParser.listedAgents.contains(agent) {
            do {
                if let offered = ModelListCache.liveModels(for: agent, lists: try lists()),
                   !offered.contains(where: { $0.id.caseInsensitiveCompare(model) == .orderedSame }) {
                    return TierModelRefusal(
                        message: "\(agent.rawValue)'s \(tier.rawValue) tier is set to \(model), which \(agent.rawValue) no longer offers",
                        remedy: "Pick another in Settings > Models. Offered: \(offered.map(\.id).joined(separator: ", ")).")
                }
            } catch {
                return TierModelRefusal(message: "could not read the live model lists — \(error)", remedy: nil)
            }
        }
        guard agent == .opencode || agent == .kilo else { return nil }
        do {
            let offered = try (agent == .kilo ? kiloModels : openCodeModels)(destRoot)
            guard offered.contains(where: { $0.caseInsensitiveCompare(model) == .orderedSame }) else {
                return TierModelRefusal(
                    message: "\(model) (\(agent.rawValue) tier \(tier.rawValue)) is not among the models \(agent.displayName) lists — free models come and go",
                    remedy: "Set the tier in linkC settings.")
            }
        } catch {
            let reason = agent == .kilo ? KiloLogin.reporting(String(describing: error)) : String(describing: error)
            return TierModelRefusal(
                message: "could not check \(agent.rawValue) tier \(tier.rawValue)'s model \(model) against the models \(agent.displayName) lists — \(reason)",
                remedy: nil)
        }
        return nil
    }
}

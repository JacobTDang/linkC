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

/// What one request reads to judge tier models, each read at most once: the app's cached model
/// lists, and what an agent's own CLI lists in the folder. A CLI listing starts a process that can
/// take most of a minute, so a request that has asked for one, a failure included, never asks again.
/// Routing and the delegation that follows it share one, so the agent routing picked is listed once.
final class TierModelSources {
    private let readLists: () throws -> [AgentKind: AgentModelList]
    private let listFolder: (AgentKind) throws -> [String]
    private var lists: Result<[AgentKind: AgentModelList], any Error>?
    private var folderListings: [AgentKind: Result<[String], any Error>] = [:]

    init(
        readLists: @escaping () throws -> [AgentKind: AgentModelList],
        listFolder: @escaping (AgentKind) throws -> [String]
    ) {
        self.readLists = readLists
        self.listFolder = listFolder
    }

    /// The cached lists, read on first use.
    func modelLists() throws -> [AgentKind: AgentModelList] {
        if let lists { return try lists.get() }
        let read = Result { try readLists() }
        lists = read
        return try read.get()
    }

    /// The models `agent`'s CLI lists in the folder, fetched on first use.
    func folderModels(of agent: AgentKind) throws -> [String] {
        if let listed = folderListings[agent] { return try listed.get() }
        let listed = Result { try listFolder(agent) }
        folderListings[agent] = listed
        return try listed.get()
    }
}

extension MCPServer {
    /// The reads one request makes to judge tier models, for the project whose folder is `destRoot`.
    func tierModelSources(destRoot: String) -> TierModelSources {
        TierModelSources(readLists: modelLists) { agent in
            try (agent == .kilo ? self.kiloModels : self.openCodeModels)(destRoot)
        }
    }
}

extension TierModelRefusal {
    /// Whether `agent`'s model for `tier` is one a task can run on: free where the agent runs free
    /// models only, still offered by the agent's cached list, and, when `consultingFolderListing`,
    /// still among what its own CLI lists. That last check runs the CLI, so a caller still choosing
    /// among agents leaves it off and asks it only of the agent it chose. Routing and delegation both
    /// ask this, so a model is judged the same way, case included, whichever path asks. Nil when it
    /// is usable or the tier has no model.
    static func check(
        agent: AgentKind,
        tier: ModelTier,
        settings: AgentModelSettings,
        sources: TierModelSources,
        consultingFolderListing: Bool
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
                if let offered = ModelListCache.liveModels(for: agent, lists: try sources.modelLists()),
                   !offered.contains(where: { $0.id.caseInsensitiveCompare(model) == .orderedSame }) {
                    return TierModelRefusal(
                        message: "\(agent.rawValue)'s \(tier.rawValue) tier is set to \(model), which \(agent.rawValue) no longer offers",
                        remedy: "Pick another in Settings > Models. Offered: \(offered.map(\.id).joined(separator: ", ")).")
                }
            } catch {
                return TierModelRefusal(message: "could not read the live model lists — \(error)", remedy: nil)
            }
        }
        guard consultingFolderListing, agent == .opencode || agent == .kilo else { return nil }
        do {
            let offered = try sources.folderModels(of: agent)
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

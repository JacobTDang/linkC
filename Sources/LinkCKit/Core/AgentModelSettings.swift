import Foundation

/// What a delegated task asks for. Delegation speaks only in tiers: providers rename models
/// constantly, and a rate-limit reroute moves a task to another agent kind, where a literal
/// model id would mean nothing.
public enum ModelTier: String, Codable, Sendable, CaseIterable, Equatable {
    case light, standard, deep

    /// Light first: `tier(forModel:agent:)` resolves an id shared by two tiers to the cheaper one.
    public static let resolutionOrder: [ModelTier] = [.light, .standard, .deep]

    public var label: String {
        switch self {
        case .light: return "Light"
        case .standard: return "Standard"
        case .deep: return "Deep"
        }
    }
}

/// The tier → model id mapping, keyed by `AgentKind.rawValue` so the JSON on disk reads plainly
/// and an unknown agent in an edited file is ignored rather than fatal.
public struct AgentModelSettings: Codable, Sendable, Equatable {
    public private(set) var models: [String: [String: String]]
    public private(set) var defaultTiers: [String: String]

    public init(models: [String: [String: String]], defaultTiers: [String: String]) {
        self.models = models
        self.defaultTiers = defaultTiers
    }

    /// Today's models — only ids verified against the real CLIs. `gpt-6-astra` is confirmed
    /// from `~/.codex/config.toml` and a live run; `gpt-6-sol` and `gpt-6-luna` both came back
    /// HTTP 400 ("not supported when using Codex with a ChatGPT account") when tried for real,
    /// and Codex validates nothing locally — a wrong id starts a session that then fails every
    /// request rather than refusing up front. So codex's `light` and `standard` are left empty:
    /// an empty entry means that tier is unconfigured, and delegation refuses loudly rather
    /// than launching a session pinned to a model nobody confirmed works. `agy models` lists
    /// the agy ids below verbatim. All are editable in settings if a provider changes them.
    public static let seeded = AgentModelSettings(
        models: [
            AgentKind.claude.rawValue: ["light": "haiku", "standard": "sonnet", "deep": "opus"],
            AgentKind.codex.rawValue: ["light": "", "standard": "", "deep": "gpt-6-astra"],
            AgentKind.agy.rawValue: [
                "light": "gemini-3.8-flash-low", "standard": "gemini-3.8-flash-medium", "deep": "gemini-3.1-pro-high"
            ]
        ],
        defaultTiers: [
            AgentKind.claude.rawValue: ModelTier.standard.rawValue,
            AgentKind.codex.rawValue: ModelTier.standard.rawValue,
            AgentKind.agy.rawValue: ModelTier.standard.rawValue
        ]
    )

    /// The model id to launch, or nil when this agent has no model for this tier — the caller
    /// refuses rather than substituting one.
    public func model(for agent: AgentKind, tier: ModelTier) -> String? {
        guard let id = models[agent.rawValue]?[tier.rawValue] else { return nil }
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func defaultTier(for agent: AgentKind) -> ModelTier {
        defaultTiers[agent.rawValue].flatMap(ModelTier.init(rawValue:)) ?? .standard
    }

    /// Which tier a running model belongs to, for a session whose model was switched by hand.
    public func tier(forModel model: String, agent: AgentKind) -> ModelTier? {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return ModelTier.resolutionOrder.first {
            self.model(for: agent, tier: $0)?.caseInsensitiveCompare(trimmed) == .orderedSame
        }
    }

    /// Every model id configured for `agent`, across all tiers, in light → standard → deep
    /// order and de-duplicated case-insensitively. `switch_model` validates a hand switch
    /// against this — the live mapping the delegator actually sees via `get_models` — rather
    /// than `AgentModelCatalog`, which is seed suggestions only, not a whitelist.
    public func configuredModels(for agent: AgentKind) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for tier in ModelTier.resolutionOrder {
            guard let id = model(for: agent, tier: tier) else { continue }
            guard seen.insert(id.lowercased()).inserted else { continue }
            result.append(id)
        }
        return result
    }

    public mutating func setModel(_ id: String, for agent: AgentKind, tier: ModelTier) {
        models[agent.rawValue, default: [:]][tier.rawValue] = id.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public mutating func setDefaultTier(_ tier: ModelTier, for agent: AgentKind) {
        defaultTiers[agent.rawValue] = tier.rawValue
    }
}

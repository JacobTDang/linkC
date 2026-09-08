import Foundation

/// Representation of an AI agent model supported within the free or subscription tier.
public struct AgentModelInfo: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    public let displayName: String
    public let isFreeOrSubscription: Bool
    public let isDefault: Bool

    public init(id: String, displayName: String, isFreeOrSubscription: Bool = true, isDefault: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.isFreeOrSubscription = isFreeOrSubscription
        self.isDefault = isDefault
    }
}

/// Catalog defining free and subscription-included models per agent, whitelist validation, and CLI commands.
public enum AgentModelCatalog: Sendable {
    /// Supported free and subscription-tier models for the given agent kind.
    public static func models(for agent: AgentKind) -> [AgentModelInfo] {
        switch agent {
        case .claude:
            return [
                AgentModelInfo(id: "sonnet", displayName: "Claude 3.5 Sonnet", isFreeOrSubscription: true, isDefault: true),
                AgentModelInfo(id: "haiku", displayName: "Claude 3.5 Haiku", isFreeOrSubscription: true, isDefault: false),
                AgentModelInfo(id: "opus", displayName: "Claude 3 Opus", isFreeOrSubscription: true, isDefault: false)
            ]
        case .codex:
            return [
                AgentModelInfo(id: "gpt-4o", displayName: "GPT-4o", isFreeOrSubscription: true, isDefault: true),
                AgentModelInfo(id: "o3-mini", displayName: "o3-mini", isFreeOrSubscription: true, isDefault: false),
                AgentModelInfo(id: "o1-mini", displayName: "o1-mini", isFreeOrSubscription: true, isDefault: false)
            ]
        case .agy:
            return [
                AgentModelInfo(id: "pro", displayName: "Pro", isFreeOrSubscription: true, isDefault: true),
                AgentModelInfo(id: "flash", displayName: "Flash", isFreeOrSubscription: true, isDefault: false),
                AgentModelInfo(id: "flash_lite", displayName: "Flash Lite", isFreeOrSubscription: true, isDefault: false)
            ]
        case .cursor:
            return [
                AgentModelInfo(id: "default", displayName: "Cursor Default", isFreeOrSubscription: true, isDefault: true)
            ]
        case .shell:
            return []
        }
    }

    /// Default free or subscription model for the agent.
    public static func defaultModel(for agent: AgentKind) -> AgentModelInfo {
        let all = models(for: agent)
        if let def = all.first(where: { $0.isDefault }) {
            return def
        }
        if let first = all.first {
            return first
        }
        return AgentModelInfo(id: "default", displayName: "Default", isFreeOrSubscription: true, isDefault: true)
    }

    /// Ordered fallback models for the agent, optionally excluding the active model.
    public static func fallbackModels(for agent: AgentKind, excluding: String? = nil) -> [AgentModelInfo] {
        let all = models(for: agent)
        guard let excluding else { return all }
        let trimmed = excluding.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return all }
        return all.filter {
            $0.id.caseInsensitiveCompare(trimmed) != .orderedSame &&
            $0.displayName.caseInsensitiveCompare(trimmed) != .orderedSame
        }
    }

    /// Validates whether the specified model is included in the free or subscription tier whitelist.
    public static func isFreeOrSubscription(model: String, for agent: AgentKind) -> Bool {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return models(for: agent).contains {
            ($0.id.caseInsensitiveCompare(trimmed) == .orderedSame ||
             $0.displayName.caseInsensitiveCompare(trimmed) == .orderedSame) &&
            $0.isFreeOrSubscription
        }
    }

    /// Generates an interactive terminal switch command for the agent.
    public static func interactiveSwitchCommand(model: String, for agent: AgentKind) -> String {
        "/model \(model)"
    }

    /// Generates CLI launch arguments for specifying the model.
    public static func launchArguments(model: String, for agent: AgentKind) -> [String] {
        ["--model", model]
    }
}

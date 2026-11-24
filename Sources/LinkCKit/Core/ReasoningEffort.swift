import Foundation

/// How hard the model should think on a turn. Mapped from a task's model tier at launch
/// (`light` → `low`, `standard` → `medium`, `deep` → `high`) and editable per agent in
/// Settings > Models. Only agents whose CLI accepts an effort knob use this; the rest stay
/// unset and Settings says so.
public enum ReasoningEffort: String, Codable, Sendable, CaseIterable, Equatable {
    case low, medium, high, xhigh, max

    public var label: String { rawValue }

    /// The effort a tier launches with when nothing has been configured for that agent yet.
    public static func `default`(for tier: ModelTier) -> ReasoningEffort {
        switch tier {
        case .light: return .low
        case .standard: return .medium
        case .deep: return .high
        }
    }
}

/// Whether an agent's CLI can take a reasoning-effort setting from linkC, and which levels.
public enum AgentEffortSupport: Sendable, Equatable {
    case levels([ReasoningEffort])
    /// Shown beside the tier in Settings > Models when the agent has no effort knob linkC can set.
    case unsupported(reason: String)

    public static func forAgent(_ agent: AgentKind) -> AgentEffortSupport {
        switch agent {
        case .claude, .agy, .codex:
            return .levels(ReasoningEffort.allCases)
        case .crush:
            // Crush's `reasoning_effort` config key only accepts low|medium|high.
            return .levels([.low, .medium, .high])
        case .cursor, .grok:
            return .unsupported(
                reason: "not supported by \(agent.displayName) — effort is in model ids and cannot be pinned by linkC")
        case .opencode, .kilo:
            return .unsupported(
                reason: "not supported by \(agent.displayName) — the TUI has no effort flag")
        case .freebuff, .shell:
            return .unsupported(reason: "not supported by \(agent.displayName)")
        }
    }

    public var isSupported: Bool {
        if case .levels = self { return true }
        return false
    }

    public var levels: [ReasoningEffort]? {
        if case .levels(let levels) = self { return levels }
        return nil
    }
}

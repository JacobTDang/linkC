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

    /// The levels an agent's CLI takes at all. For agy that is the most `--effort` accepts; which of
    /// them a given model takes is `forModel`.
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

    /// The levels a tier on `model` can run at, which is what Settings offers. For agy, only the
    /// levels agy lists for that model (`AgyEffort`); for every other agent, `forAgent`.
    public static func forModel(_ model: String?, agent: AgentKind, listed: [ListedModel]?) -> AgentEffortSupport {
        guard agent == .agy else { return forAgent(agent) }
        guard let model else { return .unsupported(reason: "no model is set for this tier") }
        guard let listed else {
            return .unsupported(reason: "agy's models have not been listed yet, so \(model) runs as configured")
        }
        let levels = AgyEffort.levels(for: model, listed: listed)
        guard !levels.isEmpty else {
            return .unsupported(reason: "agy lists no effort levels for \(model), so it runs as configured")
        }
        return .levels(levels)
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

/// agy keeps effort in its model ids: `agy models` lists `gemini-3.8-flash-low`, `-medium` and `-high`,
/// and `--effort` picks among the levels it lists for a base id. Measured on agy 1.5.16 with
/// `agy --print`: `--model gemini-3.8-flash --effort high` runs Gemini 3.8 Flash (High); a level agy
/// does not list for the base is refused (`gemini-3.8-flash --effort xhigh`: "available: low, medium,
/// high"; `gpt-oss-120b --effort high`: "available: medium"); a leveled id with another `--effort` is
/// refused as a conflict; and a model whose ids carry no level (`claude-opus-4-6-thinking`) refuses
/// `--effort` outright. A refused flag kills the worker at launch, so the flag goes only where agy
/// lists the level.
public enum AgyEffort {
    /// `id` as its base and level when it ends in `-<level>`; nil for an id with no level suffix.
    public static func split(_ id: String) -> (base: String, level: ReasoningEffort)? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let dash = trimmed.lastIndex(of: "-"),
              let level = ReasoningEffort(rawValue: String(trimmed[trimmed.index(after: dash)...])) else { return nil }
        let base = String(trimmed[..<dash])
        return base.isEmpty ? nil : (base, level)
    }

    /// The levels agy lists for `id`'s base, in `ReasoningEffort` order: none for an id with no level.
    public static func levels(for id: String, listed: [ListedModel]) -> [ReasoningEffort] {
        guard let base = split(id)?.base else { return [] }
        let offered = Set(listed.compactMap { model -> ReasoningEffort? in
            guard let parts = split(model.id), parts.base == base else { return nil }
            return parts.level
        })
        return ReasoningEffort.allCases.filter(offered.contains)
    }

    /// What to launch for the configured `id` at `effort`: its base id with `--effort` when agy lists
    /// that level for it, else the id as configured with no flag. With no list there is no telling.
    public static func launch(id: String, effort: ReasoningEffort?, listed: [ListedModel]?) -> (model: String, effort: ReasoningEffort?) {
        guard let effort, let listed, let base = split(id)?.base,
              levels(for: id, listed: listed).contains(effort) else { return (id, nil) }
        return (base, effort)
    }

    /// The level `id` runs at when launched at `effort`: that effort when agy lists it, else the level
    /// the id names; nil for an id with no level.
    public static func runningLevel(id: String, effort: ReasoningEffort?, listed: [ListedModel]?) -> ReasoningEffort? {
        launch(id: id, effort: effort, listed: listed).effort ?? split(id)?.level
    }
}

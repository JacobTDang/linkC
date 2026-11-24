import Foundation

/// CLI commands for launching and switching an agent's model. Live model ids come from
/// `ModelListCache` / `ModelListParser`, not from a hard-coded catalog.
public enum AgentModelCatalog: Sendable {
    /// Generates an interactive terminal switch command for the agent.
    public static func interactiveSwitchCommand(model: String, for agent: AgentKind) -> String {
        "/model \(model)"
    }

    /// Generates CLI launch arguments for specifying the model. OpenCode 2.2.5's TUI has no model
    /// flag — it refuses one — so its model goes in its inline config (`MCPRegistrar.openCodeConfigContent`).
    /// Crush's TUI has none either: its model goes in a per-session config (`CrushSessionConfig`).
    public static func launchArguments(model: String, for agent: AgentKind) -> [String] {
        agent == .opencode || agent == .kilo || agent == .crush ? [] : ["--model", model]
    }

    /// CLI flags that set reasoning effort at launch. Claude and agy take `--effort <level>`;
    /// Codex takes `-c model_reasoning_effort="<level>"`. Crush writes `reasoning_effort` into its
    /// per-session config (`CrushSessionConfig`) instead. Cursor/Grok bake effort into model ids
    /// and cannot be pinned by linkC; OpenCode and Kilo's TUIs have no effort flag.
    public static func effortLaunchArguments(effort: ReasoningEffort, for agent: AgentKind) -> [String] {
        switch agent {
        case .claude, .agy:
            return ["--effort", effort.rawValue]
        case .codex:
            return ["-c", "model_reasoning_effort=\"\(effort.rawValue)\""]
        case .crush, .opencode, .kilo, .cursor, .grok, .freebuff, .shell:
            return []
        }
    }

    /// Effort suffixes agy's Gemini (and similar) ids carry. Measured against agy: a leveled id
    /// plus a conflicting `--effort` is refused (`--model …-low conflicts with --effort=medium`);
    /// a matching level is accepted; a suffixless id plus `--effort` resolves to the leveled
    /// variant. Launch therefore strips the suffix whenever an effort flag is set, so the flag
    /// alone picks the level.
    private static let agyEffortSuffixes = ["-low", "-medium", "-high", "-xhigh", "-max", "-none", "-minimal"]

    /// The model id to pass agy when also passing `--effort`: the family's base id, with any
    /// baked-in effort suffix removed.
    public static func agyModelIdForLaunch(model: String, effort: ReasoningEffort) -> String {
        _ = effort
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in agyEffortSuffixes where trimmed.hasSuffix(suffix) {
            return String(trimmed.dropLast(suffix.count))
        }
        return trimmed
    }
}

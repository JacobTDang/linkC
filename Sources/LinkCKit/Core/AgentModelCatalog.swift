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

    /// CLI flags that set reasoning effort at launch. Claude and agy take `--effort <level>` (agy only
    /// for a model it lists that level for: `AgyEffort`); Codex takes `-c model_reasoning_effort="<level>"`.
    /// Crush's effort goes on the pinned models of its per-session config (`CrushSessionConfig`) instead.
    /// Cursor/Grok bake effort into model ids and cannot be pinned by linkC; OpenCode and Kilo's TUIs
    /// have no effort flag.
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
}

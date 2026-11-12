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
        agent == .opencode || agent == .crush ? [] : ["--model", model]
    }
}

import Foundation

/// What linkC does differently for OpenCode. See docs/superpowers/specs/2026-11-07-opencode-agent-design.md.
extension AppCoordinator {
    /// What an OpenCode terminal adds to `LINKC_SESSION`: no update dialog, and an inline config
    /// with the session's model — OpenCode's TUI takes no model flag — and linkC's tool server, so
    /// the tools are there even when registering in `opencode.json` failed. The server entry carries
    /// no session id: OpenCode hands its own environment, `LINKC_SESSION` included, to the servers
    /// it starts. A value already in linkC's environment is merged into, not replaced.
    func openCodeEnvironment(model: String?) throws -> [String: String] {
        var env = AgentDescriptor.environment(for: .opencode, home: FileManager.default.homeDirectoryForCurrentUser)
        env[AgentDescriptor.openCodeConfigContentKey] = try MCPRegistrar.openCodeConfigContent(
            inherited: ProcessInfo.processInfo.environment[AgentDescriptor.openCodeConfigContentKey],
            binaryPath: MCPRegistrar.defaultBinaryPath(),
            model: model)
        return env
    }
}

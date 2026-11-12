import Foundation

/// What linkC does differently for Kilo. See docs/superpowers/specs/2026-11-12-freebuff-kilo-crush-design.md §4.3.
extension AppCoordinator {
    /// What a Kilo terminal adds to `LINKC_SESSION`: no update dialog, and an inline config
    /// with the session's model — Kilo's TUI takes no model flag — and linkC's tool server, so
    /// the tools are there even when registering in `kilo.jsonc` failed (K2). The server entry
    /// carries no session id: Kilo hands its own environment, `LINKC_SESSION` included, to the
    /// servers it starts. A value already in linkC's environment is merged into, not replaced.
    func kiloEnvironment(model: String?) throws -> [String: String] {
        var env = AgentDescriptor.environment(for: .kilo, home: FileManager.default.homeDirectoryForCurrentUser)
        env[AgentDescriptor.kiloConfigContentKey] = try MCPRegistrar.kiloConfigContent(
            inherited: ProcessInfo.processInfo.environment[AgentDescriptor.kiloConfigContentKey],
            binaryPath: MCPRegistrar.defaultBinaryPath(),
            model: model)
        return env
    }

    /// Says that a Kilo session was brought back as a new conversation, in the log and to the
    /// user: its old one would have run on whatever model it last used.
    func tellKiloStartedFresh(title: String, folder: String) {
        let message = "Kilo starts a new conversation on restore, so it only ever runs a free model."
        NSLog("[linkC] %@ (%@): %@", title, folder, message)
        notifications.postLocal(title: "linkC: Kilo started a new conversation", body: "\(title): \(message)")
    }
}

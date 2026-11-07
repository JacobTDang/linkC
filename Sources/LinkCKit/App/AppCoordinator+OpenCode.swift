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

    /// Starts `terminal` on this folder's newest OpenCode session, or on a new one when none ran
    /// here, once the listing is back. The listing takes about a second, so it runs off the main
    /// thread while the session waits in `.starting`. A listing that fails ends the session and
    /// says why: continuing must never quietly become a new conversation.
    func continueOpenCode(session: Session, terminal: TerminalSession, executable: String, args: [String], env: [String: String]) {
        let list = openCodeSessionList
        let folder = session.cwd
        Task { @MainActor [weak self] in
            do {
                let listing = try await list(executable, folder)
                let id = try OpenCodeSessions.newest(in: folder, listing: listing)
                // Stopped while the listing ran: there is nothing left to start.
                guard let self, self.store.session(id: session.id) != nil else { return }
                try terminal.start(executable: executable, args: Self.openCodeArguments(args, continuing: id), env: env)
                self.sweepTicker?.wake()
            } catch {
                NSLog("[linkC] OpenCode could not continue in %@ — %@", folder, String(describing: error))
                guard let self else { return }
                self.notifications.post(title: "linkC: OpenCode could not continue",
                                        body: "\(session.title): \(error)")
                self.cleanup(sessionId: session.id)
            }
        }
    }

    /// `args` with `--session <id>` after OpenCode's flags, or unchanged when there is no session
    /// to continue.
    static func openCodeArguments(_ args: [String], continuing id: String?) -> [String] {
        guard let id else { return args }
        let flags = AgentDescriptor.descriptor(for: .opencode).yoloFlags
        return flags + ["--session", id] + args.dropFirst(flags.count)
    }

    /// `opencode session list --format json --standalone`, run in `folder` off the main thread.
    nonisolated static func listOpenCodeSessions(executable: String, folder: String) async throws -> String {
        let result = try await LiveProcessRunner().runCapturing(
            executable, args: OpenCodeSessions.listArguments, cwd: URL(fileURLWithPath: folder),
            env: AgentDescriptor.environment(for: .opencode, home: FileManager.default.homeDirectoryForCurrentUser),
            timeout: 30)
        guard result.status == 0 else {
            throw LinkCError.process("`opencode session list` in \(folder) exited \(result.status): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return result.stdout
    }
}

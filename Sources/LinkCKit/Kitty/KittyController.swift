import Foundation

/// Owns a dedicated kitty instance and drives it via remote control (`kitten @ ...`).
/// This is the only code in linkC that talks to kitty. Every command is built as an
/// argv array and handed to `runner` — never interpolated into a shell string, since
/// `cwd`/`title` may contain spaces or unicode.
public actor KittyController {
    public let kittyPath: String
    public let kittenPath: String
    public let socketPath: String   // e.g. "unix:/tmp/linkc.sock"
    private let runner: CommandRunner
    private let maxReadinessAttempts: Int
    private let readinessPollInterval: Duration
    /// Set by the backgrounded kitty launch in `ensureWorkspaceRunning` if it fails fast
    /// (e.g. bad flags, already running with a conflicting config). We can't propagate it
    /// synchronously — the launch is intentionally fire-and-forget since kitty is a
    /// long-lived process — but we must not silently discard it either, so it's folded
    /// into the eventual thrown error instead of a generic timeout message.
    private var lastLaunchFailure: String?

    public init(kittyPath: String, kittenPath: String, socketPath: String, runner: CommandRunner) {
        self.init(
            kittyPath: kittyPath,
            kittenPath: kittenPath,
            socketPath: socketPath,
            runner: runner,
            maxReadinessAttempts: 40,
            readinessPollInterval: .milliseconds(100)
        )
    }

    /// Test-only tuning seam (not part of the public contract) so readiness-polling
    /// tests don't have to wait on real kitty startup timing.
    init(
        kittyPath: String,
        kittenPath: String,
        socketPath: String,
        runner: CommandRunner,
        maxReadinessAttempts: Int,
        readinessPollInterval: Duration
    ) {
        self.kittyPath = kittyPath
        self.kittenPath = kittenPath
        self.socketPath = socketPath
        self.runner = runner
        self.maxReadinessAttempts = maxReadinessAttempts
        self.readinessPollInterval = readinessPollInterval
    }

    /// Launch the dedicated kitty (with control socket) if it isn't already reachable.
    public func ensureWorkspaceRunning() async throws {
        if try await probeReachable() { return }

        lastLaunchFailure = nil

        // kitty is a long-lived GUI process — we must not await its exit here. Fire the
        // launch in the background and poll `ls` until the control socket answers. Any
        // failure it reports is captured (not discarded) so it can surface below.
        let backgroundRunner = runner
        let path = kittyPath
        let launchArgv = Self.workspaceLaunchArgv(socketPath: socketPath)
        Task { [weak self] in
            do {
                let result = try await backgroundRunner.run(executable: path, arguments: launchArgv, environment: nil)
                if !result.succeeded {
                    await self?.recordLaunchFailure("kitty exited immediately (status \(result.exitCode)): \(result.stderr)")
                }
            } catch {
                await self?.recordLaunchFailure("failed to launch kitty at \(path): \(error)")
            }
        }

        for _ in 0..<maxReadinessAttempts {
            try await Task.sleep(for: readinessPollInterval)
            if try await probeReachable() { return }
            if let failure = lastLaunchFailure {
                throw LinkCError.kitty("kitty failed to start: \(failure)")
            }
        }

        throw LinkCError.kitty("kitty did not start listening on \(socketPath) in time")
    }

    private func recordLaunchFailure(_ message: String) {
        lastLaunchFailure = message
    }

    /// Launch a session tab running `command` (e.g. ["claude", "--settings", path]);
    /// returns the new kitty window id.
    public func launchSession(command: [String], cwd: String, title: String, linkcSessionId: String, extraEnv: [String: String]) async throws -> Int {
        let argv = Self.launchArgv(
            socketPath: socketPath,
            cwd: cwd,
            title: title,
            linkcSessionId: linkcSessionId,
            extraEnv: extraEnv,
            command: command
        )
        let result = try await runner.run(executable: kittenPath, arguments: argv, environment: nil)
        guard result.succeeded else {
            throw LinkCError.kitty("kitten launch failed (exit \(result.exitCode)): \(result.stderr)")
        }
        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let windowId = Int(trimmed) else {
            throw LinkCError.kitty("kitten launch did not return an integer window id, got: \(trimmed)")
        }
        return windowId
    }

    public func focus(linkcSessionId: String) async throws {
        let argv = Self.matchArgv(subcommand: "focus-tab", socketPath: socketPath, linkcSessionId: linkcSessionId)
        let result = try await runner.run(executable: kittenPath, arguments: argv, environment: nil)
        guard result.succeeded else {
            throw LinkCError.kitty("kitten focus-tab failed (exit \(result.exitCode)): \(result.stderr)")
        }
    }

    public func close(linkcSessionId: String) async throws {
        let argv = Self.matchArgv(subcommand: "close-tab", socketPath: socketPath, linkcSessionId: linkcSessionId)
        let result = try await runner.run(executable: kittenPath, arguments: argv, environment: nil)
        guard result.succeeded else {
            throw LinkCError.kitty("kitten close-tab failed (exit \(result.exitCode)): \(result.stderr)")
        }
    }

    public func list() async throws -> [KittyOSWindow] {
        let result = try await runner.run(executable: kittenPath, arguments: Self.lsArgv(socketPath: socketPath), environment: nil)
        guard result.succeeded else {
            throw LinkCError.kitty("kitten ls failed (exit \(result.exitCode)): \(result.stderr)")
        }
        return try KittyLsParser.parse(Data(result.stdout.utf8))
    }

    /// The linkc_session of the currently focused window (for focus-aware notifications).
    public func focusedLinkcSession() async throws -> String? {
        try await list().focusedLinkcSession
    }

    // MARK: - Reachability

    private func probeReachable() async throws -> Bool {
        try await runner.run(executable: kittenPath, arguments: Self.lsArgv(socketPath: socketPath), environment: nil).succeeded
    }

    // MARK: - argv construction
    //
    // Kept as pure static functions, free of actor state, and always built as arrays —
    // never by interpolating into a shell string.

    private static func rcPrefix(socketPath: String) -> [String] {
        ["@", "--to", socketPath]
    }

    private static func lsArgv(socketPath: String) -> [String] {
        rcPrefix(socketPath: socketPath) + ["ls"]
    }

    private static func matchArgv(subcommand: String, socketPath: String, linkcSessionId: String) -> [String] {
        rcPrefix(socketPath: socketPath) + [subcommand, "--match", "var:linkc_session=\(linkcSessionId)"]
    }

    private static func launchArgv(
        socketPath: String,
        cwd: String,
        title: String,
        linkcSessionId: String,
        extraEnv: [String: String],
        command: [String]
    ) -> [String] {
        var argv = rcPrefix(socketPath: socketPath)
        argv += ["launch", "--type=tab", "--cwd=\(cwd)", "--tab-title", title]
        argv += ["--var", "linkc_session=\(linkcSessionId)"]
        argv += ["--env", "LINKC_SESSION=\(linkcSessionId)"]
        for (key, value) in extraEnv.sorted(by: { $0.key < $1.key }) {
            argv += ["--env", "\(key)=\(value)"]
        }
        argv += command
        return argv
    }

    private static func workspaceLaunchArgv(socketPath: String) -> [String] {
        [
            "--instance-group", "linkc",
            "-o", "allow_remote_control=yes",
            "-o", "macos_quit_when_last_window_closed=yes",
            "--listen-on", socketPath,
        ]
    }
}

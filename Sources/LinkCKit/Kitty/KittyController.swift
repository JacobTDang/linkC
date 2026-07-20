import Foundation

// STUB — implemented in Task: Kitty module.
// Contract that the executable and other modules depend on.

/// Runs external commands via Foundation.Process. Drains stdout/stderr concurrently
/// (safe for large `kitten @ ls` output). Implemented in the Kitty task.
public struct ProcessCommandRunner: CommandRunner {
    public init() {}
    public func run(executable: String, arguments: [String], environment: [String: String]?) async throws -> CommandResult {
        throw LinkCError.unimplemented("ProcessCommandRunner.run")
    }
}

/// Parses `kitten @ ls` JSON into the KittyOSWindow tree. Implemented in the Kitty task.
public enum KittyLsParser {
    public static func parse(_ data: Data) throws -> [KittyOSWindow] {
        throw LinkCError.unimplemented("KittyLsParser.parse")
    }
}

/// Owns a dedicated kitty instance and drives it via remote control.
public actor KittyController {
    public let kittyPath: String
    public let kittenPath: String
    public let socketPath: String   // e.g. "unix:/tmp/linkc.sock"
    private let runner: CommandRunner

    public init(kittyPath: String, kittenPath: String, socketPath: String, runner: CommandRunner) {
        self.kittyPath = kittyPath
        self.kittenPath = kittenPath
        self.socketPath = socketPath
        self.runner = runner
    }

    /// Launch the dedicated kitty (with control socket) if it isn't already reachable.
    public func ensureWorkspaceRunning() async throws { throw LinkCError.unimplemented("ensureWorkspaceRunning") }

    /// Launch a session tab; returns the new kitty window id.
    public func launchSession(cwd: String, title: String, linkcSessionId: String, extraEnv: [String: String]) async throws -> Int {
        throw LinkCError.unimplemented("launchSession")
    }

    public func focus(linkcSessionId: String) async throws { throw LinkCError.unimplemented("focus") }
    public func close(linkcSessionId: String) async throws { throw LinkCError.unimplemented("close") }
    public func list() async throws -> [KittyOSWindow] { throw LinkCError.unimplemented("list") }

    /// The linkc_session of the currently focused window (for focus-aware notifications).
    public func focusedLinkcSession() async throws -> String? { throw LinkCError.unimplemented("focusedLinkcSession") }
}

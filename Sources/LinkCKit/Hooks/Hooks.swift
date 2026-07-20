import Foundation

// STUB — implemented in Task: Hooks module.

/// Decodes a hook request (our `X-LinkC-*` headers + Claude's JSON body) into a HookEvent.
public enum HookEventDecoder {
    /// Returns nil if the event kind is unknown. Header lookup must be case-insensitive.
    public static func decode(headers: [String: String], body: Data) -> HookEvent? {
        return nil
    }
}

/// Local loopback HTTP server that receives Claude Code HTTP hooks.
/// Responds 200 with an empty body immediately and never blocks a turn.
public final class HookServer {
    public let port: UInt16
    /// Called on each decoded event. The caller is responsible for hopping to the main actor.
    public var onEvent: (@Sendable (HookEvent) -> Void)?

    public init(port: UInt16) { self.port = port }

    public func start() throws { throw LinkCError.unimplemented("HookServer.start") }
    public func stop() {}
}

/// Produces the per-session settings JSON passed via `claude --settings`.
/// Deep-merges the user's global + project settings with linkC's hooks so a linkC
/// session behaves identically to a normal one, plus reports its lifecycle.
public enum SettingsComposer {
    /// The hooks block linkC injects, pointing every relevant event at the local server.
    public static func linkcHooks(port: UInt16) -> [String: Any] { [:] }

    /// Deep-merge user + project settings with linkC hooks. Appends to existing hook
    /// arrays rather than clobbering them.
    public static func compose(userSettings: Data?, projectSettings: Data?, port: UInt16) throws -> Data {
        throw LinkCError.unimplemented("SettingsComposer.compose")
    }
}

import Foundation

/// A live session, as linkC hands it to its agent's `SessionLiveReader`.
public struct LiveSessionTarget: Equatable, Sendable {
    /// linkC's id for the session.
    public let sessionId: String
    public let agent: AgentKind
    /// The session's folder, canonical.
    public let cwd: String
    /// The agent's own id for its conversation, when linkC knows it (OpenCode's, which linkC passes).
    public let agentSessionId: String?
    /// The files the session's process tree holds open (`ProcessSnooper.openFilePaths`): an agent's
    /// session record among them ties the session to it exactly.
    public let openFiles: [String]

    public init(sessionId: String, agent: AgentKind, cwd: String, agentSessionId: String? = nil, openFiles: [String] = []) {
        self.sessionId = sessionId
        self.agent = agent
        self.cwd = cwd
        self.agentSessionId = agentSessionId
        self.openFiles = openFiles
    }
}

/// Reads what one agent's own files say about a live session: its context use, the step its turn is
/// on, its running subagents. Runs off the main actor; a field the files don't record stays nil.
/// Throws when a record it found cannot be read, so the failure is said rather than shown as nothing.
public protocol SessionLiveReader: Sendable {
    func read(_ target: LiveSessionTarget) throws -> SessionLiveDetail
}

extension SessionLiveDetail {
    /// How full a context window is, 0–100, from the tokens used and the window the agent records.
    /// Nil when either is not recorded or the window is empty.
    static func contextPercent(used: UInt64?, window: UInt64?) -> Int? {
        guard let used, let window, window > 0 else { return nil }
        return Int(min(100, (Double(used) / Double(window) * 100).rounded()))
    }
}

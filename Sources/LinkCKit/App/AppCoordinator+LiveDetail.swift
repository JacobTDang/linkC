import Foundation

extension AppCoordinator {
    /// The reader of each agent whose own files say something about a live session, over the
    /// user's own files under `home`.
    static func liveReaders(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [AgentKind: any SessionLiveReader] {
        [
            .codex: CodexRolloutReader(),
            .opencode: OpenCodeLiveReader(home: home),
        ]
    }

    /// What `session`'s agent reports first-hand about it, for its row in `projects.json`. Claude's
    /// comes from what linkC already holds for it; every other agent's from the last read of its files.
    func liveDetail(for session: Session) -> SessionLiveDetail {
        switch session.agentKind {
        case .claude:
            // The step and subagents from its transcript, as the hooks keep it read.
            return SessionLiveDetail(contextPercent: sessionStatuses.status(for: session.id)?.contextPercent,
                                     step: usageTracker?.sessionActivity(session.id),
                                     subagents: usageTracker?.sessionSubagentSteps(session.id) ?? [])
        default:
            return liveDetails.detail(for: session.id) ?? SessionLiveDetail()
        }
    }

    /// Asks for a read of every live session's own files, off the main actor; it lands for a later publish.
    func refreshLiveDetails(_ sessions: [Session]) {
        liveDetails.refresh(sessions.map { session in
            LiveDetailSampler.Session(
                id: session.id, agent: session.agentKind, cwd: ProjectPath.canonical(session.cwd),
                agentSessionId: session.claudeSessionId,
                pid: terminals.session(id: session.id).map(\.processId).flatMap { $0 > 0 ? $0 : nil })
        })
    }

    /// Test seam: wait for the read of the sessions' own files that runs now.
    func settleLiveDetailsForTests() async {
        await liveDetails.settle()
    }
}

import Foundation

/// Which workers to close now. A worker is closed once it holds no open task and has sat idle —
/// finished, ready, or waiting for input — for the grace. A session the user opened is never
/// closed, and neither is one still working or waiting on a prompt. Pure: `now` is injected.
public enum WorkerReaper {
    /// Long enough for back-to-back tasks and a follow-up to reuse a worker and its context.
    public static let idleGrace: TimeInterval = 10 * 60

    private static let idleStates: Set<SessionState> = [.ready, .finished, .waitingIdle]

    public static func closable(
        sessions: [Session], taskAssignees: Set<String>, now: Date, grace: TimeInterval = idleGrace
    ) -> [String] {
        sessions
            .filter { session in
                session.isWorker
                    && !taskAssignees.contains(session.id)
                    && idleStates.contains(session.state)
                    && now.timeIntervalSince(session.stateChangedAt) >= grace
            }
            .map(\.id)
    }
}

import Foundation

/// Which workers to close now. A worker holding no open task is closed once it is idle
/// (finished, ready, or waiting for input) and either its last task ended a `completionGrace`
/// ago or it has sat idle for the `idleGrace` backstop. A session the user opened is never
/// closed, and neither is one still working or waiting on a prompt. Pure: `now` is injected.
public enum WorkerReaper {
    /// Long enough for back-to-back tasks and a follow-up to reuse a worker and its context.
    public static let idleGrace: TimeInterval = 10 * 60
    /// How long a worker lingers after its task reaches a final state: time for the report or
    /// notice to land, and for a quick follow-up task to reuse it.
    public static let completionGrace: TimeInterval = 60

    private static let idleStates: Set<SessionState> = [.ready, .finished, .waitingIdle]

    /// `tasks` is every task in the workspace. An open task assigned to a session holds it; a
    /// final one starts its completion grace. A queued or gating task a worker could take keeps
    /// it through the completion grace, so a follow-up is not raced by the close; the idle
    /// backstop does not wait for one.
    public static func closable(sessions: [Session], tasks: [TaskRecord], now: Date) -> [String] {
        let holders = Set(tasks.filter { $0.state.isOpen }.compactMap(\.assigneeSessionId))
        let unassigned = tasks.filter { $0.state.isOpen && $0.assigneeSessionId == nil }
        var lastEnded: [String: Date] = [:]
        for task in tasks where !task.state.isOpen {
            guard let assignee = task.assigneeSessionId else { continue }
            let ended = task.finishedAt ?? task.createdAt
            lastEnded[assignee] = max(lastEnded[assignee] ?? .distantPast, ended)
        }
        return sessions
            .filter { session in
                guard session.isWorker, !holders.contains(session.id),
                      idleStates.contains(session.state) else { return false }
                if now.timeIntervalSince(session.stateChangedAt) >= idleGrace { return true }
                guard let ended = lastEnded[session.id],
                      now.timeIntervalSince(ended) >= completionGrace else { return false }
                return !unassigned.contains { session.canCarry($0) }
            }
            .map(\.id)
    }
}

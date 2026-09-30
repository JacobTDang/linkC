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

    /// What to do about a request to close `task`'s worker. `session` is the task's assignee as the
    /// app knows it (nil once it is gone) and `onScreen` says whether the user is looking at it.
    /// The delegator is answered at once, so a busy worker is refused; the worker's own request is
    /// made mid-turn by definition, so it waits for the turn to end.
    public static func decision(
        for request: CloseRequest, task: TaskRecord, among tasks: [TaskRecord],
        session: Session?, onScreen: Bool
    ) -> CloseDecision {
        if task.assigneeSessionId != nil, session == nil { return .alreadyClosed }
        if let reason = CloseRequest.refusal(for: task, among: tasks) { return .refuse(reason) }
        guard let session else { return .alreadyClosed }
        guard session.isWorker else {
            return .refuse("that session is not a worker linkC launched for a task (a session you opened, or one you took over by opening it), and linkC never closes those.")
        }
        guard !onScreen else {
            return .refuse("it is open on screen, and linkC never closes the session on screen.")
        }
        guard idleStates.contains(session.state) else {
            switch request.by {
            case .worker:
                return .wait
            case .delegator:
                return .refuse("it is not idle (still working or waiting on a prompt); a worker also closes by itself about a minute after its task ends.")
            }
        }
        return .close(sessionId: session.id)
    }
}

/// What the relay does with a request to close a worker.
public enum CloseDecision: Equatable, Sendable {
    case close(sessionId: String)
    /// The session is already gone, so the request is met.
    case alreadyClosed
    /// Not yet: ask again on a later pass.
    case wait
    case refuse(String)
}

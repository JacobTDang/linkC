import Foundation

/// Which workers to close now. A worker holding no open task is closed once it is idle
/// (finished, ready, or waiting for input) and either it has been idle for a `completionGrace`
/// since its last task ended or it has sat idle for the `idleGrace` backstop. A session the user
/// opened is never closed, and neither is one still working or waiting on a prompt. Pure: `now`
/// is injected.
public enum WorkerReaper {
    /// Long enough for back-to-back tasks and a follow-up to reuse a worker and its context.
    public static let idleGrace: TimeInterval = 10 * 60
    /// How long a worker lingers after its task reaches a final state: time for the report or
    /// notice to land, and for a quick follow-up task to reuse it. It must also have been idle for
    /// that long, so a worker that looked busy a moment ago is not closed on one idle reading.
    public static let completionGrace: TimeInterval = 60

    private static let idleStates: Set<SessionState> = [.ready, .finished, .waitingIdle]

    /// `tasks` is every task in the workspace. An open task assigned to a session holds it; a
    /// final one starts its completion grace. A queued or gating task a worker could take keeps
    /// it through the completion grace, so a follow-up is not raced by the close; the idle
    /// backstop does not wait for one.
    ///
    /// `lastTypedAt` is when linkC last typed into each session. linkC types only into a session
    /// that reads as idle, and the reading lags what it typed, so text typed in after the task
    /// ended (a peer note the worker may be acting on) keeps the worker from the completion rule
    /// and restarts the backstop's clock.
    public static func closable(
        sessions: [Session], tasks: [TaskRecord], lastTypedAt: [String: Date], now: Date
    ) -> [String] {
        let holders = Set(tasks.filter { $0.state.isOpen }.compactMap(\.assigneeSessionId))
        let unassigned = tasks.filter { $0.state.isOpen && $0.assigneeSessionId == nil }
        let lastEnded = latestEnds(in: tasks)
        return sessions
            .filter { session in
                guard session.isWorker, !holders.contains(session.id),
                      idleStates.contains(session.state) else { return false }
                let typed = lastTypedAt[session.id]
                let idleSince = max(session.stateChangedAt, typed ?? .distantPast)
                if now.timeIntervalSince(idleSince) >= idleGrace { return true }
                guard let ended = lastEnded[session.id] else { return false }
                if let typed, typed > ended { return false }
                guard now.timeIntervalSince(max(ended, session.stateChangedAt)) >= completionGrace else { return false }
                return !unassigned.contains { session.canCarry($0) }
            }
            .map(\.id)
    }

    /// When each session's latest task reached a final state: its finish time, or its creation for
    /// a row that has none.
    private static func latestEnds(in tasks: [TaskRecord]) -> [String: Date] {
        var lastEnded: [String: Date] = [:]
        for task in tasks where !task.state.isOpen {
            guard let assignee = task.assigneeSessionId else { continue }
            lastEnded[assignee] = max(lastEnded[assignee] ?? .distantPast, task.finishedAt ?? task.createdAt)
        }
        return lastEnded
    }

    /// What to do about a request to close `task`'s worker. `session` is the task's assignee as the
    /// app knows it (nil once it is gone) and `onScreen` says whether the user is looking at it.
    /// `lastTypedAt` is when linkC last typed into it. The delegator is answered at once, so a
    /// worker that is busy, or that may be acting on what linkC typed in, is refused; the worker's
    /// own request is made mid-turn by definition, so it waits for the turn to settle.
    public static func decision(
        for request: CloseRequest, task: TaskRecord, among tasks: [TaskRecord],
        session: Session?, onScreen: Bool, lastTypedAt: Date?
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
        func hold(_ reason: String) -> CloseDecision {
            switch request.by {
            case .worker: return .wait
            case .delegator: return .refuse(reason)
            }
        }
        guard idleStates.contains(session.state) else {
            return hold("it is not idle (still working or waiting on a prompt); a worker also closes by itself about a minute after its task ends.")
        }
        // Its idle reading dates from before what linkC typed in, or from before its task ended
        // when the text came after: it may be acting on it. (A task not yet settled has no end.)
        let ended = task.state.isOpen ? nil : latestEnds(in: tasks)[session.id]
        let settledAt = min(session.stateChangedAt, ended ?? .distantFuture)
        if let typed = lastTypedAt, typed > settledAt {
            return hold("linkC typed into it after its task ended, so it may still be acting on that; it closes by itself once it has been idle for ten minutes.")
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

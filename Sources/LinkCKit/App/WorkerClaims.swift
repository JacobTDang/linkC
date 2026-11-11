import Foundation

/// What one relay pass does with a queued task.
public enum WorkerClaim: Equatable, Sendable {
    /// The session is idle and ready to take the brief now.
    case deliver(to: String)
    /// The session is idle but not ready yet: inside the injection gap, or its paste not settled.
    case awaitReady(String)
    /// The session is still starting.
    case awaitStart(String)
    /// A pinned task whose session cannot take it this pass. It never starts a session.
    case awaitPinned
    /// No session is free for the task: start a worker.
    case spawn
}

/// Which session each queued task goes to in one relay pass (spec 2026-11-11 §4). A free session
/// is one that can carry the task, is idle or still starting, and is not still holding a task it
/// was given and has not reported. Each free session is claimed by at most one task in a pass, so a
/// worker still booting counts as taken and two tasks start exactly two workers, not one per pass.
/// When no session is free, the task starts another: there is no cap. Pure: it decides only.
public enum WorkerClaims {
    private static let idleStates: Set<SessionState> = [.ready, .finished, .waitingIdle]

    /// `queued` in queue order. `sessions` are the folder's sessions. `holdingUnreported` are the
    /// assignees of delivered or started tasks. `ready` are the idle sessions that can take a paste
    /// now. Pinned tasks claim first, so an earlier unpinned task cannot take a pinned task's session.
    public static func plan(
        queued: [TaskRecord], sessions: [Session], holdingUnreported: Set<String>, ready: Set<String>
    ) -> [String: WorkerClaim] {
        let live = sessions.filter { $0.state != .ended }
        var claimed: Set<String> = []
        var claims: [String: WorkerClaim] = [:]

        func claim(_ session: Session) -> WorkerClaim {
            claimed.insert(session.id)
            if session.state == .starting { return .awaitStart(session.id) }
            return ready.contains(session.id) ? .deliver(to: session.id) : .awaitReady(session.id)
        }

        for task in queued {
            guard let target = task.targetSessionId else { continue }
            if let session = live.first(where: { $0.id == target }), !claimed.contains(target),
               session.canCarry(task), isFree(session) {
                claims[task.id] = claim(session)
            } else {
                claims[task.id] = .awaitPinned
            }
        }

        for task in queued where task.targetSessionId == nil {
            let free = live.filter {
                !claimed.contains($0.id) && !holdingUnreported.contains($0.id) && $0.canCarry(task) && isFree($0)
            }
            let preferred = free.first { idleStates.contains($0.state) && ready.contains($0.id) }
                ?? free.first { idleStates.contains($0.state) }
                ?? free.first
            claims[task.id] = preferred.map(claim) ?? .spawn
        }
        return claims
    }

    private static func isFree(_ session: Session) -> Bool {
        session.state == .starting || idleStates.contains(session.state)
    }
}

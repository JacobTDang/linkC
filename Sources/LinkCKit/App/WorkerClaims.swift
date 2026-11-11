import Foundation

/// What one relay pass does with a queued task.
public enum WorkerClaim: Equatable, Sendable {
    /// The session is idle and ready to take the brief now.
    case deliver(to: String)
    /// The session is idle but not ready yet: inside the injection gap, or its paste not settled.
    case awaitReady(String)
    /// The session is still starting.
    case awaitStart(String)
    /// A worker holding no task that is busy or held at a prompt, such as a trust dialog at boot. It
    /// is waited for: a worker started past it could stop at the same prompt, pass after pass.
    case awaitBusy(String)
    /// A session that could carry the task is rate-limited, so its agent is paused.
    case awaitLimited(String)
    /// A pinned task whose session cannot take it this pass. It never starts a session.
    case awaitPinned
    /// No session is free for the task: start a worker.
    case spawn
}

/// Which session each queued task goes to in one relay pass (spec 2026-11-11 §4). A free session
/// is one that can carry the task, is idle or still starting, and is not still holding a task it
/// was given and has not reported. Each free session is claimed by at most one task in a pass, so a
/// worker still booting counts as taken. A task that finds no free session starts another worker:
/// there is no cap. Pure: it decides only.
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
            if !idleStates.contains(session.state) { return .awaitBusy(session.id) }
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
            let carriers = live.filter { $0.canCarry(task) }
            let unclaimed = carriers.filter { !claimed.contains($0.id) && !holdingUnreported.contains($0.id) }
            let free = unclaimed.filter(isFree)
            let pick = free.first { idleStates.contains($0.state) && ready.contains($0.id) }
                ?? free.first { idleStates.contains($0.state) }
                ?? free.first
                ?? unclaimed.first { $0.isWorker && ($0.state == .working || $0.state == .waitingPermission) }
            if let pick {
                claims[task.id] = claim(pick)
            } else if let limited = carriers.first(where: { $0.state == .error }) {
                claims[task.id] = .awaitLimited(limited.id)
            } else {
                claims[task.id] = .spawn
            }
        }
        return claims
    }

    private static func isFree(_ session: Session) -> Bool {
        session.state == .starting || idleStates.contains(session.state)
    }
}

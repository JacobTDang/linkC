import Foundation

/// The stuck-task watchdog: reports a task that is out with a worker but no longer moving. It
/// never cancels, reassigns, or retries — the whole action is one line to the delegating agent and
/// one notification to the user, once per stuck spell.
extension AppCoordinator {
    /// Delivered this long ago without the worker starting it.
    static let neverStartedThreshold: TimeInterval = 10 * 60
    /// The worker has been sitting on a prompt this long.
    static let waitingOnUserThreshold: TimeInterval = 5 * 60
    /// The worker says it is working but its screen has not changed for this long.
    static let goneQuietThreshold: TimeInterval = 15 * 60

    /// Why a task looks stuck, in the words the delegator and the user are told.
    enum StuckReason: String, Equatable {
        case neverStarted = "delivered 10m ago and never started"
        case waitingOnUser = "its worker has been waiting on a prompt for 5m"
        case goneQuiet = "its worker's screen has not changed for 15m"
    }

    /// The reason `task` looks stuck at `date`, or nil while it is still moving. A long quiet test
    /// run is indistinguishable from a hang from outside; the action is only a notice.
    func stuckReason(for task: TaskRecord, at date: Date) -> StuckReason? {
        if task.state == .delivered, let deliveredAt = task.deliveredAt,
           date.timeIntervalSince(deliveredAt) > Self.neverStartedThreshold {
            return .neverStarted
        }
        guard let sessionId = task.assigneeSessionId, let session = store.session(id: sessionId) else { return nil }
        if session.state == .waitingPermission,
           date.timeIntervalSince(session.stateChangedAt) > Self.waitingOnUserThreshold {
            return .waitingOnUser
        }
        if session.state == .working, let since = screenUnchangedSince(sessionId),
           date.timeIntervalSince(since) > Self.goneQuietThreshold {
            return .goneQuiet
        }
        return nil
    }

    /// One watchdog pass over `workspacePath`'s open tasks. Returns `true` when the inbox lock was
    /// still contended after `Self.relayLockTimeout`, which ends the tick.
    @discardableResult
    func watchStuckTasks(workspacePath: String, inboxStore: InboxStore) -> Bool {
        guard workspaceExists(workspacePath) else { return false }
        let open: [TaskRecord]
        do {
            open = try inboxStore.openTasks(timeout: Self.relayLockTimeout)
        } catch {
            if isRelayLockTimeout(error) { return true }
            NSLog("[linkC relay] watchStuckTasks: open tasks — %@", String(describing: error))
            return false
        }

        let date = now()
        var reported: [StuckReason] = []
        for task in open where task.state == .delivered || task.state == .started {
            do {
                guard let reason = stuckReason(for: task, at: date) else {
                    // Moving again: clear the mark so a later stall is reported.
                    if task.stuckNotifiedAt != nil {
                        try inboxStore.setStuckNotified(taskId: task.id, at: nil, timeout: Self.relayLockTimeout)
                    }
                    continue
                }
                guard task.stuckNotifiedAt == nil else { continue }
                try inboxStore.notifyStuck(
                    taskId: task.id,
                    body: "Task \(task.shortId) looks stuck: \(reason.rawValue). "
                        + "linkc_get_task(\"\(task.id)\") or linkc_cancel_task(\"\(task.id)\").",
                    at: date,
                    timeout: Self.relayLockTimeout
                )
                reported.append(reason)
            } catch {
                if isRelayLockTimeout(error) { return true }
                NSLog("[linkC relay] watchStuckTasks: task %@ — %@", task.shortId, String(describing: error))
            }
        }

        if !reported.isEmpty {
            var seen: Set<String> = []
            let reasons = reported.map(\.rawValue).filter { seen.insert($0).inserted }
            notifications.post(
                title: "linkC: \(reported.count) task(s) look stuck",
                body: "\(reasons.joined(separator: "; ")). The delegating agent was told."
            )
        }
        return false
    }
}

import Foundation

extension AppCoordinator {
    /// Closes this workspace's workers that have sat idle with no open task for
    /// `WorkerReaper.idleGrace`. A relay phase: returns `true` when the inbox lock was still
    /// contended after `relayLockTimeout`, so the tick stops there; any other failure is logged
    /// and closes nothing. It runs before `dispatchTasks`, so a worker idle past the grace can be
    /// closed in the tick a new task was queued for it; the next tick picks or spawns another.
    @discardableResult
    func reapIdleWorkers(workspacePath: String, inboxStore: InboxStore) -> Bool {
        // Like every relay phase: a store read would recreate a deleted workspace on disk.
        guard workspaceExists(workspacePath) else { return false }
        let workers = store.sessions.filter {
            $0.isWorker && ($0.cwd as NSString).standardizingPath == workspacePath
        }
        guard !workers.isEmpty else { return false }
        let assignees: Set<String>
        do {
            assignees = Set(try inboxStore.openTasks(timeout: Self.relayLockTimeout).compactMap(\.assigneeSessionId))
        } catch {
            if isRelayLockTimeout(error) { return true }
            NSLog("[linkC relay] reapIdleWorkers: open tasks — %@", String(describing: error))
            return false
        }
        for id in WorkerReaper.closable(sessions: workers, taskAssignees: assignees, now: now()) {
            // Only `focusSession` clears `isWorker`, but a worker can land on screen another way
            // (a relaunch, or the fallback that hands the selection to the newest terminal when
            // the one on screen closes) without ever being adopted. Never close the one the user
            // is actually looking at.
            guard id != terminals.selectedId else { continue }
            NSLog("[linkC relay] closing idle worker %@ in %@", id, workspacePath)
            stopSession(id)
        }
        return false
    }
}

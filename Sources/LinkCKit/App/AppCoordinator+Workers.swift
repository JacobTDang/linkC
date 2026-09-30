import Foundation

extension AppCoordinator {
    /// Closes this workspace's workers whose tasks have ended (`WorkerReaper.completionGrace`) or
    /// that have sat idle with no open task for `WorkerReaper.idleGrace`. A relay phase: returns
    /// `true` when the inbox lock was still contended after `relayLockTimeout`, so the tick stops
    /// there; any other failure is logged and closes nothing. It runs before `dispatchTasks`, so a
    /// worker idle past the backstop can be closed in the tick a new task was queued for it; the
    /// next tick picks or spawns another. A finished worker a queued task could take is kept for
    /// that task instead.
    @discardableResult
    func reapIdleWorkers(workspacePath: String, inboxStore: InboxStore) -> Bool {
        // Like every relay phase: a store read would recreate a deleted workspace on disk.
        guard workspaceExists(workspacePath) else { return false }
        let norm = ProjectPath.canonical(workspacePath)
        let workers = store.sessions.filter {
            $0.isWorker && $0.cwd == norm
        }
        guard !workers.isEmpty else { return false }
        let tasks: [TaskRecord]
        do {
            tasks = try inboxStore.load(timeout: Self.relayLockTimeout).tasks
        } catch {
            if isRelayLockTimeout(error) { return true }
            NSLog("[linkC relay] reapIdleWorkers: tasks — %@", String(describing: error))
            return false
        }
        for id in WorkerReaper.closable(sessions: workers, tasks: tasks, now: now()) {
            // Only `focusSession` clears `isWorker`, but a worker can land on screen another way
            // (a relaunch, or the fallback that hands the selection to the newest terminal when
            // the one on screen closes) without ever being adopted. Never close the one the user
            // is actually looking at.
            guard id != terminals.selectedId else { continue }
            NSLog("[linkC relay] closing finished worker %@ in %@", id, workspacePath)
            stopSession(id)
        }
        return false
    }
}

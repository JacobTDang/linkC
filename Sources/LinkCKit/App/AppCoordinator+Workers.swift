import Foundation

extension AppCoordinator {
    /// Closes this workspace's workers that have sat idle with no open task for
    /// `WorkerReaper.idleGrace`. A relay phase: returns `true` when the inbox lock was still
    /// contended after `relayLockTimeout`, so the tick stops there; any other failure is logged
    /// and closes nothing.
    @discardableResult
    func reapIdleWorkers(workspacePath: String, inboxStore: InboxStore) -> Bool {
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
            NSLog("[linkC relay] closing idle worker %@ in %@", id, workspacePath)
            stopSession(id)
        }
        return false
    }
}

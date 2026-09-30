import Foundation

extension AppCoordinator {
    /// Closes this workspace's workers: those a delegator or the worker itself asked to close, those
    /// idle for `WorkerReaper.completionGrace` since their tasks ended, and those that have sat idle
    /// with no open task for `WorkerReaper.idleGrace`. A relay phase: returns `true` when the inbox lock
    /// was still contended after `relayLockTimeout`, so the tick stops there; any other failure is
    /// logged and closes nothing. It runs before `dispatchTasks`, so a worker idle past the backstop
    /// can be closed in the tick a new task was queued for it; the next tick picks or spawns
    /// another. A finished worker a queued task could take is kept for that task instead.
    @discardableResult
    func reapIdleWorkers(workspacePath: String, inboxStore: InboxStore) -> Bool {
        // Like every relay phase: a store read would recreate a deleted workspace on disk.
        guard workspaceExists(workspacePath) else { return false }
        let norm = ProjectPath.canonical(workspacePath)
        guard store.sessions.contains(where: { $0.cwd == norm }) else { return false }
        let tasks: [TaskRecord]
        do {
            tasks = try inboxStore.load(timeout: Self.relayLockTimeout).tasks
        } catch {
            if isRelayLockTimeout(error) { return true }
            NSLog("[linkC relay] reapIdleWorkers: tasks — %@", String(describing: error))
            return false
        }
        if answerCloseRequests(tasks: tasks, inboxStore: inboxStore) { return true }
        let workers = store.sessions.filter {
            $0.isWorker && $0.cwd == norm
        }
        for id in WorkerReaper.closable(sessions: workers, tasks: tasks, lastTypedAt: lastInjectionAt, now: now()) {
            // Only opening a worker or typing into it clears `isWorker`, but a worker can land on
            // screen another way (a relaunch, or the fallback that hands the selection to the newest
            // terminal when the one on screen closes) and be only watched. Never close the one the
            // user is actually looking at.
            guard id != terminals.selectedId else { continue }
            NSLog("[linkC relay] closing finished worker %@ in %@", id, workspacePath)
            stopSession(id)
        }
        return false
    }

    /// Decides every pending close request in `tasks` and writes the answer back on the task, for
    /// the tool that asked to read. A request that has to wait stays pending. Returns `true` when
    /// the inbox lock was still contended after `relayLockTimeout`; the request is then decided
    /// again next tick, and a session already closed reads as closed.
    private func answerCloseRequests(tasks: [TaskRecord], inboxStore: InboxStore) -> Bool {
        for task in tasks {
            guard let request = task.closeRequest, request.isPending else { continue }
            let session = task.assigneeSessionId.flatMap { store.session(id: $0) }
            let onScreen = session.map { $0.id == terminals.selectedId } ?? false
            let outcome: CloseRequest.Outcome
            switch WorkerReaper.decision(
                for: request, task: task, among: tasks, session: session, onScreen: onScreen,
                lastTypedAt: session.flatMap { lastInjectionAt[$0.id] }) {
            case .wait:
                continue
            case .close(let sessionId):
                NSLog("[linkC relay] closing worker %@ on request for task %@", sessionId, task.shortId)
                stopSession(sessionId)
                outcome = .closed(at: now())
            case .alreadyClosed:
                outcome = .closed(at: now())
            case .refuse(let reason):
                NSLog("[linkC relay] not closing the worker for task %@: %@", task.shortId, reason)
                outcome = .refused(reason)
            }
            do {
                try inboxStore.resolveCloseRequest(taskId: task.id, outcome: outcome, timeout: Self.relayLockTimeout)
            } catch {
                if isRelayLockTimeout(error) { return true }
                NSLog("[linkC relay] answerCloseRequests: task %@ — %@", task.shortId, String(describing: error))
            }
        }
        return false
    }
}

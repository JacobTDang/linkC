import Foundation

/// Task Protocol v2 relay: delivers tasks to exactly one assignee, relays short kind-tagged
/// messages, and expires what can no longer be delivered. Never reads terminal output.
extension AppCoordinator {
    /// Queued tasks older than this are expired rather than delivered.
    static let queuedTaskExpiry: TimeInterval = 60 * 60
    /// Verification runs in flight across all workspaces; each is a full build and test run.
    static let maxConcurrentVerifications = 2
    /// Lock-wait budget for every store call the relay tick itself makes. The default `InboxStore`
    /// timeout (5s) is sized for a person waiting on one CLI command, not for a `@MainActor` tick
    /// that runs every second or few across every workspace: eight to ten `linkc-mcp` processes
    /// write the same `inbox.json`, so a single slow writer would otherwise stall the whole UI for
    /// up to 5s, several times per tick. A contended lock is not a failure here — the tick simply
    /// skips and the next one, a second later (a contended pass keeps the cadence at one second,
    /// see `RelayWork`), retries — so this budget only needs to be short, not zero.
    /// Matches the blackboard heartbeat's own 0.5s timeout a few lines below in `sampleAgentStates`.
    static let relayLockTimeout: TimeInterval = 0.5
    /// Minimum time a session must have been paste-ready (see `TerminalSession.pasteReadySince`)
    /// before `dispatchTasks` will deliver to it. Measured against the real Claude CLI:
    /// bracketed-paste negotiation flips true roughly 250-300ms after start, but the CLI cannot
    /// actually consume input until roughly 1.5-2s after start — a brief delivered right at
    /// negotiation lands in a composer that isn't listening yet and is lost. 2 seconds covers
    /// the measured gap with margin. Production always uses this value; tests override the
    /// per-instance `deliverySettle` to 0 instead of sleeping. Public: it is the default for the
    /// public designated initializer's `deliverySettle` parameter, and the live test waits on it
    /// directly. Named separately from the instance property `deliverySettle` — a static and an
    /// instance member of the same name resolve unambiguously in Swift, but relying on that
    /// shadowing here would make the constant harder to spot; `defaultDeliverySettle` is the
    /// value, `deliverySettle` is whatever's actually in effect.
    public static let defaultDeliverySettle: TimeInterval = 2
    /// How long `dispatchTasks` will wait for an idle candidate session to negotiate bracketed
    /// paste before giving up on it. A CLI that never enables bracketed paste (an unsupported
    /// agent binary, a broken TERM) used to sit silently logging "waiting" every tick until the
    /// generic 60-minute `queuedTaskExpiry` finally caught it, with no reason more specific than
    /// "undelivered for 60m". Two minutes is generous next to the real negotiation window
    /// (`defaultDeliverySettle`'s doc: true readiness lands within ~2s) — anything still waiting
    /// this long genuinely never will.
    static let pasteNegotiationTimeout: TimeInterval = 2 * 60

    /// One relay tick for `workspacePath`: expire, start verification, then deliver only if no
    /// run holds this checkout. A verification owns HEAD and the tree while it runs.
    ///
    /// Each phase gives up on the inbox lock after `Self.relayLockTimeout` rather than the store's
    /// default 5s. A timeout there is not a failure — the row it would have touched just waits for
    /// the next tick — but once one phase hits a contended lock, the others almost certainly would
    /// too (it's the same file), so the tick stops rather than paying the wait four times over.
    public func processPendingMessages(workspacePath: String) {
        let norm = ProjectPath.canonical(workspacePath)
        let inboxStore = InboxStore(workspaceRoot: norm)
        relayWork.beginPass(in: norm)
        pollPasteReadiness(workspacePath: norm)
        guard !reportTaskEvents(workspacePath: norm, inboxStore: inboxStore) else {
            return logRelayLockContention(workspacePath: norm)
        }
        guard !settleResolvableTasks(workspacePath: norm, inboxStore: inboxStore) else {
            return logRelayLockContention(workspacePath: norm)
        }
        // Ahead of expiry, so a task that could be settled this very tick (a worker's own report,
        // a gate with nothing to gate) is settled with its real reason rather than expired with a
        // generic "lease lapsed" one, just because its lease or budget happened to run out first.
        guard !expireTasks(workspacePath: norm, inboxStore: inboxStore) else {
            return logRelayLockContention(workspacePath: norm)
        }
        // After expiry, so a task that is already dead is failed rather than reported stuck.
        guard !watchStuckTasks(workspacePath: norm, inboxStore: inboxStore) else {
            return logRelayLockContention(workspacePath: norm)
        }
        guard !reapIdleWorkers(workspacePath: norm, inboxStore: inboxStore) else {
            return logRelayLockContention(workspacePath: norm)
        }
        guard !launchVerifications(workspacePath: norm, inboxStore: inboxStore) else {
            return logRelayLockContention(workspacePath: norm)
        }
        guard !dispatchTasks(workspacePath: norm, inboxStore: inboxStore) else {
            return logRelayLockContention(workspacePath: norm)
        }
        guard !sendPendingDelegatorNotices(workspacePath: norm, inboxStore: inboxStore) else {
            return logRelayLockContention(workspacePath: norm)
        }
        // After the delegator notices above are queued, so one about a task from another project leaves
        // for home in the same pass.
        guard !forwardNoticesHome(workspacePath: norm, inboxStore: inboxStore) else {
            return logRelayLockContention(workspacePath: norm)
        }
        if dispatchMessages(workspacePath: norm, inboxStore: inboxStore) {
            logRelayLockContention(workspacePath: norm)
        }
    }

    /// Forwards notices about tasks that came from another project back to that project's inbox
    /// (spec 2026-11-11 cross-project §5.5). Returns true when the lock was contended.
    @discardableResult
    func forwardNoticesHome(workspacePath: String, inboxStore: InboxStore) -> Bool {
        guard workspaceExists(workspacePath) else { return false }
        let norm = ProjectPath.canonical(workspacePath)
        let pending: [PendingMessage]
        do {
            pending = try inboxStore.fetchPending(timeout: Self.relayLockTimeout)
        } catch {
            if isRelayLockTimeout(error) { return true }
            NSLog("[linkC relay] forwardNoticesHome: fetch — %@", String(describing: error))
            return false
        }
        for message in pending where Self.ownsForwardHome(message) {
            guard let taskId = message.taskId else { continue }
            let record: TaskRecord?
            do {
                record = try inboxStore.task(id: taskId, timeout: Self.relayLockTimeout)
            } catch {
                if isRelayLockTimeout(error) { return true }
                NSLog("[linkC relay] forwardNoticesHome: message %@ task lookup — %@", message.id, String(describing: error))
                continue
            }
            guard let task = record,
                  let fromProject = task.fromProject,
                  ProjectPath.canonical(fromProject) != norm else { continue }

            guard workspaceExists(fromProject) else {
                if failForwardedMessage(message, inboxStore: inboxStore) { return true }
                NSLog("[linkC relay] forwardNoticesHome: home project gone — %@", fromProject)
                continue
            }

            do {
                _ = try InboxStore(workspaceRoot: fromProject).receiveForwarded(message, timeout: Self.relayLockTimeout)
            } catch {
                if isRelayLockTimeout(error) { return true }
                // The home inbox cannot take it (a corrupt file, say), and the next tick would meet the
                // same error. Failing the local copy ends the retries; the log is the one report.
                if failForwardedMessage(message, inboxStore: inboxStore) { return true }
                NSLog("[linkC relay] forwardNoticesHome: message %@ could not be forwarded to %@, marked failed — %@",
                      message.id, fromProject, String(describing: error))
                continue
            }
            do {
                try inboxStore.markMessageDelivered(id: message.id, timeout: Self.relayLockTimeout)
            } catch {
                if isRelayLockTimeout(error) { return true }
                NSLog("[linkC relay] forwardNoticesHome: mark delivered — %@", String(describing: error))
            }
        }
        return false
    }

    /// Marks a notice that cannot go home as failed, so it leaves the queue. True when the lock was
    /// contended; any other error is logged, and the notice is tried again next tick.
    private func failForwardedMessage(_ message: PendingMessage, inboxStore: InboxStore) -> Bool {
        do {
            try inboxStore.markMessageFailed(id: message.id, timeout: Self.relayLockTimeout)
        } catch {
            if isRelayLockTimeout(error) { return true }
            NSLog("[linkC relay] forwardNoticesHome: message %@ mark failed — %@", message.id, String(describing: error))
        }
        return false
    }

    /// A queued notice this phase forwards home: has a taskId, no toSessionId, and belongs to a
    /// cross-project task (checked by the caller against the local task row).
    static func ownsForwardHome(_ message: PendingMessage) -> Bool {
        message.taskId != nil && message.toSessionId == nil
    }

    /// True when `error` is the store's own lock-acquisition timeout rather than a real failure
    /// (a corrupt `inbox.json`, a missing row, an illegal transition, ...). `InboxStore` throws
    /// the typed `LinkCError.lockTimeout` case for this alone, so this checks the case, never the
    /// message text.
    func isRelayLockTimeout(_ error: Error) -> Bool {
        guard let linkCError = error as? LinkCError, case .lockTimeout = linkCError else { return false }
        return true
    }

    /// Touches `acceptsPaste` once per tick for every live session in this workspace, whether or
    /// not a task or message is currently pending for it. `TerminalSession.pasteReadySince` is
    /// set lazily on the first *read* of `acceptsPaste` (see its doc) — `dispatchTasks` used to be
    /// the only caller, gated behind a queued task existing, so a session that finished
    /// negotiating long before any work ever arrived paid the full settle margin all over again
    /// the moment work finally showed up, because the clock only started at that later read. No
    /// store I/O here — reads terminal state already held in memory.
    private func pollPasteReadiness(workspacePath: String) {
        for session in store.sessions where session.cwd == workspacePath && session.state != .ended {
            _ = terminals.session(id: session.id)?.acceptsPaste
        }
    }

    /// Posts the task changes in `workspacePath` since the last pass, for Discord only (spec §2.1). A relay
    /// phase: returns `true` when the inbox lock was still contended after `relayLockTimeout`, so the tick
    /// stops there. A read that fails keeps the last snapshot, so the next pass compares again: nothing is
    /// lost or repeated.
    @discardableResult
    func reportTaskEvents(workspacePath norm: String, inboxStore: InboxStore) -> Bool {
        // Like every relay phase: a store read would recreate a deleted workspace on disk.
        guard workspaceExists(norm) else { return false }
        let tasks: [TaskRecord]
        do {
            tasks = try inboxStore.load(timeout: Self.relayLockTimeout).tasks
        } catch {
            if isRelayLockTimeout(error) { return true }
            NSLog("[linkC relay] reportTaskEvents: tasks — %@", String(describing: error))
            return false
        }
        for event in taskEvents.events(in: norm, tasks: tasks, at: now()) {
            notifications.postEvent(event)
        }
        return false
    }

    /// Logs once that this tick ended early because the inbox lock was still held by another
    /// writer after `Self.relayLockTimeout`. Never called more than once per `processPendingMessages`
    /// call — a permanently contended workspace must be visible, not merely idle every tick.
    private func logRelayLockContention(workspacePath: String) {
        relayWork.noteContention(in: workspacePath)
        NSLog("[linkC relay] processPendingMessages: %@ — inbox lock still contended after %.1fs; retrying next tick",
              workspacePath, Self.relayLockTimeout)
    }

    func isIdle(_ state: SessionState) -> Bool {
        switch state {
        case .ready, .finished, .waitingIdle: return true
        case .working, .starting, .waitingPermission, .error, .ended: return false
        }
    }

    /// The text injected into the assignee's terminal. Composed at injection time; never stored as a message.
    static func deliveryFrame(for task: TaskRecord) -> String {
        let origin: String
        if let fromProject = task.fromProject {
            let name = URL(fileURLWithPath: fromProject).lastPathComponent
            origin = "[linkC task \(task.shortId) from \(name) · \(task.fromAgent.displayName)]"
        } else {
            origin = "[linkC task \(task.shortId) from \(task.fromAgent.displayName)]"
        }
        var lines = [origin, task.prompt, ""]
        if task.isQuestion {
            let name = task.fromProject.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "another project"
            lines.append("This is a question from \(name). Answer it with linkc_complete_task(\"\(task.id)\", status: \"done\", summary: <your answer, at most 1,000 characters>). Do not change any files.")
            lines.append("")
            lines.append("When you begin, call linkc_start_task(\"\(task.id)\").")
            return lines.joined(separator: "\n")
        }
        if let v = task.verification {
            lines.append("Work on branch \(v.branch). linkC verifies by running `\(v.command)` at the sha you report. Do not modify: \(v.testPaths.joined(separator: ", ")).")
            lines.append("")
        }
        // A worker with no verification (no branch, nothing linkC will run) is very often not
        // working in a git checkout at all — asking it for a sha it may have no way to give is
        // demanding proof of something that was never required.
        let completionArgs = task.verification != nil ? "status, summary, sha" : "status, summary"
        lines.append("When you begin, call linkc_start_task(\"\(task.id)\"). When finished, commit your work and call linkc_complete_task(\"\(task.id)\", \(completionArgs)). Do not paste this brief into any reply.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Expiry

    /// True when `path` is an existing directory. Every relay step checks this first: the inbox
    /// lives inside the workspace, so a missing workspace has nothing to deliver and must never
    /// be recreated by a store write.
    func workspaceExists(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Returns `true` when the phase ended early because the inbox lock was still contended after
    /// `Self.relayLockTimeout` — the caller stops the tick there rather than logging per call.
    @discardableResult
    func expireTasks(workspacePath: String, inboxStore: InboxStore) -> Bool {
        guard workspaceExists(workspacePath) else { return false }
        let norm = ProjectPath.canonical(workspacePath)
        let open: [TaskRecord]
        do {
            open = try inboxStore.openTasks(timeout: Self.relayLockTimeout)
        } catch {
            if isRelayLockTimeout(error) { return true }
            NSLog("[linkC relay] expireTasks: open tasks — %@", String(describing: error))
            return false
        }
        guard !open.isEmpty else { return false }
        let now = Date()

        for task in open {
            // A run in flight is not a stale task. Its own timeout bounds it.
            let inFlightId = verificationsInFlight[norm] ?? verificationsInFlight[workspacePath]
            if inFlightId == task.id { continue }
            switch task.state {
            case .gating:
                if now.timeIntervalSince(task.createdAt) > Self.queuedTaskExpiry {
                    do {
                        try inboxStore.expireTaskAndNotify(
                            taskId: task.id, reason: "gate did not run within 60m",
                            notifyBody: "expired — gate did not run within 60m", timeout: Self.relayLockTimeout
                        )
                        logTaskEnded(task, as: "expired", reason: "gate did not run within 60m")
                    } catch {
                        if isRelayLockTimeout(error) { return true }
                        NSLog("[linkC relay] expireTasks: task %@ stale gate — %@", task.shortId, String(describing: error))
                    }
                }
            case .queued:
                // `queuedAt` is when the task actually entered `.queued` — creation for one with
                // no gate, or the moment its gate passed for one that started `.gating`. Falls
                // back to `createdAt` only for a row written before this field existed.
                if now.timeIntervalSince(task.queuedAt ?? task.createdAt) > Self.queuedTaskExpiry {
                    // dispatchTasks never even looks at a workspace's queue while a verification
                    // owns that checkout — for a different task, since this one's own run would
                    // have hit the `continue` above. "undelivered for 60m" would be untrue for a
                    // task that sat behind a held checkout rather than one nobody could deliver.
                    let reason = (verificationsInFlight[norm] != nil || verificationsInFlight[workspacePath] != nil)
                        ? "undelivered for 60m — held back by a verification in this workspace"
                        : "undelivered for 60m"
                    do {
                        try inboxStore.expireTask(taskId: task.id, reason: reason, timeout: Self.relayLockTimeout)
                        logTaskEnded(task, as: "expired", reason: reason)
                    } catch {
                        if isRelayLockTimeout(error) { return true }
                        NSLog("[linkC relay] expireTasks: task %@ stale queued — %@", task.shortId, String(describing: error))
                    }
                }
            case .delivered, .started:
                let assignee = task.assigneeSessionId.flatMap { store.session(id: $0) }
                let assigneeAlive = assignee.map { $0.state != .ended } ?? false
                if !assigneeAlive {
                    let reason = "assignee session ended before reporting"
                    do {
                        try inboxStore.failTaskAndNotify(
                            taskId: task.id, reason: reason, notifyBody: "failed — \(reason)", timeout: Self.relayLockTimeout
                        )
                        // A session leaves the list when its process exits or it is closed, and neither
                        // says why; this line is what names the session the task lost.
                        logTaskEnded(task, as: "failed", reason: "\(reason) (session \(task.assigneeSessionId ?? "none") "
                            + (assignee == nil ? "is no longer in the session list)" : "is marked ended)"))
                    } catch {
                        if isRelayLockTimeout(error) { return true }
                        NSLog("[linkC relay] expireTasks: task %@ dead assignee — %@", task.shortId, String(describing: error))
                    }
                } else if task.leaseExpiresAt < now {
                    do {
                        try inboxStore.expireTaskAndNotify(
                            taskId: task.id, reason: "lease expired",
                            notifyBody: "expired — lease lapsed without a report", timeout: Self.relayLockTimeout
                        )
                        logTaskEnded(task, as: "expired", reason: "lease expired")
                    } catch {
                        if isRelayLockTimeout(error) { return true }
                        NSLog("[linkC relay] expireTasks: task %@ expired lease — %@", task.shortId, String(describing: error))
                    }
                }
            case .reported:
                // A worker may exit after reporting, so only the lease applies here.
                if task.leaseExpiresAt < now {
                    do {
                        try inboxStore.expireTaskAndNotify(
                            taskId: task.id, reason: "lease expired before verification",
                            notifyBody: "expired — lease lapsed before verification", timeout: Self.relayLockTimeout
                        )
                        logTaskEnded(task, as: "expired", reason: "lease expired before verification")
                    } catch {
                        if isRelayLockTimeout(error) { return true }
                        NSLog("[linkC relay] expireTasks: task %@ reported lease — %@", task.shortId, String(describing: error))
                    }
                }
            case .done, .failed, .cancelled, .expired:
                break
            }
        }
        return false
    }

    /// One line in the log for a task linkC ended on its own, with the reason the task now carries,
    /// so what happened to it can be told from the log as well as from the inbox.
    private func logTaskEnded(_ task: TaskRecord, as outcome: String, reason: String) {
        NSLog("[linkC relay] task %@ %@ — %@", task.shortId, outcome, reason)
    }

    func echo(_ body: String, for task: TaskRecord, inboxStore: InboxStore, timeout: TimeInterval = 5.0) throws {
        _ = try inboxStore.enqueue(
            from: task.toAgent,
            to: task.fromAgent,
            kind: .completion,
            taskId: task.id,
            body: body,
            timeout: timeout
        )
    }

    func injectionGapElapsed(sessionId: String) -> Bool {
        guard let last = lastInjectionAt[sessionId] else { return true }
        return now().timeIntervalSince(last) >= injectionGap
    }

    // MARK: - Tasks

    /// Returns `true` when the phase ended early because the inbox lock was still contended after
    /// `Self.relayLockTimeout` — the caller stops the tick there rather than logging per call.
    @discardableResult
    func dispatchTasks(workspacePath: String, inboxStore: InboxStore) -> Bool {
        guard workspaceExists(workspacePath) else { return false }
        let norm = ProjectPath.canonical(workspacePath)
        // A verification owns this checkout until it finishes: injecting a brief now would let a
        // worker edit the tree the verdict is about to be measured against.
        guard verificationsInFlight[norm] == nil && verificationsInFlight[workspacePath] == nil else { return false }
        let open: [TaskRecord]
        do {
            open = try inboxStore.openTasks(timeout: Self.relayLockTimeout)
        } catch {
            if isRelayLockTimeout(error) { return true }
            NSLog("[linkC relay] dispatchTasks: open tasks — %@", String(describing: error))
            return false
        }
        let queued = open.filter { $0.state == .queued }
        forgetOpenCodeRefusals(in: norm, of: .task, keeping: Set(queued.map(\.id)))
        // A task is told about only while it is held: forget the ones that are gone from the queue.
        let queuedIds = Set(queued.map(\.id))
        limitHoldNoticesSent[norm] = limitHoldNoticesSent[norm]?.filter { queuedIds.contains($0.key) }
        guard !queued.isEmpty else { return false }

        // Each queued task claims its own session, or starts one (`WorkerClaims`). A session counts as
        // ready only once it can take a paste: the brief is always multi-line, so it must arrive as one
        // bracketed paste, never as raw text a line-oriented TUI would submit line by line. Negotiation
        // alone is not enough: a real CLI's flag flips well before it can actually consume input (see
        // `Self.defaultDeliverySettle`), so the session must also have been ready for the settle margin.
        // An idle session not ready yet is still claimed, so it is waited for rather than started past.
        let folderSessions = store.sessions.filter { $0.cwd == norm && $0.state != .ended }
        let holdingUnreported = Set(open.filter { $0.state == .delivered || $0.state == .started }.compactMap(\.assigneeSessionId))
        let ready = Set(folderSessions.filter {
            isIdle($0.state) && injectionGapElapsed(sessionId: $0.id) && pasteSettled(sessionId: $0.id)
        }.map(\.id))
        let claims = WorkerClaims.plan(queued: queued, sessions: folderSessions, holdingUnreported: holdingUnreported,
                                       ready: ready, now: now())

        var loggedInjectionWait = false
        var launched: Set<String> = []
        var heldThisPass: Set<String> = []
        for task in queued {
            // A pool limit holds back only tasks that would run on that pool. The delegator is told
            // the first time a task is held, with what is limited and what is not.
            let taskModel = modelForLimit(of: task)
            do {
                if let limit = try inboxStore.isAgentLimited(agent: task.toAgent, model: taskModel, timeout: Self.relayLockTimeout) {
                    NSLog("[linkC relay] dispatchTasks: task %@ waits — %@%@ is limited until %@ (%@)",
                          task.shortId, task.toAgent.displayName,
                          limit.pool.map { " \($0) pool" } ?? "",
                          limit.cooldownExpiresAt.description, limit.reason)
                    switch holdForLimit(task, limit: limit, model: taskModel, in: norm, inboxStore: inboxStore) {
                    case .held: heldThisPass.insert(task.id)
                    case .failed: break
                    case .contended: return true
                    }
                    continue
                }
            } catch {
                if isRelayLockTimeout(error) { return true }
                NSLog("[linkC relay] dispatchTasks: task %@ limit check — %@", task.shortId, String(describing: error))
            }
            guard let claim = claims[task.id] else {
                NSLog("[linkC relay] dispatchTasks: task %@ has no claim this pass — waiting", task.shortId)
                continue
            }
            let assignee: String
            switch claim {
            case .deliver(let id):
                assignee = id
            case .awaitStart(let id):
                NSLog("[linkC relay] dispatchTasks: task %@ waits for %@ session %@ to start", task.shortId, task.toAgent.displayName, id)
                continue
            case .awaitBusy(let id):
                NSLog("[linkC relay] dispatchTasks: task %@ waits for %@ worker %@, which holds no task and is %@",
                      task.shortId, task.toAgent.displayName, id, store.session(id: id)?.state.rawValue ?? "gone")
                continue
            case .awaitLimited(let id):
                NSLog("[linkC relay] dispatchTasks: task %@ waits — %@ session %@ is rate-limited",
                      task.shortId, task.toAgent.displayName, id)
                // The session's own model decides which limit row holds it, whatever the task's tier maps to now.
                let sessionModel = store.session(id: id)?.model
                var sessionLimit: AgentLimitStatus?
                do {
                    sessionLimit = try inboxStore.isAgentLimited(
                        agent: task.toAgent, model: sessionModel, timeout: Self.relayLockTimeout)
                } catch {
                    if isRelayLockTimeout(error) { return true }
                    NSLog("[linkC relay] dispatchTasks: task %@ session limit check — %@", task.shortId, String(describing: error))
                }
                switch holdForLimit(task, limit: sessionLimit, model: sessionModel, sessionId: id, in: norm, inboxStore: inboxStore) {
                case .held: heldThisPass.insert(task.id)
                case .failed: break
                case .contended: return true
                }
                continue
            case .awaitReady(let id):
                if !injectionGapElapsed(sessionId: id) {
                    if !loggedInjectionWait {
                        NSLog("[linkC relay] dispatchTasks: waiting for the injection gap")
                        loggedInjectionWait = true
                    }
                    continue
                }
                // An idle session that has sat this long without ever negotiating bracketed paste
                // never will — a CLI that doesn't support it, or a broken TERM. Waiting out the
                // generic 60-minute queued expiry would bury the real reason behind "undelivered
                // for 60m"; fail this task now, with the reason that actually explains it, and
                // stop retrying it every tick. The wait is counted from when the session went idle,
                // so time the task spent queued behind workers still starting is not held against it.
                let idleSince = store.session(id: id)?.stateChangedAt ?? task.createdAt
                if now().timeIntervalSince(max(task.createdAt, idleSince)) > Self.pasteNegotiationTimeout {
                    let reason = "\(task.toAgent.displayName) never accepted pasted input"
                    do {
                        try inboxStore.expireTaskAndNotify(
                            taskId: task.id, reason: reason, notifyBody: "expired — \(reason)", timeout: Self.relayLockTimeout
                        )
                        logTaskEnded(task, as: "expired", reason: reason)
                    } catch {
                        if isRelayLockTimeout(error) { return true }
                        NSLog("[linkC relay] dispatchTasks: task %@ paste-negotiation timeout — %@", task.shortId, String(describing: error))
                    }
                    continue
                }
                NSLog("[linkC relay] dispatchTasks: task %@ has an idle session that has not settled after negotiating bracketed paste yet — waiting", task.shortId)
                continue
            case .awaitPinned:
                // A pinned task goes to its own session or nowhere: never to another, and no session is
                // launched for it. With its session gone before delivery there is nothing to deliver to.
                let target = task.targetSessionId ?? "none"
                if store.session(id: target).map({ $0.state == .ended }) ?? true {
                    let reason = "its session ended before the task was delivered"
                    do {
                        try inboxStore.expireTaskAndNotify(
                            taskId: task.id, reason: reason, notifyBody: "expired — \(reason)", timeout: Self.relayLockTimeout
                        )
                        logTaskEnded(task, as: "expired", reason: reason)
                    } catch {
                        if isRelayLockTimeout(error) { return true }
                        NSLog("[linkC relay] dispatchTasks: task %@ pinned session gone — %@", task.shortId, String(describing: error))
                    }
                } else {
                    NSLog("[linkC relay] dispatchTasks: task %@ is pinned to session %@, which cannot take it now — waiting",
                          task.shortId, target)
                }
                continue
            case .spawn:
                if spawnWorker(for: task, workspacePath: workspacePath, inboxStore: inboxStore, launched: &launched) { return true }
                continue
            }

            do {
                try inboxStore.markTaskDelivered(taskId: task.id, sessionId: assignee, timeout: Self.relayLockTimeout)
            } catch {
                if isRelayLockTimeout(error) { return true }
                NSLog("[linkC relay] dispatchTasks: task %@ mark delivered — %@", task.shortId, String(describing: error))
                continue
            }
            let frame = Self.deliveryFrame(for: task)
            // The mark above is a real disk write — under lock contention it can take up to
            // `Self.relayLockTimeout` — so the terminal confirmed live and settled just above can
            // still have gone stale (child exited, session torn down) by the time the text
            // actually goes in. `sendInput` reports that rather than failing silently: a task
            // left `.delivered` with nothing ever typed would sit invisibly stuck, since nothing
            // else moves it until its 4h lease lapses. Fail it loud and immediately instead —
            // `.delivered → .failed` is always a legal transition, so the delegator is told now,
            // with the real reason, rather than after a very long silence.
            if terminals.sendInput(sessionId: assignee, text: frame) {
                recordInjection(sessionId: assignee, text: frame, startsWork: true)
                store.updateState(id: assignee, to: .working)
            } else {
                let reason = "delivery marked done but the text never reached \(task.toAgent.displayName)'s terminal"
                NSLog("[linkC relay] dispatchTasks: task %@ — %@", task.shortId, reason)
                do {
                    try inboxStore.failTaskAndNotify(
                        taskId: task.id, reason: reason, notifyBody: "failed — \(reason)", timeout: Self.relayLockTimeout
                    )
                } catch {
                    if isRelayLockTimeout(error) { return true }
                    NSLog("[linkC relay] dispatchTasks: task %@ fail-after-lost-delivery — %@", task.shortId, String(describing: error))
                }
            }
        }
        // A task is told about again only if a later hold meets it: forget the ones no longer held.
        limitHoldNoticesSent[norm] = limitHoldNoticesSent[norm]?.filter { heldThisPass.contains($0.key) }
        return false
    }

    /// Whether `sessionId`'s terminal has negotiated bracketed paste and stayed ready for the settle margin.
    private func pasteSettled(sessionId: String) -> Bool {
        guard let terminal = terminals.session(id: sessionId), terminal.acceptsPaste,
              let readySince = terminal.pasteReadySince else { return false }
        return now().timeIntervalSince(readySince) >= deliverySettle
    }

    /// Starts a worker for `task`, which found no free session. It is delivered on a later pass: a CLI
    /// needs seconds to reach its prompt, and a frame typed into a booting TUI is lost. The session stays
    /// `.starting` until its agent is really running: Claude's SessionStart hook, or `sampleAgentStates`
    /// for every other kind. At most one worker is launched per agent and tier in a pass (`launched`), so
    /// a CLI that exits at launch is retried once a pass, not once per queued task; each task still runs
    /// the checks before it, so a refusal is reported for every task. Returns `true` when the inbox lock
    /// timed out.
    private func spawnWorker(for task: TaskRecord, workspacePath: String, inboxStore: InboxStore, launched: inout Set<String>) -> Bool {
        // A tiered task whose tier no longer resolves to a model (settings edited while the task sat
        // queued) must not spawn an unpinned session: that session could never carry the task, so the
        // next pass would spawn another one, forever. Nor can it wait: nothing the queue does gives the
        // tier a model, so it fails now and its delegator is told what to set. A model is never invented.
        if let tier = task.tier, resolvedModel(for: task.toAgent, tier: tier) == nil {
            let reason = "\(task.toAgent.displayName)'s \(tier.label) tier has no model. Set one in Settings > Models."
            do {
                try inboxStore.failTaskAndNotify(
                    taskId: task.id, reason: reason, notifyBody: "failed — \(reason)", timeout: Self.relayLockTimeout)
                logTaskEnded(task, as: "failed", reason: reason)
            } catch {
                if isRelayLockTimeout(error) { return true }
                NSLog("[linkC relay] dispatchTasks: task %@ unconfigured tier — %@", task.shortId, String(describing: error))
            }
            return false
        }
        if task.toAgent == .opencode {
            let availability: OpenCodeModelAvailability
            if let model = task.model {
                availability = openCodeModelAvailability(
                    in: workspacePath, model: model, subject: model, remedy: "pick another free model")
            } else {
                availability = openCodeModelAvailability(in: workspacePath, tier: task.tier ?? defaultTier(for: .opencode))
            }
            switch availability {
            case .checking:
                return false
            case .available:
                break
            case .refused(let reason):
                // Waiting will not make OpenCode list the model: end the task with the reason, rather
                // than leave it queued for an hour behind a generic "undelivered". A task that names
                // its model fails: it was asked for something that cannot run.
                do {
                    if task.model != nil {
                        try inboxStore.failTaskAndNotify(
                            taskId: task.id, reason: reason, notifyBody: "failed — \(reason)", timeout: Self.relayLockTimeout)
                        logTaskEnded(task, as: "failed", reason: reason)
                    } else {
                        try inboxStore.expireTaskAndNotify(
                            taskId: task.id, reason: reason, notifyBody: "expired — \(reason)", timeout: Self.relayLockTimeout)
                        logTaskEnded(task, as: "expired", reason: reason)
                    }
                    lastSpawnFailure = SpawnFailure(agent: .opencode, workspacePath: workspacePath, error: reason)
                    notifications.post(title: Self.openCodeRefusalTitle, body: reason, project: workspacePath)
                } catch {
                    if isRelayLockTimeout(error) { return true }
                    NSLog("[linkC relay] dispatchTasks: task %@ OpenCode refusal — %@", task.shortId, String(describing: error))
                }
                return false
            case .uncheckable(let reason):
                // The listing failed, so nothing is known about the model: the task waits (and expires
                // on its own like any queued task), and its delegator is told once.
                reportOpenCodeSpawnRefusal(reason, from: task.fromAgent, taskId: task.id,
                                           key: OpenCodeRefusalKey(workspace: ProjectPath.canonical(workspacePath), kind: .task, id: task.id),
                                           workspacePath: workspacePath, inboxStore: inboxStore)
                return false
            }
        }
        let launchKey = "\(task.toAgent.rawValue)|\(task.tier?.rawValue ?? "")|\(task.model ?? "")"
        guard launched.insert(launchKey).inserted else {
            NSLog("[linkC relay] dispatchTasks: task %@ waits for the next pass to start its %@ worker",
                  task.shortId, task.toAgent.displayName)
            return false
        }
        do {
            _ = try spawnTeammate(in: workspacePath, agent: task.toAgent, goal: task.prompt,
                                  tier: task.tier, model: task.model, asWorker: true)
        } catch {
            // Swallowing this used to leave the task `.queued` forever, retried every second, with
            // nothing anywhere saying why.
            lastSpawnFailure = SpawnFailure(agent: task.toAgent, workspacePath: workspacePath, error: String(describing: error))
            NSLog("[linkC relay] dispatchTasks: task %@ could not spawn %@ — %@",
                  task.shortId, task.toAgent.displayName, String(describing: error))
            // A task that names its model fails with the launch's own error: starting the same
            // worker on every pass would only repeat it until the queue expires the task.
            if let model = task.model {
                let reason = "\(task.toAgent.displayName) could not start with model \(model): \(error)"
                do {
                    try inboxStore.failTaskAndNotify(
                        taskId: task.id, reason: reason, notifyBody: "failed — \(reason)", timeout: Self.relayLockTimeout)
                    logTaskEnded(task, as: "failed", reason: reason)
                } catch {
                    if isRelayLockTimeout(error) { return true }
                    NSLog("[linkC relay] dispatchTasks: task %@ launch failure — %@", task.shortId, String(describing: error))
                }
            }
        }
        return false
    }

    /// What `holdForLimit` did with a task.
    private enum HoldOutcome {
        /// The task waits for the limit to end.
        case held
        /// The limit outlasts the queue, so the task was failed and its delegator told.
        case failed
        /// The inbox lock was still contended after `relayLockTimeout`: the pass stops.
        case contended
    }

    /// Holds `task` back for a limit, and tells its delegator why it waits: the limit holding it, when
    /// it ends, and what is not limited. A limit that ends after the task would expire in the queue is
    /// no hold: the queue would end the task without a word, so it fails at once and its delegator is
    /// told when to delegate it again. `limit` is nil when no limit row holds it but its own session is
    /// rate-limited (`sessionId`), which has no end to name. A task is told again when the end it was
    /// told moves later. The mark is kept only after the notice reaches the inbox, so one that could
    /// not be written is tried again on the next pass.
    private func holdForLimit(
        _ task: TaskRecord, limit: AgentLimitStatus?, model: String?, sessionId: String? = nil,
        in workspace: String, inboxStore: InboxStore
    ) -> HoldOutcome {
        if let limit, limit.cooldownExpiresAt > (task.queuedAt ?? task.createdAt).addingTimeInterval(Self.queuedTaskExpiry) {
            return failTaskHeldPastExpiry(task, limit: limit, model: model, inboxStore: inboxStore)
        }
        let told = LimitHoldNotice(until: limit?.cooldownExpiresAt)
        let before = limitHoldNoticesSent[workspace]?[task.id]
        guard before != told else { return .held }
        let why: String
        if let limit, sessionId == nil {
            do {
                why = try MCPServer.limitRefusal(
                    agent: task.toAgent, limit: limit, model: model, readLists: modelLists,
                    settings: liveModelSettings(), inboxStore: inboxStore, lockTimeout: Self.relayLockTimeout)
            } catch {
                if isRelayLockTimeout(error) { return .contended }
                NSLog("[linkC relay] task %@ held — could not build its notice: %@", task.shortId, String(describing: error))
                return .held
            }
        } else if let limit {
            why = "\(task.toAgent.displayName) session \(sessionId ?? "") is rate-limited until "
                + "\(MCPServer.limitEndText(limit.cooldownExpiresAt)) (\(limit.reason))."
        } else {
            why = "\(task.toAgent.displayName) session \(sessionId ?? "") is rate-limited and has not recovered yet."
        }
        let body = "Task \(task.shortId) \(before == nil ? "waits" : "still waits"): \(why)"
        if enqueueDelegatorNotice(body, from: task.toAgent, to: task.fromAgent, taskId: task.id, inboxStore: inboxStore) {
            limitHoldNoticesSent[workspace, default: [:]][task.id] = told
        }
        return .held
    }

    /// Fails `task`, which a limit would hold past the time the queue expires it, and tells its delegator.
    private func failTaskHeldPastExpiry(
        _ task: TaskRecord, limit: AgentLimitStatus, model: String?, inboxStore: InboxStore
    ) -> HoldOutcome {
        let described: MCPServer.LimitDescription
        do {
            described = try MCPServer.limitDescription(
                agent: task.toAgent, limit: limit, model: model, readLists: modelLists,
                settings: liveModelSettings(), inboxStore: inboxStore, lockTimeout: Self.relayLockTimeout)
        } catch {
            if isRelayLockTimeout(error) { return .contended }
            NSLog("[linkC relay] task %@ held past its expiry — could not build its reason: %@", task.shortId, String(describing: error))
            return .held
        }
        let elsewhere = described.notLimited.map { "delegate it again then, or to: \($0)" } ?? "delegate it again then"
        let reason = "\(described.limit). That is after this task would expire in the queue; \(elsewhere).\(described.caveat)"
        do {
            try inboxStore.failTaskAndNotify(
                taskId: task.id, reason: reason, notifyBody: "failed — \(reason)", timeout: Self.relayLockTimeout)
            logTaskEnded(task, as: "failed", reason: reason)
            return .failed
        } catch {
            if isRelayLockTimeout(error) { return .contended }
            NSLog("[linkC relay] dispatchTasks: task %@ held past its expiry — %@", task.shortId, String(describing: error))
            return .held
        }
    }

    // MARK: - Messages

    /// Returns `true` when the phase ended early because the inbox lock was still contended after
    /// `Self.relayLockTimeout` — the caller stops the tick there rather than logging per call.
    @discardableResult
    func dispatchMessages(workspacePath: String, inboxStore: InboxStore) -> Bool {
        guard workspaceExists(workspacePath) else { return false }
        let norm = ProjectPath.canonical(workspacePath)
        let pending: [PendingMessage]
        do {
            pending = try inboxStore.fetchPending(timeout: Self.relayLockTimeout)
        } catch {
            if isRelayLockTimeout(error) { return true }
            NSLog("[linkC relay] dispatchMessages: fetch pending — %@", String(describing: error))
            return false
        }
        // A notice stays marked "already told to the user" only while it is still queued here —
        // once it is delivered (below) or expires (a separate phase), evict it so a long-running
        // app does not keep one entry per notice ever seen stuck for its whole lifetime.
        relayWork.noteQueuedMessages(pending.contains { hasLiveTarget($0, in: norm, inboxStore: inboxStore) }, in: norm)
        let stillQueued = Set(pending.map(\.id))
        undeliveredNoticesReported[norm]?.formIntersection(stillQueued)
        if undeliveredNoticesReported[norm]?.isEmpty == true {
            undeliveredNoticesReported.removeValue(forKey: norm)
        }
        forgetOpenCodeRefusals(in: norm, of: .message, keeping: stillQueued)

        guard !pending.isEmpty else { return false }

        // A verification owns this checkout until it finishes: injecting a brief now would let a
        // worker edit the tree the verdict is about to be measured against. Only a brief — the
        // legacy `.task` message row — needs to wait for that; a completion line, a cancel
        // notice, a peer note, or a model switch never touches the tree and must still reach
        // whoever is waiting on it while a run is in flight.
        let verificationInFlight = verificationsInFlight[norm] != nil || verificationsInFlight[workspacePath] != nil

        var groups: [String: (session: Session, messages: [PendingMessage])] = [:]
        var sessionOrder: [String] = []
        var loggedInjectionWait = false
        for message in pending where message.status == .queued {
            // Owned by forwardNoticesHome: a notice about a task from another project. Skip when
            // that phase could not finish, so it is never pasted here. A task that cannot be looked up
            // is skipped too: delivering the notice anyway could paste it into a session of the target
            // project, which did not ask.
            if Self.ownsForwardHome(message), let taskId = message.taskId {
                let record: TaskRecord?
                do {
                    record = try inboxStore.task(id: taskId, timeout: Self.relayLockTimeout)
                } catch {
                    if isRelayLockTimeout(error) { return true }
                    NSLog("[linkC relay] dispatchMessages: message %@ task lookup — %@; skipped this tick", message.id, String(describing: error))
                    continue
                }
                if let fromProject = record?.fromProject,
                   ProjectPath.canonical(fromProject) != norm {
                    continue
                }
            }

            if message.kind == .task, verificationInFlight { continue }

            if message.kind == .notice {
                do {
                    try inboxStore.markMessageDelivered(id: message.id, timeout: Self.relayLockTimeout)
                } catch {
                    if isRelayLockTimeout(error) { return true }
                    NSLog("[linkC relay] dispatchMessages: message %@ mark notice delivered — %@", message.id, String(describing: error))
                }
                continue
            }

            // A message for one worker goes there or nowhere: with that worker gone, it fails and the user is told.
            if let addressee = message.toSessionId,
               store.session(id: addressee).map({ $0.state == .ended || $0.cwd != norm }) ?? true {
                if failMessageForEndedWorker(message, addressee: addressee, workspacePath: norm, inboxStore: inboxStore) { return true }
                continue
            }

            let target: Session?
            do {
                target = try deliveryTarget(for: message, in: norm, inboxStore: inboxStore, caller: "dispatchMessages")
            } catch {
                // A contended lock is not "this task has no delegator": falling through would hand
                // the notice to a different session of the same kind. End the tick — the next one
                // routes it properly.
                return true
            }
            if target == nil {
                // Only a task brief is worth spawning an agent for. Every other message — a
                // completion line, a stuck notice, a peer note, a command — waits for a session to
                // exist instead, and the user is told when it has waited too long.
                guard message.kind == .task else {
                    noteUndeliveredNotice(message, workspacePath: norm, inboxStore: inboxStore)
                    continue
                }
                let goal: String? = message.kind == .task ? message.prompt : nil
                if message.toAgent == .opencode {
                    let tier = defaultTier(for: .opencode)
                    switch openCodeModelAvailability(in: workspacePath, tier: tier) {
                    case .checking:
                        continue
                    case .available:
                        break
                    case .refused(let reason):
                        // Waiting will not make OpenCode list the model: fail the message, and tell its sender.
                        do {
                            try inboxStore.markMessageFailed(id: message.id, timeout: Self.relayLockTimeout)
                        } catch {
                            if isRelayLockTimeout(error) { return true }
                            NSLog("[linkC relay] dispatchMessages: message %@ OpenCode refusal — %@", message.id, String(describing: error))
                            continue
                        }
                        lastSpawnFailure = SpawnFailure(agent: .opencode, workspacePath: workspacePath, error: reason)
                        announceOpenCodeRefusal(reason, notice: reason, from: .opencode, to: message.fromAgent,
                                                taskId: message.taskId, inboxStore: inboxStore)
                        continue
                    case .uncheckable(let reason):
                        reportOpenCodeSpawnRefusal(reason, from: message.fromAgent, taskId: message.taskId,
                                                   key: OpenCodeRefusalKey(workspace: norm, kind: .message, id: message.id),
                                                   workspacePath: workspacePath, inboxStore: inboxStore)
                        continue
                    }
                }
                do {
                    _ = try spawnTeammate(in: workspacePath, agent: message.toAgent, goal: goal, asWorker: true)
                } catch {
                    lastSpawnFailure = SpawnFailure(agent: message.toAgent, workspacePath: workspacePath, error: String(describing: error))
                    NSLog("[linkC relay] dispatchMessages: message %@ could not spawn %@ — %@",
                          message.id, message.toAgent.displayName, String(describing: error))
                }
                continue
            }
            guard let session = target, isIdle(session.state) else {
                noteUndeliveredNotice(message, workspacePath: norm, inboxStore: inboxStore)
                continue
            }

            guard injectionGapElapsed(sessionId: session.id) else {
                if !loggedInjectionWait {
                    NSLog("[linkC relay] dispatchMessages: waiting for the injection gap")
                    loggedInjectionWait = true
                }
                continue
            }
            guard terminals.session(id: session.id)?.isRunning == true else {
                NSLog("[linkC relay] dispatchMessages: session %@ child exited — leaving queued", session.id)
                continue
            }
            if groups[session.id] == nil {
                sessionOrder.append(session.id)
                groups[session.id] = (session, [])
            }
            groups[session.id]?.messages.append(message)
        }

        for sessionId in sessionOrder {
            guard let group = groups[sessionId] else { continue }
            var batch: [PendingMessage] = []
            for message in group.messages {
                let standalone = message.kind == .command || message.kind == .task
                if standalone && !batch.isEmpty { break }
                // Recheck before marking, since a prior group's store work can take time.
                guard terminals.session(id: sessionId)?.isRunning == true else {
                    NSLog("[linkC relay] dispatchMessages: session %@ child exited — leaving queued", sessionId)
                    break
                }
                do {
                    try inboxStore.markMessageDelivered(id: message.id, timeout: Self.relayLockTimeout)
                } catch {
                    if isRelayLockTimeout(error) {
                        // Earlier marks are durable: send that portion before ending the tick.
                        injectMessageBatch(batch, into: group.session)
                        return true
                    }
                    // Stop the batch here rather than skip to the next message: this one stays
                    // queued, and letting later messages in the group send ahead of it would
                    // deliver them out of order. It gets another chance next tick.
                    NSLog("[linkC relay] dispatchMessages: message %@ mark delivered — %@", message.id, String(describing: error))
                    break
                }
                batch.append(message)
                if standalone { break }
            }
            injectMessageBatch(batch, into: group.session)
        }
        return false
    }

    /// Fails `message`, addressed to `addressee`, which has ended or left the workspace, and tells the
    /// user. Returns `true` when the inbox lock timed out.
    private func failMessageForEndedWorker(_ message: PendingMessage, addressee: String, workspacePath: String, inboxStore: InboxStore) -> Bool {
        do {
            try inboxStore.markMessageFailed(id: message.id, timeout: Self.relayLockTimeout)
        } catch {
            if isRelayLockTimeout(error) { return true }
            NSLog("[linkC relay] dispatchMessages: message %@ for ended session %@ — %@", message.id, addressee, String(describing: error))
            return false
        }
        NSLog("[linkC relay] dispatchMessages: message %@ failed — its %@ worker %@ ended before it was delivered",
              message.id, message.toAgent.displayName, addressee)
        notifications.post(
            title: "linkC: a message was not delivered",
            body: "The \(message.toAgent.displayName) worker it was for ended before it could be delivered.",
            project: workspacePath
        )
        return false
    }

    /// One queued task or message OpenCode was asked to start: the key a refusal is reported under.
    struct OpenCodeRefusalKey: Hashable {
        enum Kind { case task, message }
        let workspace: String
        let kind: Kind
        let id: String
    }

    static let openCodeRefusalTitle = "linkC: OpenCode could not start"

    /// Forgets the refusals reported in `workspace` for `kind` of item that are no longer queued, so a
    /// report stays marked only while its item waits.
    private func forgetOpenCodeRefusals(in workspace: String, of kind: OpenCodeRefusalKey.Kind, keeping queued: Set<String>) {
        func stillQueued(_ key: OpenCodeRefusalKey) -> Bool {
            key.workspace != workspace || key.kind != kind || queued.contains(key.id)
        }
        openCodeRefusalUsersTold = openCodeRefusalUsersTold.filter(stillQueued)
        openCodeRefusalNoticesSent = openCodeRefusalNoticesSent.filter(stillQueued)
    }

    /// Reports that OpenCode could not be asked about `key`'s model: the user is told on the first pass,
    /// whether or not the sender's notice can be written, and the notice is tried on every pass until it
    /// lands, so it is never lost. The item stays queued, so every later pass meets it again.
    private func reportOpenCodeSpawnRefusal(
        _ reason: String, from delegator: AgentKind, taskId: String?, key: OpenCodeRefusalKey,
        workspacePath: String, inboxStore: InboxStore
    ) {
        if openCodeRefusalUsersTold.insert(key).inserted {
            // A "last known problem" marker only: whether to report is decided by `key`.
            lastSpawnFailure = SpawnFailure(agent: .opencode, workspacePath: workspacePath, error: reason)
            notifications.post(title: Self.openCodeRefusalTitle, body: reason, project: workspacePath)
        }
        guard !openCodeRefusalNoticesSent.contains(key) else { return }
        if enqueueDelegatorNotice(reason, from: .opencode, to: delegator, taskId: taskId, inboxStore: inboxStore) {
            openCodeRefusalNoticesSent.insert(key)
        }
    }

    /// Sends `notice` to `delegator` and tells the user `reason`, whether or not the notice could be written.
    private func announceOpenCodeRefusal(
        _ reason: String, notice: String, from sender: AgentKind, to delegator: AgentKind, taskId: String?,
        inboxStore: InboxStore
    ) {
        _ = enqueueDelegatorNotice(notice, from: sender, to: delegator, taskId: taskId, inboxStore: inboxStore)
        notifications.post(title: Self.openCodeRefusalTitle, body: reason, project: inboxStore.workspaceRoot)
    }

    /// Whether `notice` reached `delegator`'s inbox; a failure is logged.
    private func enqueueDelegatorNotice(
        _ notice: String, from sender: AgentKind, to delegator: AgentKind, taskId: String?, inboxStore: InboxStore
    ) -> Bool {
        do {
            _ = try inboxStore.enqueue(from: sender, to: delegator, kind: .notice, taskId: taskId, body: notice,
                                       timeout: Self.relayLockTimeout)
            return true
        } catch {
            NSLog("[linkC relay] notice to the delegator — %@", String(describing: error))
            return false
        }
    }

    /// Whether a queued message is something a tick can act on: a brief spawns an agent, and any
    /// other kind (a notice is marked delivered at once) needs a session of its target kind that
    /// can be typed into. A message carrying a `taskId` is delivered to its delegator session,
    /// so it routes delegator-first just as `dispatchMessages` does. One with no live target waits
    /// for one to be launched, and launching wakes the sweep, so it must not hold the fast cadence
    /// in the meantime. A session in `.error` (a usage limit; the cooldown can last hours) is no more
    /// able to take it than a missing one, and the sweep notices it leaving `.error` at any cadence.
    /// Nor is one whose process has exited, which the delivery itself leaves queued.
    private func hasLiveTarget(_ message: PendingMessage, in workspace: String, inboxStore: InboxStore) -> Bool {
        switch message.kind {
        case .task: return true
        case .notice: return false
        default:
            let target: Session?
            do {
                target = try deliveryTarget(for: message, in: workspace, inboxStore: inboxStore, caller: "hasLiveTarget")
            } catch {
                // A contended lock proves nothing about the target; keep the fast cadence to retry.
                return true
            }
            guard let target else { return false }
            return target.state != .error && terminals.session(id: target.id)?.isRunning == true
        }
    }

    /// The session a queued message goes to. A message about a task belongs to the session that
    /// delegated it — any other session of that kind is a different conversation — so that one is
    /// chosen while it lives in this workspace (`fromSessionId` comes from the caller's own
    /// `LINKC_SESSION`, so a delegator in another project must not pull this workspace's notice into
    /// that project's terminal). Otherwise, or once it is gone, the first live session of the target
    /// kind. Delivery and the sweep cadence both route through here so they cannot disagree about
    /// where a message is going. Throws only the relay lock timeout; any other lookup failure is
    /// logged and treated as "no delegator".
    func deliveryTarget(for message: PendingMessage, in workspace: String, inboxStore: InboxStore, caller: String) throws -> Session? {
        if let addressee = message.toSessionId {
            return store.sessions.first { $0.id == addressee && $0.state != .ended && $0.cwd == workspace }
        }
        if let taskId = message.taskId {
            let record: TaskRecord?
            do {
                record = try inboxStore.task(id: taskId, timeout: Self.relayLockTimeout)
            } catch {
                if isRelayLockTimeout(error) { throw error }
                NSLog("[linkC relay] %@: message %@ delegator lookup — %@", caller, message.id, String(describing: error))
                record = nil
            }
            if let delegatorId = record?.fromSessionId,
               let delegator = store.sessions.first(where: { $0.id == delegatorId && $0.state != .ended && $0.cwd == workspace }) {
                return delegator
            }
            if record == nil {
                let pointer: SentTask?
                do {
                    pointer = try inboxStore.sentTask(matching: taskId, timeout: Self.relayLockTimeout)
                } catch {
                    if isRelayLockTimeout(error) { throw error }
                    NSLog("[linkC relay] %@: message %@ sent-task lookup — %@", caller, message.id, String(describing: error))
                    pointer = nil
                }
                if let sessionId = pointer?.fromSessionId,
                   let session = store.sessions.first(where: { $0.id == sessionId && $0.state != .ended && $0.cwd == workspace }) {
                    return session
                }
            }
        }
        return store.sessions.first { $0.cwd == workspace && $0.agentKind == message.toAgent && $0.state != .ended }
    }

    private func injectMessageBatch(_ messages: [PendingMessage], into session: Session) {
        guard !messages.isEmpty else { return }
        let prompts = messages.map(\.prompt)
        terminals.sendInput(sessionId: session.id, text: prompts.joined(separator: "\n"))
        recordInjection(sessionId: session.id, texts: prompts, startsWork: true)
        // Commands and legacy briefs are always singleton batches.
        if let message = messages.first, message.kind == .command, message.prompt.hasPrefix("/model ") {
            let id = String(message.prompt.dropFirst("/model ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            store.updateModel(id: session.id, model: id.isEmpty ? nil : id,
                              modelTier: tier(forModel: id, agent: session.agentKind))
        }
        if messages.first?.kind == .task { store.updateState(id: session.id, to: .working) }
    }

    // MARK: - Verification

    /// Settles gating/reported tasks that need no verification run (a gate with no verification,
    /// a reported failure, a report missing its required sha, or an unverified report), and
    /// collects the rest — the ones that DO need a run — into `runnable`. Shared by
    /// `settleResolvableTasks`, an early pass `processPendingMessages` runs ahead of
    /// `expireTasks`, and `launchVerifications` itself, which reuses it to actually start a run.
    /// Returns `stopped: true` when the inbox lock was still contended after
    /// `Self.relayLockTimeout` — the caller stops the tick there rather than logging per call.
    private func resolveGatingAndReportedTasks(
        workspacePath: String, inboxStore: InboxStore
    ) -> (stopped: Bool, runnable: [(task: TaskRecord, run: VerificationRun)]) {
        guard workspaceExists(workspacePath) else { return (false, []) }
        let open: [TaskRecord]
        do {
            open = try inboxStore.openTasks(timeout: Self.relayLockTimeout)
        } catch {
            if isRelayLockTimeout(error) { return (true, []) }
            NSLog("[linkC relay] launchVerifications: open tasks — %@", String(describing: error))
            return (false, [])
        }
        relayWork.noteOpenTasks(!open.isEmpty, in: workspacePath)

        // Each task's run is decided where the task is classified, below: gating decides gate
        // vs. cancel-with-no-verification, reported decides verify vs. settle. A store error
        // while settling a task here is logged, and the task is left for the next tick.
        var runnable: [(task: TaskRecord, run: VerificationRun)] = []
        for task in open where task.state == .gating || task.state == .reported {
            do {
                if task.state == .gating {
                    if let verification = task.verification {
                        runnable.append((task, .gate(verification)))
                    } else {
                        // Only a hand-edited inbox holds this. Cancel it so it cannot block the workspace.
                        let reason = "gate failed: task has no verification"
                        try inboxStore.resolveGateAndNotify(
                            taskId: task.id, verdict: .notRun(reason: reason),
                            notifyBody: "cancelled — \(reason)", timeout: Self.relayLockTimeout
                        )
                        logTaskEnded(task, as: "cancelled", reason: reason)
                    }
                } else if let verification = task.verification {
                    if task.report?.status != "done" {
                        try settle(task, reason: "worker reported failure", inboxStore: inboxStore, timeout: Self.relayLockTimeout)
                    } else if let sha = task.report?.sha {
                        runnable.append((task, .verify(verification, sha: sha)))
                    } else {
                        try settle(task, reason: "report is missing its sha", inboxStore: inboxStore, timeout: Self.relayLockTimeout)
                    }
                } else {
                    let line = task.report?.status == "done" ? "done (unverified)" : "failed — worker reported failure"
                    try inboxStore.acceptUnverifiedAndNotify(taskId: task.id, notifyBody: line, timeout: Self.relayLockTimeout)
                }
            } catch {
                if isRelayLockTimeout(error) { return (true, runnable) }
                NSLog("[linkC relay] launchVerifications: task %@ settle — %@", task.shortId, String(describing: error))
            }
        }
        return (false, runnable)
    }

    /// Settles every gating/reported task that needs no verification run — nothing else. Run
    /// ahead of `expireTasks`: without this, a task whose 4h lease (or 60m gate/queue budget)
    /// happened to lapse in exactly the tick that would have settled it got expired instead, with
    /// a generic "lease lapsed" reason burying the worker's own report. Tasks that genuinely need
    /// a run are left for `launchVerifications`, whose own in-flight guard in `expireTasks`
    /// already protects a run actually started this tick.
    /// Returns `true` when the phase ended early because the inbox lock was still contended after
    /// `Self.relayLockTimeout`.
    @discardableResult
    func settleResolvableTasks(workspacePath: String, inboxStore: InboxStore) -> Bool {
        resolveGatingAndReportedTasks(workspacePath: workspacePath, inboxStore: inboxStore).stopped
    }

    /// Settles what needs no run (reports, and a gating task with nothing to gate), then starts
    /// at most one verification run for this workspace, and at most `maxConcurrentVerifications`
    /// overall. Never blocks the main actor: the run awaits the verifier off the main actor and
    /// hops back to record the verdict.
    /// Returns `true` when the phase ended early because the inbox lock was still contended after
    /// `Self.relayLockTimeout` — the caller stops the tick there rather than logging per call.
    @discardableResult
    func launchVerifications(workspacePath: String, inboxStore: InboxStore) -> Bool {
        guard workspaceExists(workspacePath) else { return false }
        let resolved = resolveGatingAndReportedTasks(workspacePath: workspacePath, inboxStore: inboxStore)
        if resolved.stopped { return true }

        let norm = ProjectPath.canonical(workspacePath)
        guard verificationsInFlight[norm] == nil,
              verificationsInFlight.count < Self.maxConcurrentVerifications,
              let (next, run) = resolved.runnable.min(by: { $0.task.createdAt < $1.task.createdAt }) else { return false }

        verificationsInFlight[norm] = next.id
        let verifier = self.verifier
        let workspace = URL(fileURLWithPath: norm)
        Task { [weak self] in
            let verdict: Verdict
            switch run {
            case .gate(let verification):
                verdict = await verifier.gate(verification, in: workspace)
            case .verify(let verification, let sha):
                verdict = await verifier.verify(verification, sha: sha, in: workspace)
            }
            self?.finishVerification(of: next, verdict: verdict, workspacePath: norm)
        }
        return false
    }

    private func settle(_ task: TaskRecord, reason: String, inboxStore: InboxStore, timeout: TimeInterval = 5.0) throws {
        try inboxStore.adjudicateAndNotify(taskId: task.id, verdict: .notRun(reason: reason), notifyBody: "failed — \(reason)", timeout: timeout)
    }

    /// Records the verdict and sends the delegator its one line. A task that ended while its run
    /// was in flight rejects the transition; the verdict is logged and dropped.
    func finishVerification(of task: TaskRecord, verdict: Verdict, workspacePath: String) {
        let norm = ProjectPath.canonical(workspacePath)
        defer { verificationsInFlight.removeValue(forKey: norm) }
        guard workspaceExists(norm) else {
            NSLog("[linkC relay] finishVerification: task %@ workspace is gone; verdict dropped", task.shortId)
            return
        }
        let inboxStore = InboxStore(workspaceRoot: norm)
        do {
            if task.state == .gating {
                // `AppCoordinator` is @MainActor: the store's default 5s timeout would block the
                // whole UI on a contended lock, the same reason every other relay call already
                // passes this shorter budget.
                try inboxStore.resolveGate(taskId: task.id, verdict: verdict, timeout: Self.relayLockTimeout)
                if !verdict.passed {
                    try echo("cancelled — \(verdict.reason ?? "gate failed")", for: task, inboxStore: inboxStore)
                }
            } else {
                try inboxStore.adjudicate(taskId: task.id, verdict: verdict, timeout: Self.relayLockTimeout)
                let line: String
                if verdict.passed {
                    if let sha = verdict.sha {
                        line = "done — verified at \(VerificationRunner.short(sha))"
                    } else {
                        // Only a verifier that passes without ever reporting a sha reaches this —
                        // rendering "" would silently claim a commit that doesn't exist.
                        NSLog("[linkC relay] finishVerification: task %@ passed with no sha", task.shortId)
                        line = "done — verified (no sha)"
                    }
                } else {
                    line = "failed — \(verdict.reason ?? "verification failed")"
                }
                try echo(line, for: task, inboxStore: inboxStore)
            }
        } catch {
            NSLog("[linkC relay] finishVerification: task %@ verdict dropped — %@", task.shortId, String(describing: error))
        }
    }

    // MARK: - Turn end

    /// For each open task assigned to `sessionId`, sends one short "ended without report" line
    /// to the delegator — once per task. Reads no terminal output. Returns the number notified.
    /// A task whose reroute is held back for a limit match is skipped: it is about to move, and the
    /// line would be stale by the time the delegator reads it. `checkLimitsAndReroute` sends it if
    /// the banner leaves the screen and the task stays.
    @discardableResult
    public func relayTurnEnd(sessionId: String, workspacePath: String) -> Int {
        guard let session = store.session(id: sessionId), session.agentKind != .shell else { return 0 }
        let norm = ProjectPath.canonical(workspacePath)
        let inboxStore = InboxStore(workspaceRoot: norm)
        let open: [TaskRecord]
        do {
            open = try inboxStore.openTasks(for: session.agentKind)
        } catch {
            NSLog("[linkC relay] relayTurnEnd: open tasks — %@", String(describing: error))
            return 0
        }

        var notified = 0
        for task in open where task.assigneeSessionId == sessionId
            && (task.state == .delivered || task.state == .started)
            && !task.unreportedTurnEndNotified
            && limitHolds[sessionId]?.taskId != task.id {
            do {
                try echo(
                    // The line is read when the delegator is next idle, so it names the state at turn
                    // end and leaves the current one to `linkc_get_task`.
                    "\(session.agentKind.displayName) turn ended without a report; the task was \(task.state.rawValue) at that point. linkc_get_task(\"\(task.id)\") shows where it stands now, or linkc_cancel_task(\"\(task.id)\").",
                    for: task,
                    inboxStore: inboxStore
                )
                try inboxStore.markUnreportedTurnEndNotified(taskId: task.id)
                notified += 1
            } catch {
                NSLog("[linkC relay] relayTurnEnd: task %@ — %@", task.shortId, String(describing: error))
            }
        }
        if notified > 0 {
            notifications.post(
                title: "linkC: \(session.agentKind.displayName) turn ended",
                body: "\(notified) task(s) still open without a report; \(open.first?.fromAgent.displayName ?? "the delegator") was told.",
                project: norm
            )
            processPendingMessages(workspacePath: norm)
        }
        return notified
    }

    // MARK: - Handoff goal

    /// Explicit goal → newest open task's brief → blackboard goal → nil. Never reads messages.
    func resolveHandoffGoal(workspacePath: String, explicit: String?) -> String? {
        if let explicit = explicit?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            return explicit
        }
        let norm = ProjectPath.canonical(workspacePath)
        do {
            if let newest = try InboxStore(workspaceRoot: norm).openTasks().last {
                return newest.prompt
            }
        } catch {
            NSLog("[linkC relay] resolveHandoffGoal: open tasks — %@", String(describing: error))
        }
        do {
            let board = try BlackboardStore(workspaceRoot: norm).load(timeout: 0.5)
            if let goal = board.activeAgents.last?.goal, !goal.isEmpty, goal != "(idle)" {
                return goal
            }
        } catch {
            NSLog("[linkC relay] resolveHandoffGoal: blackboard — %@", String(describing: error))
        }
        return nil
    }

    // MARK: - Limits and reroute

    /// Detects a provider limit in `sessionId`'s recent output (the one place terminal text is read,
    /// and only for pattern matching). Records the cooldown, tells the delegator via a `.notice`,
    /// cancels the current task, and creates a hop+1 copy for the best available peer (max 2 hops).
    ///
    /// `screen` is the caller's read of the session's screen, for a sweep that has already taken
    /// one; without it the screen is read here.
    @discardableResult
    public func checkLimitsAndReroute(for sessionId: String, screen: ScreenSnapshot? = nil) -> Bool {
        guard let session = store.session(id: sessionId) else { return false }
        guard session.agentKind != .shell, session.state != .ended else { return false }
        // A session already tripped by a previous reroute or breaker is left alone: its buffer
        // still holds the limit text, so re-processing it every tick would loop forever.
        guard session.state != .error else { return false }

        let norm = session.cwd
        let screen = screen ?? terminals.session(id: sessionId)?.screenSnapshot() ?? .none
        // The rules cost far more than comparing what they would read. A session at its prompt
        // shows the same screen for minutes, and the answer for it was already given. A reroute held
        // back is looked at on every tick instead: it ends by the clock or by the worker going quiet,
        // and neither shows on the screen.
        let injected = recentlyInjectedTexts(sessionId: sessionId)
        let held = limitHolds[sessionId]
        let scan = LimitScan(screen: screen.fingerprint, agent: session.agentKind, injected: injected)
        guard held != nil || limitScans[sessionId] != scan else { return false }
        limitScans[sessionId] = scan
        let recentOutput = screen.recentOutput(lines: 50)
        // Everything linkC has typed into this session is excluded: a brief or notice can quote a
        // limit phrase, and the CLI echoing that back is not the agent hitting a limit. Suppressed
        // by content, once per injected entry, with no time bound and no framing requirement — an
        // unframed injection (a legacy v1 message with no `kind`) is guarded exactly like a framed
        // one — so a real banner that repeats a phrase an older brief quoted still matches (see
        // `LimitDetector.withoutInjected`).
        guard let match = limitDetection(recentOutput, session.agentKind, injected) else {
            // The banner is gone, so the reroute it was held back for is no longer wanted. A turn that
            // ended in the meantime was not reported while the hold lasted. Opening the worker's tab
            // moves a finished session to ready, which is still a turn that is over.
            if limitHolds.removeValue(forKey: sessionId) != nil,
               [.finished, .ready, .waitingIdle].contains(session.state) {
                relayTurnEnd(sessionId: sessionId, workspacePath: norm)
            }
            return false
        }

        // A stale banner must not re-arm a limit forever: once a cooldown expires and the session
        // returns to `.ready`, the exact same old banner can still sit in the last 50 lines of an
        // idle terminal. Signature the recent output this match came from; a later detection with
        // the SAME signature for this session is that identical old banner, not new evidence — no
        // record, no reroute. Only output that actually changed (the agent printed something
        // since) can count as a fresh hit. A reroute already held back was matched from a fresh hit.
        let outputSignature = String(recentOutput.hashValue)
        if held == nil {
            guard limitSignatures[sessionId] != outputSignature else { return false }
            limitSignatures[sessionId] = outputSignature
        }

        let inboxStore = InboxStore(workspaceRoot: norm)
        // Current task: newest open task assigned to this exact session.
        let assigned: [TaskRecord]
        do {
            assigned = try inboxStore.openTasks(for: session.agentKind)
        } catch {
            NSLog("[linkC relay] checkLimitsAndReroute: open tasks — %@", String(describing: error))
            assigned = []
        }
        let currentTask = assigned
            .filter { $0.assigneeSessionId == sessionId && ($0.state == .delivered || $0.state == .started) }
            .last

        // The agent is out of quota from the moment its limit is matched, whether or not its worker
        // is done: recording it now sends new delegations elsewhere while the reroute is held back.
        let tickNow = now()
        if held == nil {
            recordLimit(of: session, match: match, at: tickNow, inboxStore: inboxStore)
        }

        // A busy worker keeps its task for now: the peer would start in a checkout the worker is
        // still using. The reroute goes ahead once the worker is quiet, or after `limitHoldCap`.
        let holdForTask = held.flatMap { $0.taskId == currentTask?.id ? $0 : nil }
        if let currentTask, let busy = activity(of: session, screen: screen),
           holdBack(match, task: currentTask, of: session, busy: busy, since: holdForTask, at: tickNow, inboxStore: inboxStore) {
            return false
        }
        limitHolds[sessionId] = nil

        // A task that names its model is never moved: the model means nothing to another agent. It
        // stays with its worker until the limit ends, and its delegator is told now.
        if let currentTask, let model = currentTask.model {
            tellDelegatorModelTaskStays(currentTask, model: model, of: session, inboxStore: inboxStore)
            limitHeldModelTasks[session.id] = currentTask.id
            store.updateState(id: session.id, to: .error)
            return true
        }

        // Tell the delegator (notice: shown in inbox/dashboard, never injected). Sent when the
        // breaker trips or once the current task has actually been cancelled — never for a task
        // that finished under us.
        let tellDelegator: () -> Void = {
            guard let currentTask, currentTask.fromAgent != session.agentKind else { return }
            // The live, user-editable model settings — not `AgentModelCatalog`, whose hardcoded
            // list goes stale the moment a provider renames or retires a model (it still listed
            // "Claude 3.5 Sonnet" and "GPT-4o" long after those model ids stopped resolving).
            // `.light` is each agent's cheapest configured tier — the same one a real reroute
            // would actually fall back to.
            let fallback = self.resolvedModel(for: session.agentKind, tier: .light) ?? "fallback"
            do {
                _ = try inboxStore.enqueue(
                    from: session.agentKind, to: currentTask.fromAgent, kind: .notice, taskId: currentTask.id,
                    body: "\(session.agentKind.displayName) reached usage limit: '\(match.matchedPattern)'. Free fallback model '\(fallback)' is available. Task \(currentTask.shortId) paused."
                )
            } catch {
                NSLog("[linkC relay] checkLimitsAndReroute: task %@ notice — %@", currentTask.shortId, String(describing: error))
            }
            self.notifications.post(
                title: "linkC: \(session.agentKind.displayName) Rate Limited",
                body: "\(session.agentKind.displayName) reached usage limit: '\(match.matchedPattern)'. Free fallback model '\(fallback)' is available.",
                project: session.cwd
            )
        }

        // Candidates: installed, not limited for this task's tier model, not this agent; prefer ones already active here.
        let supportedPeers = AgentKind.peers
        var candidates = supportedPeers.filter { candidate in
            guard !candidate.isLongTaskOnly else { return false }
            guard candidate != session.agentKind && candidate != currentTask?.fromAgent else { return false }
            do {
                let peerModel = currentTask?.tier.flatMap { resolvedModel(for: candidate, tier: $0) }
                guard try inboxStore.isAgentLimited(agent: candidate, model: peerModel) == nil else { return false }
            } catch {
                NSLog("[linkC relay] checkLimitsAndReroute: limit status for %@ — %@", candidate.displayName, String(describing: error))
            }
            if candidate == .claude {
                return FileManager.default.isExecutableFile(atPath: claudePath)
                    || (agentPathResolver?(candidate) ?? AgentDescriptor.resolveExecutable(for: candidate)) != nil
            }
            if let resolver = agentPathResolver { return resolver(candidate) != nil }
            return AgentDescriptor.resolveExecutable(for: candidate) != nil
        }
        // A tiered task can only move to a peer that can actually run its tier. Cursor never
        // resolves one; anyone else with no model configured for it is just as unusable — a
        // "reroute" onto either would only strand the copy in `dispatchTasks` forever.
        if let tier = currentTask?.tier {
            candidates = candidates.filter { resolvedModel(for: $0, tier: tier) != nil }
        }
        candidates.sort { a, b in
            let aActive = store.sessions.contains { $0.cwd == norm && $0.agentKind == a && $0.state != .ended }
            let bActive = store.sessions.contains { $0.cwd == norm && $0.agentKind == b && $0.state != .ended }
            return aActive && !bActive
        }
        // A task on its last hop moves nowhere, so OpenCode is not asked about it: the hop-exhausted
        // path below tells its delegator.
        var openCodeRefusal: String?
        if candidates.first == .opencode, let currentTask, currentTask.hop < 2 {
            let tier = currentTask.tier ?? defaultTier(for: .opencode)
            switch openCodeModelAvailability(in: norm, tier: tier) {
            case .checking:
                // OpenCode's models are still being listed off the main actor. Forget this screen's scan
                // so the next tick reads the unchanged screen again from the start; `recordLimit` keeps a
                // live record as it is, so reading it twice records nothing new. The signature is forgotten
                // too, but only when this pass set it, which only a pass with no hold in force does: a pass
                // with one never sets it, so clearing it there would take away the stale-banner guard of
                // the pass that began the hold.
                // The hold in force this pass (cleared above because it ended or the worker went quiet)
                // is put back: the next pass then continues it, meets `limitHoldCap` or a quiet worker
                // at once, and goes on against the listing. Without it a worker still busy would start
                // a fresh hold, and a fresh notice, on every listing, and its task would never move.
                limitScans[sessionId] = nil
                if held == nil { limitSignatures[sessionId] = nil }
                limitHolds[sessionId] = held
                return false
            case .available:
                break
            case .refused(let reason), .uncheckable(let reason):
                candidates.removeFirst()
                openCodeRefusal = reason
            }
        }

        let hop = currentTask?.hop ?? 0
        guard hop < 2, let target = candidates.first else {
            if let currentTask, let openCodeRefusal {
                // Once per limit: the session is held in `.error` from here, so this tick is not repeated.
                announceOpenCodeRefusal(
                    openCodeRefusal,
                    notice: "\(session.agentKind.displayName) reached its usage limit, and task \(currentTask.shortId) stays with it: OpenCode can't take it — \(openCodeRefusal)",
                    from: session.agentKind, to: currentTask.fromAgent, taskId: currentTask.id, inboxStore: inboxStore)
                store.updateState(id: session.id, to: .error)
                return true
            }
            if let currentTask, let tier = currentTask.tier {
                // No peer can serve this tier. Cancelling the task and announcing a reroute
                // would be a lie — nothing was rerouted, and the hop copy could never be
                // delivered — so the task and the delegator stay untouched. The session must
                // still be marked, though: leaving it as it was let the top-of-function guard
                // never trip, so the very next tick re-detected the same banner still sitting
                // in the scrollback and re-recorded the limit, pushing its own cooldown out
                // forever. The session's own rate limit may still clear on its own.
                NSLog("[linkC relay] checkLimitsAndReroute: task %@ tier %@ has no capable peer to reroute to — leaving in place",
                      currentTask.shortId, tier.label)
                store.updateState(id: session.id, to: .error)
                return true
            }
            tellDelegator()
            store.updateState(id: session.id, to: .error)
            notifications.post(
                title: "linkC: Swarm Rate Limited",
                body: "All candidate agents in \(URL(fileURLWithPath: norm).lastPathComponent) are rate limited or the task has exhausted its reroute hops. Pausing auto-delegation.",
                project: norm
            )
            return true
        }

        // Handoff memo from the task's brief (never from messages).
        do {
            try HandoffComposer.writeHandoffSync(
                workspacePath: norm,
                sourceAgent: session.agentKind,
                lastGoal: resolveHandoffGoal(workspacePath: norm, explicit: currentTask?.prompt),
                gitSummary: gitStatusSummary(in: norm),
                recentTerminalOutput: recentOutput
            )
        } catch {
            NSLog("[linkC relay] checkLimitsAndReroute: write handoff — %@", String(describing: error))
        }

        if let currentTask {
            // What the worker was doing when its task moved goes on the task itself, so a reroute
            // can be explained afterwards.
            var evidence = "\(session.agentKind.displayName) session was \(session.state.rawValue)"
            if let since = screenUnchangedSince(sessionId) {
                evidence += ", screen unchanged for \(Int(max(0, tickNow.timeIntervalSince(since))))s"
            }
            if let holdForTask {
                evidence += ", reroute held for \(Int(max(0, tickNow.timeIntervalSince(holdForTask.since))))s"
            }
            // The copy exists only if the cancel succeeded. If the assignee reached a terminal
            // state between the openTasks read and here, the transition throws and nothing is
            // re-dispatched or announced. A verified copy keeps its verification and the gate it
            // passed, and is not gated again: HEAD has moved and the tree may hold partial work.
            var copyId: String?
            do {
                try inboxStore.cancelTask(
                    taskId: currentTask.id, reason: "rerouted to \(target.displayName) after limit — \(evidence)"
                )
                NSLog("[linkC relay] checkLimitsAndReroute: task %@ cancelled, rerouted to %@ (hop %d) — limit rule '%@' matched; %@",
                      currentTask.shortId, target.displayName, hop + 1, match.matchedPattern, evidence)
                tellDelegator()
                copyId = try createRerouteCopy(of: currentTask, to: target, hop: hop + 1, in: inboxStore)
            } catch {
                NSLog("[linkC relay] checkLimitsAndReroute: task %@ cancel/hop %d copy — %@", currentTask.shortId, hop + 1, String(describing: error))
            }
            // This project's inbox lock is released: the sending project's pointer follows the copy, so
            // its answer still finds the session that asked. Never both locks at once.
            if let copyId, let fromProject = currentTask.fromProject {
                followReroute(from: currentTask, toCopy: copyId, inProject: fromProject)
            }
        } else {
            // Nothing is in flight, so there is nothing to move. linkC does NOT invent work
            // here. It used to create a "continue from the handoff" task for a peer, so a
            // single false-positive match spent another agent's quota on work nobody asked
            // for. The limit is recorded and the session marked; what to do next is the
            // person's call.
            NSLog("[linkC relay] checkLimitsAndReroute: %@ limited (%@) with nothing in flight; recorded only",
                  session.agentKind.displayName, match.matchedPattern)
        }

        store.updateState(id: session.id, to: .error)
        processPendingMessages(workspacePath: norm)
        return true
    }
}

extension AppCoordinator {
    /// The reroute copy of `task` for `target`: the same work from the same place, so it keeps the return
    /// address and, for an ask, stays a question. Returns the copy's id. Kept out of line: inlined into
    /// `checkLimitsAndReroute`, Swift 6.3.3's release optimizer (CopyPropagation) crashes on it.
    @inline(never)
    fileprivate func createRerouteCopy(of task: TaskRecord, to target: AgentKind, hop: Int,
                                       in inboxStore: InboxStore) throws -> String {
        try inboxStore.createTask(
            from: task.fromAgent, to: target, fromSessionId: task.fromSessionId,
            tier: task.tier, prompt: task.prompt,
            files: task.files, hop: hop, force: true,
            verification: task.verification, gate: task.gate,
            fromProject: task.fromProject, isQuestion: task.isQuestion
        ).id
    }

    /// Points the sending project's record of `task` at its reroute copy, `copyId`. A failure leaves the
    /// record on the cancelled original, so it is logged with both ids.
    fileprivate func followReroute(from task: TaskRecord, toCopy copyId: String, inProject home: String) {
        let copyShortId = String(copyId.prefix(8))
        guard workspaceExists(home) else {
            NSLog("[linkC relay] checkLimitsAndReroute: task %@ rerouted to %@, but its sending project is gone — %@",
                  task.shortId, copyShortId, home)
            return
        }
        do {
            if try InboxStore(workspaceRoot: home).replaceSent(taskId: task.id, with: copyId) == false {
                NSLog("[linkC relay] checkLimitsAndReroute: task %@ rerouted to %@, but %@ holds no record of having sent it",
                      task.shortId, copyShortId, home)
            }
        } catch {
            NSLog("[linkC relay] checkLimitsAndReroute: task %@ rerouted to %@, but %@'s record of it could not follow — %@",
                  task.shortId, copyShortId, home, String(describing: error))
        }
    }

    /// Records `session`'s agent as out of quota: until the limit's own reset when there is real
    /// evidence of one, otherwise for the rule's fixed cooldown.
    fileprivate func recordLimit(of session: Session, match: LimitMatch, at tickNow: Date, inboxStore: InboxStore) {
        // The agent's current usage, if any — Claude's freshest number is the live status-line
        // reading; every other agent goes through its own registered reader (empty/production —
        // see `usageReaders`'s doc comment).
        let usage: AgentUsage? = session.agentKind == .claude ? claudeUsage : usageReaders[session.agentKind]?()
        // Whether there is real evidence to rest on (a usage window's own reset, or a time the
        // banner itself states) — not merely `checkLimitsAndReroute`'s fixed fallback duration
        // recomputed against a later `now`, which would always look "later" than an already-live
        // cooldown that is actually ticking down. See `LimitCooldown.hasConfidentSignal`.
        let hasConfidentExpiry = LimitCooldown.hasConfidentSignal(
            bannerText: match.bannerText, usage: usage, now: tickNow, calendar: .current
        )
        let pool = ModelPool.pool(of: session.model ?? "", agent: session.agentKind)
        do {
            try inboxStore.recordLimit(agent: session.agentKind, reason: match.matchedPattern,
                                       cooldown: match.cooldown, pool: pool)
            if hasConfidentExpiry {
                // recordLimit only ever creates the record with the fixed cooldown (or keeps a
                // still-live one exactly as it was); extendLimit is the only thing allowed to push
                // it out further to the more accurate expiry below, and only ever later, never
                // shorter.
                let expiry = LimitCooldown.expiry(
                    bannerText: match.bannerText, usage: usage, now: tickNow, calendar: .current, fallback: match.cooldown
                )
                try inboxStore.extendLimit(agent: session.agentKind, until: expiry, pool: pool)
            }
        } catch {
            NSLog("[linkC relay] checkLimitsAndReroute: record limit — %@", String(describing: error))
        }
    }

    /// The model a task would run: its own model, or its tier's configured model.
    func modelForLimit(of task: TaskRecord) -> String? {
        if let model = task.model { return model }
        if let tier = task.tier { return resolvedModel(for: task.toAgent, tier: tier) }
        return nil
    }

    /// A limit rule matched the screen of a session that is busy with `task`. True while the
    /// reroute stays held back: the task is left where it is. `previous` is the hold already in
    /// place for this task (nil for one that begins now). False once `limitHoldCap` has passed
    /// since it began: the task moves anyway. `busy` says why the session counts as busy.
    ///
    /// The delegator is told once the hold has outlasted two quiet periods. A worker whose turn has
    /// ended is moved within one quiet period and a tick, and a notice that the task was left with
    /// it would be contradicted by that move.
    fileprivate func holdBack(
        _ match: LimitMatch, task: TaskRecord, of session: Session, busy: String,
        since previous: LimitHold?, at tickNow: Date, inboxStore: InboxStore
    ) -> Bool {
        var hold = previous ?? LimitHold(taskId: task.id, since: tickNow)
        let heldFor = tickNow.timeIntervalSince(hold.since)
        guard heldFor < Self.limitHoldCap else {
            NSLog("[linkC relay] checkLimitsAndReroute: %@ (session %@) is still busy — %@ — %ds after its limit rule '%@' matched; task %@ moves anyway",
                  session.agentKind.displayName, session.id, busy, Int(heldFor), match.matchedPattern, task.shortId)
            return false
        }
        if previous == nil {
            NSLog("[linkC relay] checkLimitsAndReroute: %@ matched limit rule '%@' but %@ (session %@); task %@ left in place for up to %ds",
                  session.agentKind.displayName, match.matchedPattern, busy, session.id, task.shortId, Int(Self.limitHoldCap))
        }
        if !hold.delegatorTold, heldFor >= 2 * turnEndQuietPeriod {
            hold.delegatorTold = true
            tellDelegatorOfHold(task: task, of: session, busy: busy, inboxStore: inboxStore)
        }
        limitHolds[session.id] = hold
        return true
    }

    /// Tells the delegator of a task with a model that it stays with its limited worker, and why.
    private func tellDelegatorModelTaskStays(_ task: TaskRecord, model: String, of session: Session, inboxStore: InboxStore) {
        var why = "\(session.agentKind.displayName) reached its usage limit on model \(model)."
        do {
            if let limit = try inboxStore.isAgentLimited(agent: session.agentKind, model: model, timeout: Self.relayLockTimeout) {
                why = try MCPServer.limitRefusal(
                    agent: session.agentKind, limit: limit, model: model, readLists: modelLists,
                    settings: liveModelSettings(), inboxStore: inboxStore, lockTimeout: Self.relayLockTimeout)
            }
        } catch {
            NSLog("[linkC relay] task %@ — limit status for its notice — %@", task.shortId, String(describing: error))
        }
        NSLog("[linkC relay] checkLimitsAndReroute: task %@ names model %@ and is never rerouted — %@", task.shortId, model, why)
        notifications.post(title: "linkC: \(session.agentKind.displayName) Rate Limited", body: why, project: session.cwd)
        guard task.fromAgent != session.agentKind else { return }
        sendDelegatorNotice(
            "Task \(task.shortId) stays with \(session.agentKind.displayName): \(why) A task with a model is never moved to another agent; it carries on when the limit ends. linkc_cancel_task(\"\(task.id)\") to stop it.",
            from: session.agentKind, to: task.fromAgent, taskId: task.id, inboxStore: inboxStore)
    }

    /// Sends `body` to `delegator`; when the inbox cannot take it now, it is kept and sent again on
    /// each relay tick of its workspace until it is written.
    private func sendDelegatorNotice(
        _ body: String, from sender: AgentKind, to delegator: AgentKind, taskId: String?, inboxStore: InboxStore
    ) {
        guard !enqueueDelegatorNotice(body, from: sender, to: delegator, taskId: taskId, inboxStore: inboxStore) else { return }
        pendingDelegatorNotices.append(PendingDelegatorNotice(
            workspace: ProjectPath.canonical(inboxStore.workspaceRoot), sender: sender, delegator: delegator,
            taskId: taskId, body: body))
    }

    /// Sends again the notices of `workspacePath` the inbox could not take. Returns `true` when the
    /// inbox lock was still contended after `Self.relayLockTimeout`, so the tick stops there. A notice
    /// that fails for any other reason stays, and the failure is logged on every try.
    @discardableResult
    func sendPendingDelegatorNotices(workspacePath: String, inboxStore: InboxStore) -> Bool {
        let norm = ProjectPath.canonical(workspacePath)
        guard workspaceExists(norm) else { return false }
        for notice in pendingDelegatorNotices where notice.workspace == norm {
            do {
                _ = try inboxStore.enqueue(
                    from: notice.sender, to: notice.delegator, kind: .notice, taskId: notice.taskId, body: notice.body,
                    timeout: Self.relayLockTimeout)
            } catch {
                if isRelayLockTimeout(error) { return true }
                NSLog("[linkC relay] notice to the delegator, tried again — %@", String(describing: error))
                continue
            }
            if let sent = pendingDelegatorNotices.firstIndex(of: notice) { pendingDelegatorNotices.remove(at: sent) }
        }
        return false
    }

    /// Tells a worker whose model task stayed with it through a limit that the limit has ended, once
    /// its session is out of `.error`. Nothing else would: the task is still started, and the worker
    /// is idle at its prompt with no one asking it to go on. A notice that cannot be written is tried
    /// again on the next sample, since the entry stays until it is. A task that has ended meanwhile, or
    /// moved to another worker, needs no word.
    func resumeModelTaskAfterLimit(of sessionId: String) {
        guard let taskId = limitHeldModelTasks[sessionId],
              let session = store.session(id: sessionId), session.state != .error, session.state != .ended else { return }
        let inbox = InboxStore(workspaceRoot: session.cwd)
        do {
            let task = try inbox.task(id: taskId, timeout: Self.relayLockTimeout)
            if let task, task.assigneeSessionId == sessionId, task.state == .delivered || task.state == .started {
                _ = try inbox.enqueue(
                    from: session.agentKind, to: session.agentKind, kind: .command, toSessionId: sessionId,
                    body: "linkC: the limit has ended. Carry on with task \(task.id).", timeout: Self.relayLockTimeout)
            }
            limitHeldModelTasks[sessionId] = nil
        } catch {
            NSLog("[linkC relay] resumeModelTaskAfterLimit: session %@ task %@ — %@ (trying again next sample)",
                  sessionId, taskId, String(describing: error))
        }
    }

    private func tellDelegatorOfHold(task: TaskRecord, of session: Session, busy: String, inboxStore: InboxStore) {
        guard task.fromAgent != session.agentKind else { return }
        let outcome = task.model == nil
            ? "It moves to another agent once the worker is quiet, or at most \(Int(Self.limitHoldCap / 60)) minutes after the limit rule first matched."
            : "A task with a model is never moved to another agent, so it stays with this worker."
        do {
            _ = try inboxStore.enqueue(
                from: session.agentKind, to: task.fromAgent, kind: .notice, taskId: task.id,
                body: "\(session.agentKind.displayName)'s screen matches a limit rule but \(busy), so task \(task.shortId) is left with it for now. \(outcome) linkc_cancel_task(\"\(task.id)\") to stop it now."
            )
        } catch {
            NSLog("[linkC relay] checkLimitsAndReroute: task %@ held-back notice — %@", task.shortId, String(describing: error))
        }
    }
}

/// A reroute held back for a busy worker: the task it is for, when the hold began, and whether the
/// delegator has been told.
struct LimitHold: Equatable {
    let taskId: String
    let since: Date
    var delegatorTold = false
}

/// The run `launchVerifications` starts: the gate at base, or verification at the reported sha.
private enum VerificationRun: Sendable {
    case gate(Verification)
    case verify(Verification, sha: String)
}

/// Everything the limit rules' answer depends on for one session: the screen (by
/// `ScreenSnapshot.fingerprint`), the agent whose rules apply, and what linkC has typed into the
/// session, whose echo the rules leave out.
struct LimitScan: Equatable {
    let screen: Int
    let agent: AgentKind
    let injected: [String]
}

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
    /// that runs once a second across every workspace: eight to ten `linkc-mcp` processes write
    /// the same `inbox.json`, so a single slow writer would otherwise stall the whole UI for up to
    /// 5s, several times per tick. A contended lock is not a failure here — the tick simply skips
    /// and the next one retries a second later — so this budget only needs to be short, not zero.
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

    /// One relay tick for `workspacePath`: expire, start verification, then deliver only if no
    /// run holds this checkout. A verification owns HEAD and the tree while it runs.
    ///
    /// Each phase gives up on the inbox lock after `Self.relayLockTimeout` rather than the store's
    /// default 5s. A timeout there is not a failure — the row it would have touched just waits for
    /// the next tick — but once one phase hits a contended lock, the others almost certainly would
    /// too (it's the same file), so the tick stops rather than paying the wait four times over.
    public func processPendingMessages(workspacePath: String) {
        let norm = (workspacePath as NSString).standardizingPath
        let inboxStore = InboxStore(workspaceRoot: norm)
        guard !expireTasks(workspacePath: norm, inboxStore: inboxStore) else {
            return logRelayLockContention(workspacePath: norm)
        }
        // After expiry, so a task that is already dead is failed rather than reported stuck.
        guard !watchStuckTasks(workspacePath: norm, inboxStore: inboxStore) else {
            return logRelayLockContention(workspacePath: norm)
        }
        guard !launchVerifications(workspacePath: norm, inboxStore: inboxStore) else {
            return logRelayLockContention(workspacePath: norm)
        }
        guard !dispatchTasks(workspacePath: norm, inboxStore: inboxStore) else {
            return logRelayLockContention(workspacePath: norm)
        }
        if dispatchMessages(workspacePath: norm, inboxStore: inboxStore) {
            logRelayLockContention(workspacePath: norm)
        }
    }

    /// True when `error` is the store's own lock-acquisition timeout rather than a real failure
    /// (a corrupt `inbox.json`, a missing row, an illegal transition, ...). `InboxStore` throws
    /// `LinkCError.server` for all of these and carries no dedicated case for this one, so the
    /// message text is what distinguishes it — matching the same pattern already used to identify
    /// a `BlackboardStore` lock timeout.
    func isRelayLockTimeout(_ error: Error) -> Bool {
        guard let linkCError = error as? LinkCError, case .server(let message) = linkCError else { return false }
        return message.contains("Timed out acquiring inbox lock")
    }

    /// Logs once that this tick ended early because the inbox lock was still held by another
    /// writer after `Self.relayLockTimeout`. Never called more than once per `processPendingMessages`
    /// call — a permanently contended workspace must be visible, not merely idle every tick.
    private func logRelayLockContention(workspacePath: String) {
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
        var lines = ["[linkC task \(task.shortId) from \(task.fromAgent.displayName)]", task.prompt, ""]
        if let v = task.verification {
            lines.append("Work on branch \(v.branch). linkC verifies by running `\(v.command)` at the sha you report. Do not modify: \(v.testPaths.joined(separator: ", ")).")
            lines.append("")
        }
        lines.append("When you begin, call linkc_start_task(\"\(task.id)\"). When finished, commit your work and call linkc_complete_task(\"\(task.id)\", status, summary, sha). Do not paste this brief into any reply.")
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
            if verificationsInFlight[workspacePath] == task.id { continue }
            switch task.state {
            case .gating:
                if now.timeIntervalSince(task.createdAt) > Self.queuedTaskExpiry {
                    do {
                        try inboxStore.expireTaskAndNotify(
                            taskId: task.id, reason: "gate did not run within 60m",
                            notifyBody: "expired — gate did not run within 60m", timeout: Self.relayLockTimeout
                        )
                    } catch {
                        if isRelayLockTimeout(error) { return true }
                        NSLog("[linkC relay] expireTasks: task %@ stale gate — %@", task.shortId, String(describing: error))
                    }
                }
            case .queued:
                if now.timeIntervalSince(task.createdAt) > Self.queuedTaskExpiry {
                    // dispatchTasks never even looks at a workspace's queue while a verification
                    // owns that checkout — for a different task, since this one's own run would
                    // have hit the `continue` above. "undelivered for 60m" would be untrue for a
                    // task that sat behind a held checkout rather than one nobody could deliver.
                    let reason = verificationsInFlight[workspacePath] != nil
                        ? "undelivered for 60m — held back by a verification in this workspace"
                        : "undelivered for 60m"
                    do {
                        try inboxStore.expireTask(taskId: task.id, reason: reason, timeout: Self.relayLockTimeout)
                    } catch {
                        if isRelayLockTimeout(error) { return true }
                        NSLog("[linkC relay] expireTasks: task %@ stale queued — %@", task.shortId, String(describing: error))
                    }
                }
            case .delivered, .started:
                let assigneeAlive = task.assigneeSessionId.flatMap { store.session(id: $0) }.map { $0.state != .ended } ?? false
                if !assigneeAlive {
                    let reason = "assignee session ended before reporting"
                    do {
                        try inboxStore.failTaskAndNotify(
                            taskId: task.id, reason: reason, notifyBody: "failed — \(reason)", timeout: Self.relayLockTimeout
                        )
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

    // MARK: - Tasks

    /// Returns `true` when the phase ended early because the inbox lock was still contended after
    /// `Self.relayLockTimeout` — the caller stops the tick there rather than logging per call.
    @discardableResult
    func dispatchTasks(workspacePath: String, inboxStore: InboxStore) -> Bool {
        guard workspaceExists(workspacePath) else { return false }
        // A verification owns this checkout until it finishes: injecting a brief now would let a
        // worker edit the tree the verdict is about to be measured against.
        guard verificationsInFlight[workspacePath] == nil else { return false }
        let queued: [TaskRecord]
        do {
            queued = try inboxStore.openTasks(timeout: Self.relayLockTimeout).filter { $0.state == .queued }
        } catch {
            if isRelayLockTimeout(error) { return true }
            NSLog("[linkC relay] dispatchTasks: open tasks — %@", String(describing: error))
            return false
        }
        guard !queued.isEmpty else { return false }

        for task in queued {
            let candidates = store.sessions.filter {
                ($0.cwd as NSString).standardizingPath == workspacePath && $0.agentKind == task.toAgent
                    && $0.state != .ended && $0.id != task.fromSessionId
                    // A tiered task runs only on a session pinned to that tier. A row written
                    // before tiers has none, and keeps the pre-tier rule: any session of its kind.
                    && (task.tier == nil || $0.modelTier == task.tier)
            }
            if candidates.isEmpty {
                // A tiered task whose tier no longer resolves to a model (settings edited while
                // the task sat queued) must not spawn an unpinned session — that session could
                // never satisfy `$0.modelTier == task.tier` above, so the next tick would spawn
                // another one, forever. Leave it queued and say why; do not invent a model.
                if let tier = task.tier, resolvedModel(for: task.toAgent, tier: tier) == nil {
                    NSLog("[linkC relay] dispatchTasks: task %@ has no %@ model configured for tier %@ — leaving queued",
                          task.shortId, task.toAgent.displayName, tier.label)
                    continue
                }
                // Spawn now, deliver on a later tick. A CLI needs seconds to reach its prompt, and a
                // frame typed into a booting TUI is lost — the worker never sees the task. The session
                // stays `.starting` until its agent is really running: Claude's SessionStart hook, or
                // `sampleAgentStates` for every other kind.
                do {
                    _ = try spawnTeammate(in: workspacePath, agent: task.toAgent, goal: task.prompt, tier: task.tier)
                } catch {
                    // Swallowing this used to leave the task `.queued` forever, retried every
                    // second, with nothing anywhere saying why — the same silence the sibling
                    // "no model configured" branch above no longer has.
                    lastSpawnFailure = SpawnFailure(agent: task.toAgent, workspacePath: workspacePath, error: String(describing: error))
                    NSLog("[linkC relay] dispatchTasks: task %@ could not spawn %@ — %@",
                          task.shortId, task.toAgent.displayName, String(describing: error))
                }
                continue
            }
            let idleCandidates = candidates.filter { isIdle($0.state) }
            guard !idleCandidates.isEmpty else {
                NSLog("[linkC relay] dispatchTasks: task %@ has %@ session(s) for %@ but none is idle — waiting",
                      task.shortId, String(candidates.count), task.toAgent.displayName)
                continue // all busy: wait for a later tick
            }
            // The brief is always multi-line, so it must arrive as one bracketed paste — never as
            // raw text a line-oriented TUI would submit line by line. Require negotiation here,
            // among the idle candidates, rather than folding it into the `candidates` filter above:
            // that filter also decides whether to spawn a new session, and an idle-but-not-yet-
            // negotiated session would look like "no session exists" there, spawning a duplicate
            // every tick instead of waiting for this one to finish negotiating.
            //
            // Negotiation alone is not enough: a real CLI's flag flips well before it can
            // actually consume input (see `Self.defaultDeliverySettle`), so also require the session to
            // have been ready for at least the settle margin. A session that never settles is
            // simply not a candidate this tick — never dropped, never silently skipped forever —
            // and the log line below fires every tick it's waited on, so it can't starve in
            // silence.
            guard let session = idleCandidates.first(where: { candidate in
                guard let terminal = terminals.session(id: candidate.id), terminal.acceptsPaste,
                      let readySince = terminal.pasteReadySince else { return false }
                return now().timeIntervalSince(readySince) >= deliverySettle
            }) else {
                NSLog("[linkC relay] dispatchTasks: task %@ has an idle session but none has settled after negotiating bracketed paste yet — waiting", task.shortId)
                continue
            }

            do {
                try inboxStore.markTaskDelivered(taskId: task.id, sessionId: session.id, timeout: Self.relayLockTimeout)
            } catch {
                if isRelayLockTimeout(error) { return true }
                NSLog("[linkC relay] dispatchTasks: task %@ mark delivered — %@", task.shortId, String(describing: error))
                continue
            }
            let frame = Self.deliveryFrame(for: task)
            terminals.sendInput(sessionId: session.id, text: frame)
            recordInjection(sessionId: session.id, text: frame)
            store.updateState(id: session.id, to: .working)
        }
        return false
    }

    // MARK: - Messages

    /// Returns `true` when the phase ended early because the inbox lock was still contended after
    /// `Self.relayLockTimeout` — the caller stops the tick there rather than logging per call.
    @discardableResult
    func dispatchMessages(workspacePath: String, inboxStore: InboxStore) -> Bool {
        guard workspaceExists(workspacePath) else { return false }
        let pending: [PendingMessage]
        do {
            pending = try inboxStore.fetchPending(timeout: Self.relayLockTimeout)
        } catch {
            if isRelayLockTimeout(error) { return true }
            NSLog("[linkC relay] dispatchMessages: fetch pending — %@", String(describing: error))
            return false
        }
        guard !pending.isEmpty else { return false }

        // A verification owns this checkout until it finishes: injecting a brief now would let a
        // worker edit the tree the verdict is about to be measured against. Only a brief — the
        // legacy `.task` message row — needs to wait for that; a completion line, a cancel
        // notice, a peer note, or a model switch never touches the tree and must still reach
        // whoever is waiting on it while a run is in flight.
        let verificationInFlight = verificationsInFlight[workspacePath] != nil

        for message in pending where message.status == .queued {
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

            // A notice about a task belongs to the session that delegated it: any other session of
            // that kind is a different conversation. Fall back to one only when it is gone.
            var target: Session?
            if let taskId = message.taskId {
                let record: TaskRecord?
                do {
                    record = try inboxStore.task(id: taskId, timeout: Self.relayLockTimeout)
                } catch {
                    // A contended lock is not "this task has no delegator": falling through would
                    // hand the notice to a different session of the same kind. End the tick — the
                    // next one, a second later, routes it properly.
                    if isRelayLockTimeout(error) { return true }
                    NSLog("[linkC relay] dispatchMessages: message %@ delegator lookup — %@",
                          message.id, String(describing: error))
                    record = nil
                }
                if let delegatorId = record?.fromSessionId {
                    // Same workspace as the fallback below demands: `fromSessionId` comes from the
                    // caller's own `LINKC_SESSION`, so one from another project must not pull this
                    // workspace's notice into that project's terminal.
                    target = store.sessions.first {
                        $0.id == delegatorId && $0.state != .ended
                            && ($0.cwd as NSString).standardizingPath == workspacePath
                    }
                }
            }
            if target == nil {
                target = store.sessions.first {
                    ($0.cwd as NSString).standardizingPath == workspacePath && $0.agentKind == message.toAgent && $0.state != .ended
                }
            }
            if target == nil {
                // Only a task brief is worth spawning an agent for. Every other message — a
                // completion line, a stuck notice, a peer note, a command — waits for a session to
                // exist instead, and the user is told when it has waited too long.
                guard message.kind == .task else {
                    noteUndeliveredNotice(message)
                    continue
                }
                let goal: String? = message.kind == .task ? message.prompt : nil
                do {
                    _ = try spawnTeammate(in: workspacePath, agent: message.toAgent, goal: goal)
                } catch {
                    lastSpawnFailure = SpawnFailure(agent: message.toAgent, workspacePath: workspacePath, error: String(describing: error))
                    NSLog("[linkC relay] dispatchMessages: message %@ could not spawn %@ — %@",
                          message.id, message.toAgent.displayName, String(describing: error))
                }
                continue
            }
            guard let session = target, isIdle(session.state) else {
                noteUndeliveredNotice(message)
                continue
            }

            // The mark durably records delivery before the terminal ever shows the text, and its
            // own disk I/O and lock wait sit inside the window between reading `target` above and
            // `sendInput` below. A child that dies in that window makes `sendInput` drop the text
            // silently, so the message would be recorded delivered and never shown, with no trace.
            // This check cannot close the window completely — the child can still die between here
            // and the send — but it closes the common case, and `sendInput` itself now logs the
            // residual one.
            guard terminals.session(id: session.id)?.isRunning == true else { continue }

            // Mark before injecting: if the mark throws — a lock timeout under contention — the
            // row stays queued and must not be sent this tick, or the next tick injects the same
            // text again on top of it. `dispatchTasks` marks first for the same reason.
            do {
                try inboxStore.markMessageDelivered(id: message.id, timeout: Self.relayLockTimeout)
            } catch {
                if isRelayLockTimeout(error) { return true }
                NSLog("[linkC relay] dispatchMessages: message %@ mark delivered — %@", message.id, String(describing: error))
                continue
            }
            terminals.sendInput(sessionId: session.id, text: message.prompt)
            recordInjection(sessionId: session.id, text: message.prompt)
            // A hand switch makes the pin a lie. Re-derive it here, where the switch actually
            // happens: an id that maps to a tier takes it, an unmapped one clears the pin, and a
            // session with no pin receives no tiered work.
            if message.kind == .command, message.prompt.hasPrefix("/model ") {
                let id = String(message.prompt.dropFirst("/model ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                store.updateModel(id: session.id, model: id.isEmpty ? nil : id,
                                  modelTier: tier(forModel: id, agent: session.agentKind))
            }
            if message.kind == .task { store.updateState(id: session.id, to: .working) }
        }
        return false
    }

    // MARK: - Verification

    /// Settles what needs no run (reports, and a gating task with nothing to gate), then starts
    /// at most one verification run for this workspace, and at most `maxConcurrentVerifications`
    /// overall. Never blocks the main actor: the run awaits the verifier off the main actor and
    /// hops back to record the verdict.
    /// Returns `true` when the phase ended early because the inbox lock was still contended after
    /// `Self.relayLockTimeout` — the caller stops the tick there rather than logging per call.
    @discardableResult
    func launchVerifications(workspacePath: String, inboxStore: InboxStore) -> Bool {
        guard workspaceExists(workspacePath) else { return false }
        let open: [TaskRecord]
        do {
            open = try inboxStore.openTasks(timeout: Self.relayLockTimeout)
        } catch {
            if isRelayLockTimeout(error) { return true }
            NSLog("[linkC relay] launchVerifications: open tasks — %@", String(describing: error))
            return false
        }

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
                if isRelayLockTimeout(error) { return true }
                NSLog("[linkC relay] launchVerifications: task %@ settle — %@", task.shortId, String(describing: error))
            }
        }

        guard verificationsInFlight[workspacePath] == nil,
              verificationsInFlight.count < Self.maxConcurrentVerifications,
              let (next, run) = runnable.min(by: { $0.task.createdAt < $1.task.createdAt }) else { return false }

        verificationsInFlight[workspacePath] = next.id
        let verifier = self.verifier
        let workspace = URL(fileURLWithPath: workspacePath)
        Task { [weak self] in
            let verdict: Verdict
            switch run {
            case .gate(let verification):
                verdict = await verifier.gate(verification, in: workspace)
            case .verify(let verification, let sha):
                verdict = await verifier.verify(verification, sha: sha, in: workspace)
            }
            self?.finishVerification(of: next, verdict: verdict, workspacePath: workspacePath)
        }
        return false
    }

    private func settle(_ task: TaskRecord, reason: String, inboxStore: InboxStore, timeout: TimeInterval = 5.0) throws {
        try inboxStore.adjudicateAndNotify(taskId: task.id, verdict: .notRun(reason: reason), notifyBody: "failed — \(reason)", timeout: timeout)
    }

    /// Records the verdict and sends the delegator its one line. A task that ended while its run
    /// was in flight rejects the transition; the verdict is logged and dropped.
    func finishVerification(of task: TaskRecord, verdict: Verdict, workspacePath: String) {
        defer { verificationsInFlight.removeValue(forKey: workspacePath) }
        guard workspaceExists(workspacePath) else {
            NSLog("[linkC relay] finishVerification: task %@ workspace is gone; verdict dropped", task.shortId)
            return
        }
        let inboxStore = InboxStore(workspaceRoot: workspacePath)
        do {
            if task.state == .gating {
                try inboxStore.resolveGate(taskId: task.id, verdict: verdict)
                if !verdict.passed {
                    try echo("cancelled — \(verdict.reason ?? "gate failed")", for: task, inboxStore: inboxStore)
                }
            } else {
                try inboxStore.adjudicate(taskId: task.id, verdict: verdict)
                let line = verdict.passed
                    ? "done — verified at \(VerificationRunner.short(verdict.sha ?? ""))"
                    : "failed — \(verdict.reason ?? "verification failed")"
                try echo(line, for: task, inboxStore: inboxStore)
            }
        } catch {
            NSLog("[linkC relay] finishVerification: task %@ verdict dropped — %@", task.shortId, String(describing: error))
        }
    }

    // MARK: - Turn end

    /// For each open task assigned to `sessionId`, sends one short "ended without report" line
    /// to the delegator — once per task. Reads no terminal output. Returns the number notified.
    @discardableResult
    public func relayTurnEnd(sessionId: String, workspacePath: String) -> Int {
        guard let session = store.session(id: sessionId), session.agentKind != .shell else { return 0 }
        let norm = (workspacePath as NSString).standardizingPath
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
            && !task.unreportedTurnEndNotified {
            do {
                try echo(
                    "\(session.agentKind.displayName) turn ended without a report. Task remains \(task.state.rawValue); linkc_get_task(\"\(task.id)\") or linkc_cancel_task(\"\(task.id)\").",
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
                body: "\(notified) task(s) still open without a report; \(open.first?.fromAgent.displayName ?? "the delegator") was told."
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
        let norm = (workspacePath as NSString).standardizingPath
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
    @discardableResult
    public func checkLimitsAndReroute(for sessionId: String) -> Bool {
        guard let session = store.session(id: sessionId) else { return false }
        guard session.agentKind != .shell, session.state != .ended else { return false }
        // A session already tripped by a previous reroute or breaker is left alone: its buffer
        // still holds the limit text, so re-processing it every tick would loop forever.
        guard session.state != .error else { return false }

        let norm = (session.cwd as NSString).standardizingPath
        let recentOutput = terminals.session(id: sessionId)?.recentOutput(lines: 50) ?? ""
        // Everything linkC has typed into this session is excluded: a brief or notice can quote a
        // limit phrase, and the CLI echoing that back is not the agent hitting a limit. Suppressed
        // by content, once per injected entry, with no time bound and no framing requirement — an
        // unframed injection (a legacy v1 message with no `kind`) is guarded exactly like a framed
        // one — so a real banner that repeats a phrase an older brief quoted still matches (see
        // `LimitDetector.withoutInjected`).
        guard let match = LimitDetector.detectLimit(
            inOutput: recentOutput,
            agent: session.agentKind,
            ignoringInjected: recentlyInjectedTexts(sessionId: sessionId)
        ) else { return false }

        let inboxStore = InboxStore(workspaceRoot: norm)
        do {
            try inboxStore.recordLimit(agent: session.agentKind, reason: match.matchedPattern, cooldown: match.cooldown)
        } catch {
            NSLog("[linkC relay] checkLimitsAndReroute: record limit — %@", String(describing: error))
        }

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

        // Tell the delegator (notice: shown in inbox/dashboard, never injected). Sent when the
        // breaker trips or once the current task has actually been cancelled — never for a task
        // that finished under us.
        let tellDelegator: () -> Void = {
            guard let currentTask, currentTask.fromAgent != session.agentKind else { return }
            let fallback = AgentModelCatalog.fallbackModels(for: session.agentKind).first?.displayName ?? "fallback"
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
                body: "\(session.agentKind.displayName) reached usage limit: '\(match.matchedPattern)'. Free fallback model '\(fallback)' is available."
            )
        }

        // Candidates: installed, not limited, not this agent; prefer ones already active here.
        let supportedPeers: [AgentKind] = [.claude, .codex, .agy, .cursor]
        var candidates = supportedPeers.filter { candidate in
            guard candidate != session.agentKind else { return false }
            do {
                guard try inboxStore.isAgentLimited(agent: candidate) == nil else { return false }
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
            let aActive = store.sessions.contains { ($0.cwd as NSString).standardizingPath == norm && $0.agentKind == a && $0.state != .ended }
            let bActive = store.sessions.contains { ($0.cwd as NSString).standardizingPath == norm && $0.agentKind == b && $0.state != .ended }
            return aActive && !bActive
        }

        let hop = currentTask?.hop ?? 0
        guard hop < 2, let target = candidates.first else {
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
                body: "All candidate agents in \(URL(fileURLWithPath: norm).lastPathComponent) are rate limited or the task has exhausted its reroute hops. Pausing auto-delegation."
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
            // The copy exists only if the cancel succeeded. If the assignee reached a terminal
            // state between the openTasks read and here, the transition throws and nothing is
            // re-dispatched or announced. A verified copy keeps its verification and the gate it
            // passed, and is not gated again: HEAD has moved and the tree may hold partial work.
            do {
                try inboxStore.cancelTask(taskId: currentTask.id, reason: "rerouted to \(target.displayName) after limit")
                tellDelegator()
                _ = try inboxStore.createTask(
                    from: currentTask.fromAgent, to: target, tier: currentTask.tier, prompt: currentTask.prompt,
                    files: currentTask.files, hop: hop + 1, force: true,
                    verification: currentTask.verification, gate: currentTask.gate
                )
            } catch {
                NSLog("[linkC relay] checkLimitsAndReroute: task %@ cancel/hop %d copy — %@", currentTask.shortId, hop + 1, String(describing: error))
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

/// The run `launchVerifications` starts: the gate at base, or verification at the reported sha.
private enum VerificationRun: Sendable {
    case gate(Verification)
    case verify(Verification, sha: String)
}

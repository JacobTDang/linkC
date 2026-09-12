import Foundation

/// Task Protocol v2 relay: delivers tasks to exactly one assignee, relays short kind-tagged
/// messages, and expires what can no longer be delivered. Never reads terminal output.
extension AppCoordinator {
    /// Queued tasks older than this are expired rather than delivered.
    static let queuedTaskExpiry: TimeInterval = 60 * 60
    /// Verification runs in flight across all workspaces; each is a full build and test run.
    static let maxConcurrentVerifications = 2

    /// One relay tick for `workspacePath`: expire, deliver tasks, deliver messages, verify.
    public func processPendingMessages(workspacePath: String) {
        let norm = (workspacePath as NSString).standardizingPath
        let inboxStore = InboxStore(workspaceRoot: norm)
        expireTasks(workspacePath: norm, inboxStore: inboxStore)
        dispatchTasks(workspacePath: norm, inboxStore: inboxStore)
        dispatchMessages(workspacePath: norm, inboxStore: inboxStore)
        launchVerifications(workspacePath: norm, inboxStore: inboxStore)
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

    func expireTasks(workspacePath: String, inboxStore: InboxStore) {
        guard workspaceExists(workspacePath) else { return }
        let open: [TaskRecord]
        do {
            open = try inboxStore.openTasks()
        } catch {
            NSLog("[linkC relay] expireTasks: open tasks — %@", String(describing: error))
            return
        }
        guard !open.isEmpty else { return }
        let now = Date()

        for task in open {
            switch task.state {
            case .gating:
                if now.timeIntervalSince(task.createdAt) > Self.queuedTaskExpiry {
                    do {
                        try inboxStore.expireTask(taskId: task.id, reason: "gate did not run within 60m")
                        try echo("expired — gate did not run within 60m", for: task, inboxStore: inboxStore)
                    } catch {
                        NSLog("[linkC relay] expireTasks: task %@ stale gate — %@", task.shortId, String(describing: error))
                    }
                }
            case .queued:
                if now.timeIntervalSince(task.createdAt) > Self.queuedTaskExpiry {
                    do {
                        try inboxStore.expireTask(taskId: task.id, reason: "undelivered for 60m")
                    } catch {
                        NSLog("[linkC relay] expireTasks: task %@ stale queued — %@", task.shortId, String(describing: error))
                    }
                }
            case .delivered, .started:
                let assigneeAlive = task.assigneeSessionId.flatMap { store.session(id: $0) }.map { $0.state != .ended } ?? false
                if !assigneeAlive {
                    let reason = "assignee session ended before reporting"
                    do {
                        try inboxStore.failTask(taskId: task.id, reason: reason)
                        try echo("failed — \(reason)", for: task, inboxStore: inboxStore)
                    } catch {
                        NSLog("[linkC relay] expireTasks: task %@ dead assignee — %@", task.shortId, String(describing: error))
                    }
                } else if task.leaseExpiresAt < now {
                    do {
                        try inboxStore.expireTask(taskId: task.id, reason: "lease expired")
                        try echo("expired — lease lapsed without a report", for: task, inboxStore: inboxStore)
                    } catch {
                        NSLog("[linkC relay] expireTasks: task %@ expired lease — %@", task.shortId, String(describing: error))
                    }
                }
            case .reported:
                // A worker may exit after reporting, so only the lease applies here.
                if task.leaseExpiresAt < now {
                    do {
                        try inboxStore.expireTask(taskId: task.id, reason: "lease expired before verification")
                        try echo("expired — lease lapsed before verification", for: task, inboxStore: inboxStore)
                    } catch {
                        NSLog("[linkC relay] expireTasks: task %@ reported lease — %@", task.shortId, String(describing: error))
                    }
                }
            case .done, .failed, .cancelled, .expired:
                break
            }
        }
    }

    private func echo(_ body: String, for task: TaskRecord, inboxStore: InboxStore) throws {
        _ = try inboxStore.enqueue(
            from: task.toAgent,
            to: task.fromAgent,
            kind: .completion,
            taskId: task.id,
            body: body
        )
    }

    // MARK: - Tasks

    func dispatchTasks(workspacePath: String, inboxStore: InboxStore) {
        guard workspaceExists(workspacePath) else { return }
        let queued: [TaskRecord]
        do {
            queued = try inboxStore.openTasks().filter { $0.state == .queued }
        } catch {
            NSLog("[linkC relay] dispatchTasks: open tasks — %@", String(describing: error))
            return
        }
        guard !queued.isEmpty else { return }

        for task in queued {
            let candidates = store.sessions.filter {
                ($0.cwd as NSString).standardizingPath == workspacePath && $0.agentKind == task.toAgent
                    && $0.state != .ended && $0.id != task.fromSessionId
                    // A tiered task runs only on a session pinned to that tier. A row written
                    // before tiers has none, and keeps the pre-tier rule: any session of its kind.
                    && (task.tier == nil || $0.modelTier == task.tier)
            }
            if candidates.isEmpty {
                // Spawn now, deliver on a later tick. A CLI needs seconds to reach its prompt, and a
                // frame typed into a booting TUI is lost — the worker never sees the task. The session
                // stays `.starting` until its agent is really running: Claude's SessionStart hook, or
                // `sampleAgentStates` for every other kind.
                _ = try? spawnTeammate(in: workspacePath, agent: task.toAgent, goal: task.prompt, tier: task.tier)
                continue
            }
            guard let session = candidates.first(where: { isIdle($0.state) }) else { continue } // all busy: wait for a later tick

            do {
                try inboxStore.markTaskDelivered(taskId: task.id, sessionId: session.id)
            } catch {
                NSLog("[linkC relay] dispatchTasks: task %@ mark delivered — %@", task.shortId, String(describing: error))
                continue
            }
            terminals.sendInput(sessionId: session.id, text: Self.deliveryFrame(for: task))
            store.updateState(id: session.id, to: .working)
        }
    }

    // MARK: - Messages

    func dispatchMessages(workspacePath: String, inboxStore: InboxStore) {
        guard workspaceExists(workspacePath) else { return }
        let pending: [PendingMessage]
        do {
            pending = try inboxStore.fetchPending()
        } catch {
            NSLog("[linkC relay] dispatchMessages: fetch pending — %@", String(describing: error))
            return
        }
        guard !pending.isEmpty else { return }

        for message in pending where message.status == .queued {
            if message.kind == .notice {
                do {
                    try inboxStore.markMessageDelivered(id: message.id)
                } catch {
                    NSLog("[linkC relay] dispatchMessages: message %@ mark notice delivered — %@", message.id, String(describing: error))
                }
                continue
            }

            var target = store.sessions.first {
                ($0.cwd as NSString).standardizingPath == workspacePath && $0.agentKind == message.toAgent && $0.state != .ended
            }
            if target == nil {
                // Same rule as tasks: a just-spawned CLI cannot read its terminal yet.
                let goal: String? = message.kind == .task ? message.prompt : nil
                _ = try? spawnTeammate(in: workspacePath, agent: message.toAgent, goal: goal)
                continue
            }
            guard let session = target, isIdle(session.state) else { continue }

            terminals.sendInput(sessionId: session.id, text: message.prompt)
            if message.kind == .task { store.updateState(id: session.id, to: .working) }
            do {
                try inboxStore.markMessageDelivered(id: message.id)
            } catch {
                NSLog("[linkC relay] dispatchMessages: message %@ mark delivered — %@", message.id, String(describing: error))
            }
        }
    }

    // MARK: - Verification

    /// Settles what needs no run (reports, and a gating task with nothing to gate), then starts
    /// at most one verification run for this workspace, and at most `maxConcurrentVerifications`
    /// overall. Never blocks the main actor: the run awaits the verifier off the main actor and
    /// hops back to record the verdict.
    func launchVerifications(workspacePath: String, inboxStore: InboxStore) {
        guard workspaceExists(workspacePath) else { return }
        let open: [TaskRecord]
        do {
            open = try inboxStore.openTasks()
        } catch {
            NSLog("[linkC relay] launchVerifications: open tasks — %@", String(describing: error))
            return
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
                        try inboxStore.resolveGate(taskId: task.id, verdict: .notRun(reason: reason))
                        try echo("cancelled — \(reason)", for: task, inboxStore: inboxStore)
                    }
                } else if let verification = task.verification {
                    if task.report?.status != "done" {
                        try settle(task, reason: "worker reported failure", inboxStore: inboxStore)
                    } else if let sha = task.report?.sha {
                        runnable.append((task, .verify(verification, sha: sha)))
                    } else {
                        try settle(task, reason: "report is missing its sha", inboxStore: inboxStore)
                    }
                } else {
                    try inboxStore.acceptUnverified(taskId: task.id)
                    let line = task.report?.status == "done" ? "done (unverified)" : "failed — worker reported failure"
                    try echo(line, for: task, inboxStore: inboxStore)
                }
            } catch {
                NSLog("[linkC relay] launchVerifications: task %@ settle — %@", task.shortId, String(describing: error))
            }
        }

        guard !verificationsInFlight.contains(workspacePath),
              verificationsInFlight.count < Self.maxConcurrentVerifications,
              let (next, run) = runnable.min(by: { $0.task.createdAt < $1.task.createdAt }) else { return }

        verificationsInFlight.insert(workspacePath)
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
    }

    private func settle(_ task: TaskRecord, reason: String, inboxStore: InboxStore) throws {
        try inboxStore.adjudicate(taskId: task.id, verdict: .notRun(reason: reason))
        try echo("failed — \(reason)", for: task, inboxStore: inboxStore)
    }

    /// Records the verdict and sends the delegator its one line. A task that ended while its run
    /// was in flight rejects the transition; the verdict is logged and dropped.
    func finishVerification(of task: TaskRecord, verdict: Verdict, workspacePath: String) {
        defer { verificationsInFlight.remove(workspacePath) }
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
        guard let match = LimitDetector.detectLimit(inOutput: recentOutput, agent: session.agentKind) else { return false }

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
        candidates.sort { a, b in
            let aActive = store.sessions.contains { ($0.cwd as NSString).standardizingPath == norm && $0.agentKind == a && $0.state != .ended }
            let bActive = store.sessions.contains { ($0.cwd as NSString).standardizingPath == norm && $0.agentKind == b && $0.state != .ended }
            return aActive && !bActive
        }

        let hop = currentTask?.hop ?? 0
        guard hop < 2, let target = candidates.first else {
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
            // No task on this session: synthesize one unless a recent reroute already did.
            let recentCutoff = session.stateChangedAt.addingTimeInterval(-60)
            let alreadyRerouted: Bool
            do {
                alreadyRerouted = try inboxStore.openTasks().contains {
                    $0.fromAgent == session.agentKind && $0.toAgent == target && $0.createdAt >= recentCutoff
                }
            } catch {
                NSLog("[linkC relay] checkLimitsAndReroute: open tasks for reroute check — %@", String(describing: error))
                alreadyRerouted = false
            }
            if alreadyRerouted {
                NSLog("[linkC relay] checkLimitsAndReroute: %@ already rerouted to %@; skipping synthesis", session.agentKind.displayName, target.displayName)
            } else {
                do {
                    _ = try inboxStore.createTask(
                        from: session.agentKind, to: target,
                        prompt: "Task rerouted from \(session.agentKind.displayName) due to rate limit (\(match.matchedPattern)). Inspect .linkc/HANDOFF.md and continue.",
                        files: [], hop: hop + 1, force: true
                    )
                } catch {
                    NSLog("[linkC relay] checkLimitsAndReroute: reroute task — %@", String(describing: error))
                }
            }
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

import Foundation

/// Task Protocol v2 relay: delivers tasks to exactly one assignee, relays short kind-tagged
/// messages, and expires what can no longer be delivered. Never reads terminal output.
extension AppCoordinator {
    /// Queued tasks older than this are expired rather than delivered.
    static let queuedTaskExpiry: TimeInterval = 60 * 60

    /// One relay tick for `workspacePath`: expire, deliver tasks, deliver messages.
    public func processPendingMessages(workspacePath: String) {
        let norm = (workspacePath as NSString).standardizingPath
        let inboxStore = InboxStore(workspaceRoot: norm)
        expireTasks(workspacePath: norm, inboxStore: inboxStore)
        dispatchTasks(workspacePath: norm, inboxStore: inboxStore)
        dispatchMessages(workspacePath: norm, inboxStore: inboxStore)
    }

    func isIdle(_ state: SessionState) -> Bool {
        switch state {
        case .ready, .finished, .waitingIdle: return true
        case .working, .starting, .waitingPermission, .error, .ended: return false
        }
    }

    /// The text injected into the assignee's terminal. Composed at injection time; never stored as a message.
    static func deliveryFrame(for task: TaskRecord) -> String {
        """
        [linkC task \(task.shortId) from \(task.fromAgent.displayName)]
        \(task.prompt)

        When you begin, call linkc_start_task("\(task.id)"). When finished, call linkc_complete_task("\(task.id)", status, summary, commits, tests). Do not paste this brief into any reply.
        """
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
                    let summary = "assignee session ended before reporting"
                    do {
                        try inboxStore.completeTask(taskId: task.id, report: TaskReport(status: "failed", summary: summary))
                        try echo(
                            "failed — \(summary). linkc_get_task(\"\(task.id)\") for details.",
                            for: task,
                            inboxStore: inboxStore
                        )
                    } catch {
                        NSLog("[linkC relay] expireTasks: task %@ dead assignee — %@", task.shortId, String(describing: error))
                    }
                } else if task.leaseExpiresAt < now {
                    do {
                        try inboxStore.expireTask(taskId: task.id, reason: "lease expired")
                        try echo(
                            "expired — lease lapsed without a report. linkc_get_task(\"\(task.id)\") for details.",
                            for: task,
                            inboxStore: inboxStore
                        )
                    } catch {
                        NSLog("[linkC relay] expireTasks: task %@ expired lease — %@", task.shortId, String(describing: error))
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
                ($0.cwd as NSString).standardizingPath == workspacePath && $0.agentKind == task.toAgent && $0.state != .ended
            }
            var target = candidates.first { isIdle($0.state) }
            if target == nil && candidates.isEmpty {
                guard let spawned = try? spawnTeammate(in: workspacePath, agent: task.toAgent, goal: task.prompt) else { continue }
                store.updateState(id: spawned.id, to: .ready)
                target = store.session(id: spawned.id) ?? spawned
            }
            guard let session = target else { continue } // all busy: wait for a later tick

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
                let goal: String? = message.kind == .task ? message.prompt : nil
                guard let spawned = try? spawnTeammate(in: workspacePath, agent: message.toAgent, goal: goal) else { continue }
                store.updateState(id: spawned.id, to: .ready)
                target = store.session(id: spawned.id) ?? spawned
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
                try inboxStore.markUnreportedTurnEndNotified(taskId: task.id)
            } catch {
                NSLog("[linkC relay] relayTurnEnd: task %@ mark notified — %@", task.shortId, String(describing: error))
            }
            do {
                _ = try inboxStore.enqueue(
                    from: session.agentKind, to: task.fromAgent, kind: .completion, taskId: task.id,
                    body: "\(session.agentKind.displayName) turn ended without a report. Task remains \(task.state.rawValue); linkc_get_task(\"\(task.id)\") or linkc_cancel_task(\"\(task.id)\")."
                )
            } catch {
                NSLog("[linkC relay] relayTurnEnd: task %@ enqueue — %@", task.shortId, String(describing: error))
            }
            notified += 1
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
}

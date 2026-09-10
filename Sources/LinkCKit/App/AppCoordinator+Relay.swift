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
        guard let open = try? inboxStore.openTasks(), !open.isEmpty else { return }
        let now = Date()

        for task in open {
            switch task.state {
            case .queued:
                if now.timeIntervalSince(task.createdAt) > Self.queuedTaskExpiry {
                    try? inboxStore.expireTask(taskId: task.id, reason: "undelivered for 60m")
                }
            case .delivered, .started:
                let assigneeAlive = task.assigneeSessionId.flatMap { store.session(id: $0) }.map { $0.state != .ended } ?? false
                if !assigneeAlive {
                    let summary = "assignee session ended before reporting"
                    try? inboxStore.completeTask(taskId: task.id, report: TaskReport(status: "failed", summary: summary))
                    _ = try? inboxStore.enqueue(
                        from: task.toAgent, to: task.fromAgent, kind: .completion, taskId: task.id,
                        body: "failed — \(summary). linkc_get_task(\"\(task.id)\") for details."
                    )
                } else if task.leaseExpiresAt < now {
                    try? inboxStore.expireTask(taskId: task.id, reason: "lease expired")
                    _ = try? inboxStore.enqueue(
                        from: task.toAgent, to: task.fromAgent, kind: .completion, taskId: task.id,
                        body: "expired — lease lapsed without a report. linkc_get_task(\"\(task.id)\") for details."
                    )
                }
            case .done, .failed, .cancelled, .expired:
                break
            }
        }
    }

    // MARK: - Tasks

    func dispatchTasks(workspacePath: String, inboxStore: InboxStore) {
        guard workspaceExists(workspacePath) else { return }
        guard let queued = try? inboxStore.openTasks().filter({ $0.state == .queued }), !queued.isEmpty else { return }

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

            terminals.sendInput(sessionId: session.id, text: Self.deliveryFrame(for: task))
            store.updateState(id: session.id, to: .working)
            try? inboxStore.markTaskDelivered(taskId: task.id, sessionId: session.id)
        }
    }

    // MARK: - Messages

    func dispatchMessages(workspacePath: String, inboxStore: InboxStore) {
        guard workspaceExists(workspacePath) else { return }
        guard let pending = try? inboxStore.fetchPending(), !pending.isEmpty else { return }

        for message in pending where message.status == .queued {
            if message.kind == .notice {
                try? inboxStore.markMessageDelivered(id: message.id)
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
            try? inboxStore.markMessageDelivered(id: message.id)
        }
    }
}

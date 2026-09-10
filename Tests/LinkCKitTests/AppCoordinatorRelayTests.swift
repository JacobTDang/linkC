import XCTest
@testable import LinkCKit

final class AppCoordinatorRelayTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-relay-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private final class RecordingSink: NotificationSink, @unchecked Sendable {
        private let lock = NSLock()
        private var _deliveries: [(id: String, title: String, body: String)] = []
        var deliveries: [(id: String, title: String, body: String)] {
            lock.lock(); defer { lock.unlock() }; return _deliveries
        }
        func deliver(id: String, title: String, body: String) {
            lock.lock(); _deliveries.append((id, title, body)); lock.unlock()
        }
    }

    @MainActor
    private func makeCoordinator(
        sink: NotificationSink = RecordingSink()
    ) -> AppCoordinator {
        let scriptURL = tempDir.appendingPathComponent("mock_agent.sh")
        if !FileManager.default.fileExists(atPath: scriptURL.path) {
            let scriptContent = "#!/bin/sh\nexec /bin/cat\n"
            try? scriptContent.write(to: scriptURL, atomically: true, encoding: .utf8)
            var attrs = (try? FileManager.default.attributesOfItem(atPath: scriptURL.path)) ?? [:]
            attrs[.posixPermissions] = 0o755
            try? FileManager.default.setAttributes(attrs, ofItemAtPath: scriptURL.path)
        }

        let settingsDir = tempDir.appendingPathComponent("settings")
        try? FileManager.default.createDirectory(at: settingsDir, withIntermediateDirectories: true)
        return AppCoordinator(
            terminals: TerminalSessionManager(),
            hookServer: HookServer(port: 0),
            notifications: NotificationManager(sink: sink, now: { Date() }),
            claudePath: scriptURL.path,
            settingsDir: settingsDir,
            userSettingsURL: tempDir.appendingPathComponent("user-settings.json"),
            manifestDir: tempDir.appendingPathComponent("manifest"),
            agentPathResolver: { _ in scriptURL.path },
            isWatching: { _ in false }
        )
    }

    @MainActor
    private func waitUntil(_ predicate: @MainActor () -> Bool, iterations: Int = 100) async throws -> Bool {
        for _ in 0..<iterations {
            if predicate() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return predicate()
    }

    // MARK: - Test Cases

    /// Test 1: A queued task auto-spawns the assignee and is delivered exactly once with the v2 frame.
    @MainActor
    func testQueuedTaskAutoSpawnsAssigneeAndDeliversFramedBrief() async throws {
        let ws = tempDir.path
        let inbox = InboxStore(workspaceRoot: ws)
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "Refactor database migrations", files: ["db/migrations.sql"])

        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }

        coordinator.processPendingMessages(workspacePath: ws)

        guard let codexSession = coordinator.store.sessions.first(where: { $0.agentKind == .codex }) else {
            return XCTFail("Expected codex session to be auto-spawned")
        }
        let delivered = try XCTUnwrap(inbox.task(id: task.id))
        XCTAssertEqual(delivered.state, .delivered)
        XCTAssertEqual(delivered.assigneeSessionId, codexSession.id)
        XCTAssertNotNil(delivered.deliveredAt)

        let term = coordinator.terminals.session(id: codexSession.id)
        let echoed = try await waitUntil {
            let out = term?.recentOutput(lines: 20) ?? ""
            // Substrings kept short: the PTY may wrap long lines at the terminal width.
            return out.contains("[linkC task \(task.shortId)")
                && out.contains("Refactor database migrations")
                && out.contains("linkc_start_task")
        }
        XCTAssertTrue(echoed, "Expected framed brief in terminal")

        // Second tick must not redeliver
        coordinator.processPendingMessages(workspacePath: ws)
        XCTAssertEqual(try inbox.task(id: task.id)?.state, .delivered)
        XCTAssertEqual(coordinator.store.sessions.filter { $0.agentKind == .codex }.count, 1)
    }

    /// Test 2: Busy assignee delays the task until idle; only one session of that kind receives it.
    @MainActor
    func testBusyAssigneeDelaysTaskAndOnlyOneSessionReceivesIt() async throws {
        let ws = tempDir.path
        let inbox = InboxStore(workspaceRoot: ws)
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }

        let busy = try coordinator.newSession(cwd: ws, agent: .codex)
        coordinator.store.updateState(id: busy.id, to: .working)
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "Analyze test coverage", files: [])

        coordinator.processPendingMessages(workspacePath: ws)
        XCTAssertEqual(try inbox.task(id: task.id)?.state, .queued)

        let idle = try coordinator.newSession(cwd: ws, agent: .codex)
        coordinator.store.updateState(id: idle.id, to: .ready)
        coordinator.processPendingMessages(workspacePath: ws)

        let t = try XCTUnwrap(inbox.task(id: task.id))
        XCTAssertEqual(t.state, .delivered)
        XCTAssertEqual(t.assigneeSessionId, idle.id)
        XCTAssertEqual(coordinator.store.sessions.filter { $0.agentKind == .codex }.count, 2)
    }

    /// Test 2b: Notices are never injected; completions and peer notes are injected once.
    @MainActor
    func testNoticesAreNeverInjectedButCompletionsAre() async throws {
        let ws = tempDir.path
        let inbox = InboxStore(workspaceRoot: ws)
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }

        let claude = try coordinator.newSession(cwd: ws, agent: .claude)
        coordinator.store.updateState(id: claude.id, to: .ready)

        let notice = try inbox.enqueue(from: .codex, to: .claude, kind: .notice, body: "Codex is rate limited")
        let echo = try inbox.enqueue(from: .codex, to: .claude, kind: .completion, taskId: "abcdef12-0000", body: "done by Codex — shipped")

        coordinator.processPendingMessages(workspacePath: ws)

        let loaded = try inbox.load()
        XCTAssertEqual(loaded.messages.first { $0.id == notice.id }?.status, .delivered)
        XCTAssertEqual(loaded.messages.first { $0.id == echo.id }?.status, .delivered)

        let out = try await waitUntil {
            coordinator.terminals.session(id: claude.id)?.recentOutput(lines: 20).contains("[linkC task abcdef12] done by Codex") ?? false
        }
        XCTAssertTrue(out)
        let noticeLeaked = coordinator.terminals.session(id: claude.id)?.recentOutput(lines: 20).contains("rate limited") ?? false
        XCTAssertFalse(noticeLeaked, "notice text must never reach a terminal")
    }

    /// Test 2c: Expiry rules — stale queue and dead assignee.
    @MainActor
    func testExpireTasksForStaleQueueAndDeadAssignee() async throws {
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }

        // Stale queue
        let ws2 = tempDir.appendingPathComponent("ws2").path
        let inbox2 = InboxStore(workspaceRoot: ws2)
        let t2 = try inbox2.createTask(from: .claude, to: .codex, prompt: "stale", files: [])
        var seeded = try inbox2.load()
        seeded.tasks[0] = TaskRecord(
            id: t2.id, fromAgent: .claude, toAgent: .codex, prompt: "stale", state: .queued,
            createdAt: Date().addingTimeInterval(-61 * 60)
        )
        try inbox2.saveRaw(seeded)
        coordinator.processPendingMessages(workspacePath: ws2)
        let stale = try XCTUnwrap(inbox2.task(id: t2.id))
        XCTAssertEqual(stale.state, .expired)
        XCTAssertEqual(stale.cancelReason, "undelivered for 60m")
        XCTAssertTrue(coordinator.store.sessions.isEmpty, "expired task must not spawn an assignee")

        // Dead assignee
        let ws3 = tempDir.appendingPathComponent("ws3").path
        try FileManager.default.createDirectory(atPath: ws3, withIntermediateDirectories: true)
        let inbox3 = InboxStore(workspaceRoot: ws3)
        let t3 = try inbox3.createTask(from: .claude, to: .codex, prompt: "started then died", files: [])
        try inbox3.markTaskDelivered(taskId: t3.id, sessionId: "no-such-session")
        try inbox3.markTaskStarted(taskId: t3.id)
        coordinator.processPendingMessages(workspacePath: ws3)
        let dead = try XCTUnwrap(inbox3.task(id: t3.id))
        XCTAssertEqual(dead.state, .failed)
        XCTAssertEqual(dead.report?.summary, "assignee session ended before reporting")
        let echo = try XCTUnwrap(inbox3.load().messages.first { $0.taskId == t3.id })
        XCTAssertEqual(echo.kind, .completion)
        XCTAssertEqual(echo.toAgent, .claude)
        XCTAssertTrue(echo.prompt.contains("failed"))
    }

    @MainActor
    func testExpireTasksDoesNotEchoWhenTransitionAlreadyTerminal() throws {
        let ws = tempDir.path
        let inbox = InboxStore(workspaceRoot: ws)
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }

        let assignee = try coordinator.newSession(cwd: ws, agent: .codex)
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "race completion", files: [])
        try inbox.markTaskDelivered(taskId: task.id, sessionId: assignee.id)
        let staleOpenRecord = try XCTUnwrap(inbox.task(id: task.id))
        try inbox.completeTask(
            taskId: task.id,
            report: TaskReport(status: "done", summary: "completed by another process")
        )
        coordinator.store.updateState(id: assignee.id, to: .ended)

        // Preserve the stale delivered snapshot that expireTasks could have read immediately
        // before the other process completed the authoritative record.
        var seeded = try inbox.load()
        seeded.tasks.append(staleOpenRecord)
        try inbox.saveRaw(seeded)

        coordinator.expireTasks(workspacePath: ws, inboxStore: inbox)

        XCTAssertEqual(try inbox.task(id: task.id)?.state, .done)
        let falseEcho = try inbox.load().messages.first {
            $0.kind == .completion
                && $0.taskId == task.id
                && $0.prompt.contains("assignee session ended")
        }
        XCTAssertNil(falseEcho)
    }

    @MainActor
    func testDispatchTasksMarksDeliveredAndInjectsFrame() async throws {
        let ws = tempDir.path
        let inbox = InboxStore(workspaceRoot: ws)
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }

        let assignee = try coordinator.newSession(cwd: ws, agent: .codex)
        coordinator.store.updateState(id: assignee.id, to: .ready)
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "ordering guard", files: [])

        coordinator.dispatchTasks(workspacePath: ws, inboxStore: inbox)

        XCTAssertEqual(try inbox.task(id: task.id)?.state, .delivered)
        let injected = try await waitUntil {
            coordinator.terminals.session(id: assignee.id)?
                .recentOutput(lines: 20)
                .contains("[linkC task \(task.shortId)") ?? false
        }
        XCTAssertTrue(injected, "Expected the framed task after it was marked delivered")
    }

    /// Test 2d: Legacy v1 `.task` rows are still dispatched once.
    @MainActor
    func testLegacyV1TaskMessageIsStillDispatched() async throws {
        let ws = tempDir.path
        let inbox = InboxStore(workspaceRoot: ws)
        var seeded = Inbox(workspacePath: ws)
        seeded.messages = [PendingMessage(id: "legacy-1", fromAgent: .claude, toAgent: .codex, prompt: "Old style brief", status: .queued, kind: .task)]
        try inbox.saveRaw(seeded)

        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }
        coordinator.processPendingMessages(workspacePath: ws)

        XCTAssertEqual(try inbox.load().messages.first?.status, .delivered)
        let codex = try XCTUnwrap(coordinator.store.sessions.first { $0.agentKind == .codex })
        let echoed = try await waitUntil {
            coordinator.terminals.session(id: codex.id)?.recentOutput(lines: 10).contains("Old style brief") ?? false
        }
        XCTAssertTrue(echoed)
    }

    /// Test 2e: A tick for a workspace that no longer exists spawns nothing and does not recreate the directory.
    @MainActor
    func testMissingWorkspaceTickSpawnsNothingAndDoesNotRecreateDirectory() throws {
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }
        let ws = tempDir.appendingPathComponent("vanishing").path
        let inbox = InboxStore(workspaceRoot: ws)
        _ = try inbox.createTask(from: .claude, to: .codex, prompt: "brief", files: [])
        try FileManager.default.removeItem(atPath: ws)

        coordinator.processPendingMessages(workspacePath: ws)

        XCTAssertTrue(coordinator.store.sessions.isEmpty, "nothing may be spawned for a missing workspace")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ws), "relay must not recreate a deleted workspace")
    }

    /// Test 3: Rate limit detection triggers re-routing to peer agent with handoff memo.
    @MainActor
    func testRateLimitDetectionTriggersRerouteToPeerAgentWithHandoff() async throws {
        let ws = tempDir.path
        let inbox = InboxStore(workspaceRoot: ws)
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }

        // Spawn source session for claude
        let sourceSession = try coordinator.newSession(cwd: ws, agent: .claude)
        coordinator.store.updateState(id: sourceSession.id, to: .working)

        // Seed initial message that claude was working on
        let initialMsg = try inbox.enqueue(
            from: .cursor,
            to: .claude,
            prompt: "Build high-throughput streaming proxy",
            files: ["Proxy.swift"]
        )
        try inbox.markMessageDelivered(id: initialMsg.id)

        // Inject rate limit pattern into source session's terminal via /bin/cat echo
        coordinator.terminals.sendInput(sessionId: sourceSession.id, text: "Rate limit reached. Please try again later.\n")

        // Allow /bin/cat PTY time to echo the line into terminal buffer
        let outputReady = try await waitUntil {
            coordinator.terminals.session(id: sourceSession.id)?.recentOutput(lines: 10).contains("Rate limit reached") ?? false
        }
        XCTAssertTrue(outputReady)

        // Trigger checkLimitsAndReroute
        let rerouted = coordinator.checkLimitsAndReroute(for: sourceSession.id)
        XCTAssertTrue(rerouted, "Rate limit should have been detected and rerouted")

        // 1. Limit recorded in inbox store
        let limitStatus = try inbox.isAgentLimited(agent: .claude)
        XCTAssertNotNil(limitStatus)
        XCTAssertEqual(limitStatus?.agent, .claude)

        // 2. Handoff memo written to disk
        let handoffURL = URL(fileURLWithPath: ws).appendingPathComponent(".linkc/HANDOFF.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: handoffURL.path), "HANDOFF.md must be written")
        let handoffContent = try String(contentsOf: handoffURL, encoding: .utf8)
        XCTAssertTrue(handoffContent.contains("Build high-throughput streaming proxy"))

        // 3. New message enqueued for peer agent with rerouteCount == 1
        let loaded = try inbox.load()
        guard let reroutedMsg = loaded.messages.first(where: { $0.fromAgent == .claude && $0.rerouteCount == 1 }) else {
            return XCTFail("Expected rerouted message from claude")
        }
        XCTAssertNotEqual(reroutedMsg.toAgent, .claude)
        XCTAssertNotEqual(reroutedMsg.toAgent, .shell)
        XCTAssertEqual(reroutedMsg.rerouteCount, 1)

        // 4. Candidate peer session was spawned
        let peerSession = coordinator.store.sessions.first(where: { $0.agentKind == reroutedMsg.toAgent })
        XCTAssertNotNil(peerSession, "Candidate peer session should be auto-spawned")
    }

    /// Test 4: Circuit breaker stops re-route after 2 hops and posts an alert notification.
    @MainActor
    func testCircuitBreakerStopsRerouteAfterTwoHops() async throws {
        let ws = tempDir.path
        let inbox = InboxStore(workspaceRoot: ws)
        let sink = RecordingSink()
        let coordinator = makeCoordinator(sink: sink)
        defer { coordinator.shutdown() }

        let session = try coordinator.newSession(cwd: ws, agent: .claude)
        coordinator.store.updateState(id: session.id, to: .working)

        // Seed task that has already reached 2 hops (rerouteCount == 2)
        let hop2Msg = try inbox.enqueue(
            from: .codex,
            to: .claude,
            prompt: "Complex distributed algorithm",
            files: [],
            rerouteCount: 2
        )
        try inbox.markMessageDelivered(id: hop2Msg.id)

        // Inject rate limit pattern
        coordinator.terminals.sendInput(sessionId: session.id, text: "You've reached your usage limit\n")
        let outputReady = try await waitUntil {
            coordinator.terminals.session(id: session.id)?.recentOutput(lines: 10).contains("reached your usage limit") ?? false
        }
        XCTAssertTrue(outputReady)

        // Check limits and attempt reroute
        _ = coordinator.checkLimitsAndReroute(for: session.id)

        // Limit is recorded
        let limitStatus = try inbox.isAgentLimited(agent: .claude)
        XCTAssertNotNil(limitStatus)

        // Circuit breaker tripped: NO 3rd hop message added to inbox
        let loaded = try inbox.load()
        let messagesAfter = loaded.messages
        XCTAssertFalse(messagesAfter.contains(where: { $0.rerouteCount > 2 }), "Circuit breaker must prevent enqueuing a 3rd hop message")
        XCTAssertTrue(messagesAfter.contains(where: { $0.fromAgent == .claude && $0.toAgent == .codex && $0.prompt.hasPrefix("[System Notice]") }), "Notice message should be sent to delegating agent")

        // Notification posted
        XCTAssertTrue(sink.deliveries.contains(where: {
            $0.title == "linkC: Swarm Rate Limited" && $0.body.contains("Pausing auto-delegation")
        }), "Alert notification should be posted when circuit breaker trips")

        // No extra sessions spawned
        XCTAssertEqual(coordinator.store.sessions.count, 1)
    }

    /// Test 5: Stop hook and session start hook trigger pending message processing.
    @MainActor
    func testHookStopTriggersPendingMessageProcessing() async throws {
        let ws = tempDir.path
        let inbox = InboxStore(workspaceRoot: ws)
        let coordinator = makeCoordinator()
        try coordinator.start()
        defer { coordinator.shutdown() }

        let session = try coordinator.newSession(cwd: ws, agent: .claude)

        // Enqueue message to claude
        _ = try inbox.enqueue(
            from: .codex,
            to: .claude,
            prompt: "Review PR #42",
            files: []
        )

        // Session starts in .working
        coordinator.store.updateState(id: session.id, to: .working)

        // Simulate stop hook event
        coordinator.handle(HookEvent(kind: .stop, linkcSessionId: session.id, claudeSessionId: "c1", cwd: ws))

        // State is now finished, and processPendingMessages should have been triggered by .stop hook
        let delivered = try await waitUntil {
            (try? inbox.fetchPending().isEmpty) ?? false
        }
        XCTAssertTrue(delivered, "Stop hook should have triggered pending message delivery")
    }

    /// Test 6: sampleAgentStates preserves .error state when rate limit is detected on a non-Claude session.
    @MainActor
    func testSampleAgentStatesPreservesErrorStateOnRateLimit() async throws {
        let ws = tempDir.path
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }

        // Create a non-Claude session in .working state
        let session = try coordinator.newSession(cwd: ws, agent: .codex)
        coordinator.store.updateState(id: session.id, to: .working)

        // Inject rate limit pattern into terminal buffer
        coordinator.terminals.sendInput(sessionId: session.id, text: "429 Too Many Requests\n")
        let outputReady = try await waitUntil {
            coordinator.terminals.session(id: session.id)?.recentOutput(lines: 10).contains("429 Too Many Requests") ?? false
        }
        XCTAssertTrue(outputReady)

        // Run sampleAgentStates (which runs rate limit check then activity check in same tick)
        coordinator.sampleAgentStates()

        // Verify the store state remains .error and was not overwritten back to .finished
        let updatedSession = coordinator.store.session(id: session.id)
        XCTAssertEqual(updatedSession?.state, .error, "Session state must remain .error and not be overwritten to .finished")
    }

    /// Test 7: checkLimitsAndReroute scopes alreadyRerouted check to current task and does not abort on old history.
    @MainActor
    func testCheckLimitsAndRerouteScopesAlreadyReroutedCheckToCurrentTask() async throws {
        let ws = tempDir.path
        let inbox = InboxStore(workspaceRoot: ws)
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }

        // Seed an OLD historical message that was previously rerouted by .claude in this workspace
        let oldReroutedMsg = try inbox.enqueue(
            from: .claude,
            to: .cursor,
            prompt: "Old task from yesterday",
            files: [],
            rerouteCount: 1
        )
        // Ensure its createdAt is in the past
        let pastDate = Date().addingTimeInterval(-3600)
        var loaded = try inbox.load()
        if let idx = loaded.messages.firstIndex(where: { $0.id == oldReroutedMsg.id }) {
            loaded.messages[idx] = PendingMessage(
                id: oldReroutedMsg.id,
                fromAgent: oldReroutedMsg.fromAgent,
                toAgent: oldReroutedMsg.toAgent,
                prompt: oldReroutedMsg.prompt,
                claimedFiles: oldReroutedMsg.claimedFiles,
                status: .delivered,
                rerouteCount: oldReroutedMsg.rerouteCount,
                createdAt: pastDate,
                deliveredAt: pastDate
            )
            let data = try JSONEncoder().encode(loaded)
            let inboxURL = URL(fileURLWithPath: ws).appendingPathComponent(".linkc/inbox.json")
            try data.write(to: inboxURL)
        }

        // Spawn claude session
        let claudeSession = try coordinator.newSession(cwd: ws, agent: .claude)
        coordinator.store.updateState(id: claudeSession.id, to: .working)

        // Enqueue a NEW task for claude
        let newMsg = try inbox.enqueue(
            from: .codex,
            to: .claude,
            prompt: "New fresh task to run",
            files: ["Fresh.swift"]
        )
        try inbox.markMessageDelivered(id: newMsg.id)

        // Inject rate limit pattern
        coordinator.terminals.sendInput(sessionId: claudeSession.id, text: "Rate limit reached. Try later.\n")
        let outputReady = try await waitUntil {
            coordinator.terminals.session(id: claudeSession.id)?.recentOutput(lines: 10).contains("Rate limit reached") ?? false
        }
        XCTAssertTrue(outputReady)

        // Check limits and reroute - must NOT be blocked by the old historical rerouted message
        let rerouted = coordinator.checkLimitsAndReroute(for: claudeSession.id)
        XCTAssertTrue(rerouted, "Should reroute the new task despite old historical reroute message")

        // Verify new rerouted message was enqueued for peer
        let updatedInbox = try inbox.load()
        let newRerouted = updatedInbox.messages.first {
            $0.fromAgent == .claude && $0.prompt == "New fresh task to run"
        }
        XCTAssertNotNil(newRerouted, "New task should have been rerouted")
        XCTAssertEqual(newRerouted?.rerouteCount, 1)
    }

    /// Test 8: checkLimitsAndReroute skips uninstalled candidate agents in favor of installed ones.
    @MainActor
    func testCheckLimitsAndRerouteSkipsUninstalledCandidateAgents() async throws {
        let ws = tempDir.path
        let scriptURL = tempDir.appendingPathComponent("mock_agent.sh")
        if !FileManager.default.fileExists(atPath: scriptURL.path) {
            let scriptContent = "#!/bin/sh\nexec /bin/cat\n"
            try? scriptContent.write(to: scriptURL, atomically: true, encoding: .utf8)
            var attrs = (try? FileManager.default.attributesOfItem(atPath: scriptURL.path)) ?? [:]
            attrs[.posixPermissions] = 0o755
            try? FileManager.default.setAttributes(attrs, ofItemAtPath: scriptURL.path)
        }

        let settingsDir = tempDir.appendingPathComponent("settings_uninstalled_test")
        try? FileManager.default.createDirectory(at: settingsDir, withIntermediateDirectories: true)

        // Create coordinator where .codex is NOT installed (returns nil), but .agy IS installed
        let coordinator = AppCoordinator(
            terminals: TerminalSessionManager(),
            hookServer: HookServer(port: 0),
            notifications: NotificationManager(sink: RecordingSink(), now: { Date() }),
            claudePath: scriptURL.path,
            settingsDir: settingsDir,
            userSettingsURL: tempDir.appendingPathComponent("user-settings.json"),
            manifestDir: tempDir.appendingPathComponent("manifest_uninstalled_test"),
            agentPathResolver: { kind in
                // Simulate .codex being uninstalled on this machine
                if kind == .codex { return nil }
                return scriptURL.path
            },
            isWatching: { _ in false }
        )
        defer { coordinator.shutdown() }

        let inbox = InboxStore(workspaceRoot: ws)
        let claudeSession = try coordinator.newSession(cwd: ws, agent: .claude)
        coordinator.store.updateState(id: claudeSession.id, to: .working)

        let msg = try inbox.enqueue(
            from: .cursor,
            to: .claude,
            prompt: "Deploy service mesh",
            files: []
        )
        try inbox.markMessageDelivered(id: msg.id)

        coordinator.terminals.sendInput(sessionId: claudeSession.id, text: "Rate limit reached\n")
        let outputReady = try await waitUntil {
            coordinator.terminals.session(id: claudeSession.id)?.recentOutput(lines: 10).contains("Rate limit reached") ?? false
        }
        XCTAssertTrue(outputReady)

        let rerouted = coordinator.checkLimitsAndReroute(for: claudeSession.id)
        XCTAssertTrue(rerouted)

        // Verify that .codex was skipped and .agy was chosen as the target candidate
        let loaded = try inbox.load()
        guard let reroutedMsg = loaded.messages.first(where: { $0.fromAgent == .claude && $0.rerouteCount == 1 }) else {
            return XCTFail("Expected rerouted message")
        }
        XCTAssertEqual(reroutedMsg.toAgent, .agy, "Uninstalled .codex must be skipped; .agy must be selected")
    }

    /// Test 9: checkLimitsAndReroute ignores ended sessions.
    @MainActor
    func testCheckLimitsAndRerouteIgnoredWhenSessionIsEnded() async throws {
        let ws = tempDir.path
        let inbox = InboxStore(workspaceRoot: ws)
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }

        let claudeSession = try coordinator.newSession(cwd: ws, agent: .claude)
        // Transition session to .ended
        coordinator.store.updateState(id: claudeSession.id, to: .ended)

        // Inject rate limit pattern
        coordinator.terminals.sendInput(sessionId: claudeSession.id, text: "Rate limit reached. Try later.\n")
        let outputReady = try await waitUntil {
            coordinator.terminals.session(id: claudeSession.id)?.recentOutput(lines: 10).contains("Rate limit reached") ?? false
        }
        XCTAssertTrue(outputReady)

        // Calling checkLimitsAndReroute on .ended session must return false and not record a limit
        let rerouted = coordinator.checkLimitsAndReroute(for: claudeSession.id)
        XCTAssertFalse(rerouted, "checkLimitsAndReroute must ignore ended sessions")

        let limitStatus = try inbox.isAgentLimited(agent: .claude)
        XCTAssertNil(limitStatus, "No limit should be recorded for an ended session")
    }

    /// Test 10: checkLimitsAndReroute prioritizes candidates that already have an active session in the workspace.
    @MainActor
    func testCheckLimitsAndReroutePrioritizesAgentWithActiveSessionInWorkspace() async throws {
        let ws = tempDir.path
        let inbox = InboxStore(workspaceRoot: ws)
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }

        // Spawn claude session that will be working
        let claudeSession = try coordinator.newSession(cwd: ws, agent: .claude)
        coordinator.store.updateState(id: claudeSession.id, to: .working)

        // Spawn an active cursor session in the same workspace (not codex)
        let cursorSession = try coordinator.newSession(cwd: ws, agent: .cursor)
        coordinator.store.updateState(id: cursorSession.id, to: .ready)

        let msg = try inbox.enqueue(
            from: .shell,
            to: .claude,
            prompt: "Refactor router",
            files: ["Router.swift"]
        )
        try inbox.markMessageDelivered(id: msg.id)

        coordinator.terminals.sendInput(sessionId: claudeSession.id, text: "Rate limit reached\n")
        let outputReady = try await waitUntil {
            coordinator.terminals.session(id: claudeSession.id)?.recentOutput(lines: 10).contains("Rate limit reached") ?? false
        }
        XCTAssertTrue(outputReady)

        let rerouted = coordinator.checkLimitsAndReroute(for: claudeSession.id)
        XCTAssertTrue(rerouted)

        // In supportedPeers [.claude, .codex, .agy, .cursor], .codex is ahead of .cursor.
        // But because .cursor has an active session in this workspace, candidate sorting must prioritize .cursor!
        let loaded = try inbox.load()
        guard let reroutedMsg = loaded.messages.first(where: { $0.fromAgent == .claude && $0.rerouteCount == 1 }) else {
            return XCTFail("Expected rerouted message")
        }
        XCTAssertEqual(reroutedMsg.toAgent, .cursor, "Active .cursor session in workspace must be prioritized over .codex")
    }

    /// Test 11: checkLimitsAndReroute sends reply notice to delegating agent and works when session is .finished.
    @MainActor
    func testLimitDetectionSendsReplyMessageToDelegatingAgent() async throws {
        let ws = tempDir.path
        let inbox = InboxStore(workspaceRoot: ws)
        let sink = RecordingSink()
        let coordinator = makeCoordinator(sink: sink)
        defer { coordinator.shutdown() }

        // Session A (Claude) delegates task to Session B (Codex)
        let delegatedMsg = try inbox.enqueue(
            from: .claude,
            to: .codex,
            prompt: "Optimize database indices",
            files: ["schema.sql"]
        )
        try inbox.markMessageDelivered(id: delegatedMsg.id)

        // Spawn Codex session and transition it to .finished (simulating turn end hook)
        let codexSession = try coordinator.newSession(cwd: ws, agent: .codex)
        coordinator.store.updateState(id: codexSession.id, to: .finished)

        // Inject rate limit pattern into Codex session output
        coordinator.terminals.sendInput(sessionId: codexSession.id, text: "429 Too Many Requests\n")
        let outputReady = try await waitUntil {
            coordinator.terminals.session(id: codexSession.id)?.recentOutput(lines: 10).contains("429 Too Many Requests") ?? false
        }
        XCTAssertTrue(outputReady)

        // Trigger limit check (session state is .finished)
        let detected = coordinator.checkLimitsAndReroute(for: codexSession.id)
        XCTAssertTrue(detected, "Limit check must succeed even when session state is .finished")

        // Assert that inboxStore receives a notice message addressed to Claude from Codex reporting the limit
        let loaded = try inbox.load()
        guard let notice = loaded.messages.first(where: {
            $0.fromAgent == .codex && $0.toAgent == .claude && $0.prompt.hasPrefix("[System Notice]")
        }) else {
            return XCTFail("Expected system notice message addressed to Claude from Codex")
        }

        XCTAssertTrue(notice.prompt.contains("Codex reached usage limit: '429 Too Many Requests'"))
        XCTAssertTrue(notice.prompt.contains("Free fallback model"))
        XCTAssertTrue(notice.prompt.contains("Task paused."))
        XCTAssertEqual(notice.claimedFiles, ["schema.sql"])

        // Assert desktop notification was posted explaining the limit and fallback
        XCTAssertTrue(sink.deliveries.contains(where: {
            $0.title == "linkC: Codex Rate Limited" && $0.body.contains("429 Too Many Requests")
        }), "Desktop notification should be posted for Codex rate limit")
    }

    /// Test 12: Turn end without a report sends exactly one short line, never scrollback, and never loops.
    @MainActor
    func testTurnEndWithoutReportSendsOneLineOncePerTaskAndNeverScrapes() async throws {
        let ws = tempDir.path
        let inbox = InboxStore(workspaceRoot: ws)
        let sink = RecordingSink()
        let coordinator = makeCoordinator(sink: sink)
        defer { coordinator.shutdown() }

        let cursorSession = try coordinator.newSession(cwd: ws, agent: .cursor)
        let task = try inbox.createTask(from: .claude, to: .cursor, prompt: "Build user authentication module", files: ["Auth.swift"])
        try inbox.markTaskDelivered(taskId: task.id, sessionId: cursorSession.id)
        coordinator.store.updateState(id: cursorSession.id, to: .working)

        coordinator.terminals.sendInput(sessionId: cursorSession.id, text: "Generated Auth.swift with 5 tests passing.\n")
        _ = try await waitUntil {
            coordinator.terminals.session(id: cursorSession.id)?.recentOutput(lines: 10).contains("Generated Auth.swift") ?? false
        }

        XCTAssertEqual(coordinator.relayTurnEnd(sessionId: cursorSession.id, workspacePath: ws), 1)
        XCTAssertEqual(coordinator.relayTurnEnd(sessionId: cursorSession.id, workspacePath: ws), 0, "second turn end must not notify again")

        let msgs = try inbox.load().messages
        XCTAssertEqual(msgs.count, 1)
        let line = try XCTUnwrap(msgs.first)
        XCTAssertEqual(line.kind, .completion)
        XCTAssertEqual(line.fromAgent, .cursor)
        XCTAssertEqual(line.toAgent, .claude)
        XCTAssertEqual(line.taskId, task.id)
        XCTAssertTrue(line.prompt.hasPrefix("[linkC task \(task.shortId)] Cursor Agent turn ended without a report"))
        XCTAssertFalse(line.prompt.contains("Generated Auth.swift"), "terminal output must never be relayed")
        XCTAssertFalse(line.prompt.contains("Build user authentication module"), "brief must not be echoed")

        XCTAssertEqual(try inbox.task(id: task.id)?.state, .delivered, "task stays open for the delegator to decide")
        XCTAssertTrue(sink.deliveries.contains { $0.title == "linkC: Cursor Agent turn ended" })
    }

    /// Test 12b: A completion message delivered to the delegator is never treated as a task and never re-echoed.
    @MainActor
    func testCompletionEchoIsNeverReEchoed() throws {
        let ws = tempDir.path
        let inbox = InboxStore(workspaceRoot: ws)
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }

        let claude = try coordinator.newSession(cwd: ws, agent: .claude)
        coordinator.store.updateState(id: claude.id, to: .ready)
        let echo = try inbox.enqueue(from: .codex, to: .claude, kind: .completion, taskId: "abcdef12-0000", body: "done by Codex — shipped")
        coordinator.processPendingMessages(workspacePath: ws)
        XCTAssertEqual(try inbox.load().messages.first { $0.id == echo.id }?.status, .delivered)

        coordinator.store.updateState(id: claude.id, to: .working)
        XCTAssertEqual(coordinator.relayTurnEnd(sessionId: claude.id, workspacePath: ws), 0)
        XCTAssertEqual(try inbox.load().messages.count, 1, "no new message may be produced from an echo")
    }

    /// Test 12c: Explicit completion before turn end means no 'ended without report' line.
    @MainActor
    func testExplicitCompletionSuppressesTurnEndLine() throws {
        let ws = tempDir.path
        let inbox = InboxStore(workspaceRoot: ws)
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }

        let codex = try coordinator.newSession(cwd: ws, agent: .codex)
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "Do it", files: [])
        try inbox.markTaskDelivered(taskId: task.id, sessionId: codex.id)
        try inbox.markTaskStarted(taskId: task.id)
        try inbox.completeTask(taskId: task.id, report: TaskReport(status: "done", summary: "ok"))

        XCTAssertEqual(coordinator.relayTurnEnd(sessionId: codex.id, workspacePath: ws), 0)
        XCTAssertTrue(try inbox.load().messages.isEmpty)
    }
}

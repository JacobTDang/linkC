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

    /// Test 3: Rate limit on a started task cancels it, writes the handoff with the task's brief, and creates a hop+1 task.
    @MainActor
    func testRateLimitCancelsOriginalTaskWritesHandoffAndCreatesHopOneTask() async throws {
        let ws = tempDir.path
        let inbox = InboxStore(workspaceRoot: ws)
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }

        let sourceSession = try coordinator.newSession(cwd: ws, agent: .claude)
        coordinator.store.updateState(id: sourceSession.id, to: .working)
        let original = try inbox.createTask(from: .cursor, to: .claude, prompt: "Build high-throughput streaming proxy", files: ["Proxy.swift"])
        try inbox.markTaskDelivered(taskId: original.id, sessionId: sourceSession.id)
        try inbox.markTaskStarted(taskId: original.id)

        coordinator.terminals.sendInput(sessionId: sourceSession.id, text: "Rate limit reached. Please try again later.\n")
        let outputReady = try await waitUntil {
            coordinator.terminals.session(id: sourceSession.id)?.recentOutput(lines: 10).contains("Rate limit reached") ?? false
        }
        XCTAssertTrue(outputReady)

        XCTAssertTrue(coordinator.checkLimitsAndReroute(for: sourceSession.id))
        XCTAssertNotNil(try inbox.isAgentLimited(agent: .claude))

        let cancelled = try XCTUnwrap(inbox.task(id: original.id))
        XCTAssertEqual(cancelled.state, .cancelled)
        XCTAssertTrue(cancelled.cancelReason?.hasPrefix("rerouted to") ?? false)

        let handoff = try String(contentsOf: URL(fileURLWithPath: ws).appendingPathComponent(".linkc/HANDOFF.md"), encoding: .utf8)
        XCTAssertTrue(handoff.contains("Build high-throughput streaming proxy"))
        XCTAssertFalse(handoff.contains("[linkC task"), "handoff goal must be the brief, never a frame")

        let copy = try XCTUnwrap(inbox.openTasks().first { $0.hop == 1 })
        XCTAssertEqual(copy.fromAgent, .cursor, "delegator is preserved across hops")
        XCTAssertNotEqual(copy.toAgent, .claude)
        XCTAssertEqual(copy.prompt, original.prompt)
        XCTAssertEqual(copy.files, ["Proxy.swift"])
        XCTAssertNotNil(coordinator.store.sessions.first { $0.agentKind == copy.toAgent })

        let notice = try XCTUnwrap(inbox.load().messages.first { $0.kind == .notice })
        XCTAssertEqual(notice.toAgent, .cursor)
        XCTAssertTrue(notice.prompt.hasPrefix("[linkC notice]"))
        XCTAssertTrue(notice.prompt.contains("reached usage limit"))
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
        let hop2 = try inbox.createTask(from: .codex, to: .claude, prompt: "Complex distributed algorithm", files: [], hop: 2)
        try inbox.markTaskDelivered(taskId: hop2.id, sessionId: session.id)

        coordinator.terminals.sendInput(sessionId: session.id, text: "You've reached your usage limit\n")
        let outputReady = try await waitUntil {
            coordinator.terminals.session(id: session.id)?.recentOutput(lines: 10).contains("reached your usage limit") ?? false
        }
        XCTAssertTrue(outputReady)

        _ = coordinator.checkLimitsAndReroute(for: session.id)

        XCTAssertNotNil(try inbox.isAgentLimited(agent: .claude))
        XCTAssertFalse(try inbox.load().tasks.contains { $0.hop > 2 })
        XCTAssertEqual(try inbox.task(id: hop2.id)?.state, .delivered, "breaker leaves the task for the delegator")
        XCTAssertTrue(try inbox.load().messages.contains { $0.kind == .notice && $0.toAgent == .codex })
        XCTAssertTrue(sink.deliveries.contains { $0.title == "linkC: Swarm Rate Limited" && $0.body.contains("Pausing auto-delegation") })
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

    /// Test 7: Old cancelled/rerouted history does not block rerouting the current task.
    @MainActor
    func testRerouteIsScopedToCurrentTaskNotHistory() async throws {
        let ws = tempDir.path
        let inbox = InboxStore(workspaceRoot: ws)
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }

        let old = try inbox.createTask(from: .claude, to: .cursor, prompt: "Old task from yesterday", files: [], hop: 1)
        try inbox.cancelTask(taskId: old.id, reason: "rerouted to Codex after limit")

        let claudeSession = try coordinator.newSession(cwd: ws, agent: .claude)
        coordinator.store.updateState(id: claudeSession.id, to: .working)
        let fresh = try inbox.createTask(from: .codex, to: .claude, prompt: "New fresh task to run", files: ["Fresh.swift"])
        try inbox.markTaskDelivered(taskId: fresh.id, sessionId: claudeSession.id)

        coordinator.terminals.sendInput(sessionId: claudeSession.id, text: "Rate limit reached. Try later.\n")
        let outputReady = try await waitUntil {
            coordinator.terminals.session(id: claudeSession.id)?.recentOutput(lines: 10).contains("Rate limit reached") ?? false
        }
        XCTAssertTrue(outputReady)

        XCTAssertTrue(coordinator.checkLimitsAndReroute(for: claudeSession.id))
        let copy = try XCTUnwrap(inbox.openTasks().first { $0.prompt == "New fresh task to run" })
        XCTAssertEqual(copy.hop, 1)
        XCTAssertEqual(try inbox.task(id: fresh.id)?.state, .cancelled)
    }

    /// Test 8: Uninstalled candidates are skipped.
    @MainActor
    func testCheckLimitsAndRerouteSkipsUninstalledCandidateAgents() async throws {
        let ws = tempDir.path
        let scriptURL = tempDir.appendingPathComponent("mock_agent.sh")
        if !FileManager.default.fileExists(atPath: scriptURL.path) {
            try? "#!/bin/sh\nexec /bin/cat\n".write(to: scriptURL, atomically: true, encoding: .utf8)
            var attrs = (try? FileManager.default.attributesOfItem(atPath: scriptURL.path)) ?? [:]
            attrs[.posixPermissions] = 0o755
            try? FileManager.default.setAttributes(attrs, ofItemAtPath: scriptURL.path)
        }
        let settingsDir = tempDir.appendingPathComponent("settings_uninstalled_test")
        try? FileManager.default.createDirectory(at: settingsDir, withIntermediateDirectories: true)
        let coordinator = AppCoordinator(
            terminals: TerminalSessionManager(),
            hookServer: HookServer(port: 0),
            notifications: NotificationManager(sink: RecordingSink(), now: { Date() }),
            claudePath: scriptURL.path,
            settingsDir: settingsDir,
            userSettingsURL: tempDir.appendingPathComponent("user-settings.json"),
            manifestDir: tempDir.appendingPathComponent("manifest_uninstalled_test"),
            agentPathResolver: { kind in kind == .codex ? nil : scriptURL.path },
            isWatching: { _ in false }
        )
        defer { coordinator.shutdown() }

        let inbox = InboxStore(workspaceRoot: ws)
        let claudeSession = try coordinator.newSession(cwd: ws, agent: .claude)
        coordinator.store.updateState(id: claudeSession.id, to: .working)
        let task = try inbox.createTask(from: .cursor, to: .claude, prompt: "Deploy service mesh", files: [])
        try inbox.markTaskDelivered(taskId: task.id, sessionId: claudeSession.id)

        coordinator.terminals.sendInput(sessionId: claudeSession.id, text: "Rate limit reached\n")
        let outputReady = try await waitUntil {
            coordinator.terminals.session(id: claudeSession.id)?.recentOutput(lines: 10).contains("Rate limit reached") ?? false
        }
        XCTAssertTrue(outputReady)

        XCTAssertTrue(coordinator.checkLimitsAndReroute(for: claudeSession.id))
        let copy = try XCTUnwrap(inbox.openTasks().first { $0.hop == 1 })
        XCTAssertEqual(copy.toAgent, .agy, "Uninstalled .codex must be skipped; .agy must be selected")
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

    /// Test 10: Candidates with an active session in the workspace are preferred.
    @MainActor
    func testCheckLimitsAndReroutePrioritizesAgentWithActiveSessionInWorkspace() async throws {
        let ws = tempDir.path
        let inbox = InboxStore(workspaceRoot: ws)
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }

        let claudeSession = try coordinator.newSession(cwd: ws, agent: .claude)
        coordinator.store.updateState(id: claudeSession.id, to: .working)
        let cursorSession = try coordinator.newSession(cwd: ws, agent: .cursor)
        coordinator.store.updateState(id: cursorSession.id, to: .ready)

        let task = try inbox.createTask(from: .shell, to: .claude, prompt: "Refactor router", files: ["Router.swift"])
        try inbox.markTaskDelivered(taskId: task.id, sessionId: claudeSession.id)

        coordinator.terminals.sendInput(sessionId: claudeSession.id, text: "Rate limit reached\n")
        let outputReady = try await waitUntil {
            coordinator.terminals.session(id: claudeSession.id)?.recentOutput(lines: 10).contains("Rate limit reached") ?? false
        }
        XCTAssertTrue(outputReady)

        XCTAssertTrue(coordinator.checkLimitsAndReroute(for: claudeSession.id))
        let copy = try XCTUnwrap(inbox.openTasks().first { $0.hop == 1 })
        XCTAssertEqual(copy.toAgent, .cursor, "Active .cursor session in workspace must be prioritized over .codex")
    }

    /// Test 11: The limit alert to the delegator is a notice (never injected) and a desktop notification.
    @MainActor
    func testLimitDetectionSendsNoticeToDelegatingAgent() async throws {
        let ws = tempDir.path
        let inbox = InboxStore(workspaceRoot: ws)
        let sink = RecordingSink()
        let coordinator = makeCoordinator(sink: sink)
        defer { coordinator.shutdown() }

        let codexSession = try coordinator.newSession(cwd: ws, agent: .codex)
        coordinator.store.updateState(id: codexSession.id, to: .finished)
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "Optimize database indices", files: ["schema.sql"])
        try inbox.markTaskDelivered(taskId: task.id, sessionId: codexSession.id)

        coordinator.terminals.sendInput(sessionId: codexSession.id, text: "429 Too Many Requests\n")
        let outputReady = try await waitUntil {
            coordinator.terminals.session(id: codexSession.id)?.recentOutput(lines: 10).contains("429 Too Many Requests") ?? false
        }
        XCTAssertTrue(outputReady)

        XCTAssertTrue(coordinator.checkLimitsAndReroute(for: codexSession.id))
        let notice = try XCTUnwrap(inbox.load().messages.first { $0.kind == .notice && $0.fromAgent == .codex && $0.toAgent == .claude })
        XCTAssertTrue(notice.prompt.contains("Codex reached usage limit: '429 Too Many Requests'"))
        XCTAssertTrue(notice.prompt.contains("Free fallback model"))
        XCTAssertEqual(notice.taskId, task.id)
        XCTAssertTrue(sink.deliveries.contains { $0.title == "linkC: Codex Rate Limited" && $0.body.contains("429 Too Many Requests") })
    }

    /// Test 11b: A rerouted session is never re-processed on the next tick — the limit text is
    /// still in its buffer, but the source is `.error`, so no second hop+1 task and no second notice.
    @MainActor
    func testRerouteIsIdempotentAcrossTicks() async throws {
        let ws = tempDir.path
        let inbox = InboxStore(workspaceRoot: ws)
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }

        let sourceSession = try coordinator.newSession(cwd: ws, agent: .claude)
        coordinator.store.updateState(id: sourceSession.id, to: .working)
        let original = try inbox.createTask(from: .cursor, to: .claude, prompt: "Build high-throughput streaming proxy", files: ["Proxy.swift"])
        try inbox.markTaskDelivered(taskId: original.id, sessionId: sourceSession.id)
        try inbox.markTaskStarted(taskId: original.id)

        coordinator.terminals.sendInput(sessionId: sourceSession.id, text: "Rate limit reached. Please try again later.\n")
        let outputReady = try await waitUntil {
            coordinator.terminals.session(id: sourceSession.id)?.recentOutput(lines: 10).contains("Rate limit reached") ?? false
        }
        XCTAssertTrue(outputReady)

        XCTAssertTrue(coordinator.checkLimitsAndReroute(for: sourceSession.id))
        let firstCopy = try XCTUnwrap(inbox.openTasks().first { $0.hop == 1 })
        let stateAfterFirst = try XCTUnwrap(coordinator.store.session(id: sourceSession.id)).state
        XCTAssertEqual(stateAfterFirst, .error)

        // Next tick: same session, same buffer.
        coordinator.sampleAgentStates()
        _ = coordinator.checkLimitsAndReroute(for: sourceSession.id)

        let hopOne = try inbox.openTasks().filter { $0.hop == 1 }
        XCTAssertEqual(hopOne.count, 1, "second tick must not synthesize another hop-1 task")
        XCTAssertEqual(hopOne.first?.id, firstCopy.id)
        XCTAssertEqual(hopOne.first?.toAgent, firstCopy.toAgent)
        XCTAssertFalse(try inbox.load().tasks.contains { $0.prompt.hasPrefix("Task rerouted from") }, "no synthesized reroute task")

        let notices = try inbox.load().messages.filter { $0.kind == .notice && $0.toAgent == .cursor }
        XCTAssertEqual(notices.count, 1, "delegator is told exactly once")
        XCTAssertEqual(coordinator.store.session(id: sourceSession.id)?.state, stateAfterFirst, "second call leaves the source state alone")
    }

    /// Test 11c: If the assignee finished between the open-tasks read and the cancel, no hop+1 copy
    /// may be created — finished work must never be re-dispatched.
    @MainActor
    func testRerouteSkipsCopyWhenOriginalAlreadyDone() async throws {
        let ws = tempDir.path
        let inbox = InboxStore(workspaceRoot: ws)
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }

        let sourceSession = try coordinator.newSession(cwd: ws, agent: .claude)
        coordinator.store.updateState(id: sourceSession.id, to: .working)
        let original = try inbox.createTask(from: .cursor, to: .claude, prompt: "Build high-throughput streaming proxy", files: ["Proxy.swift"])
        try inbox.markTaskDelivered(taskId: original.id, sessionId: sourceSession.id)
        try inbox.markTaskStarted(taskId: original.id)

        // Authoritative record reaches .done; a stale open snapshot with the same id is kept so
        // openTasks() still reports it as the current task while cancelTask hits the .done row.
        let staleOpenRecord = try XCTUnwrap(inbox.task(id: original.id))
        try inbox.completeTask(taskId: original.id, report: TaskReport(status: "done", summary: "shipped before the limit hit"))
        var seeded = try inbox.load()
        seeded.tasks.append(staleOpenRecord)
        try inbox.saveRaw(seeded)

        coordinator.terminals.sendInput(sessionId: sourceSession.id, text: "Rate limit reached. Please try again later.\n")
        let outputReady = try await waitUntil {
            coordinator.terminals.session(id: sourceSession.id)?.recentOutput(lines: 10).contains("Rate limit reached") ?? false
        }
        XCTAssertTrue(outputReady)

        XCTAssertTrue(coordinator.checkLimitsAndReroute(for: sourceSession.id))

        XCTAssertEqual(try inbox.task(id: original.id)?.state, .done)
        XCTAssertFalse(try inbox.load().tasks.contains { $0.hop == 1 }, "finished work must not be re-dispatched")
        XCTAssertFalse(
            try inbox.load().messages.contains { $0.kind == .notice && $0.taskId == original.id },
            "no 'paused' notice for a task that was already done"
        )
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

    /// Test 13: sampleAgentStates heartbeats every live non-shell session so presence is truthful.
    @MainActor
    func testSampleAgentStatesHeartbeatsLiveSessions() throws {
        let ws = tempDir.path
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }
        let codex = try coordinator.newSession(cwd: ws, agent: .codex)
        _ = try coordinator.newSession(cwd: ws, agent: .shell)

        coordinator.sampleAgentStates()

        let board = try BlackboardStore(workspaceRoot: ws).load()
        let rec = try XCTUnwrap(board.activeAgents.first { $0.agentKind == .codex })
        XCTAssertEqual(rec.pid, coordinator.terminals.session(id: codex.id)?.processId)
        XCTAssertGreaterThan(rec.pid, 0)
        XCTAssertFalse(board.activeAgents.contains { $0.agentKind == .shell })
    }
}

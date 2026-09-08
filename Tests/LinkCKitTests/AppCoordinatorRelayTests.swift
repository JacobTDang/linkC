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

    /// Test 1: Processing pending message auto-spawns session if missing and dispatches prompt.
    @MainActor
    func testProcessPendingMessageAutoSpawnsSessionAndDispatchesPrompt() async throws {
        let ws = tempDir.path
        let inbox = InboxStore(workspaceRoot: ws)
        let msg = try inbox.enqueue(
            from: .claude,
            to: .codex,
            prompt: "Refactor database migrations",
            files: ["db/migrations.sql"]
        )
        XCTAssertEqual(msg.status, .queued)

        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }

        XCTAssertNil(coordinator.store.sessions.first(where: { $0.agentKind == .codex }))

        coordinator.processPendingMessages(workspacePath: ws)

        // 1. Target session was auto-spawned for codex
        guard let codexSession = coordinator.store.sessions.first(where: { $0.agentKind == .codex }) else {
            return XCTFail("Expected codex session to be auto-spawned")
        }
        XCTAssertEqual((codexSession.cwd as NSString).standardizingPath, (ws as NSString).standardizingPath)

        // 2. Message was marked delivered
        let pending = try inbox.fetchPending()
        XCTAssertTrue(pending.isEmpty, "Message should no longer be pending")

        let loaded = try inbox.load()
        let deliveredMsg = loaded.messages.first(where: { $0.id == msg.id })
        XCTAssertEqual(deliveredMsg?.status, .delivered)
        XCTAssertNotNil(deliveredMsg?.deliveredAt)

        // 3. Prompt was dispatched to terminal
        let term = coordinator.terminals.session(id: codexSession.id)
        XCTAssertNotNil(term)
        let echoed = try await waitUntil {
            term?.recentOutput(lines: 10).contains("Refactor database migrations") ?? false
        }
        XCTAssertTrue(echoed, "Expected prompt to be dispatched and echoed in terminal")
    }

    /// Test 2: Busy session delays prompt until .ready/.finished.
    @MainActor
    func testBusySessionDelaysPromptUntilReadyOrFinished() async throws {
        let ws = tempDir.path
        let inbox = InboxStore(workspaceRoot: ws)
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }

        // Pre-create session and put it in .working state
        let session = try coordinator.newSession(cwd: ws, agent: .codex)
        coordinator.store.updateState(id: session.id, to: .working)

        let msg = try inbox.enqueue(
            from: .claude,
            to: .codex,
            prompt: "Analyze test coverage",
            files: []
        )

        // Process while session is .working
        coordinator.processPendingMessages(workspacePath: ws)

        // Message must remain queued
        var pending = try inbox.fetchPending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.id, msg.id)
        XCTAssertEqual(pending.first?.status, .queued)

        // Transition session to .finished (turn complete)
        coordinator.store.updateState(id: session.id, to: .finished)

        // Process again
        coordinator.processPendingMessages(workspacePath: ws)

        // Message should now be delivered
        pending = try inbox.fetchPending()
        XCTAssertTrue(pending.isEmpty, "Message should be delivered now that session is finished")

        let loaded = try inbox.load()
        let deliveredMsg = loaded.messages.first(where: { $0.id == msg.id })
        XCTAssertEqual(deliveredMsg?.status, .delivered)
        XCTAssertNotNil(deliveredMsg?.deliveredAt)
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
        try inbox.markDelivered(id: initialMsg.id)

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
        guard let reroutedMsg = loaded.messages.first(where: { $0.fromAgent == .claude }) else {
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
        try inbox.markDelivered(id: hop2Msg.id)

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

        // Circuit breaker tripped: NO new message added to inbox
        let loaded = try inbox.load()
        let messagesAfter = loaded.messages
        XCTAssertEqual(messagesAfter.count, 1, "Circuit breaker must prevent enqueuing a 3rd hop message")
        XCTAssertEqual(messagesAfter.first?.id, hop2Msg.id)

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
        try inbox.markDelivered(id: newMsg.id)

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
        try inbox.markDelivered(id: msg.id)

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

    /// Test 9: checkLimitsAndReroute ignores sessions that are not .working or .error (idle/ready guard).
    @MainActor
    func testCheckLimitsAndRerouteIgnoredWhenSessionIsIdleOrReady() async throws {
        let ws = tempDir.path
        let inbox = InboxStore(workspaceRoot: ws)
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }

        let claudeSession = try coordinator.newSession(cwd: ws, agent: .claude)
        // Transition session to .ready (idle)
        coordinator.store.updateState(id: claudeSession.id, to: .ready)

        // Inject rate limit pattern
        coordinator.terminals.sendInput(sessionId: claudeSession.id, text: "Rate limit reached. Try later.\n")
        let outputReady = try await waitUntil {
            coordinator.terminals.session(id: claudeSession.id)?.recentOutput(lines: 10).contains("Rate limit reached") ?? false
        }
        XCTAssertTrue(outputReady)

        // Calling checkLimitsAndReroute on .ready session must return false and not record a limit
        let rerouted = coordinator.checkLimitsAndReroute(for: claudeSession.id)
        XCTAssertFalse(rerouted, "checkLimitsAndReroute must ignore idle/ready sessions")

        let limitStatus = try inbox.isAgentLimited(agent: .claude)
        XCTAssertNil(limitStatus, "No limit should be recorded for an idle session")
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
        try inbox.markDelivered(id: msg.id)

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
}

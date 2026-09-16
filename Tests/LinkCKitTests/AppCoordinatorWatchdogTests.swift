import XCTest
import os
@testable import LinkCKit

/// A wall clock a test moves forward instantly instead of sleeping through a threshold.
private final class ControllableClock: Sendable {
    private let box: OSAllocatedUnfairLock<Date>
    init(_ initial: Date = Date()) { box = OSAllocatedUnfairLock(initialState: initial) }
    func set(_ date: Date) { box.withLock { $0 = date } }
    func advance(_ seconds: TimeInterval) { box.withLock { $0 = $0.addingTimeInterval(seconds) } }
    func now() -> Date { box.withLock { $0 } }
}

final class AppCoordinatorWatchdogTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-watchdog-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    final class RecordingSink: NotificationSink, @unchecked Sendable {
        private let lock = NSLock()
        private var _deliveries: [(id: String, title: String, body: String)] = []
        var deliveries: [(id: String, title: String, body: String)] {
            lock.lock(); defer { lock.unlock() }; return _deliveries
        }
        func deliver(id: String, title: String, body: String) {
            lock.lock(); _deliveries.append((id, title, body)); lock.unlock()
        }
    }

    /// A mock agent that negotiates bracketed paste (so the relay will deliver to it) and then
    /// copies its input through, like a real CLI's raw-mode loop.
    @MainActor
    private func makeCoordinator(
        sink: NotificationSink = RecordingSink(),
        now: @escaping @MainActor @Sendable () -> Date = Date.init
    ) -> AppCoordinator {
        let scriptURL = tempDir.appendingPathComponent("mock_agent.sh")
        if !FileManager.default.fileExists(atPath: scriptURL.path) {
            let scriptContent = "#!/bin/sh\nstty -echo 2>/dev/null\nprintf '\\033[?2004h'\nexec /bin/cat\n"
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
            deliverySettle: 0,
            now: now,
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

    /// The quiet clock starts when a screen is first sampled and only restarts when the screen
    /// really changes — a spinner redrawing its timer must not count.
    @MainActor
    func testTheQuietClockRestartsOnlyWhenTheScreenChanges() async throws {
        let clock = ControllableClock()
        let coordinator = makeCoordinator(now: { clock.now() })
        defer { coordinator.shutdown() }
        let session = try coordinator.newSession(cwd: tempDir.path, agent: .claude)
        let term = try XCTUnwrap(coordinator.terminals.session(id: session.id))
        let started = try await waitUntil { term.isRunning }
        XCTAssertTrue(started, "the mock agent never started")

        coordinator.sampleAgentStates()
        let firstSeen = try XCTUnwrap(coordinator.screenUnchangedSince(session.id))

        clock.advance(60)
        term.sendInput("✻ Percolating… (12s · ↓ 115 tokens)\r")
        _ = try await waitUntil { term.recentOutput(lines: 5).contains("Percolating") }
        coordinator.sampleAgentStates()
        XCTAssertEqual(coordinator.screenUnchangedSince(session.id), firstSeen, "a spinner row is not progress")

        clock.advance(60)
        term.sendInput("Ran 1 shell command\r")
        _ = try await waitUntil { term.recentOutput(lines: 5).contains("Ran 1 shell command") }
        coordinator.sampleAgentStates()
        XCTAssertEqual(coordinator.screenUnchangedSince(session.id), clock.now(), "real output restarts the clock")
    }

    /// A brief typed into a session that never starts the task: after 10 minutes the delegator
    /// gets one line and the user one notification, and a second tick repeats neither.
    @MainActor
    func testANeverStartedTaskIsReportedOnceToTheDelegatorAndTheUser() async throws {
        let ws = tempDir.path
        let clock = ControllableClock()
        let sink = RecordingSink()
        let coordinator = makeCoordinator(sink: sink, now: { clock.now() })
        defer { coordinator.shutdown() }
        let inbox = InboxStore(workspaceRoot: ws)
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "Refactor migrations", files: [])

        coordinator.processPendingMessages(workspacePath: ws)
        let codex = try XCTUnwrap(coordinator.store.sessions.first(where: { $0.agentKind == .codex }))
        coordinator.store.updateState(id: codex.id, to: .ready)
        let ready = try await waitUntil { coordinator.terminals.session(id: codex.id)?.acceptsPaste ?? false }
        XCTAssertTrue(ready, "the mock agent never negotiated bracketed paste")
        // `pasteReadySince` is recorded off the real wall clock (see `TerminalSession.acceptsPaste`),
        // not the injected `now`; the controllable clock was frozen before that real negotiation
        // happened, so it must catch up here or dispatch's settle check reads negative and never
        // delivers. Matches `testDispatchWithholdsDeliveryUntilTheSettleMarginElapsesThenDelivers`.
        clock.set(Date())
        coordinator.processPendingMessages(workspacePath: ws)
        XCTAssertEqual(try inbox.task(id: task.id)?.state, .delivered)

        clock.advance(11 * 60)
        coordinator.processPendingMessages(workspacePath: ws)

        let notices = try inbox.load().messages.filter { $0.prompt.contains("looks stuck") }
        XCTAssertEqual(notices.count, 1, "the delegator is told once")
        XCTAssertTrue(notices[0].prompt.contains(task.shortId))
        XCTAssertTrue(notices[0].prompt.contains("never started"))
        XCTAssertEqual(sink.deliveries.filter { $0.body.contains("never started") }.count, 1)
        XCTAssertNotNil(try inbox.task(id: task.id)?.stuckNotifiedAt)

        clock.advance(5 * 60)
        coordinator.processPendingMessages(workspacePath: ws)
        XCTAssertEqual(try inbox.load().messages.filter { $0.prompt.contains("looks stuck") }.count, 1, "a second tick must not repeat it")
    }

    /// A worker sitting on a prompt for 5 minutes, and a worker whose screen has not changed for
    /// 15, are both stuck; when the screen moves again the mark clears and a later stall reports.
    @MainActor
    func testAWaitingWorkerAndAQuietWorkerAreBothReported() async throws {
        let ws = tempDir.path
        let clock = ControllableClock()
        let coordinator = makeCoordinator(now: { clock.now() })
        defer { coordinator.shutdown() }
        let inbox = InboxStore(workspaceRoot: ws)

        let waiting = try coordinator.newSession(cwd: ws, agent: .codex)
        let waitingTask = try inbox.createTask(from: .claude, to: .codex, prompt: "One", files: [])
        try inbox.markTaskDelivered(taskId: waitingTask.id, sessionId: waiting.id)
        try inbox.markTaskStarted(taskId: waitingTask.id)
        coordinator.store.updateState(id: waiting.id, to: .waitingPermission)

        clock.advance(6 * 60)
        coordinator.processPendingMessages(workspacePath: ws)
        let waitingNotice = try inbox.load().messages.first { $0.prompt.contains(waitingTask.shortId) }
        XCTAssertTrue(waitingNotice?.prompt.contains("waiting on a prompt") ?? false)

        let quiet = try coordinator.newSession(cwd: ws, agent: .cursor)
        let quietTask = try inbox.createTask(from: .claude, to: .cursor, prompt: "Two", files: [])
        try inbox.markTaskDelivered(taskId: quietTask.id, sessionId: quiet.id)
        try inbox.markTaskStarted(taskId: quietTask.id)
        let term = try XCTUnwrap(coordinator.terminals.session(id: quiet.id))
        let running = try await waitUntil { term.isRunning }
        XCTAssertTrue(running)
        coordinator.sampleAgentStates()
        coordinator.store.updateState(id: quiet.id, to: .working)

        clock.advance(16 * 60)
        coordinator.processPendingMessages(workspacePath: ws)
        XCTAssertTrue(try inbox.task(id: quietTask.id)?.stuckNotifiedAt != nil)
        XCTAssertTrue(try inbox.load().messages.first { $0.prompt.contains(quietTask.shortId) }?.prompt.contains("screen has not changed") ?? false)

        // The screen moves: the mark clears and a later stall is reported again.
        term.sendInput("Ran 1 shell command\r")
        _ = try await waitUntil { term.recentOutput(lines: 5).contains("Ran 1 shell command") }
        coordinator.sampleAgentStates()
        coordinator.store.updateState(id: quiet.id, to: .working)
        coordinator.processPendingMessages(workspacePath: ws)
        XCTAssertNil(try inbox.task(id: quietTask.id)?.stuckNotifiedAt, "a task that moves again must be reportable later")

        clock.advance(16 * 60)
        coordinator.processPendingMessages(workspacePath: ws)
        XCTAssertNotNil(try inbox.task(id: quietTask.id)?.stuckNotifiedAt, "a later stall reports again")
        XCTAssertEqual(try inbox.load().messages.filter { $0.prompt.contains(quietTask.shortId) }.count, 2)
    }

    /// Two tasks reported stuck in the same tick for two different reasons must both be named in
    /// the notification body, not just `reported.first`'s reason.
    @MainActor
    func testTwoTasksStuckForDifferentReasonsInOneTickNameBothInTheNotificationBody() async throws {
        let ws = tempDir.path
        let clock = ControllableClock()
        let sink = RecordingSink()
        let coordinator = makeCoordinator(sink: sink, now: { clock.now() })
        defer { coordinator.shutdown() }
        let inbox = InboxStore(workspaceRoot: ws)

        let neverStartedTask = try inbox.createTask(from: .claude, to: .codex, prompt: "Refactor migrations", files: [])
        coordinator.processPendingMessages(workspacePath: ws)
        let codex = try XCTUnwrap(coordinator.store.sessions.first(where: { $0.agentKind == .codex }))
        coordinator.store.updateState(id: codex.id, to: .ready)
        let ready = try await waitUntil { coordinator.terminals.session(id: codex.id)?.acceptsPaste ?? false }
        XCTAssertTrue(ready, "the mock agent never negotiated bracketed paste")
        // See the comment in testANeverStartedTaskIsReportedOnceToTheDelegatorAndTheUser: the
        // controllable clock must catch up to the real negotiation time or dispatch never delivers.
        clock.set(Date())
        coordinator.processPendingMessages(workspacePath: ws)
        XCTAssertEqual(try inbox.task(id: neverStartedTask.id)?.state, .delivered)

        let waiting = try coordinator.newSession(cwd: ws, agent: .cursor)
        let waitingTask = try inbox.createTask(from: .claude, to: .cursor, prompt: "Two", files: [])
        try inbox.markTaskDelivered(taskId: waitingTask.id, sessionId: waiting.id)
        try inbox.markTaskStarted(taskId: waitingTask.id)
        coordinator.store.updateState(id: waiting.id, to: .waitingPermission)

        clock.advance(11 * 60)
        coordinator.processPendingMessages(workspacePath: ws)

        let stuckDeliveries = sink.deliveries.filter { $0.title.contains("look stuck") }
        XCTAssertEqual(stuckDeliveries.count, 1)
        let body = try XCTUnwrap(stuckDeliveries.first?.body)
        XCTAssertTrue(body.contains("never started"), "must name the never-started task's reason: \(body)")
        XCTAssertTrue(body.contains("waiting on a prompt"), "must name the waiting worker's reason too: \(body)")
    }
}

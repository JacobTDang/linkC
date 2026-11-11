import XCTest
import os
@testable import LinkCKit

/// A clock a test sets by hand, for the reaper's grace periods.
private final class SettableClock: Sendable {
    private let box = OSAllocatedUnfairLock(initialState: Date())

    func set(_ date: Date) {
        box.withLock { $0 = date }
    }

    func now() -> Date {
        box.withLock { $0 }
    }
}

/// The coordinator's events for Discord: task changes, closed workers, and alerts with their folder.
@MainActor
final class AppCoordinatorDiscordEventTests: XCTestCase {
    nonisolated(unsafe) private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-discord-events-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private var folder: String { ProjectPath.canonical(tempDir.path) }

    private final class Box {
        var events: [LinkCEvent] = []
    }

    private func makeCoordinator(now: @escaping @MainActor @Sendable () -> Date = Date.init) -> (AppCoordinator, Box) {
        let script = tempDir.appendingPathComponent("mock_agent.sh")
        try? "#!/bin/sh\nstty -echo 2>/dev/null\nprintf '\\033[?2004h'\nexec /bin/cat\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let settingsDir = tempDir.appendingPathComponent("settings")
        try? FileManager.default.createDirectory(at: settingsDir, withIntermediateDirectories: true)
        let coordinator = AppCoordinator(
            terminals: TerminalSessionManager(),
            hookServer: HookServer.forTesting(),
            notifications: NotificationManager(sink: RecordingSink(), now: { Date() }),
            claudePath: script.path,
            settingsDir: settingsDir,
            userSettingsURL: tempDir.appendingPathComponent("user-settings.json"),
            manifestDir: tempDir.appendingPathComponent("manifest"),
            agentPathResolver: { _ in script.path },
            deliverySettle: 0,
            injectionGap: 0,
            now: now,
            isWatching: { _ in false }
        )
        let box = Box()
        coordinator.onEvent = { box.events.append($0) }
        return (coordinator, box)
    }

    private func stopAll(_ coordinator: AppCoordinator) {
        coordinator.store.sessions.forEach { coordinator.stopSession($0.id) }
        coordinator.shutdown()
    }

    func testATaskChangeRaisesOneTaskEventAndTheFirstPassNone() throws {
        let (coordinator, box) = makeCoordinator()
        defer { stopAll(coordinator) }
        let inbox = InboxStore(workspaceRoot: folder)
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "carry", files: [])
        try inbox.cancelTask(taskId: task.id, reason: "not needed")

        coordinator.processPendingMessages(workspacePath: folder)
        XCTAssertTrue(box.events.filter { $0.kind == .task }.isEmpty, "the first pass only records")

        let second = try inbox.createTask(from: .claude, to: .codex, prompt: "other work", files: [])
        try inbox.cancelTask(taskId: second.id, reason: "changed my mind")
        coordinator.processPendingMessages(workspacePath: folder)

        let taskEvents = box.events.filter { $0.kind == .task }
        XCTAssertEqual(taskEvents.map(\.title), ["Task cancelled · Claude → Codex"])
        XCTAssertEqual(taskEvents.first?.project, folder)
    }

    func testAWorkerClosedOnRequestRaisesAnEvent() throws {
        let (coordinator, box) = makeCoordinator()
        defer { stopAll(coordinator) }
        let inbox = InboxStore(workspaceRoot: folder)
        let worker = try coordinator.newSession(cwd: folder, agent: .codex, asWorker: true)
        let mine = try coordinator.newSession(cwd: folder, agent: .codex)
        XCTAssertEqual(coordinator.terminals.selectedId, mine.id, "the worker is off screen, so linkC may close it")
        let task = try inbox.createTask(from: .claude, to: .codex, fromSessionId: "D", prompt: "carry", files: [])
        try inbox.markTaskDelivered(taskId: task.id, sessionId: worker.id)
        try inbox.reportTask(taskId: task.id, report: TaskReport(status: "done", summary: "did it"))
        coordinator.store.updateState(id: worker.id, to: .finished)
        _ = try inbox.requestClose(taskId: task.id, by: .delegator)

        coordinator.reapIdleWorkers(workspacePath: folder, inboxStore: inbox)

        let closed = box.events.filter { $0.kind == .workerClosed }
        XCTAssertEqual(closed.map(\.title), ["Codex worker closed"])
        XCTAssertEqual(closed.first?.project, folder)
        XCTAssertEqual(closed.first?.body, "Closed on request for task \(task.shortId).")
    }

    func testAWorkerClosedForSittingIdleRaisesAnEvent() throws {
        let clock = SettableClock()
        let (coordinator, box) = makeCoordinator(now: clock.now)
        defer { stopAll(coordinator) }
        let inbox = InboxStore(workspaceRoot: folder)
        let worker = try coordinator.newSession(cwd: folder, agent: .codex, asWorker: true)
        let mine = try coordinator.newSession(cwd: folder, agent: .codex)
        XCTAssertEqual(coordinator.terminals.selectedId, mine.id, "the worker is off screen, so linkC may close it")
        coordinator.store.updateState(id: worker.id, to: .finished)

        clock.set(Date().addingTimeInterval(WorkerReaper.idleGrace + 60))
        coordinator.reapIdleWorkers(workspacePath: folder, inboxStore: inbox)

        XCTAssertNil(coordinator.store.session(id: worker.id), "past the grace: closed")
        let closed = box.events.filter { $0.kind == .workerClosed }
        XCTAssertEqual(closed.map(\.title), ["Codex worker closed"])
        XCTAssertEqual(closed.first?.project, folder)
        XCTAssertEqual(closed.first?.body, "It sat idle after its work ended.")
    }

    /// Like every relay phase, a contended read ends the pass: one wait for the lock, not one per phase.
    func testAContendedInboxEndsThePassAtTheTaskEvents() throws {
        let (coordinator, _) = makeCoordinator()
        defer { stopAll(coordinator) }
        let inbox = InboxStore(workspaceRoot: folder)
        _ = try inbox.createTask(from: .claude, to: .codex, prompt: "carry", files: [])
        let lockPath = (folder as NSString).appendingPathComponent(".linkc/.inbox.lock")
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
        XCTAssertGreaterThan(fd, 0)
        XCTAssertEqual(flock(fd, LOCK_EX), 0)
        defer { flock(fd, LOCK_UN); close(fd) }

        XCTAssertTrue(coordinator.reportTaskEvents(workspacePath: folder, inboxStore: inbox),
                      "a read that timed out on the lock says so")
        let start = Date()
        coordinator.processPendingMessages(workspacePath: folder)
        XCTAssertLessThan(Date().timeIntervalSince(start), AppCoordinator.relayLockTimeout * 1.8,
                          "the pass stopped after the first wait for the lock")
    }

    func testALocalNotificationRaisesNoEvent() {
        let (coordinator, box) = makeCoordinator()
        defer { stopAll(coordinator) }
        coordinator.postLocalNotification(title: "linkC update", body: "installed")
        XCTAssertTrue(box.events.isEmpty)
    }

    func testAServiceAlertRaisesAServiceEvent() {
        let (coordinator, box) = makeCoordinator()
        defer { stopAll(coordinator) }
        coordinator.notify(id: "health:api", title: "api", body: "api is not responding", tone: .failed)
        XCTAssertEqual(box.events.map(\.kind), [.service])
        XCTAssertEqual(box.events.map(\.tone), [.failed])
    }
}

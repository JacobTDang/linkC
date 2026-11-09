import XCTest
@testable import LinkCKit

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

    private func makeCoordinator() -> (AppCoordinator, Box) {
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
        let task = try inbox.createTask(from: .claude, to: .codex, fromSessionId: "D", prompt: "carry", files: [])
        try inbox.markTaskDelivered(taskId: task.id, sessionId: worker.id)
        try inbox.reportTask(taskId: task.id, report: TaskReport(status: "done", summary: "did it"))
        coordinator.store.updateState(id: worker.id, to: .finished)
        _ = try inbox.requestClose(taskId: task.id, by: .delegator)

        coordinator.reapIdleWorkers(workspacePath: folder, inboxStore: inbox)

        let closed = box.events.filter { $0.kind == .workerClosed }
        XCTAssertEqual(closed.map(\.title), ["Codex worker closed"])
        XCTAssertEqual(closed.first?.project, folder)
        XCTAssertEqual(closed.first?.body, "Closed on request for task `\(task.shortId)`.")
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

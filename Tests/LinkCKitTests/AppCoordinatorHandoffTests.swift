import XCTest
import os
@testable import LinkCKit

@MainActor
final class AppCoordinatorHandoffTests: XCTestCase {
    nonisolated(unsafe) private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-handoff-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private var requests: OpenRequestStore { OpenRequestStore(directory: tempDir.appendingPathComponent("open-requests")) }
    private var folder: String { ProjectPath.canonical(tempDir.path) }

    private func makeCoordinator(models: AgentModelSettings = .seeded,
                                  modelLists: [AgentKind: AgentModelList] = [:],
                                  now: @escaping @MainActor @Sendable () -> Date = Date.init) -> AppCoordinator {
        let script = tempDir.appendingPathComponent("mock_agent.sh")
        try? "#!/bin/sh\nstty -echo 2>/dev/null\nprintf '\\033[?2004h'\nexec /bin/cat\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let settingsDir = tempDir.appendingPathComponent("settings")
        try? FileManager.default.createDirectory(at: settingsDir, withIntermediateDirectories: true)
        return AppCoordinator(
            terminals: TerminalSessionManager(),
            hookServer: HookServer.forTesting(),
            notifications: NotificationManager(sink: NullSink(), now: { Date() }),
            claudePath: script.path,
            settingsDir: settingsDir,
            userSettingsURL: tempDir.appendingPathComponent("user-settings.json"),
            manifestDir: tempDir.appendingPathComponent("manifest"),
            agentPathResolver: { _ in script.path },
            modelSettings: { models },
            modelLists: { modelLists },
            deliverySettle: 0,
            injectionGap: 0,
            now: now,
            openRequests: requests,
            openCodeModels: { _ in ["opencode/free-model"] },
            kiloModels: { _ in ["kilo/free-model"] },
            isWatching: { _ in false }
        )
    }

    /// The memo a handoff to `session` left.
    private func handoffMemo(for session: Session) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: folder).appendingPathComponent(".linkc/HANDOFF.md"), encoding: .utf8)
    }

    private struct NullSink: NotificationSink {
        func deliver(id: String, title: String, body: String) {}
    }

    private func stopAll(_ coordinator: AppCoordinator) {
        coordinator.store.sessions.forEach { coordinator.stopSession($0.id) }
        coordinator.shutdown()
    }

    func testHandoffCreatesHandoffMemoAndOpensUserOwnedSessionWithOpeningPrompt() throws {
        let coordinator = makeCoordinator()
        defer { stopAll(coordinator) }

        let s1 = try coordinator.newSession(cwd: folder, agent: .claude, mode: .new)

        let s2 = try coordinator.handoff(from: s1.id, to: .codex, tier: .standard, goal: "Finish implementing Feature X")

        XCTAssertEqual(s2.agentKind, .codex)
        XCTAssertEqual(s2.cwd, s1.cwd)
        XCTAssertFalse(s2.isWorker, "Handoff session must be user-owned, not a delegated worker")
        XCTAssertEqual(coordinator.store.session(id: s1.id)?.state, s1.state, "Source session must be left running")

        // HANDOFF.md must exist in cwd/.linkc/HANDOFF.md
        let handoffURL = URL(fileURLWithPath: folder).appendingPathComponent(".linkc/HANDOFF.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: handoffURL.path))
        let memo = try String(contentsOf: handoffURL, encoding: .utf8)
        XCTAssertTrue(memo.contains("[CLAUDE] Claude Code"))
        XCTAssertTrue(memo.contains("Finish implementing Feature X"))

        // Opening prompt must be queued for s2
        let prompt = coordinator.openingPrompts[s2.id]
        XCTAssertNotNil(prompt)
        XCTAssertTrue(prompt?.text.contains(".linkc/HANDOFF.md") ?? false)
        XCTAssertTrue(prompt?.text.contains("Finish implementing Feature X") ?? false)
    }

    /// The goal is the source session's own. A worker's brief in the folder is that worker's work, the
    /// board's goal is whoever posted last, and the folder name is no goal at all: with none of its own,
    /// the memo and the prompt name none.
    func testWithNoGoalOfItsOwnTheHandoffNamesNone() throws {
        let coordinator = makeCoordinator()
        defer { stopAll(coordinator) }

        let s1 = try coordinator.newSession(cwd: folder, agent: .claude, mode: .new)
        let worker = try coordinator.newSession(cwd: folder, agent: .codex, mode: .new)
        let inbox = InboxStore(workspaceRoot: folder)
        let brief = try inbox.createTask(from: .claude, to: .codex, fromSessionId: s1.id,
                                         prompt: "Worker B's brief", files: [])
        try inbox.markTaskDelivered(taskId: brief.id, sessionId: worker.id)
        _ = try BlackboardStore(workspaceRoot: folder).broadcastIntent(
            agentKind: .codex, pid: 4242, goal: "The board's goal", files: [])

        let s2 = try coordinator.handoff(from: s1.id, to: .codex)

        let memo = try handoffMemo(for: s2)
        XCTAssertTrue(memo.contains("## Goal\n(None recorded)"), memo)
        let prompt = try XCTUnwrap(coordinator.openingPrompts[s2.id]?.text)
        XCTAssertFalse(prompt.contains("continue working on"), prompt)
        XCTAssertTrue(prompt.hasSuffix("and continue."), prompt)
    }

    /// A task the source session carries is its goal, whatever else is open in the folder.
    func testATaskTheSessionCarriesIsItsGoal() throws {
        let coordinator = makeCoordinator()
        defer { stopAll(coordinator) }

        let s1 = try coordinator.newSession(cwd: folder, agent: .claude, mode: .new)
        let worker = try coordinator.newSession(cwd: folder, agent: .codex, mode: .new)
        let inbox = InboxStore(workspaceRoot: folder)
        let own = try inbox.createTask(from: .codex, to: .claude, prompt: "Ship the cache clock", files: [])
        try inbox.markTaskDelivered(taskId: own.id, sessionId: s1.id)
        let other = try inbox.createTask(from: .claude, to: .codex, fromSessionId: s1.id,
                                         prompt: "Worker B's brief", files: [])
        try inbox.markTaskDelivered(taskId: other.id, sessionId: worker.id)

        let s2 = try coordinator.handoff(from: s1.id, to: .codex)

        XCTAssertTrue(try handoffMemo(for: s2).contains("## Goal\nShip the cache clock"))
        let prompt = try XCTUnwrap(coordinator.openingPrompts[s2.id]?.text)
        XCTAssertTrue(prompt.hasSuffix("continue working on: Ship the cache clock"), prompt)
    }

    func testHandoffRefusesUnknownSourceSession() throws {
        let coordinator = makeCoordinator()
        defer { stopAll(coordinator) }

        XCTAssertThrowsError(try coordinator.handoff(from: "nonexistent-id", to: .codex)) { error in
            XCTAssertTrue(error.localizedDescription.contains("nonexistent-id") || error.localizedDescription.contains("not found"))
        }
    }

    func testHandoffRefusesShellAsTargetAgent() throws {
        let coordinator = makeCoordinator()
        defer { stopAll(coordinator) }

        let s1 = try coordinator.newSession(cwd: folder, agent: .claude, mode: .new)
        XCTAssertThrowsError(try coordinator.handoff(from: s1.id, to: .shell)) { error in
            XCTAssertTrue(error.localizedDescription.contains("shell is not an agent"))
        }
    }

    func testHandoffRefusesCursorPinnedToModelOrTier() throws {
        let coordinator = makeCoordinator()
        defer { stopAll(coordinator) }

        let s1 = try coordinator.newSession(cwd: folder, agent: .claude, mode: .new)
        XCTAssertThrowsError(try coordinator.handoff(from: s1.id, to: .cursor, tier: .standard)) { error in
            XCTAssertTrue(error.localizedDescription.contains("cursor cannot be pinned to a model"))
        }
        XCTAssertThrowsError(try coordinator.handoff(from: s1.id, to: .cursor, model: "gpt-4o")) { error in
            XCTAssertTrue(error.localizedDescription.contains("cursor cannot be pinned to a model"))
        }
    }

    func testHandoffRefusesFreebuffWithTierOrModel() throws {
        let coordinator = makeCoordinator()
        defer { stopAll(coordinator) }

        let s1 = try coordinator.newSession(cwd: folder, agent: .claude, mode: .new)
        XCTAssertThrowsError(try coordinator.handoff(from: s1.id, to: .freebuff, tier: .standard)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Freebuff has no tiers"))
        }
        XCTAssertThrowsError(try coordinator.handoff(from: s1.id, to: .freebuff, model: "custom-model")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Freebuff has no tiers"))
        }
    }

    func testHandoffRefusesBothTierAndModelPassed() throws {
        let coordinator = makeCoordinator()
        defer { stopAll(coordinator) }

        let s1 = try coordinator.newSession(cwd: folder, agent: .claude, mode: .new)
        XCTAssertThrowsError(try coordinator.handoff(from: s1.id, to: .codex, tier: .standard, model: "o3-mini")) { error in
            XCTAssertTrue(error.localizedDescription.contains("pass tier or model, not both"))
        }
    }

    func testHandoffRefusesModelNotListedByAgent() throws {
        let lists: [AgentKind: AgentModelList] = [
            .codex: AgentModelList(models: [ListedModel(id: "o3-mini", name: "o3-mini")], fetchedAt: Date(), error: nil)
        ]
        let coordinator = makeCoordinator(modelLists: lists)
        defer { stopAll(coordinator) }

        let s1 = try coordinator.newSession(cwd: folder, agent: .claude, mode: .new)
        XCTAssertThrowsError(try coordinator.handoff(from: s1.id, to: .codex, model: "unlisted-model")) { error in
            XCTAssertTrue(error.localizedDescription.contains("is not among the models"))
        }
    }

    func testOpenRequestWithHandoffFromExecutesHandoff() throws {
        let coordinator = makeCoordinator()
        defer { stopAll(coordinator) }

        let s1 = try coordinator.newSession(cwd: folder, agent: .claude, mode: .new)

        let req = OpenRequest(
            agent: .codex,
            folder: folder,
            prompt: nil,
            tier: .standard,
            task: nil,
            handoffFrom: s1.id,
            goal: "Continue from handoff"
        )
        try requests.submit(req)
        coordinator.handleOpenRequests()

        let answer = try XCTUnwrap(requests.result(for: req.id))
        XCTAssertTrue(answer.ok, answer.message)
        let s2Id = try XCTUnwrap(answer.sessionId)
        let s2 = try XCTUnwrap(coordinator.store.session(id: s2Id))
        XCTAssertEqual(s2.agentKind, .codex)
        XCTAssertFalse(s2.isWorker)
        XCTAssertNotNil(coordinator.openingPrompts[s2.id])
    }

    /// A handoff from the sidebar opens in the panel like any session started there; only a handoff
    /// an agent asked for gets a window of its own.
    func testASidebarHandoffStaysInThePanel() throws {
        let coordinator = makeCoordinator()
        defer { stopAll(coordinator) }
        var tornOff: [String] = []
        coordinator.onCommandSessionOpened = { tornOff.append($0) }

        let s1 = try coordinator.newSession(cwd: folder, agent: .claude, mode: .new)
        _ = try coordinator.handoff(from: s1.id, to: .codex)

        XCTAssertEqual(tornOff, [])
    }

    func testARequestedHandoffGetsAWindowOfItsOwn() throws {
        let coordinator = makeCoordinator()
        defer { stopAll(coordinator) }
        var tornOff: [String] = []
        coordinator.onCommandSessionOpened = { tornOff.append($0) }

        let s1 = try coordinator.newSession(cwd: folder, agent: .claude, mode: .new)
        let req = OpenRequest(agent: .codex, folder: folder, prompt: nil, tier: nil, task: nil, handoffFrom: s1.id)
        try requests.submit(req)
        coordinator.handleOpenRequests()

        let answer = try XCTUnwrap(requests.result(for: req.id))
        XCTAssertTrue(answer.ok, answer.message)
        XCTAssertEqual(tornOff, [try XCTUnwrap(answer.sessionId)])
    }

    func testOpenRequestWithInvalidHandoffFromReturnsRefused() throws {
        let coordinator = makeCoordinator()
        defer { stopAll(coordinator) }

        let req = OpenRequest(
            agent: .codex,
            folder: folder,
            prompt: nil,
            tier: .standard,
            task: nil,
            handoffFrom: "invalid-id"
        )
        try requests.submit(req)
        coordinator.handleOpenRequests()

        let answer = try XCTUnwrap(requests.result(for: req.id))
        XCTAssertFalse(answer.ok)
        XCTAssertTrue(answer.message.contains("invalid-id") || answer.message.contains("not found"))
    }
}

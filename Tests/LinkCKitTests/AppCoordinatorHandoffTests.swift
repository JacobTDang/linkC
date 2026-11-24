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
        coordinator.store.updateTitle(id: s1.id, to: "Implement Feature X")

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

    func testHandoffFallsBackToSourceTitleWhenNoExplicitOrResolvedGoal() throws {
        let coordinator = makeCoordinator()
        defer { stopAll(coordinator) }

        let s1 = try coordinator.newSession(cwd: folder, agent: .claude, mode: .new)
        coordinator.store.updateTitle(id: s1.id, to: "Refactor Database Layer")

        let s2 = try coordinator.handoff(from: s1.id, to: .codex, tier: .standard)

        let handoffURL = URL(fileURLWithPath: folder).appendingPathComponent(".linkc/HANDOFF.md")
        let memo = try String(contentsOf: handoffURL, encoding: .utf8)
        XCTAssertTrue(memo.contains("Refactor Database Layer"))

        let prompt = coordinator.openingPrompts[s2.id]
        XCTAssertNotNil(prompt)
        XCTAssertTrue(prompt?.text.contains("Refactor Database Layer") ?? false)
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
        coordinator.store.updateTitle(id: s1.id, to: "Session 1 Task")

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

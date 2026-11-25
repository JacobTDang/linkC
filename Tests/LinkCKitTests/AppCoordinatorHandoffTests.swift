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
    private var handoffRequests: OpenRequestStore { OpenRequestStore(directory: tempDir.appendingPathComponent("handoff-requests")) }
    private var folder: String { ProjectPath.canonical(tempDir.path) }

    private func makeCoordinator(models: AgentModelSettings = .seeded,
                                  modelLists: [AgentKind: AgentModelList] = [:],
                                  missingAgents: Set<AgentKind> = [],
                                  now: @escaping @MainActor @Sendable () -> Date = Date.init) -> AppCoordinator {
        // Each agent's stand-in records the argv it was started with, then waits like an idle agent.
        let argvDir = tempDir.path
        for kind in AgentKind.allCases {
            let script = agentScript(kind)
            try? FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? """
            #!/bin/sh
            printf '%s\\n' "$0" "$@" > "\(argvDir)/argv-$LINKC_SESSION.tmp" && mv "\(argvDir)/argv-$LINKC_SESSION.tmp" "\(argvDir)/argv-$LINKC_SESSION"
            stty -echo 2>/dev/null
            printf '\\033[?2004h'
            exec /bin/cat

            """.write(to: script, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        }
        let settingsDir = tempDir.appendingPathComponent("settings")
        try? FileManager.default.createDirectory(at: settingsDir, withIntermediateDirectories: true)
        return AppCoordinator(
            terminals: TerminalSessionManager(),
            hookServer: HookServer.forTesting(),
            notifications: NotificationManager(sink: NullSink(), now: { Date() }),
            claudePath: agentScript(.claude).path,
            settingsDir: settingsDir,
            userSettingsURL: tempDir.appendingPathComponent("user-settings.json"),
            manifestDir: tempDir.appendingPathComponent("manifest"),
            agentPathResolver: { [tempDir] kind in
                missingAgents.contains(kind) ? nil : tempDir!.appendingPathComponent("agents/\(kind.rawValue)").path
            },
            modelSettings: { models },
            modelLists: { modelLists },
            deliverySettle: 0,
            injectionGap: 0,
            now: now,
            openRequests: requests,
            handoffRequests: handoffRequests,
            openCodeModels: { _ in ["opencode/free-model"] },
            kiloModels: { _ in ["kilo/free-model"] },
            isWatching: { _ in false }
        )
    }

    private func agentScript(_ kind: AgentKind) -> URL {
        tempDir.appendingPathComponent("agents/\(kind.rawValue)")
    }

    /// The argv `session`'s process started with: its executable, then its arguments.
    private func launchArgv(of session: Session) throws -> [String] {
        let url = tempDir.appendingPathComponent("argv-\(session.id)")
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: url.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n").map(String.init)
    }

    /// The memo a handoff to `session` left.
    private func handoffMemo(for session: Session) throws -> String {
        try String(contentsOf: handoffsFolder.appendingPathComponent("\(session.id).md"), encoding: .utf8)
    }

    private var handoffsFolder: URL { URL(fileURLWithPath: folder).appendingPathComponent(".linkc/handoffs") }
    private var teammateMemo: URL { URL(fileURLWithPath: folder).appendingPathComponent(".linkc/HANDOFF.md") }

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

        let memo = try handoffMemo(for: s2)
        XCTAssertTrue(memo.contains("[CLAUDE] Claude Code"))
        XCTAssertTrue(memo.contains("Finish implementing Feature X"))

        let prompt = try XCTUnwrap(coordinator.openingPrompts[s2.id]?.text)
        XCTAssertEqual(prompt, "Please read .linkc/handoffs/\(s2.id).md and continue working on: Finish implementing Feature X")
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

    /// A tier picks the model, and the new session runs that model unpinned, as the user's own sessions
    /// open: a session pinned to the tier would be handed the tasks delegated to it.
    func testATierHandoffLaunchesTheTiersModelUnpinned() throws {
        let coordinator = makeCoordinator()
        defer { stopAll(coordinator) }
        let deep = try XCTUnwrap(AgentModelSettings.seeded.model(for: .codex, tier: .deep))

        let s1 = try coordinator.newSession(cwd: folder, agent: .claude, mode: .new)
        let s2 = try coordinator.handoff(from: s1.id, to: .codex, tier: .deep)

        XCTAssertEqual(s2.agentKind, .codex)
        XCTAssertEqual(s2.model, deep)
        XCTAssertNil(s2.modelTier)
        XCTAssertFalse(s2.isWorker)
        XCTAssertFalse(s2.canCarry(TaskRecord(fromAgent: .claude, tier: .deep, toAgent: .codex, prompt: "a delegated task")))
        let argv = try launchArgv(of: s2)
        XCTAssertEqual(argv.first, agentScript(.codex).path)
        XCTAssertTrue(argv.joined(separator: " ").contains("--model \(deep)"), "\(argv)")
    }

    /// A model named for the handoff is launched in the spelling its agent lists, unpinned.
    func testAModelHandoffLaunchesThatModelUnpinned() throws {
        let lists: [AgentKind: AgentModelList] = [
            .codex: AgentModelList(models: [ListedModel(id: "o3-mini", name: "o3-mini")], fetchedAt: Date(), error: nil)
        ]
        let coordinator = makeCoordinator(modelLists: lists)
        defer { stopAll(coordinator) }

        let s1 = try coordinator.newSession(cwd: folder, agent: .claude, mode: .new)
        let s2 = try coordinator.handoff(from: s1.id, to: .codex, model: "O3-Mini")

        XCTAssertEqual(s2.agentKind, .codex)
        XCTAssertEqual(s2.model, "o3-mini")
        XCTAssertNil(s2.modelTier)
        XCTAssertFalse(s2.isWorker)
        let argv = try launchArgv(of: s2)
        XCTAssertEqual(argv.first, agentScript(.codex).path)
        XCTAssertTrue(argv.joined(separator: " ").contains("--model o3-mini"), "\(argv)")
    }

    /// Each handoff keeps its own memo, named for the new session, so it never replaces the memo a
    /// teammate or a limit reroute reads from `.linkc/HANDOFF.md`, or another handoff's.
    func testAHandoffKeepsItsOwnMemoBesideTheTeammateMemo() throws {
        let coordinator = makeCoordinator()
        defer { stopAll(coordinator) }
        try FileManager.default.createDirectory(at: teammateMemo.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "a teammate's memo".write(to: teammateMemo, atomically: true, encoding: .utf8)

        let s1 = try coordinator.newSession(cwd: folder, agent: .claude, mode: .new)
        let s2 = try coordinator.handoff(from: s1.id, to: .codex, goal: "first")
        let s3 = try coordinator.handoff(from: s1.id, to: .codex, goal: "second")

        XCTAssertEqual(try String(contentsOf: teammateMemo, encoding: .utf8), "a teammate's memo")
        XCTAssertTrue(try handoffMemo(for: s2).contains("## Goal\nfirst"))
        XCTAssertTrue(try handoffMemo(for: s3).contains("## Goal\nsecond"))
        XCTAssertEqual(coordinator.openingPrompts[s3.id]?.text,
                       "Please read .linkc/handoffs/\(s3.id).md and continue working on: second")
    }

    /// A launch that fails leaves no memo behind, and says which agent could not start.
    func testAFailedLaunchWritesNoMemo() throws {
        let coordinator = makeCoordinator(missingAgents: [.codex])
        defer { stopAll(coordinator) }
        try FileManager.default.createDirectory(at: teammateMemo.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "a teammate's memo".write(to: teammateMemo, atomically: true, encoding: .utf8)

        let s1 = try coordinator.newSession(cwd: folder, agent: .claude, mode: .new)
        XCTAssertThrowsError(try coordinator.handoff(from: s1.id, to: .codex, goal: "anything")) { error in
            XCTAssertTrue(error.localizedDescription.hasPrefix("Codex could not start: "), error.localizedDescription)
        }

        XCTAssertEqual(try String(contentsOf: teammateMemo, encoding: .utf8), "a teammate's memo")
        let memos = (try? FileManager.default.contentsOfDirectory(atPath: handoffsFolder.path)) ?? []
        XCTAssertEqual(memos, [])
    }

    /// A session that has ended has nothing live to hand off.
    func testHandoffRefusesAnEndedSession() throws {
        let coordinator = makeCoordinator()
        defer { stopAll(coordinator) }

        let s1 = try coordinator.newSession(cwd: folder, agent: .claude, mode: .new)
        coordinator.store.updateState(id: s1.id, to: .ended)

        XCTAssertThrowsError(try coordinator.handoff(from: s1.id, to: .codex)) { error in
            XCTAssertTrue(error.localizedDescription.contains("has ended"), error.localizedDescription)
        }
        XCTAssertEqual(coordinator.store.sessions.map(\.id), [s1.id], "no session was opened")
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

    func testAHandoffRequestOpensTheHandoff() throws {
        let coordinator = makeCoordinator()
        defer { stopAll(coordinator) }

        let s1 = try coordinator.newSession(cwd: folder, agent: .claude, mode: .new)
        let req = OpenRequest(agent: .codex, folder: folder, prompt: nil, tier: .standard, task: nil,
                              handoffFrom: s1.id, goal: "Continue from handoff")
        try handoffRequests.submit(req)
        coordinator.handleOpenRequests()

        let answer = try XCTUnwrap(handoffRequests.result(for: req.id))
        XCTAssertTrue(answer.ok, answer.message)
        let s2 = try XCTUnwrap(coordinator.store.session(id: try XCTUnwrap(answer.sessionId)))
        XCTAssertEqual(s2.agentKind, .codex)
        XCTAssertFalse(s2.isWorker)
        XCTAssertEqual(coordinator.openingPrompts[s2.id]?.text,
                       "Please read .linkc/handoffs/\(s2.id).md and continue working on: Continue from handoff")
    }

    /// A handoff from a session linkC does not have is refused, and nothing opens.
    func testAHandoffFromAnUnknownSessionIsRefused() throws {
        let coordinator = makeCoordinator()
        defer { stopAll(coordinator) }

        let req = OpenRequest(agent: .codex, folder: folder, prompt: nil, tier: .standard, task: nil, handoffFrom: "invalid-id")
        try handoffRequests.submit(req)
        coordinator.handleOpenRequests()

        let answer = try XCTUnwrap(handoffRequests.result(for: req.id))
        XCTAssertFalse(answer.ok)
        XCTAssertEqual(answer.message, "no linkC session invalid-id to hand off")
        XCTAssertEqual(coordinator.store.sessions, [])
    }

    /// A handoff request names the session it hands off.
    func testAHandoffRequestNamingNoSessionIsRefused() throws {
        let coordinator = makeCoordinator()
        defer { stopAll(coordinator) }

        let req = OpenRequest(agent: .codex, folder: folder, prompt: nil, tier: nil, task: nil)
        try handoffRequests.submit(req)
        coordinator.handleOpenRequests()

        let answer = try XCTUnwrap(handoffRequests.result(for: req.id))
        XCTAssertFalse(answer.ok)
        XCTAssertEqual(coordinator.store.sessions, [])
    }

    /// The `linkc` command's folder only opens sessions. A handoff left there is refused rather than
    /// opened as a plain session with no memo, which is what a linkC that predates handoffs did with it.
    func testAHandoffInTheLinkcCommandsFolderIsRefused() throws {
        let coordinator = makeCoordinator()
        defer { stopAll(coordinator) }

        let s1 = try coordinator.newSession(cwd: folder, agent: .claude, mode: .new)
        let req = OpenRequest(agent: .codex, folder: folder, prompt: nil, tier: nil, task: nil, handoffFrom: s1.id)
        try requests.submit(req)
        coordinator.handleOpenRequests()

        let answer = try XCTUnwrap(requests.result(for: req.id))
        XCTAssertFalse(answer.ok, answer.message)
        XCTAssertEqual(coordinator.store.sessions.map(\.id), [s1.id], "no session was opened")
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
        try handoffRequests.submit(req)
        coordinator.handleOpenRequests()

        let answer = try XCTUnwrap(handoffRequests.result(for: req.id))
        XCTAssertTrue(answer.ok, answer.message)
        XCTAssertEqual(tornOff, [try XCTUnwrap(answer.sessionId)])
    }
}

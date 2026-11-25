import XCTest
@testable import LinkCKit

/// The agy sessions the user opens, or that come back after a quit: they open on agy's default
/// tier's model, so a limit they hit is recorded for that model's pool and not for all of agy.
/// A stand-in agent records the argv it was started with.
@MainActor
final class AppCoordinatorAgyModelTests: XCTestCase {
    nonisolated(unsafe) private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-agy-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private func makeCoordinator(
        models: AgentModelSettings = .seeded,
        lists: @escaping @MainActor @Sendable () throws -> [AgentKind: AgentModelList] = TestModelLists.none
    ) throws -> AppCoordinator {
        let stub = tempDir.appendingPathComponent("stub-agy.sh")
        let script = "#!/bin/sh\n"
            + "printf '%s\\n' \"$@\" > \"$(dirname \"$0\")/argv-$LINKC_SESSION\"\n"
            + "stty -echo 2>/dev/null\nprintf '\\033[?2004h'\nexec /bin/cat\n"
        try script.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let settingsDir = tempDir.appendingPathComponent("settings")
        let agent = stub.path
        return AppCoordinator(
            terminals: TerminalSessionManager(),
            hookServer: HookServer.forTesting(),
            notifications: NotificationManager(sink: NullSink(), now: { Date() }),
            claudePath: "/x/claude",
            settingsDir: settingsDir,
            userSettingsURL: tempDir.appendingPathComponent("no-such-settings.json"),
            manifestDir: settingsDir,
            agentPathResolver: { _ in agent },
            modelSettings: { models },
            modelLists: lists,
            deliverySettle: 0,
            turnEndQuietPeriod: 0,
            isWatching: { _ in false }
        )
    }

    private struct NullSink: NotificationSink {
        func deliver(id: String, title: String, body: String) {}
    }

    /// The argv the stand-in recorded, polled for up to five seconds until it holds `count` lines.
    private func launchedArguments(of session: Session, count: Int) -> [String] {
        let file = tempDir.appendingPathComponent("argv-\(session.id)")
        var lines: [String] = []
        let deadline = Date().addingTimeInterval(5)
        while lines.count < count, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            lines = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }
        return lines
    }

    private func waitUntil(_ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while !predicate(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        return predicate()
    }

    private let yolo = AgentDescriptor.descriptor(for: .agy).yoloFlags

    /// The default tier is standard in the seeded settings, whose agy model is `gemini-3.8-flash-medium`.
    func testAUserOpenedAgySessionOpensOnTheDefaultTiersModel() throws {
        let coordinator = try makeCoordinator()
        defer { coordinator.shutdown() }

        let session = try coordinator.newSession(cwd: tempDir.path, agent: .agy, mode: .new)

        XCTAssertEqual(launchedArguments(of: session, count: yolo.count + 2),
                       yolo + ["--model", "gemini-3.8-flash-medium"])
        XCTAssertEqual(session.model, "gemini-3.8-flash-medium")
        XCTAssertNil(session.modelTier, "a tier the user never asked for must not make their session a task carrier")
    }

    func testAnAgySessionOnATierStillRunsOnThatTiersModel() throws {
        let coordinator = try makeCoordinator()
        defer { coordinator.shutdown() }

        let session = try coordinator.newSession(cwd: tempDir.path, agent: .agy, mode: .new, tier: .light)

        // No agy list has been read, so which levels Flash takes is unknown: the configured id runs
        // as it is, at the level it names, with no --effort.
        XCTAssertEqual(launchedArguments(of: session, count: yolo.count + 2),
                       yolo + ["--model", "gemini-3.8-flash-low"])
        XCTAssertEqual(session.modelTier, .light)
    }

    // MARK: - Effort

    /// agy lists Flash at low, medium and high, so the tier's effort (here not the light default)
    /// goes in `--effort` on Flash's base id, which agy resolves to that level.
    func testAnAgyTierWhoseModelListsTheLevelLaunchesTheBaseIdAtTheTiersEffort() throws {
        var models = AgentModelSettings.seeded
        models.setEffort(.high, for: .agy, tier: .light)
        let coordinator = try makeCoordinator(models: models, lists: TestModelLists.agy)
        defer { coordinator.shutdown() }

        let session = try coordinator.newSession(cwd: tempDir.path, agent: .agy, mode: .new, tier: .light)

        XCTAssertEqual(launchedArguments(of: session, count: yolo.count + 4),
                       yolo + ["--model", "gemini-3.8-flash", "--effort", "high"])
    }

    /// agy refuses `--effort` for its Claude models, which list no level: the worker would die at
    /// launch. The id runs as configured, with no flag.
    func testAnAgyClaudeModelLaunchesAsConfiguredWithNoEffort() throws {
        var models = AgentModelSettings.seeded
        models.setModel("claude-opus-4-6-thinking", for: .agy, tier: .deep)
        let coordinator = try makeCoordinator(models: models, lists: TestModelLists.agy)
        defer { coordinator.shutdown() }

        let session = try coordinator.newSession(cwd: tempDir.path, agent: .agy, mode: .new, tier: .deep)

        XCTAssertEqual(launchedArguments(of: session, count: yolo.count + 2),
                       yolo + ["--model", "claude-opus-4-6-thinking"])
    }

    /// agy lists GPT-OSS at medium only: high would be refused, so the id runs as configured; medium
    /// is a level agy lists, so it goes in `--effort`.
    func testAnAgyGptOssModelTakesOnlyTheLevelAgyListsForIt() throws {
        for (effort, expected) in [
            (ReasoningEffort.high, ["--model", "gpt-oss-120b-medium"]),
            (.medium, ["--model", "gpt-oss-120b", "--effort", "medium"]),
        ] {
            var models = AgentModelSettings.seeded
            models.setModel("gpt-oss-120b-medium", for: .agy, tier: .deep)
            models.setEffort(effort, for: .agy, tier: .deep)
            let coordinator = try makeCoordinator(models: models, lists: TestModelLists.agy)
            defer { coordinator.shutdown() }

            let session = try coordinator.newSession(cwd: tempDir.path, agent: .agy, mode: .new, tier: .deep)

            XCTAssertEqual(launchedArguments(of: session, count: yolo.count + expected.count), yolo + expected,
                           effort.rawValue)
        }
    }

    /// Flash has no xhigh: agy would refuse it, so the configured id runs at the level it names.
    func testAnAgyLevelTheModelLacksLaunchesTheIdAsConfigured() throws {
        var models = AgentModelSettings.seeded
        models.setEffort(.xhigh, for: .agy, tier: .light)
        let coordinator = try makeCoordinator(models: models, lists: TestModelLists.agy)
        defer { coordinator.shutdown() }

        let session = try coordinator.newSession(cwd: tempDir.path, agent: .agy, mode: .new, tier: .light)

        XCTAssertEqual(launchedArguments(of: session, count: yolo.count + 2),
                       yolo + ["--model", "gemini-3.8-flash-low"])
    }

    func testARestoredAgySessionOpensOnTheDefaultTiersModel() throws {
        WorkspaceManifest(directory: tempDir.appendingPathComponent("settings"))
            .upsert(RestorableSession(linkcId: "G1", cwd: tempDir.path, title: "proj", agentKind: .agy, wasActiveOnQuit: true))
        let coordinator = try makeCoordinator()
        defer { coordinator.shutdown() }

        coordinator.restoreActiveSessions()

        let session = try XCTUnwrap(coordinator.store.session(id: "G1"))
        XCTAssertEqual(launchedArguments(of: session, count: yolo.count + 3),
                       yolo + ["--continue", "--model", "gemini-3.8-flash-medium"])
        XCTAssertEqual(session.model, "gemini-3.8-flash-medium")
    }

    func testRestoringAnAgyCardOpensOnTheDefaultTiersModel() throws {
        let coordinator = try makeCoordinator()
        defer { coordinator.shutdown() }
        let card = RestorableSession(linkcId: "G-old", cwd: tempDir.path, title: "proj", agentKind: .agy,
                                     wasActiveOnQuit: false, endedAt: Date())

        let session = try coordinator.restore(card)

        XCTAssertEqual(launchedArguments(of: session, count: yolo.count + 3),
                       yolo + ["--continue", "--model", "gemini-3.8-flash-medium"])
        XCTAssertEqual(session.model, "gemini-3.8-flash-medium")
    }

    /// The default tier follows Settings, not the seeded value.
    func testTheDefaultTierComesFromSettings() throws {
        var models = AgentModelSettings.seeded
        models.setDefaultTier(.deep, for: .agy)
        models.setModel("claude-opus-4-6-thinking", for: .agy, tier: .deep)
        let coordinator = try makeCoordinator(models: models)
        defer { coordinator.shutdown() }

        let session = try coordinator.newSession(cwd: tempDir.path, agent: .agy, mode: .new)

        XCTAssertEqual(session.model, "claude-opus-4-6-thinking")
        XCTAssertEqual(launchedArguments(of: session, count: yolo.count + 2),
                       yolo + ["--model", "claude-opus-4-6-thinking"])
    }

    /// agy has no model for its default tier: the user's own session opens as it always did, on
    /// whatever agy picks, and is not refused.
    func testAnAgyDefaultTierWithNoModelOpensWithoutOne() throws {
        var models = AgentModelSettings.seeded
        models.setModel("", for: .agy, tier: .standard)
        let coordinator = try makeCoordinator(models: models)
        defer { coordinator.shutdown() }

        let session = try coordinator.newSession(cwd: tempDir.path, agent: .agy, mode: .new)

        XCTAssertEqual(launchedArguments(of: session, count: yolo.count), yolo)
        XCTAssertNil(session.model)
        XCTAssertNil(session.modelTier)
    }

    /// `--conversation` is how agy picks a past conversation; nothing is appended after it.
    func testResumingAnAgyConversationPassesNoModel() throws {
        let coordinator = try makeCoordinator()
        defer { coordinator.shutdown() }

        let session = try coordinator.newSession(cwd: tempDir.path, agent: .agy, mode: .resume)

        XCTAssertEqual(launchedArguments(of: session, count: yolo.count + 1), yolo + ["--conversation"])
        XCTAssertNil(session.model)
    }

    /// Only agy gains a default model: Claude and Codex sessions the user opens are unchanged.
    func testAUserOpenedCodexSessionStillOpensWithNoModel() throws {
        let coordinator = try makeCoordinator()
        defer { coordinator.shutdown() }

        let session = try coordinator.newSession(cwd: tempDir.path, agent: .codex, mode: .new)

        let expected = AgentDescriptor.arguments(for: .codex, mode: .new, sessionId: session.id)
        XCTAssertEqual(launchedArguments(of: session, count: expected.count), expected)
        XCTAssertNil(session.model)
    }

    /// A limit on the user's own agy session is recorded for the pool of the model it opened on, so
    /// agy's Claude/GPT pool stays free.
    func testALimitOnAUserOpenedAgySessionIsRecordedForTheGeminiPool() throws {
        let coordinator = try makeCoordinator()
        defer { coordinator.shutdown() }
        let inbox = InboxStore(workspaceRoot: tempDir.path)
        let session = try coordinator.newSession(cwd: tempDir.path, agent: .agy, mode: .new)
        coordinator.store.updateState(id: session.id, to: .finished)
        coordinator.terminals.sendInput(sessionId: session.id, text: "quota exceeded\n")
        XCTAssertTrue(waitUntil {
            coordinator.terminals.session(id: session.id)?.recentOutput(lines: 10).contains("quota exceeded") ?? false
        }, "the stand-in never echoed the banner")

        coordinator.checkLimitsAndReroute(for: session.id)

        let rows = try inbox.load().agentLimits
        XCTAssertEqual(rows.map(\.agent), [.agy])
        XCTAssertEqual(rows.first?.pool, "gemini")
        XCTAssertNotNil(try inbox.isAgentLimited(agent: .agy, model: "gemini-3.8-flash-medium"))
        XCTAssertNil(try inbox.isAgentLimited(agent: .agy, model: "claude-opus-4-6-thinking"),
                     "a Gemini limit leaves the Claude/GPT pool free")
    }
}

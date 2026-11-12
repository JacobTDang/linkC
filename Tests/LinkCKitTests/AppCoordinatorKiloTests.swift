import XCTest
@testable import LinkCKit

/// Kilo sessions as linkC launches them, read back from a stand-in agent that records its
/// argv and environment.
@MainActor
final class AppCoordinatorKiloTests: XCTestCase {
    nonisolated(unsafe) private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-kilo-launch-\(UUID().uuidString)")
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

    /// The stand-in agent's path: it writes its argv to `argv-<LINKC_SESSION>` and the two
    /// variables a Kilo terminal adds to `env-<LINKC_SESSION>`, then waits for input like a TUI.
    var stubAgent: URL { tempDir.appendingPathComponent("stub-kilo.sh") }

    func makeCoordinator(models: AgentModelSettings = .seeded, sink: NotificationSink = RecordingSink()) throws -> AppCoordinator {
        let script = "#!/bin/sh\n"
            + "printf '%s\\n' \"$@\" > \"$(dirname \"$0\")/argv-$LINKC_SESSION\"\n"
            + "printf 'KILO_DISABLE_AUTOUPDATE=%s\\nKILO_CONFIG_CONTENT=%s\\n' \"$KILO_DISABLE_AUTOUPDATE\" \"$KILO_CONFIG_CONTENT\" > \"$(dirname \"$0\")/env-$LINKC_SESSION\"\n"
            + "stty -echo 2>/dev/null\nprintf '\\033[?2004h'\nexec /bin/cat\n"
        try script.write(to: stubAgent, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stubAgent.path)
        let settingsDir = tempDir.appendingPathComponent("settings")
        let agent = stubAgent.path
        return AppCoordinator(
            terminals: TerminalSessionManager(),
            hookServer: HookServer(port: 0, statusLineCacheURL: tempDir.appendingPathComponent("status-line.json")),
            notifications: NotificationManager(sink: sink, now: { Date() }),
            claudePath: "/x/claude",
            settingsDir: settingsDir,
            userSettingsURL: tempDir.appendingPathComponent("no-such-settings.json"),
            manifestDir: settingsDir,
            agentPathResolver: { _ in agent },
            modelSettings: { models },
            modelLists: TestModelLists.none,
            deliverySettle: 0,
            turnEndQuietPeriod: 0.0,
            isWatching: { _ in false }
        )
    }

    /// The lines the stand-in wrote to `<name>-<session id>`, polled for up to five seconds until
    /// there are `count` of them.
    func launchedLines(_ name: String, of session: Session, count: Int) -> [String] {
        let file = tempDir.appendingPathComponent("\(name)-\(session.id)")
        var lines: [String] = []
        let deadline = Date().addingTimeInterval(5)
        while lines.count < count, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            lines = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }
        return lines
    }

    /// The inline config the session's Kilo was started with.
    func kiloConfig(of session: Session) throws -> [String: Any] {
        let env = launchedLines("env", of: session, count: 2)
        XCTAssertEqual(env.first, "KILO_DISABLE_AUTOUPDATE=1")
        let prefix = "KILO_CONFIG_CONTENT="
        let line = try XCTUnwrap(env.last)
        XCTAssertTrue(line.hasPrefix(prefix), line)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(line.dropFirst(prefix.count).utf8)) as? [String: Any])
    }

    /// Kilo would otherwise run on whatever it picks, so even a session the user opens names its
    /// model: the default tier's. No tier was asked for, so none is recorded.
    func testAKiloSessionOpenedWithNoTierRunsOnTheDefaultTiersModel() throws {
        let coordinator = try makeCoordinator()
        defer { coordinator.shutdown() }

        let session = try coordinator.newSession(cwd: tempDir.path, agent: .kilo, mode: .new)

        XCTAssertEqual(session.agentKind, .kilo)
        XCTAssertEqual(session.model, "kilo/kilo-auto/free")
        XCTAssertNil(session.modelTier, "a tier the user never asked for must not make their session a task carrier")
        XCTAssertEqual(launchedLines("argv", of: session, count: 1), ["--auto"], "model via KILO_CONFIG_CONTENT, not argv")
        XCTAssertEqual(try kiloConfig(of: session)["model"] as? String, "kilo/kilo-auto/free")
    }

    func testAKiloSessionOnATierRunsOnThatTiersModel() throws {
        let coordinator = try makeCoordinator()
        defer { coordinator.shutdown() }

        let session = try coordinator.newSession(cwd: tempDir.path, agent: .kilo, mode: .new, tier: .deep)

        XCTAssertEqual(session.model, "kilo/nvidia/nemotron-3-ultra-550b-a55b:free")
        XCTAssertEqual(session.modelTier, .deep)
        XCTAssertEqual(try kiloConfig(of: session)["model"] as? String, "kilo/nvidia/nemotron-3-ultra-550b-a55b:free")
    }

    func testAKiloTerminalHasLinkCsToolsInline() throws {
        let coordinator = try makeCoordinator()
        defer { coordinator.shutdown() }

        let session = try coordinator.newSession(cwd: tempDir.path, agent: .kilo, mode: .new)

        let entry = try XCTUnwrap((try kiloConfig(of: session)["mcp"] as? [String: Any])?["linkc-multiplier"] as? [String: Any])
        XCTAssertEqual(entry["command"] as? [String], [MCPRegistrar.defaultBinaryPath()])
        XCTAssertEqual(entry["environment"] as? [String: String], ["LINKC_AGENT": "kilo"])
    }

    func testAKiloSessionWithNoModelForItsTierIsRefused() throws {
        var models = AgentModelSettings.seeded
        models.setModel("", for: .kilo, tier: .standard)
        let coordinator = try makeCoordinator(models: models)
        defer { coordinator.shutdown() }

        XCTAssertThrowsError(try coordinator.newSession(cwd: tempDir.path, agent: .kilo, mode: .new)) { error in
            XCTAssertTrue(String(describing: error).contains("no model configured for kilo tier standard — set it in linkC settings"),
                          String(describing: error))
        }
        XCTAssertTrue(coordinator.store.sessions.isEmpty, "a refused launch leaves no session behind")
    }

    // MARK: - Kilo never resumes

    /// Kilo's own continue would resume a conversation on whatever model it last ran, which
    /// linkC cannot see and which could be a paid one. So every path that would resume one opens a
    /// new conversation in the same folder, on the free default-tier model.
    private func assertOpensFresh(_ session: Session, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(launchedLines("argv", of: session, count: 1), ["--auto"],
                       "no --continue, --session or --conversation", file: file, line: line)
        XCTAssertEqual(session.model, "kilo/kilo-auto/free", file: file, line: line)
        XCTAssertEqual(try kiloConfig(of: session)["model"] as? String, "kilo/kilo-auto/free", file: file, line: line)
    }

    func testContinuingKiloOpensANewConversationOnTheFreeDefaultModel() throws {
        let coordinator = try makeCoordinator()
        defer { coordinator.shutdown() }

        let session = try coordinator.newSession(cwd: tempDir.path, agent: .kilo, mode: .continueLast)

        try assertOpensFresh(session)
        XCTAssertNil(session.modelTier, "a tier the user never asked for must not make their session a task carrier")
    }

    func testResumingKiloOpensANewConversationOnTheFreeDefaultModel() throws {
        let coordinator = try makeCoordinator()
        defer { coordinator.shutdown() }

        let session = try coordinator.newSession(cwd: tempDir.path, agent: .kilo, mode: .resume)

        try assertOpensFresh(session)
    }

    /// The manifest of a linkC that quit with a Kilo session live in `tempDir`.
    private func seedKiloEntry(id: String = "KI1", worker: Bool = false) {
        WorkspaceManifest(directory: tempDir.appendingPathComponent("settings"))
            .upsert(RestorableSession(linkcId: id, cwd: tempDir.path, title: "proj", agentKind: .kilo,
                                      wasActiveOnQuit: true, isWorker: worker))
    }

    func testARelaunchRestoresAKiloSessionAsANewConversationOnTheFreeDefaultModel() throws {
        seedKiloEntry()
        let coordinator = try makeCoordinator()
        defer { coordinator.shutdown() }

        coordinator.restoreActiveSessions()

        let session = try XCTUnwrap(coordinator.store.session(id: "KI1"))
        try assertOpensFresh(session)
        XCTAssertTrue(coordinator.restorables.isEmpty, "the entry came back live")
    }

    /// The user is told: a restored Kilo session is not the conversation they left.
    func testARestoredKiloSessionSaysItStartedFresh() throws {
        seedKiloEntry()
        let sink = RecordingSink()
        let coordinator = try makeCoordinator(sink: sink)
        defer { coordinator.shutdown() }

        coordinator.restoreActiveSessions()

        let notice = try XCTUnwrap(sink.deliveries.first { $0.title == "linkC: Kilo started a new conversation" })
        XCTAssertEqual(notice.body, "proj: Kilo starts a new conversation on restore, so it only ever runs a free model.")
    }

    func testRestoringAKiloCardOpensANewConversationOnTheFreeDefaultModel() throws {
        let coordinator = try makeCoordinator()
        defer { coordinator.shutdown() }
        let card = RestorableSession(linkcId: "KI-old", cwd: tempDir.path, title: "proj", agentKind: .kilo,
                                     wasActiveOnQuit: false, endedAt: Date())

        let session = try coordinator.restore(card)

        try assertOpensFresh(session)
    }

    /// Every Kilo conversation is new, so a live one in the folder is no reason to refuse.
    func testRestoringAKiloCardNextToALiveOneIsNotRefused() throws {
        let coordinator = try makeCoordinator()
        defer { coordinator.shutdown() }
        let live = try coordinator.newSession(cwd: tempDir.path, agent: .kilo, mode: .new)
        let card = RestorableSession(linkcId: "KI-old", cwd: tempDir.path, title: "proj", agentKind: .kilo,
                                     wasActiveOnQuit: false, endedAt: Date())

        let restored = try coordinator.restore(card)

        XCTAssertNotEqual(restored.id, live.id)
        XCTAssertEqual(coordinator.store.sessions.filter { $0.agentKind == .kilo }.count, 2)
    }

    /// A paid default model must not slip in through a restore: the entry stays under Earlier, and
    /// Kilo never starts.
    func testARestoreWhoseDefaultModelIsNotFreeStaysUnderEarlier() throws {
        seedKiloEntry()
        var models = AgentModelSettings.seeded
        models.setModel("kilo/anthropic/claude-opus", for: .kilo, tier: .standard)
        let coordinator = try makeCoordinator(models: models)
        defer { coordinator.shutdown() }

        coordinator.restoreActiveSessions()

        XCTAssertNil(coordinator.store.session(id: "KI1"))
        XCTAssertEqual(coordinator.restorables.map(\.linkcId), ["KI1"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("argv-KI1").path))
    }

    /// Other agents keep their own continue and restore: only Kilo's is replaced.
    func testRestoringACodexSessionStillResumesItsLastConversation() throws {
        let coordinator = try makeCoordinator()
        defer { coordinator.shutdown() }
        let card = RestorableSession(linkcId: "CX-old", cwd: tempDir.path, title: "proj", agentKind: .codex,
                                     wasActiveOnQuit: false, endedAt: Date())

        let session = try coordinator.restore(card)

        let expected = AgentDescriptor.arguments(for: .codex, mode: .continueLast, sessionId: session.id)
        XCTAssertEqual(Array(expected.suffix(2)), ["resume", "--last"])
        XCTAssertEqual(launchedLines("argv", of: session, count: expected.count), expected)
    }

    func testOnlyAKiloTerminalGetsKilosVariables() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["KILO_CONFIG_CONTENT"] != nil
                      || ProcessInfo.processInfo.environment["KILO_DISABLE_AUTOUPDATE"] != nil, "run from inside Kilo")
        let coordinator = try makeCoordinator()
        defer { coordinator.shutdown() }

        let session = try coordinator.newSession(cwd: tempDir.path, agent: .codex, mode: .new)

        XCTAssertEqual(launchedLines("env", of: session, count: 2),
                       ["KILO_DISABLE_AUTOUPDATE=", "KILO_CONFIG_CONTENT="])
    }

    /// Launch pins the model through the env var only — the user's global Kilo config is never
    /// written as part of starting a session (K2 registers MCP there; K1 does not).
    func testKiloConfigContentIsInlineOnly() throws {
        let content = try MCPRegistrar.kiloConfigContent(
            inherited: nil, binaryPath: "/tmp/linkc-mcp", model: "kilo/kilo-auto/free")
        XCTAssertTrue(content.contains("\"model\":\"kilo/kilo-auto/free\""))
        XCTAssertTrue(content.contains("\"LINKC_AGENT\":\"kilo\""))
        XCTAssertFalse(content.contains("\n"), "one line, for the environment")
    }
}

import XCTest
@testable import LinkCKit

/// OpenCode sessions as linkC launches them, read back from a stand-in agent that records its
/// argv and environment.
@MainActor
final class AppCoordinatorOpenCodeTests: XCTestCase {
    nonisolated(unsafe) private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-opencode-launch-\(UUID().uuidString)")
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
    /// variables an OpenCode terminal adds to `env-<LINKC_SESSION>`, then waits for input like a TUI.
    var stubAgent: URL { tempDir.appendingPathComponent("stub-opencode.sh") }

    func makeCoordinator(models: AgentModelSettings = .seeded, sink: NotificationSink = RecordingSink(),
                         conversations: OpenCodeConversationReader = .unavailable) throws -> AppCoordinator {
        let script = "#!/bin/sh\n"
            + "printf '%s\\n' \"$@\" > \"$(dirname \"$0\")/argv-$LINKC_SESSION\"\n"
            + "printf 'OPENCODE_DISABLE_AUTOUPDATE=%s\\nOPENCODE_CONFIG_CONTENT=%s\\n' \"$OPENCODE_DISABLE_AUTOUPDATE\" \"$OPENCODE_CONFIG_CONTENT\" > \"$(dirname \"$0\")/env-$LINKC_SESSION\"\n"
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
            kiloModels: { _ in [] },
            openCodeConversations: conversations,
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

    /// The inline config the session's OpenCode was started with.
    func openCodeConfig(of session: Session) throws -> [String: Any] {
        let env = launchedLines("env", of: session, count: 2)
        XCTAssertEqual(env.first, "OPENCODE_DISABLE_AUTOUPDATE=1")
        let prefix = "OPENCODE_CONFIG_CONTENT="
        let line = try XCTUnwrap(env.last)
        XCTAssertTrue(line.hasPrefix(prefix), line)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(line.dropFirst(prefix.count).utf8)) as? [String: Any])
    }

    /// OpenCode would otherwise run on whatever it picks — for Jacob, possibly a local model — so even
    /// a session the user opens names its model: the default tier's. No tier was asked for, so none
    /// is recorded, and the session is never handed a delegated task.
    func testAnOpenCodeSessionOpenedWithNoTierRunsOnTheDefaultTiersModel() throws {
        let coordinator = try makeCoordinator()
        defer { coordinator.shutdown() }

        let session = try coordinator.newSession(cwd: tempDir.path, agent: .opencode, mode: .new)

        XCTAssertEqual(session.agentKind, .opencode)
        XCTAssertEqual(session.model, "opencode/deepseek-v4.1-flash-free")
        XCTAssertNil(session.modelTier, "a tier the user never asked for must not make their session a task carrier")
        XCTAssertEqual(launchedLines("argv", of: session, count: 4), ["--standalone", "--auto", "--session", try XCTUnwrap(session.claudeSessionId)],
                       "no --model: OpenCode 2.2.5 refuses it")
        XCTAssertEqual(try openCodeConfig(of: session)["model"] as? String, "opencode/deepseek-v4.1-flash-free")
    }

    /// A user-global `agent.build.model` beats the inline top-level `model` in OpenCode's TUI, so every
    /// agent that runs on the session's model is pinned to it.
    func testAnOpenCodeSessionPinsEveryAgentToTheSessionsModel() throws {
        let coordinator = try makeCoordinator()
        defer { coordinator.shutdown() }

        let session = try coordinator.newSession(cwd: tempDir.path, agent: .opencode, mode: .new, tier: .deep)

        let agents = try XCTUnwrap(try openCodeConfig(of: session)["agent"] as? [String: [String: Any]])
        XCTAssertEqual(Set(agents.keys), Set(AgentDescriptor.openCodeAgents))
        for (name, settings) in agents {
            XCTAssertEqual(settings["model"] as? String, "opencode/nemotron-3.5-super-vl-free", "agent \(name)")
        }
    }

    func testAnOpenCodeSessionOnATierRunsOnThatTiersModel() throws {
        let coordinator = try makeCoordinator()
        defer { coordinator.shutdown() }

        let session = try coordinator.newSession(cwd: tempDir.path, agent: .opencode, mode: .new, tier: .deep)

        XCTAssertEqual(session.model, "opencode/nemotron-3.5-super-vl-free")
        XCTAssertEqual(session.modelTier, .deep)
        XCTAssertEqual(try openCodeConfig(of: session)["model"] as? String, "opencode/nemotron-3.5-super-vl-free")
    }

    func testAnOpenCodeTerminalHasLinkCsToolsInline() throws {
        let coordinator = try makeCoordinator()
        defer { coordinator.shutdown() }

        let session = try coordinator.newSession(cwd: tempDir.path, agent: .opencode, mode: .new)

        let entry = try XCTUnwrap((try openCodeConfig(of: session)["mcp"] as? [String: Any])?["linkc-multiplier"] as? [String: Any])
        XCTAssertEqual(entry["command"] as? [String], [MCPRegistrar.defaultBinaryPath()])
        XCTAssertEqual(entry["environment"] as? [String: String], ["LINKC_AGENT": "opencode"])
    }

    func testAnOpenCodeSessionWithNoModelForItsTierIsRefused() throws {
        var models = AgentModelSettings.seeded
        models.setModel("", for: .opencode, tier: .light)
        let coordinator = try makeCoordinator(models: models)
        defer { coordinator.shutdown() }

        XCTAssertThrowsError(try coordinator.newSession(cwd: tempDir.path, agent: .opencode, mode: .new)) { error in
            XCTAssertTrue(String(describing: error).contains("no model configured for opencode tier light — set it in linkC settings"),
                          String(describing: error))
        }
        XCTAssertTrue(coordinator.store.sessions.isEmpty, "a refused launch leaves no session behind")
    }

    // MARK: - OpenCode reopens its own conversation

    /// OpenCode's answers about its conversations, as a test sets them.
    final class FakeConversations: @unchecked Sendable {
        private let lock = NSLock()
        private var _models: [String: String] = [:]
        private var _newestFirst: [String] = []
        private var _failure: String?
        private var _asked: [String] = []

        /// Conversation id → the model it last ran on. An id that is absent is one OpenCode does not have.
        var models: [String: String] {
            get { lock.lock(); defer { lock.unlock() }; return _models }
            set { lock.lock(); _models = newValue; lock.unlock() }
        }
        /// The folder's conversations, newest first.
        var newestFirst: [String] {
            get { lock.lock(); defer { lock.unlock() }; return _newestFirst }
            set { lock.lock(); _newestFirst = newValue; lock.unlock() }
        }
        /// When set, OpenCode cannot answer, for this reason.
        var failure: String? {
            get { lock.lock(); defer { lock.unlock() }; return _failure }
            set { lock.lock(); _failure = newValue; lock.unlock() }
        }
        var asked: [String] { lock.lock(); defer { lock.unlock() }; return _asked }

        private func answer<T>(_ question: String, _ value: () -> T) throws -> T {
            lock.lock(); defer { lock.unlock() }
            _asked.append(question)
            if let reason = _failure { throw LinkCError.process(reason) }
            return value()
        }

        var reader: OpenCodeConversationReader {
            OpenCodeConversationReader(
                model: { id, _ in try self.answer("export \(id)") { self._models[id] } },
                conversations: { _ in try self.answer("list") { self._newestFirst } })
        }
    }

    /// The model of OpenCode's default tier in the seeded settings.
    private let defaultModel = "opencode/deepseek-v4.1-flash-free"

    /// The manifest of a linkC that quit with an OpenCode session live in `tempDir`.
    private func seedOpenCodeEntry(id: String = "OC1", conversation: String? = nil, worker: Bool = false) {
        WorkspaceManifest(directory: tempDir.appendingPathComponent("settings"))
            .upsert(RestorableSession(linkcId: id, claudeSessionId: conversation, cwd: tempDir.path, title: "proj",
                                      agentKind: .opencode, wasActiveOnQuit: true, isWorker: worker))
    }

    private func card(conversation: String? = nil) -> RestorableSession {
        RestorableSession(linkcId: "OC-old", claudeSessionId: conversation, cwd: tempDir.path, title: "proj",
                          agentKind: .opencode, wasActiveOnQuit: false, endedAt: Date())
    }

    /// The conversation the session's OpenCode was started on: the id after `--session`.
    private func openedConversation(_ session: Session, file: StaticString = #filePath, line: UInt = #line) -> String? {
        let argv = launchedLines("argv", of: session, count: 4)
        XCTAssertEqual(Array(argv.prefix(3)), ["--standalone", "--auto", "--session"], file: file, line: line)
        return argv.count == 4 ? argv[3] : nil
    }

    private func newConversationNotices(_ sink: RecordingSink) -> [String] {
        sink.deliveries.filter { $0.title == "linkC: OpenCode started a new conversation" }.map(\.body)
    }

    /// linkC names each new conversation, so that a restore can reopen exactly that one.
    func testANewOpenCodeSessionGetsItsOwnConversationId() throws {
        let coordinator = try makeCoordinator()
        defer { coordinator.shutdown() }

        let session = try coordinator.newSession(cwd: tempDir.path, agent: .opencode, mode: .new)

        let id = try XCTUnwrap(session.claudeSessionId)
        XCTAssertTrue(id.hasPrefix("ses_linkc"), id)
        XCTAssertEqual(openedConversation(session), id)
        let entry = WorkspaceManifest(directory: tempDir.appendingPathComponent("settings")).entries.first { $0.linkcId == session.id }
        XCTAssertEqual(entry?.claudeSessionId, id, "the manifest keeps the id for the next restore")
    }

    func testARelaunchReopensTheSessionsOwnConversationOnTheDefaultModel() throws {
        seedOpenCodeEntry(conversation: "ses_linkcmine")
        let fake = FakeConversations()
        fake.models = ["ses_linkcmine": defaultModel]
        let sink = RecordingSink()
        let coordinator = try makeCoordinator(sink: sink, conversations: fake.reader)
        defer { coordinator.shutdown() }

        coordinator.restoreActiveSessions()

        let session = try XCTUnwrap(coordinator.store.session(id: "OC1"))
        XCTAssertEqual(openedConversation(session), "ses_linkcmine")
        XCTAssertEqual(session.claudeSessionId, "ses_linkcmine")
        XCTAssertEqual(session.model, defaultModel, "the conversation keeps its own model")
        XCTAssertNil(session.modelTier)
        XCTAssertEqual(try openCodeConfig(of: session)["model"] as? String, defaultModel)
        XCTAssertEqual(fake.asked, ["export ses_linkcmine"])
        XCTAssertEqual(newConversationNotices(sink), [])
    }

    func testRestoringAnOpenCodeCardReopensItsConversation() throws {
        let fake = FakeConversations()
        fake.models = ["ses_linkcmine": defaultModel]
        let coordinator = try makeCoordinator(conversations: fake.reader)
        defer { coordinator.shutdown() }

        let session = try coordinator.restore(card(conversation: "ses_linkcmine"))

        XCTAssertEqual(openedConversation(session), "ses_linkcmine")
        XCTAssertTrue(coordinator.restorables.isEmpty)
    }

    /// OpenCode would reopen a conversation on the model it last ran on, ahead of linkC's pin. One that
    /// ran on any model but the default is therefore not reopened, and the user is told why.
    func testAConversationOnAPaidModelIsNotReopened() throws {
        seedOpenCodeEntry(conversation: "ses_linkcpaid")
        let fake = FakeConversations()
        fake.models = ["ses_linkcpaid": "anthropic/claude-opus-4"]
        let sink = RecordingSink()
        let coordinator = try makeCoordinator(sink: sink, conversations: fake.reader)
        defer { coordinator.shutdown() }

        coordinator.restoreActiveSessions()

        let session = try XCTUnwrap(coordinator.store.session(id: "OC1"))
        let id = try XCTUnwrap(session.claudeSessionId)
        XCTAssertNotEqual(id, "ses_linkcpaid")
        XCTAssertTrue(id.hasPrefix("ses_linkc"), id)
        XCTAssertEqual(openedConversation(session), id)
        XCTAssertEqual(session.model, defaultModel)
        XCTAssertEqual(newConversationNotices(sink),
                       ["proj: its last conversation ran on anthropic/claude-opus-4, not the default opencode/deepseek-v4.1-flash-free, so OpenCode started a new one."])
    }

    func testAConversationOnAnotherFreeModelIsNotReopened() throws {
        seedOpenCodeEntry(conversation: "ses_linkcpickle")
        let fake = FakeConversations()
        fake.models = ["ses_linkcpickle": "opencode/big-pickle"]
        let sink = RecordingSink()
        let coordinator = try makeCoordinator(sink: sink, conversations: fake.reader)
        defer { coordinator.shutdown() }

        coordinator.restoreActiveSessions()

        let session = try XCTUnwrap(coordinator.store.session(id: "OC1"))
        let id = try XCTUnwrap(session.claudeSessionId)
        XCTAssertNotEqual(id, "ses_linkcpickle")
        XCTAssertEqual(openedConversation(session), id)
        XCTAssertEqual(session.model, defaultModel)
        XCTAssertEqual(try openCodeConfig(of: session)["model"] as? String, defaultModel)
        XCTAssertEqual(newConversationNotices(sink),
                       ["proj: its last conversation ran on opencode/big-pickle, not the default opencode/deepseek-v4.1-flash-free, so OpenCode started a new one."])
    }

    /// The default is the one in Settings > Models, not a fixed model.
    func testAConversationOnTheDefaultTheUserChoseIsReopened() throws {
        seedOpenCodeEntry(conversation: "ses_linkcpickle")
        var models = AgentModelSettings.seeded
        models.setDefaultTier(.standard, for: .opencode)
        let fake = FakeConversations()
        fake.models = ["ses_linkcpickle": "opencode/big-pickle"]
        let sink = RecordingSink()
        let coordinator = try makeCoordinator(models: models, sink: sink, conversations: fake.reader)
        defer { coordinator.shutdown() }

        coordinator.restoreActiveSessions()

        let session = try XCTUnwrap(coordinator.store.session(id: "OC1"))
        XCTAssertEqual(openedConversation(session), "ses_linkcpickle")
        XCTAssertEqual(session.model, "opencode/big-pickle")
        XCTAssertEqual(newConversationNotices(sink), [])
    }

    /// Continue does not reach past the folder's newest conversation for an older one on the default.
    func testContinuingWhenTheNewestConversationIsOnAnotherModelStartsANewOne() throws {
        let fake = FakeConversations()
        fake.newestFirst = ["ses_new", "ses_old"]
        fake.models = ["ses_new": "opencode/big-pickle", "ses_old": defaultModel]
        let sink = RecordingSink()
        let coordinator = try makeCoordinator(sink: sink, conversations: fake.reader)
        defer { coordinator.shutdown() }

        let session = try coordinator.newSession(cwd: tempDir.path, agent: .opencode, mode: .continueLast)

        let id = try XCTUnwrap(session.claudeSessionId)
        XCTAssertFalse(["ses_new", "ses_old"].contains(id), id)
        XCTAssertEqual(openedConversation(session), id)
        XCTAssertEqual(session.model, defaultModel)
        XCTAssertEqual(newConversationNotices(sink).count, 1)
    }

    /// A conversation that never got a message is not saved yet; OpenCode creates it under the same id.
    func testAConversationOpenCodeHasNotSavedOpensUnderTheSameId() throws {
        seedOpenCodeEntry(conversation: "ses_linkcempty")
        let sink = RecordingSink()
        let coordinator = try makeCoordinator(sink: sink, conversations: FakeConversations().reader)
        defer { coordinator.shutdown() }

        coordinator.restoreActiveSessions()

        let session = try XCTUnwrap(coordinator.store.session(id: "OC1"))
        XCTAssertEqual(openedConversation(session), "ses_linkcempty")
        XCTAssertEqual(session.model, defaultModel)
        XCTAssertEqual(newConversationNotices(sink), [])
    }

    /// When OpenCode cannot say which model a conversation ran on, linkC does not guess: the entry
    /// stays under Earlier and OpenCode never starts.
    func testARelaunchWhoseLookupFailsStaysUnderEarlier() throws {
        seedOpenCodeEntry(conversation: "ses_linkcmine")
        let fake = FakeConversations()
        fake.failure = "database is locked"
        let coordinator = try makeCoordinator(conversations: fake.reader)
        defer { coordinator.shutdown() }

        coordinator.restoreActiveSessions()

        XCTAssertNil(coordinator.store.session(id: "OC1"))
        XCTAssertEqual(coordinator.restorables.map(\.linkcId), ["OC1"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("argv-OC1").path))
    }

    func testRestoringACardWhoseLookupFailsSaysWhy() throws {
        let fake = FakeConversations()
        fake.failure = "database is locked"
        let coordinator = try makeCoordinator(conversations: fake.reader)
        defer { coordinator.shutdown() }

        XCTAssertThrowsError(try coordinator.restore(card(conversation: "ses_linkcmine"))) { error in
            XCTAssertTrue(String(describing: error).contains("database is locked"), String(describing: error))
        }
        XCTAssertTrue(coordinator.store.sessions.isEmpty)
    }

    /// Two sessions never share a conversation.
    func testRestoringACardWhoseConversationIsAlreadyOpenIsRefused() throws {
        let fake = FakeConversations()
        fake.models = ["ses_linkcmine": defaultModel]
        let coordinator = try makeCoordinator(conversations: fake.reader)
        defer { coordinator.shutdown() }
        _ = try coordinator.restore(card(conversation: "ses_linkcmine"))

        XCTAssertThrowsError(try coordinator.restore(card(conversation: "ses_linkcmine")))
        XCTAssertEqual(coordinator.store.sessions.count, 1)
    }

    /// Sessions saved before linkC named its conversations continue the folder's newest one.
    func testAnEntryWithNoConversationIdContinuesTheFoldersNewest() throws {
        seedOpenCodeEntry()
        let fake = FakeConversations()
        fake.newestFirst = ["ses_new", "ses_old"]
        fake.models = ["ses_new": defaultModel, "ses_old": defaultModel]
        let coordinator = try makeCoordinator(conversations: fake.reader)
        defer { coordinator.shutdown() }

        coordinator.restoreActiveSessions()

        let session = try XCTUnwrap(coordinator.store.session(id: "OC1"))
        XCTAssertEqual(openedConversation(session), "ses_new")
        XCTAssertEqual(session.claudeSessionId, "ses_new")
    }

    /// An entry saved before linkC named conversations never takes the one another entry reopens.
    func testAnEntryWithNoIdLeavesTheConversationAnotherEntryReopens() throws {
        seedOpenCodeEntry(id: "OLD")
        seedOpenCodeEntry(id: "NEW", conversation: "ses_new")
        let fake = FakeConversations()
        fake.newestFirst = ["ses_new", "ses_old"]
        fake.models = ["ses_new": defaultModel, "ses_old": defaultModel]
        let coordinator = try makeCoordinator(conversations: fake.reader)
        defer { coordinator.shutdown() }

        coordinator.restoreActiveSessions()

        XCTAssertEqual(openedConversation(try XCTUnwrap(coordinator.store.session(id: "OLD"))), "ses_old")
        XCTAssertEqual(openedConversation(try XCTUnwrap(coordinator.store.session(id: "NEW"))), "ses_new")
    }

    /// Continue last… continues the folder's newest conversation that no session has open.
    func testContinuingSkipsAConversationAlreadyOpen() throws {
        let fake = FakeConversations()
        fake.newestFirst = ["ses_new", "ses_old"]
        fake.models = ["ses_new": defaultModel, "ses_old": defaultModel]
        let coordinator = try makeCoordinator(conversations: fake.reader)
        defer { coordinator.shutdown() }

        let first = try coordinator.newSession(cwd: tempDir.path, agent: .opencode, mode: .continueLast)
        let second = try coordinator.newSession(cwd: tempDir.path, agent: .opencode, mode: .continueLast)

        XCTAssertEqual(openedConversation(first), "ses_new")
        XCTAssertEqual(openedConversation(second), "ses_old")
        XCTAssertNil(first.modelTier, "a tier the user never asked for must not make their session a task carrier")
    }

    func testResumingOpenCodeContinuesTheFoldersNewest() throws {
        let fake = FakeConversations()
        fake.newestFirst = ["ses_new"]
        fake.models = ["ses_new": defaultModel]
        let coordinator = try makeCoordinator(conversations: fake.reader)
        defer { coordinator.shutdown() }

        let session = try coordinator.newSession(cwd: tempDir.path, agent: .opencode, mode: .resume)

        XCTAssertEqual(openedConversation(session), "ses_new")
    }

    func testContinuingAFolderWithNoConversationStartsANewOne() throws {
        let sink = RecordingSink()
        let coordinator = try makeCoordinator(sink: sink, conversations: FakeConversations().reader)
        defer { coordinator.shutdown() }

        let session = try coordinator.newSession(cwd: tempDir.path, agent: .opencode, mode: .continueLast)

        let id = try XCTUnwrap(session.claudeSessionId)
        XCTAssertTrue(id.hasPrefix("ses_linkc"), id)
        XCTAssertEqual(openedConversation(session), id)
        XCTAssertEqual(session.model, defaultModel)
        XCTAssertEqual(newConversationNotices(sink),
                       ["\(tempDir.lastPathComponent): OpenCode has no earlier conversation here, so it started a new one."])
    }

    /// A paid default model must not slip in through a restore: the entry stays under Earlier, and
    /// OpenCode never starts.
    func testARestoreWhoseDefaultModelIsNotFreeStaysUnderEarlier() throws {
        seedOpenCodeEntry()
        var models = AgentModelSettings.seeded
        models.setModel("anthropic/claude-opus-4", for: .opencode, tier: .light)
        let fake = FakeConversations()
        let coordinator = try makeCoordinator(models: models, conversations: fake.reader)
        defer { coordinator.shutdown() }

        coordinator.restoreActiveSessions()

        XCTAssertEqual(fake.asked, ["list"], "the restore got as far as the model check")
        XCTAssertNil(coordinator.store.session(id: "OC1"))
        XCTAssertEqual(coordinator.restorables.map(\.linkcId), ["OC1"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("argv-OC1").path))
    }

    /// An OpenCode conversation id means nothing to another agent.
    func testRestoringAnOpenCodeCardAsCodexPassesNoConversation() throws {
        let fake = FakeConversations()
        let coordinator = try makeCoordinator(conversations: fake.reader)
        defer { coordinator.shutdown() }

        let session = try coordinator.restore(card(conversation: "ses_linkcmine"), as: .codex)

        let expected = AgentDescriptor.arguments(for: .codex, mode: .continueLast, sessionId: session.id)
        XCTAssertEqual(launchedLines("argv", of: session, count: expected.count), expected)
        XCTAssertNil(session.claudeSessionId)
        XCTAssertEqual(fake.asked, [])
    }

    /// Other agents keep their own continue and restore.
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

    func testOnlyAnOpenCodeTerminalGetsOpenCodesVariables() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["OPENCODE_CONFIG_CONTENT"] != nil
                      || ProcessInfo.processInfo.environment["OPENCODE_DISABLE_AUTOUPDATE"] != nil, "run from inside OpenCode")
        let coordinator = try makeCoordinator()
        defer { coordinator.shutdown() }

        let session = try coordinator.newSession(cwd: tempDir.path, agent: .codex, mode: .new)

        XCTAssertEqual(launchedLines("env", of: session, count: 2),
                       ["OPENCODE_DISABLE_AUTOUPDATE=", "OPENCODE_CONFIG_CONTENT="])
    }
}

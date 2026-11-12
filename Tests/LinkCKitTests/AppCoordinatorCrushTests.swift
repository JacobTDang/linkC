import XCTest
@testable import LinkCKit

/// Crush sessions as linkC launches them, read back from a stand-in agent that records its argv,
/// its environment and the config it was pointed at. Nothing here runs Crush or touches the real
/// `~/.config/crush`: the user's config and data folders are temporary ones passed to the coordinator.
@MainActor
final class AppCoordinatorCrushTests: XCTestCase {
    nonisolated(unsafe) private var tempDir: URL!
    private var userConfig: URL { tempDir.appendingPathComponent("user-crush-config") }
    private var userData: URL { tempDir.appendingPathComponent("user-crush-data") }
    private var sessionsRoot: URL { tempDir.appendingPathComponent("settings/crush-sessions") }
    private let standard = "openrouter/nvidia/nemotron-3.5-super-vl:free"
    private let userConfigText = #"{"providers":{"openrouter":{"api_key":"sk-or-user-key"}},"models":{"large":{"provider":"anthropic","model":"claude-opus-4-5"}}}"#

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-crush-launch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: userConfig, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: userData, withIntermediateDirectories: true)
        try userConfigText.write(to: userConfig.appendingPathComponent("crush.json"), atomically: true, encoding: .utf8)
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

    var stubAgent: URL { tempDir.appendingPathComponent("stub-crush.sh") }

    /// The stand-in writes its argv to `argv-<LINKC_SESSION>`, the two variables Crush reads to
    /// `env-<LINKC_SESSION>`, and a copy of the config it was pointed at to `config-<LINKC_SESSION>`.
    func makeCoordinator(models: AgentModelSettings = .seeded, sink: NotificationSink = RecordingSink(),
                         crushDirectories: CrushDirectories? = nil, withCrushDirectories: Bool = true) throws -> AppCoordinator {
        let script = "#!/bin/sh\n"
            + "d=\"$(dirname \"$0\")\"\n"
            + "printf '%s\\n' \"$@\" > \"$d/argv-$LINKC_SESSION\"\n"
            + "printf 'CRUSH_GLOBAL_CONFIG=%s\\nCRUSH_GLOBAL_DATA=%s\\n' \"$CRUSH_GLOBAL_CONFIG\" \"$CRUSH_GLOBAL_DATA\" > \"$d/env-$LINKC_SESSION\"\n"
            + "cat \"$CRUSH_GLOBAL_CONFIG/crush.json\" > \"$d/config-$LINKC_SESSION\" 2>/dev/null\n"
            + "stty -echo 2>/dev/null\nexec /bin/cat\n"
        try script.write(to: stubAgent, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stubAgent.path)
        let settingsDir = tempDir.appendingPathComponent("settings")
        let agent = stubAgent.path
        let directories = crushDirectories ?? (withCrushDirectories ? CrushDirectories(config: userConfig, data: userData) : nil)
        return AppCoordinator(
            terminals: TerminalSessionManager(),
            hookServer: HookServer(port: 0, statusLineCacheURL: tempDir.appendingPathComponent("status-line.json")),
            notifications: NotificationManager(sink: sink, now: { Date() }),
            claudePath: "/x/claude",
            settingsDir: settingsDir,
            userSettingsURL: tempDir.appendingPathComponent("no-such-settings.json"),
            manifestDir: settingsDir,
            agentPathResolver: { _ in agent },
            crushDirectories: directories,
            modelSettings: { models },
            modelLists: TestModelLists.none,
            deliverySettle: 0,
            turnEndQuietPeriod: 0.0,
            isWatching: { _ in false }
        )
    }

    /// The lines the stand-in wrote to `<name>-<session id>`, polled for up to five seconds.
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

    /// The config Crush was handed, as the stand-in read it.
    func pinnedConfig(of session: Session) throws -> [String: Any] {
        let text = launchedLines("config", of: session, count: 1).joined(separator: "\n")
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func assertPinned(_ config: [String: Any], to model: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let slash = try XCTUnwrap(model.firstIndex(of: "/"))
        let pin = ["provider": String(model[..<slash]), "model": String(model[model.index(after: slash)...])]
        let models = try XCTUnwrap(config["models"] as? [String: Any], file: file, line: line)
        XCTAssertEqual(models["large"] as? [String: String], pin, file: file, line: line)
        XCTAssertEqual(models["small"] as? [String: String], pin, file: file, line: line)
    }

    private func assertUsersFilesUntouched(file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try String(contentsOf: userConfig.appendingPathComponent("crush.json"), encoding: .utf8), userConfigText,
                       "linkC never edits the user's own crush.json", file: file, line: line)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: userConfig.path), ["crush.json"], file: file, line: line)
    }

    // MARK: - Launch

    /// Crush's own default is the user's, so even a session the user opens names its model: the default
    /// tier's. No tier was asked for, so none is recorded, and the session is never handed a delegated task.
    func testACrushSessionOpenedWithNoTierRunsPinnedToTheDefaultTiersFreeModel() throws {
        let coordinator = try makeCoordinator()
        defer { coordinator.shutdown() }

        let session = try coordinator.newSession(cwd: tempDir.path, agent: .crush, mode: .new)

        XCTAssertEqual(session.agentKind, .crush)
        XCTAssertEqual(session.model, standard)
        XCTAssertNil(session.modelTier, "a tier the user never asked for must not make their session a task carrier")
        XCTAssertEqual(launchedLines("argv", of: session, count: 1), ["--yolo"], "no --model: Crush's TUI has no such flag")
        try assertPinned(try pinnedConfig(of: session), to: standard)
        try assertUsersFilesUntouched()
    }

    func testACrushSessionOnATierRunsPinnedToThatTiersModel() throws {
        let coordinator = try makeCoordinator()
        defer { coordinator.shutdown() }

        let session = try coordinator.newSession(cwd: tempDir.path, agent: .crush, mode: .new, tier: .deep)

        XCTAssertEqual(session.model, "openrouter/nvidia/nemotron-3-ultra-550b-a55b:free")
        XCTAssertEqual(session.modelTier, .deep)
        try assertPinned(try pinnedConfig(of: session), to: "openrouter/nvidia/nemotron-3-ultra-550b-a55b:free")
    }

    func testTheTerminalPointsCrushAtTheSessionsOwnConfigAndDataFolders() throws {
        let coordinator = try makeCoordinator()
        defer { coordinator.shutdown() }

        let session = try coordinator.newSession(cwd: tempDir.path, agent: .crush, mode: .new)

        XCTAssertEqual(launchedLines("env", of: session, count: 2), [
            "CRUSH_GLOBAL_CONFIG=\(sessionsRoot.path)/\(session.id)/config",
            "CRUSH_GLOBAL_DATA=\(sessionsRoot.path)/\(session.id)/data"])
        let config = try pinnedConfig(of: session)
        XCTAssertEqual(((config["providers"] as? [String: Any])?["openrouter"] as? [String: String]), ["api_key": "sk-or-user-key"],
                       "the copy keeps the user's key")
    }

    func testOnlyACrushTerminalGetsCrushsVariables() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["CRUSH_GLOBAL_CONFIG"] != nil
                      || ProcessInfo.processInfo.environment["CRUSH_GLOBAL_DATA"] != nil, "run from inside a Crush environment")
        let coordinator = try makeCoordinator()
        defer { coordinator.shutdown() }

        let session = try coordinator.newSession(cwd: tempDir.path, agent: .codex, mode: .new)

        XCTAssertEqual(launchedLines("env", of: session, count: 2), ["CRUSH_GLOBAL_CONFIG=", "CRUSH_GLOBAL_DATA="])
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionsRoot.path))
    }

    // MARK: - Fail loud: never launched unpinned

    func testACrushSessionWithNoModelForItsTierIsRefused() throws {
        var models = AgentModelSettings.seeded
        models.setModel("", for: .crush, tier: .standard)
        let coordinator = try makeCoordinator(models: models)
        defer { coordinator.shutdown() }

        XCTAssertThrowsError(try coordinator.newSession(cwd: tempDir.path, agent: .crush, mode: .new)) { error in
            XCTAssertTrue(String(describing: error).contains("no model configured for crush tier standard — set it in linkC settings"),
                          String(describing: error))
        }
        XCTAssertTrue(coordinator.store.sessions.isEmpty, "a refused launch leaves no session behind")
    }

    func testACrushSessionWhoseModelIsNotFreeIsRefusedAndNeverStarts() throws {
        var models = AgentModelSettings.seeded
        models.setModel("openrouter/anthropic/claude-opus-4.5", for: .crush, tier: .standard)
        let coordinator = try makeCoordinator(models: models)
        defer { coordinator.shutdown() }

        XCTAssertThrowsError(try coordinator.newSession(cwd: tempDir.path, agent: .crush, mode: .new)) { error in
            XCTAssertTrue(String(describing: error).contains("openrouter/anthropic/claude-opus-4.5 is not a free Crush model"),
                          String(describing: error))
        }
        XCTAssertTrue(coordinator.store.sessions.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionsRoot.path), "no config was written for it")
    }

    /// Without Jacob's OpenRouter key Crush would stop on its provider dialog, and a task sent to it
    /// would wait in the queue for good. The launch fails at once, saying what to do.
    func testACrushLaunchWithNoOpenRouterKeyFailsAtOnceTellingJacobToAddOne() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] != nil, "OPENROUTER_API_KEY is set in this environment")
        try #"{"options":{"disable_metrics":true}}"#.write(to: userConfig.appendingPathComponent("crush.json"), atomically: true, encoding: .utf8)
        let coordinator = try makeCoordinator()
        defer { coordinator.shutdown() }

        XCTAssertThrowsError(try coordinator.newSession(cwd: tempDir.path, agent: .crush, mode: .new)) { error in
            XCTAssertTrue(String(describing: error).contains("add an OpenRouter key to Crush"), String(describing: error))
        }
        XCTAssertTrue(coordinator.store.sessions.isEmpty, "no session is left waiting")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionsRoot.path))
    }

    func testACrushLaunchWithNoFoldersToPinThroughFailsLoud() throws {
        let coordinator = try makeCoordinator(withCrushDirectories: false)
        defer { coordinator.shutdown() }

        XCTAssertThrowsError(try coordinator.newSession(cwd: tempDir.path, agent: .crush, mode: .new)) { error in
            XCTAssertTrue(String(describing: error).contains("Crush needs a home folder"), String(describing: error))
        }
        XCTAssertTrue(coordinator.store.sessions.isEmpty)
    }

    func testAnUnreadableUserConfigRefusesTheLaunchNamingTheFile() throws {
        let file = userConfig.appendingPathComponent("crush.json")
        try "{ broken".write(to: file, atomically: true, encoding: .utf8)
        let coordinator = try makeCoordinator()
        defer { coordinator.shutdown() }

        XCTAssertThrowsError(try coordinator.newSession(cwd: tempDir.path, agent: .crush, mode: .new)) { error in
            XCTAssertTrue(String(describing: error).contains(file.path), String(describing: error))
        }
        XCTAssertTrue(coordinator.store.sessions.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionsRoot.path))
    }

    func testAProjectThatSetsItsOwnCrushModelRefusesTheLaunch() throws {
        let local = tempDir.appendingPathComponent("crush.json")
        try #"{"models":{"large":{"provider":"openrouter","model":"anthropic/claude-opus-4.5"}}}"#
            .write(to: local, atomically: true, encoding: .utf8)
        let coordinator = try makeCoordinator()
        defer { coordinator.shutdown() }

        XCTAssertThrowsError(try coordinator.newSession(cwd: tempDir.path, agent: .crush, mode: .new)) { error in
            XCTAssertTrue(String(describing: error).contains(local.path), String(describing: error))
        }
        XCTAssertTrue(coordinator.store.sessions.isEmpty)
    }

    // MARK: - Cleanup

    func testTheSessionsConfigIsDeletedWhenItEnds() throws {
        let coordinator = try makeCoordinator()
        defer { coordinator.shutdown() }
        let session = try coordinator.newSession(cwd: tempDir.path, agent: .crush, mode: .new)
        let folder = sessionsRoot.appendingPathComponent(session.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("config/crush.json").path))

        coordinator.cleanup(sessionId: session.id, end: .stopped)

        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        try assertUsersFilesUntouched()
    }

    func testTheOtherSessionsConfigSurvivesOneEnding() throws {
        let coordinator = try makeCoordinator()
        defer { coordinator.shutdown() }
        let first = try coordinator.newSession(cwd: tempDir.path, agent: .crush, mode: .new)
        let second = try coordinator.newSession(cwd: tempDir.path, agent: .crush, mode: .new)

        coordinator.cleanup(sessionId: first.id, end: .processExited)

        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionsRoot.appendingPathComponent("\(second.id)/config/crush.json").path))
    }

    private func lockFolder(_ folder: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
    }

    func testAFolderThatCannotBeDeletedWhenTheSessionEndsIsReportedToTheUser() throws {
        let sink = RecordingSink()
        let coordinator = try makeCoordinator(sink: sink)
        defer { coordinator.shutdown() }
        let session = try coordinator.newSession(cwd: tempDir.path, agent: .crush, mode: .new)
        let folder = sessionsRoot.appendingPathComponent(session.id)
        let data = folder.appendingPathComponent("data")
        try "{}".write(to: data.appendingPathComponent("crush.json"), atomically: true, encoding: .utf8)
        try lockFolder(data)

        coordinator.cleanup(sessionId: session.id, end: .stopped)

        let notice = try XCTUnwrap(sink.deliveries.first { $0.title == "linkC: could not delete a Crush session's folder" })
        XCTAssertTrue(notice.body.contains(folder.path), notice.body)
    }

    func testAFolderThatCannotBeSweptAtStartIsReportedToTheUser() throws {
        let leftover = sessionsRoot.appendingPathComponent("DEAD/data", isDirectory: true)
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        try "{}".write(to: leftover.appendingPathComponent("crush.json"), atomically: true, encoding: .utf8)
        try lockFolder(leftover)
        let sink = RecordingSink()
        let coordinator = try makeCoordinator(sink: sink)
        defer { coordinator.shutdown() }

        try coordinator.start()

        let notice = try XCTUnwrap(sink.deliveries.first { $0.title == "linkC: could not delete a Crush session's folder" })
        XCTAssertTrue(notice.body.contains(sessionsRoot.path), notice.body)
    }

    func testAFolderLeftByACrashIsSweptAtStart() throws {
        let leftover = sessionsRoot.appendingPathComponent("DEAD/config", isDirectory: true)
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        let coordinator = try makeCoordinator()
        defer { coordinator.shutdown() }

        try coordinator.start()

        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionsRoot.appendingPathComponent("DEAD").path))
    }

    // MARK: - Crush never resumes

    /// Crush's own `--continue` and `--session` reopen a conversation on the model it last ran, which
    /// linkC cannot see and which could be a paid one. Every path that would resume one opens a new
    /// conversation in the same folder, pinned to the free default.
    private func assertOpensFresh(_ session: Session, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(launchedLines("argv", of: session, count: 1), ["--yolo"], "no --continue or --session", file: file, line: line)
        XCTAssertEqual(session.model, standard, file: file, line: line)
        try assertPinned(try pinnedConfig(of: session), to: standard, file: file, line: line)
    }

    func testContinuingCrushOpensANewConversationOnTheFreeDefaultModel() throws {
        let coordinator = try makeCoordinator()
        defer { coordinator.shutdown() }

        let session = try coordinator.newSession(cwd: tempDir.path, agent: .crush, mode: .continueLast)

        try assertOpensFresh(session)
        XCTAssertNil(session.modelTier)
    }

    func testResumingCrushOpensANewConversationOnTheFreeDefaultModel() throws {
        let coordinator = try makeCoordinator()
        defer { coordinator.shutdown() }

        let session = try coordinator.newSession(cwd: tempDir.path, agent: .crush, mode: .resume)

        try assertOpensFresh(session)
    }

    func testARelaunchRestoresACrushSessionAsANewConversationOnTheFreeDefaultModel() throws {
        WorkspaceManifest(directory: tempDir.appendingPathComponent("settings"))
            .upsert(RestorableSession(linkcId: "CR1", cwd: tempDir.path, title: "proj", agentKind: .crush, wasActiveOnQuit: true))
        let coordinator = try makeCoordinator()
        defer { coordinator.shutdown() }

        coordinator.restoreActiveSessions()

        let session = try XCTUnwrap(coordinator.store.session(id: "CR1"))
        try assertOpensFresh(session)
        XCTAssertTrue(coordinator.restorables.isEmpty, "the entry came back live")
    }

    func testRestoringACrushCardOpensANewConversationOnTheFreeDefaultModel() throws {
        let coordinator = try makeCoordinator()
        defer { coordinator.shutdown() }
        let card = RestorableSession(linkcId: "CR-old", cwd: tempDir.path, title: "proj", agentKind: .crush,
                                     wasActiveOnQuit: false, endedAt: Date())

        let session = try coordinator.restore(card)

        try assertOpensFresh(session)
    }

    /// Every Crush conversation is new, so a live one in the folder is no reason to refuse.
    func testRestoringACrushCardNextToALiveOneIsNotRefused() throws {
        let coordinator = try makeCoordinator()
        defer { coordinator.shutdown() }
        let live = try coordinator.newSession(cwd: tempDir.path, agent: .crush, mode: .new)
        let card = RestorableSession(linkcId: "CR-old", cwd: tempDir.path, title: "proj", agentKind: .crush,
                                     wasActiveOnQuit: false, endedAt: Date())

        let restored = try coordinator.restore(card)

        XCTAssertNotEqual(restored.id, live.id)
        XCTAssertEqual(coordinator.store.sessions.filter { $0.agentKind == .crush }.count, 2)
    }

    func testARestoredCrushSessionSaysItStartedFresh() throws {
        WorkspaceManifest(directory: tempDir.appendingPathComponent("settings"))
            .upsert(RestorableSession(linkcId: "CR1", cwd: tempDir.path, title: "proj", agentKind: .crush, wasActiveOnQuit: true))
        let sink = RecordingSink()
        let coordinator = try makeCoordinator(sink: sink)
        defer { coordinator.shutdown() }

        coordinator.restoreActiveSessions()

        let notice = try XCTUnwrap(sink.deliveries.first { $0.title == "linkC: Crush started a new conversation" })
        XCTAssertEqual(notice.body, "proj: Crush starts a new conversation on restore, so it only ever runs a free model.")
    }

    /// A paid default model must not slip in through a restore: the entry stays under Earlier.
    func testARestoreWhoseDefaultModelIsNotFreeStaysUnderEarlier() throws {
        WorkspaceManifest(directory: tempDir.appendingPathComponent("settings"))
            .upsert(RestorableSession(linkcId: "CR1", cwd: tempDir.path, title: "proj", agentKind: .crush, wasActiveOnQuit: true))
        var models = AgentModelSettings.seeded
        models.setModel("openrouter/anthropic/claude-opus-4.5", for: .crush, tier: .standard)
        let coordinator = try makeCoordinator(models: models)
        defer { coordinator.shutdown() }

        coordinator.restoreActiveSessions()

        XCTAssertNil(coordinator.store.session(id: "CR1"))
        XCTAssertEqual(coordinator.restorables.map(\.linkcId), ["CR1"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("argv-CR1").path))
    }

    // MARK: - A refused Crush launch on the delegation path

    private func withNoOpenRouterKey() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] != nil, "OPENROUTER_API_KEY is set in this environment")
        try #"{"options":{"disable_metrics":true}}"#.write(to: userConfig.appendingPathComponent("crush.json"), atomically: true, encoding: .utf8)
    }

    private func crushRefusals(_ sink: RecordingSink) -> [(id: String, title: String, body: String)] {
        sink.deliveries.filter { $0.title == AppCoordinator.crushRefusalTitle }
    }

    /// Spec 4.3: a missing key "is reported at once ... never left to wait in the queue". A task that
    /// names only a tier is the normal way Claude delegates; it must fail, not sit queued for an hour.
    func testATierTaskForCrushWithNoOpenRouterKeyFailsAtOnceAndTheDelegatorAndJacobAreTold() throws {
        try withNoOpenRouterKey()
        let sink = RecordingSink()
        let coordinator = try makeCoordinator(sink: sink)
        defer { coordinator.shutdown() }
        let inbox = InboxStore(workspaceRoot: tempDir.path)
        let task = try inbox.createTask(from: .claude, to: .crush, tier: .standard, prompt: "brief", files: [])

        for _ in 0..<3 { coordinator.dispatchTasks(workspacePath: tempDir.path, inboxStore: inbox) }

        let record = try XCTUnwrap(try inbox.task(id: task.id))
        XCTAssertEqual(record.state, .failed, "a refused launch is never left queued")
        XCTAssertTrue(record.cancelReason?.contains("add an OpenRouter key to Crush") ?? false, record.cancelReason ?? "no reason")
        let notices = try inbox.load().messages.filter { $0.kind != .task && $0.toAgent == .claude }
        XCTAssertEqual(notices.count, 1, "the delegator is told once, and no second launch is tried")
        XCTAssertTrue(notices.first?.prompt.contains("add an OpenRouter key to Crush") ?? false, notices.first?.prompt ?? "no notice")
        let told = crushRefusals(sink)
        XCTAssertEqual(told.count, 1, "Jacob is told once")
        XCTAssertTrue(told.first?.body.contains("add an OpenRouter key to Crush") ?? false, told.first?.body ?? "no notification")
        XCTAssertTrue(coordinator.store.sessions.isEmpty)
        XCTAssertEqual(coordinator.lastSpawnFailure?.agent, .crush)
    }

    /// A project that sets its own Crush model can never be launched under linkC's free pin: the task
    /// fails with the file named, whatever the key.
    func testATierTaskForCrushInAProjectThatSetsItsOwnModelFailsAtOnce() throws {
        try #"{"models":{"large":{"provider":"openrouter","model":"anthropic/claude-opus-4.5"}}}"#
            .write(to: tempDir.appendingPathComponent("crush.json"), atomically: true, encoding: .utf8)
        let sink = RecordingSink()
        let coordinator = try makeCoordinator(sink: sink)
        defer { coordinator.shutdown() }
        let inbox = InboxStore(workspaceRoot: tempDir.path)
        let task = try inbox.createTask(from: .claude, to: .crush, tier: .deep, prompt: "brief", files: [])

        coordinator.dispatchTasks(workspacePath: tempDir.path, inboxStore: inbox)

        let record = try XCTUnwrap(try inbox.task(id: task.id))
        XCTAssertEqual(record.state, .failed)
        XCTAssertTrue(record.cancelReason?.contains("crush.json") ?? false, record.cancelReason ?? "no reason")
        XCTAssertEqual(crushRefusals(sink).count, 1)
    }

    /// The same for the one message kind that still spawns an agent, a brief sent to Crush.
    func testABriefForCrushWithNoOpenRouterKeyFailsAtOnceAndItsSenderIsTold() throws {
        try withNoOpenRouterKey()
        let sink = RecordingSink()
        let coordinator = try makeCoordinator(sink: sink)
        defer { coordinator.shutdown() }
        let inbox = InboxStore(workspaceRoot: tempDir.path)
        var seeded = Inbox(workspacePath: tempDir.path)
        seeded.messages = [PendingMessage(id: "legacy-crush", fromAgent: .claude, toAgent: .crush,
                                          prompt: "Old style brief", status: .queued, kind: .task)]
        try inbox.saveRaw(seeded)

        for _ in 0..<3 { coordinator.dispatchMessages(workspacePath: tempDir.path, inboxStore: inbox) }

        let messages = try inbox.load().messages
        XCTAssertEqual(messages.first { $0.id == "legacy-crush" }?.status, .failed)
        let notices = messages.filter { $0.kind == .notice && $0.toAgent == .claude }
        XCTAssertEqual(notices.count, 1)
        XCTAssertTrue(notices.first?.prompt.contains("add an OpenRouter key to Crush") ?? false, notices.first?.prompt ?? "no notice")
        XCTAssertEqual(crushRefusals(sink).count, 1)
        XCTAssertTrue(coordinator.store.sessions.isEmpty)
    }
}

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

    func makeCoordinator(models: AgentModelSettings = .seeded, sink: NotificationSink = RecordingSink()) throws -> AppCoordinator {
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
        XCTAssertEqual(session.model, "opencode/big-pickle")
        XCTAssertNil(session.modelTier, "a tier the user never asked for must not make their session a task carrier")
        XCTAssertEqual(launchedLines("argv", of: session, count: 2), ["--standalone", "--auto"], "no --model: OpenCode 2.2.5 refuses it")
        XCTAssertEqual(try openCodeConfig(of: session)["model"] as? String, "opencode/big-pickle")
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
        models.setModel("", for: .opencode, tier: .standard)
        let coordinator = try makeCoordinator(models: models)
        defer { coordinator.shutdown() }

        XCTAssertThrowsError(try coordinator.newSession(cwd: tempDir.path, agent: .opencode, mode: .new)) { error in
            XCTAssertTrue(String(describing: error).contains("no model configured for opencode tier standard — set it in linkC settings"),
                          String(describing: error))
        }
        XCTAssertTrue(coordinator.store.sessions.isEmpty, "a refused launch leaves no session behind")
    }

    /// Records every listing linkC asks for and answers with `listing`, or throws `failure`.
    final class SessionLister: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [(executable: String, folder: String)] = []
        let listing: String
        let failure: Error?
        init(listing: String = "", failure: Error? = nil) { self.listing = listing; self.failure = failure }
        var calls: [(executable: String, folder: String)] { lock.lock(); defer { lock.unlock() }; return _calls }
        func list(_ executable: String, _ folder: String) throws -> String {
            lock.lock(); _calls.append((executable, folder)); lock.unlock()
            if let failure { throw failure }
            return listing
        }
    }

    private func listing(id: String, in folder: String) -> String {
        #"[{"id":"\#(id)","title":"t","updated":1794071408175,"created":1794071353260,"projectId":"p","directory":"\#(folder)"}]"#
    }

    private func waitUntil(_ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while !predicate(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        return predicate()
    }

    /// A continued OpenCode session keeps the model it last ran on, so linkC records none for it. The
    /// default tier's model still goes in its config, for a folder where no session ran.
    func testContinuingOpensThisFoldersOwnSession() throws {
        let coordinator = try makeCoordinator()
        defer { coordinator.shutdown() }
        let lister = SessionLister(listing: listing(id: "ses_here", in: ProjectPath.canonical(tempDir.path)))
        coordinator.openCodeSessionList = { try lister.list($0, $1) }

        let session = try coordinator.newSession(cwd: tempDir.path, agent: .opencode, mode: .continueLast)

        XCTAssertEqual(launchedLines("argv", of: session, count: 4), ["--standalone", "--auto", "--session", "ses_here"])
        XCTAssertNil(session.model, "a continued session runs on its own last model, which linkC does not know")
        XCTAssertEqual(try openCodeConfig(of: session)["model"] as? String, "opencode/big-pickle")
        XCTAssertEqual(lister.calls.map(\.executable), [stubAgent.path])
        XCTAssertEqual(lister.calls.map(\.folder), [session.cwd], "the listing runs in the session's own folder")
    }

    func testContinuingWhereNoSessionRanStartsANewOne() throws {
        let coordinator = try makeCoordinator()
        defer { coordinator.shutdown() }
        let lister = SessionLister(listing: listing(id: "ses_elsewhere", in: "/somewhere/else"))
        coordinator.openCodeSessionList = { try lister.list($0, $1) }

        let session = try coordinator.newSession(cwd: tempDir.path, agent: .opencode, mode: .continueLast)

        XCTAssertEqual(launchedLines("argv", of: session, count: 2), ["--standalone", "--auto"])
    }

    /// Continuing must never quietly become a new conversation.
    func testAListingThatFailsEndsTheSessionAndSaysWhy() throws {
        let sink = RecordingSink()
        let coordinator = try makeCoordinator(sink: sink)
        defer { coordinator.shutdown() }
        let lister = SessionLister(failure: LinkCError.process("opencode session list exited 1: no database"))
        coordinator.openCodeSessionList = { try lister.list($0, $1) }

        let session = try coordinator.newSession(cwd: tempDir.path, agent: .opencode, mode: .continueLast)

        XCTAssertTrue(waitUntil { coordinator.store.session(id: session.id) == nil }, "the session is ended")
        let notice = try XCTUnwrap(sink.deliveries.first { $0.title == "linkC: OpenCode could not continue" })
        XCTAssertTrue(notice.body.contains("no database"), notice.body)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("argv-\(session.id)").path),
                       "OpenCode never started")
    }

    /// A listing that waits to be released and then fails, so a test can close the session while it runs.
    final class HeldLister: @unchecked Sendable {
        private let lock = NSLock()
        private var _entered = false, _released = false, _failed = false
        var entered: Bool { lock.withLock { _entered } }
        var failed: Bool { lock.withLock { _failed } }
        func release() { lock.withLock { _released = true } }
        private var released: Bool { lock.withLock { _released } }
        private func markEntered() { lock.withLock { _entered = true } }
        private func markFailed() { lock.withLock { _failed = true } }
        func list(_ executable: String, _ folder: String) async throws -> String {
            markEntered()
            while !released { try await Task.sleep(nanoseconds: 5_000_000) }
            markFailed()
            throw LinkCError.process("opencode session list exited 1: no database")
        }
    }

    /// The user closed the session while its listing ran. A listing that then fails has nobody to
    /// tell: they already ended it.
    func testAListingThatFailsAfterTheSessionWasClosedSaysNothing() throws {
        let sink = RecordingSink()
        let coordinator = try makeCoordinator(sink: sink)
        defer { coordinator.shutdown() }
        let lister = HeldLister()
        coordinator.openCodeSessionList = { try await lister.list($0, $1) }
        let session = try coordinator.newSession(cwd: tempDir.path, agent: .opencode, mode: .continueLast)
        XCTAssertTrue(waitUntil { lister.entered }, "the listing is under way")

        coordinator.stopSession(session.id)
        lister.release()
        XCTAssertTrue(waitUntil { lister.failed }, "the listing failed")

        // The failure is handled on the main actor right after. Nothing marks that moment, so give
        // it time: a notice would be delivered the instant it runs.
        let settled = Date().addingTimeInterval(0.5)
        while Date() < settled { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertNil(sink.deliveries.first { $0.title == "linkC: OpenCode could not continue" })
    }

    func testANewSessionNeverLists() throws {
        let coordinator = try makeCoordinator()
        defer { coordinator.shutdown() }
        let lister = SessionLister()
        coordinator.openCodeSessionList = { try lister.list($0, $1) }

        let session = try coordinator.newSession(cwd: tempDir.path, agent: .opencode, mode: .new)

        XCTAssertEqual(launchedLines("argv", of: session, count: 2).count, 2)
        XCTAssertTrue(lister.calls.isEmpty)
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

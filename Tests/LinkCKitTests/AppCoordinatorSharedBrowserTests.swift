import XCTest
@testable import LinkCKit

/// Sessions launched with a shared browser, read back from a stand-in agent that records its argv
/// and the browser variables it was started with.
@MainActor
final class AppCoordinatorSharedBrowserTests: XCTestCase {
    nonisolated(unsafe) private var tempDir: URL!
    private var launcher: FakeBrowserLauncher!
    private var devTools: FakeDevTools!
    private var runner: RecordingRunner!
    private var browserNotices: [String] = []
    private let agentPathBox = LockedBox("")
    private var agentPath: String {
        get { agentPathBox.value }
        set { agentPathBox.value = newValue }
    }

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-browser-launch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir.appendingPathComponent("agent-browser-home"), withIntermediateDirectories: true)
        launcher = FakeBrowserLauncher()
        devTools = FakeDevTools()
        runner = RecordingRunner()
        browserNotices = []
        let script = "#!/bin/sh\n"
            + "printf '%s\\n' \"$@\" > \"$(dirname \"$0\")/argv-$LINKC_SESSION\"\n"
            + "printf 'CDP=%s\\nPIN=%s\\nSESSION=%s\\n' \"$AGENT_BROWSER_CDP\" \"$AGENT_BROWSER_PIN_TAB\" \"$AGENT_BROWSER_SESSION\" > \"$(dirname \"$0\")/env-$LINKC_SESSION\"\n"
            + "stty -echo 2>/dev/null\nexec /bin/cat\n"
        let stub = tempDir.appendingPathComponent("stub-agent.sh")
        try script.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        agentPath = stub.path
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    private func makeBrowser() -> SharedBrowser {
        SharedBrowser(
            applicationSupport: tempDir.appendingPathComponent("support"),
            agentBrowserHome: tempDir.appendingPathComponent("agent-browser-home"),
            chromePath: "/Applications/Google Chrome",
            launcher: launcher, devTools: devTools, processes: FakeProcesses(), runner: runner,
            executableSearchPath: [],
            discover: { _, _ in AgentBrowserServer(name: "browser-tools", commandLine: ["/bin/agent-browser", "mcp"]) },
            resolveRepository: { $0 },
            report: { [weak self] in self?.browserNotices.append($0) })
    }

    private func makeCoordinator(
        browser: SharedBrowser? = nil, enabled: Bool = true,
        sink: AppCoordinatorKiloTests.RecordingSink = .init()
    ) -> AppCoordinator {
        let settingsDir = tempDir.appendingPathComponent("settings")
        return AppCoordinator(
            terminals: TerminalSessionManager(),
            hookServer: HookServer(port: 0, statusLineCacheURL: tempDir.appendingPathComponent("status-line.json")),
            notifications: NotificationManager(sink: sink, now: { Date() }),
            claudePath: "/x/claude",
            settingsDir: settingsDir,
            userSettingsURL: tempDir.appendingPathComponent("no-such-settings.json"),
            manifestDir: settingsDir,
            agentPathResolver: { [agentPathBox] _ in agentPathBox.value },
            sharedBrowser: browser ?? makeBrowser(),
            sharedBrowserEnabled: { enabled },
            modelSettings: { .seeded },
            modelLists: TestModelLists.none,
            deliverySettle: 0,
            turnEndQuietPeriod: 0.0,
            isWatching: { _ in false }
        )
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out waiting until \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// The lines the stand-in wrote to `<name>-<session id>`, once it has written `count` of them.
    private func launched(_ name: String, _ sessionId: String, count: Int) async throws -> [String] {
        let file = tempDir.appendingPathComponent("\(name)-\(sessionId)")
        var lines: [String] = []
        try await waitUntil("\(name)-\(sessionId) has \(count) lines") {
            lines = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if lines.last == "" { lines.removeLast() }
            return lines.count >= count
        }
        return lines
    }

    // MARK: - Launch order

    /// The agent is started only once its browser's port is known, and nothing waits on the main
    /// thread meanwhile: the session is in the list, its terminal not yet started.
    func testASessionStartsOnlyOnceItsBrowserIsReadyAndGetsItsVariables() async throws {
        launcher.publishesPort = nil
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }

        let session = try coordinator.newSession(cwd: tempDir.path, agent: .agy, mode: .new)

        XCTAssertNotNil(coordinator.store.session(id: session.id))
        XCTAssertEqual(coordinator.terminals.session(id: session.id)?.isRunning, false)
        try await waitUntil("Chrome is launched") { launcher.launches.count == 1 }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(coordinator.terminals.session(id: session.id)?.isRunning, false, "no port yet, no agent")

        launcher.publish(port: 43117)

        let env = try await launched("env", session.id, count: 3)
        XCTAssertEqual(env[0], "CDP=43117")
        XCTAssertEqual(env[1], "PIN=1")
        XCTAssertTrue(env[2].hasPrefix("SESSION=linkc-\(session.id)-"), env[2])
        XCTAssertEqual(coordinator.terminals.session(id: session.id)?.isRunning, true)
    }

    func testCodexGetsTheVariablesAsOverridesOnItsOwnServer() async throws {
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }

        let session = try coordinator.newSession(cwd: tempDir.path, agent: .codex, mode: .new)

        let argv = try await launched("argv", session.id, count: 10)
        XCTAssertTrue(argv.contains(#"mcp_servers.browser-tools.env.AGENT_BROWSER_CDP="43117""#), argv.joined(separator: " "))
        XCTAssertTrue(argv.contains(#"mcp_servers.browser-tools.env.AGENT_BROWSER_PIN_TAB="1""#), argv.joined(separator: " "))
        XCTAssertTrue(argv.contains { $0.hasPrefix(#"mcp_servers.browser-tools.env.AGENT_BROWSER_SESSION="linkc-\#(session.id)-"#) },
                      argv.joined(separator: " "))
        let env = try await launched("env", session.id, count: 3)
        XCTAssertEqual(env[0], "CDP=", "Codex gets them as overrides only")
    }

    // MARK: - No browser

    func testWithTheSettingOffNoChromeStartsAndTheSessionStartsAtOnce() async throws {
        let coordinator = makeCoordinator(enabled: false)
        defer { coordinator.shutdown() }

        let session = try coordinator.newSession(cwd: tempDir.path, agent: .agy, mode: .new)

        XCTAssertEqual(coordinator.terminals.session(id: session.id)?.isRunning, true)
        let env = try await launched("env", session.id, count: 3)
        XCTAssertEqual(env, ["CDP=", "PIN=", "SESSION="])
        XCTAssertTrue(launcher.launches.isEmpty)
    }

    /// cursor-agent and Freebuff hand their MCP servers a fixed handful of variables, so a Chrome
    /// started for them would serve nobody. (Grok is cursor-agent too; it needs a home folder this
    /// coordinator has none of, and `AgentDescriptorTests` covers it.)
    func testAnAgentWhoseServersCannotGetTheVariablesStartsNoChrome() async throws {
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }

        for agent in [AgentKind.cursor, .freebuff] {
            let session = try coordinator.newSession(cwd: tempDir.path, agent: agent, mode: .new)
            XCTAssertEqual(coordinator.terminals.session(id: session.id)?.isRunning, true, "\(agent)")
        }
        XCTAssertTrue(launcher.launches.isEmpty)
    }

    // MARK: - Ending

    /// An agent that cannot be started once its browser is ready gives the browser back: the
    /// session is gone, Chrome stops, the user is told, and the next session gets a new Chrome.
    func testALaunchThatFailsAfterItsBrowserIsReadyGivesItBackAndSaysSo() async throws {
        let broken = tempDir.appendingPathComponent("not-executable")
        try Data("x".utf8).write(to: broken)
        agentPath = broken.path
        let sink = AppCoordinatorKiloTests.RecordingSink()
        let coordinator = makeCoordinator(sink: sink)
        defer { coordinator.shutdown() }

        let failed = try coordinator.newSession(cwd: tempDir.path, agent: .agy, mode: .new)

        try await waitUntil("the failed session is gone") { coordinator.store.session(id: failed.id) == nil }
        XCTAssertEqual(launcher.processes.first?.stopCount, 1)
        let notice = sink.deliveries.first { $0.title.contains("could not start") }
        XCTAssertTrue(notice?.body.contains("not-executable") == true, String(describing: sink.deliveries))

        agentPath = tempDir.appendingPathComponent("stub-agent.sh").path
        let next = try coordinator.newSession(cwd: tempDir.path, agent: .agy, mode: .new)
        _ = try await launched("env", next.id, count: 3)
        XCTAssertEqual(launcher.launches.count, 2)
    }

    /// A session relaunched at startup keeps its id; its browser session name is new, or
    /// agent-browser would bind it to the tab the last run had pinned.
    func testARelaunchedSessionGetsAFreshBrowserSessionName() async throws {
        func seed() {
            WorkspaceManifest(directory: tempDir.appendingPathComponent("settings"))
                .upsert(RestorableSession(linkcId: "S1", cwd: tempDir.path, title: "proj", agentKind: .agy, wasActiveOnQuit: true))
        }
        seed()
        let first = makeCoordinator()
        first.restoreActiveSessions()
        let firstName = try await launched("env", "S1", count: 3)[2]
        first.terminals.terminate("S1")
        first.shutdown()
        try FileManager.default.removeItem(at: tempDir.appendingPathComponent("env-S1"))

        seed()
        let second = makeCoordinator()
        defer { second.shutdown() }
        second.restoreActiveSessions()
        let secondName = try await launched("env", "S1", count: 3)[2]

        XCTAssertTrue(firstName.hasPrefix("SESSION=linkc-S1-"), firstName)
        XCTAssertTrue(secondName.hasPrefix("SESSION=linkc-S1-"), secondName)
        XCTAssertNotEqual(firstName, secondName)
    }

    /// The session's end gives its share back: its daemon is stopped under the name it was given.
    func testEndingASessionStopsItsBrowserSessionUnderItsName() async throws {
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }
        let session = try coordinator.newSession(cwd: tempDir.path, agent: .agy, mode: .new)
        let name = String(try await launched("env", session.id, count: 3)[2].dropFirst("SESSION=".count))

        coordinator.terminals.terminate(session.id)

        try await waitUntil("agent-browser is asked to close") { !runner.calls.isEmpty }
        XCTAssertEqual(runner.calls, [["/bin/agent-browser", "--session", name, "close", "--json"]])
        XCTAssertEqual(launcher.processes.first?.isRunning, false, "the last session out stops Chrome")
    }
}

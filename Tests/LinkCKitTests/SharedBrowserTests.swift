import XCTest
@testable import LinkCKit

@MainActor
final class SharedBrowserTests: XCTestCase {
    nonisolated(unsafe) private var root: URL!
    private var launcher: FakeBrowserLauncher!
    private var devTools: FakeDevTools!
    private var processes: FakeProcesses!
    private var runner: RecordingRunner!
    private var clock: SteppingClock!
    private var notices: [String] = []
    private var server = AgentBrowserServer(name: "agent-browser", commandLine: ["/bin/agent-browser", "mcp"])
    private var repositories: [String: String] = [:]
    private let resolvedBox = LockedBox<[String]>([])
    private var resolved: [String] { resolvedBox.value }
    private var nonces = 0

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-shared-browser-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: agentBrowserHome, withIntermediateDirectories: true)
        launcher = FakeBrowserLauncher()
        devTools = FakeDevTools()
        processes = FakeProcesses()
        runner = RecordingRunner()
        clock = SteppingClock()
        notices = []
        repositories = [:]
        resolvedBox.value = []
        nonces = 0
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    private var support: URL { root.appendingPathComponent("support") }
    private var agentBrowserHome: URL { root.appendingPathComponent("agent-browser-home") }

    private func makeBrowser(server: AgentBrowserServer? = nil, searchPath: [String] = []) -> SharedBrowser {
        let found = server ?? self.server
        let repositories = self.repositories
        return SharedBrowser(
            applicationSupport: support, agentBrowserHome: agentBrowserHome, chromePath: "/Applications/Google Chrome",
            launcher: launcher, devTools: devTools, processes: processes, runner: runner,
            executableSearchPath: searchPath,
            discover: { _, _ in found },
            resolveRepository: { [resolvedBox] cwd in
                resolvedBox.value.append(cwd)
                return repositories[cwd] ?? cwd
            },
            now: { [clock] in clock!.now() },
            sleep: { [clock] in try await clock!.sleep($0) },
            nonce: { [weak self] in
                guard let self else { return "" }
                nonces += 1
                return "n\(nonces)"
            },
            report: { [weak self] in self?.notices.append($0) })
    }

    private func pin(_ lease: SharedBrowserLease, to target: String) throws {
        try Data(#"{"targetId":"\#(target)","url":"","pinned":true}"#.utf8)
            .write(to: agentBrowserHome.appendingPathComponent("\(lease.sessionName).target"))
    }

    private func targetFileExists(_ lease: SharedBrowserLease) -> Bool {
        FileManager.default.fileExists(atPath: agentBrowserHome.appendingPathComponent("\(lease.sessionName).target").path)
    }

    // MARK: - One Chrome per repository

    func testTwoSessionsOfOneProjectShareOneChromeEachInItsOwnPinnedSession() async throws {
        let browser = makeBrowser()

        let first = try await XCTUnwrapAsync(await browser.lease(sessionId: "S1", agent: .claude, cwd: "/tmp/project"))
        let second = try await XCTUnwrapAsync(await browser.lease(sessionId: "S2", agent: .codex, cwd: "/tmp/project"))

        XCTAssertEqual(first.environment, ["AGENT_BROWSER_CDP": "43117", "AGENT_BROWSER_PIN_TAB": "1",
                                           "AGENT_BROWSER_SESSION": "linkc-S1-n1"])
        XCTAssertEqual(second.sessionName, "linkc-S2-n2")
        XCTAssertEqual(first.server, server)
        XCTAssertEqual(launcher.launches.count, 1)
        XCTAssertTrue(launcher.launches[0].contains("--remote-debugging-port=0"))
        XCTAssertTrue(launcher.launches[0].contains("--headless=new"))
    }

    /// A relaunched session keeps its id. agent-browser remembers each session's pinned tab in
    /// `<session>.target`, so a repeated name would bind the new session to a tab that is gone.
    func testTheSameSessionIdGetsAFreshSessionNameEachTime() async throws {
        let browser = makeBrowser()

        let first = try await XCTUnwrapAsync(await browser.lease(sessionId: "S1", agent: .claude, cwd: "/tmp/project"))
        browser.release(sessionId: "S1")
        await browser.settle()
        let again = try await XCTUnwrapAsync(await browser.lease(sessionId: "S1", agent: .claude, cwd: "/tmp/project"))

        XCTAssertNotEqual(first.sessionName, again.sessionName)
        XCTAssertTrue(again.sessionName.hasPrefix("linkc-S1-"), again.sessionName)
    }

    /// Worktrees and subfolders of one repository share its browser; the answer is asked once per folder.
    func testFoldersOfOneRepositoryShareOneChrome() async throws {
        repositories = ["/repo/.worktrees/a": "/repo", "/repo/sub": "/repo"]
        let browser = makeBrowser()

        _ = await browser.lease(sessionId: "S1", agent: .claude, cwd: "/repo/.worktrees/a")
        _ = await browser.lease(sessionId: "S2", agent: .claude, cwd: "/repo/sub")
        _ = await browser.lease(sessionId: "S3", agent: .claude, cwd: "/repo/sub")

        XCTAssertEqual(launcher.launches.count, 1)
        XCTAssertEqual(resolved, ["/repo/.worktrees/a", "/repo/sub"])
    }

    func testRepositoryRootIsTheCommonGitFoldersParentForWorktreesAndSubfolders() async throws {
        let repo = root.appendingPathComponent("repo")
        let worktree = root.appendingPathComponent("wt")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let git = try XCTUnwrap(GitClient.resolveGit())
        for args in [["init", "-q"], ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "x"],
                     ["worktree", "add", "-q", worktree.path]] {
            let result = try LiveProcessRunner.runCapturingSync(executable: git, args: ["-C", repo.path] + args, cwd: nil, timeout: 20)
            XCTAssertEqual(result.status, 0, result.stderr)
        }
        let plain = root.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let runner = LiveProcessRunner()

        let expected = ProjectPath.canonical(repo.path)
        let fromRepo = try await SharedBrowser.repositoryRoot(of: repo.path, runner: runner, git: git)
        let fromWorktree = try await SharedBrowser.repositoryRoot(of: worktree.path, runner: runner, git: git)
        let fromSub = try await SharedBrowser.repositoryRoot(of: repo.appendingPathComponent("sub").path, runner: runner, git: git)
        let fromPlain = try await SharedBrowser.repositoryRoot(of: plain.path, runner: runner, git: git)
        XCTAssertEqual(fromRepo, expected)
        XCTAssertEqual(fromWorktree, expected)
        XCTAssertEqual(fromSub, expected)
        XCTAssertEqual(fromPlain, ProjectPath.canonical(plain.path))
    }

    // MARK: - Starting Chrome

    /// The port file a dead Chrome left behind names a port nobody listens on; it is removed before
    /// the launch, so only the new Chrome's port is read.
    func testAStalePortFileIsNotReadAsTheNewChromesPort() async throws {
        let profile = SharedBrowser.profileDirectory(for: "/tmp/project", in: support)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try Data("1111\n/devtools/browser/old\n".utf8).write(to: profile.appendingPathComponent("DevToolsActivePort"))
        launcher.publishesPort = nil
        clock.onSleep = { [launcher] in launcher!.publish(port: 43117) }
        let browser = makeBrowser()

        let lease = await browser.lease(sessionId: "S1", agent: .claude, cwd: "/tmp/project")

        XCTAssertEqual(lease?.port, 43117)
    }

    func testAChromeThatNeverPublishesAPortIsStoppedAndSaysSo() async throws {
        launcher.publishesPort = nil
        let browser = makeBrowser()

        let lease = await browser.lease(sessionId: "S1", agent: .claude, cwd: "/tmp/project")

        XCTAssertNil(lease)
        XCTAssertEqual(launcher.processes.first?.isRunning, false)
        XCTAssertEqual(notices.count, 1)
        XCTAssertTrue(notices[0].contains("DevTools port"), notices[0])
    }

    func testAChromeThatExitsAtOnceSaysWhatItPrinted() async throws {
        launcher.publishesPort = nil
        clock.onSleep = { [launcher, support] in
            guard let process = launcher!.processes.last, process.isRunning else { return }
            let log = SharedBrowser.logFile(for: "/tmp/project", in: support)
            try? Data("noise\nFailed to create SingletonLock: File exists (17)\n\n".utf8).write(to: log)
            process.exit(status: 21)
        }
        let browser = makeBrowser()

        let lease = await browser.lease(sessionId: "S1", agent: .claude, cwd: "/tmp/project")

        XCTAssertNil(lease)
        XCTAssertEqual(notices.count, 1)
        XCTAssertTrue(notices[0].contains("Failed to create SingletonLock: File exists (17)"), notices[0])
    }

    /// After a failed start the project is not retried for every session; a minute later it is.
    func testAFailedStartIsNotRetriedForEverySession() async throws {
        launcher.available = false
        let browser = makeBrowser()

        let first = await browser.lease(sessionId: "S1", agent: .claude, cwd: "/tmp/project")
        let second = await browser.lease(sessionId: "S2", agent: .claude, cwd: "/tmp/project")
        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(launcher.executableChecks, 1)
        XCTAssertEqual(notices.count, 1)
        XCTAssertTrue(notices[0].contains("Google Chrome"), notices[0])

        clock.time = clock.time.addingTimeInterval(61)
        launcher.available = true
        let third = await browser.lease(sessionId: "S3", agent: .claude, cwd: "/tmp/project")
        XCTAssertNotNil(third)
    }

    /// Each kind of failure is shown once, so a second, different problem is not hidden by the first.
    func testEachNewKindOfFailureIsShownOnce() async throws {
        launcher.available = false
        let browser = makeBrowser()
        _ = await browser.lease(sessionId: "S1", agent: .claude, cwd: "/tmp/project")
        clock.time = clock.time.addingTimeInterval(61)
        _ = await browser.lease(sessionId: "S2", agent: .claude, cwd: "/tmp/project")
        XCTAssertEqual(notices.count, 1, "the same failure again says nothing new")

        clock.time = clock.time.addingTimeInterval(61)
        launcher.available = true
        launcher.publishesPort = nil
        _ = await browser.lease(sessionId: "S3", agent: .claude, cwd: "/tmp/project")

        XCTAssertEqual(notices.count, 2)
        XCTAssertTrue(notices[1].contains("DevTools port"), notices[1])
    }

    /// A linkC that crashed left its Chrome running, reparented to launchd and holding the profile's
    /// lock; a new Chrome on that profile would abort. That leftover is stopped first.
    func testALeftoverChromeOfACrashedLinkCIsStoppedBeforeTheLaunch() async throws {
        let profile = SharedBrowser.profileDirectory(for: "/tmp/project", in: support)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: profile.appendingPathComponent("SingletonLock").path,
                                                   withDestinationPath: "MyMac-777")
        try Data("5555\n/devtools/browser/old\n".utf8).write(to: profile.appendingPathComponent("DevToolsActivePort"))
        processes.add(pid: 777, arguments: ["/Applications/Google Chrome", "--user-data-dir=\(profile.path)"], parent: 1)
        var events: [String] = []
        processes.events = { _ in }
        launcher.events = { events.append($0) }
        let browser = makeBrowser()

        let lease = await browser.lease(sessionId: "S1", agent: .claude, cwd: "/tmp/project")

        XCTAssertEqual(processes.signals.first?.pid, 777)
        XCTAssertEqual(processes.signals.first?.signal, SIGTERM)
        XCTAssertEqual(events, ["launch"])
        XCTAssertEqual(lease?.port, 43117, "the leftover's port file is not the new Chrome's")
    }

    func testAChromeOfALiveProcessHoldingTheProfileIsLeftAloneAndReported() async throws {
        let profile = SharedBrowser.profileDirectory(for: "/tmp/project", in: support)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: profile.appendingPathComponent("SingletonLock").path,
                                                   withDestinationPath: "MyMac-777")
        processes.add(pid: 777, arguments: ["/Applications/Google Chrome", "--user-data-dir=\(profile.path)"], parent: 4242)
        let browser = makeBrowser()

        let lease = await browser.lease(sessionId: "S1", agent: .claude, cwd: "/tmp/project")

        XCTAssertNil(lease)
        XCTAssertTrue(processes.signals.isEmpty)
        XCTAssertTrue(launcher.launches.isEmpty)
        XCTAssertTrue(notices.first?.contains("777") == true, notices.first ?? "no notice")
    }

    /// A lock naming a pid that now belongs to another program is not acted on.
    func testALockWhosePidIsNoLongerChromeKillsNothing() async throws {
        let profile = SharedBrowser.profileDirectory(for: "/tmp/project", in: support)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: profile.appendingPathComponent("SingletonLock").path,
                                                   withDestinationPath: "MyMac-777")
        processes.add(pid: 777, arguments: ["/usr/bin/vim"], parent: 1)
        let browser = makeBrowser()

        let lease = await browser.lease(sessionId: "S1", agent: .claude, cwd: "/tmp/project")

        XCTAssertNotNil(lease)
        XCTAssertTrue(processes.signals.isEmpty)
    }

    // MARK: - Chrome dying

    func testAChromeThatExitsIsDroppedAndTheNextSessionStartsANewOne() async throws {
        let browser = makeBrowser()
        _ = await browser.lease(sessionId: "S1", agent: .claude, cwd: "/tmp/project")

        launcher.processes[0].exit(status: 9)
        XCTAssertEqual(notices.count, 1)
        XCTAssertTrue(notices[0].contains("stopped"), notices[0])

        launcher.publishesPort = 50001
        let next = await browser.lease(sessionId: "S2", agent: .claude, cwd: "/tmp/project")
        XCTAssertEqual(launcher.launches.count, 2)
        XCTAssertEqual(next?.port, 50001)
    }

    /// Even when the exit was not reported yet, a Chrome that is not running is not handed out.
    func testAChromeThatIsNotRunningIsNeverHandedOut() async throws {
        let browser = makeBrowser()
        _ = await browser.lease(sessionId: "S1", agent: .claude, cwd: "/tmp/project")
        launcher.processes[0].isRunning = false

        launcher.publishesPort = 50001
        let next = await browser.lease(sessionId: "S2", agent: .claude, cwd: "/tmp/project")

        XCTAssertEqual(next?.port, 50001)
    }

    // MARK: - Which sessions get one

    func testNoChromeStartsWhenTheAgentHasNoAgentBrowserServer() async throws {
        let browser = SharedBrowser(
            applicationSupport: support, agentBrowserHome: agentBrowserHome, chromePath: "/Applications/Google Chrome",
            launcher: launcher, devTools: devTools, processes: processes, runner: runner, executableSearchPath: [],
            discover: { _, _ in nil }, resolveRepository: { $0 },
            now: { Date() }, sleep: { _ in }, nonce: { "n" }, report: { [weak self] in self?.notices.append($0) })

        let lease = await browser.lease(sessionId: "S1", agent: .claude, cwd: "/tmp/project")

        XCTAssertNil(lease)
        XCTAssertTrue(launcher.launches.isEmpty)
        XCTAssertTrue(notices.isEmpty)
    }

    func testAConfigThatCannotBeReadSaysWhyAndStartsNoChrome() async throws {
        let browser = SharedBrowser(
            applicationSupport: support, agentBrowserHome: agentBrowserHome, chromePath: "/Applications/Google Chrome",
            launcher: launcher, devTools: devTools, processes: processes, runner: runner, executableSearchPath: [],
            discover: { _, _ in throw LinkCError.server("/home/.config/kilo/kilo.jsonc is not JSON linkC can read") },
            resolveRepository: { $0 },
            now: { Date() }, sleep: { _ in }, nonce: { "n" }, report: { [weak self] in self?.notices.append($0) })

        let lease = await browser.lease(sessionId: "S1", agent: .kilo, cwd: "/tmp/project")

        XCTAssertNil(lease)
        XCTAssertTrue(launcher.launches.isEmpty)
        XCTAssertTrue(notices.first?.contains("kilo.jsonc") == true, notices.first ?? "no notice")
    }

    // MARK: - Ending sessions

    /// The count changes before anything external runs, so a second release that lands while the
    /// first is still closing tabs sees the right number and stops Chrome exactly once.
    func testReleasesStopChromeOnceTheLastSessionEndsEvenWhenTheyOverlap() async throws {
        let browser = makeBrowser()
        _ = await browser.lease(sessionId: "S1", agent: .claude, cwd: "/tmp/project")
        _ = await browser.lease(sessionId: "S2", agent: .claude, cwd: "/tmp/project")

        browser.release(sessionId: "S1")
        XCTAssertEqual(launcher.processes[0].stopCount, 0)
        browser.release(sessionId: "S2")
        XCTAssertEqual(launcher.processes[0].stopCount, 1, "stopped at once, before any tab is closed")
        await browser.settle()

        XCTAssertEqual(launcher.processes[0].stopCount, 1)
        XCTAssertTrue(devTools.closed.isEmpty, "Chrome is gone; its tabs went with it")
        XCTAssertTrue(notices.isEmpty, notices.joined(separator: "\n"))
    }

    /// A late release naming an older share leaves the session's newer one alone.
    func testAReleaseNamingAnOlderShareLeavesTheNewerOne() async throws {
        let browser = makeBrowser()
        let old = try await XCTUnwrapAsync(await browser.lease(sessionId: "S1", agent: .claude, cwd: "/tmp/project"))
        browser.release(sessionId: "S1")
        await browser.settle()
        _ = await browser.lease(sessionId: "S1", agent: .claude, cwd: "/tmp/project")

        browser.release(sessionId: "S1", sessionName: old.sessionName)
        await browser.settle()

        XCTAssertEqual(launcher.processes[1].isRunning, true)
        XCTAssertEqual(runner.calls.count, 1, "only the first share's daemon was stopped")
    }

    /// A session that ends while its Chrome is still starting leaves nothing running.
    func testASessionReleasedWhileChromeStartsGetsNoBrowserAndChromeStops() async throws {
        launcher.publishesPort = nil
        let browser = makeBrowser()
        clock.onSleep = { [launcher] in
            browser.release(sessionId: "S1")
            launcher!.publish(port: 43117)
        }

        let lease = await browser.lease(sessionId: "S1", agent: .claude, cwd: "/tmp/project")

        XCTAssertNil(lease)
        XCTAssertEqual(launcher.processes.first?.isRunning, false)
    }

    /// Every tab the session was seen pinned to is closed — `tab_new` moves the pin — and only those.
    func testEndingASessionClosesEveryTabItOpenedStopsItsDaemonAndForgetsItsTab() async throws {
        let browser = makeBrowser()
        devTools.pages = ["boot"]
        let s1 = try await XCTUnwrapAsync(await browser.lease(sessionId: "S1", agent: .claude, cwd: "/tmp/project"))
        let s2 = try await XCTUnwrapAsync(await browser.lease(sessionId: "S2", agent: .claude, cwd: "/tmp/project"))

        devTools.pages += ["T1", "U1"]
        try pin(s1, to: "T1")
        try pin(s2, to: "U1")
        await browser.trackTabs()
        devTools.pages += ["T2"]
        try pin(s1, to: "T2")
        await browser.trackTabs()

        browser.release(sessionId: "S1")
        await browser.settle()

        XCTAssertEqual(devTools.closed.sorted(), ["T1", "T2"])
        XCTAssertEqual(runner.calls, [["/bin/agent-browser", "--session", s1.sessionName, "close", "--json"]])
        XCTAssertFalse(targetFileExists(s1))
        XCTAssertTrue(targetFileExists(s2))
        XCTAssertEqual(launcher.processes[0].stopCount, 0)
        XCTAssertTrue(notices.isEmpty, notices.joined(separator: "\n"))
    }

    /// A tab nobody is pinned to (a popup, or `tab_new` then a switch back) belongs to the session
    /// when it is the only one in that browser.
    func testANewTabNobodyPinnedIsTheOnlySessionsTab() async throws {
        let browser = makeBrowser()
        devTools.pages = ["boot"]
        let s1 = try await XCTUnwrapAsync(await browser.lease(sessionId: "S1", agent: .claude, cwd: "/tmp/project"))
        devTools.pages += ["T1", "P1"]
        try pin(s1, to: "T1")
        await browser.trackTabs()
        _ = await browser.lease(sessionId: "S2", agent: .claude, cwd: "/tmp/project")

        browser.release(sessionId: "S1")
        await browser.settle()

        XCTAssertEqual(devTools.closed.sorted(), ["P1", "T1"])
    }

    func testTheDaemonIsStoppedThroughTheServersOwnCommandFoundOnThePath() async throws {
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let npx = bin.appendingPathComponent("npx")
        try Data("#!/bin/sh\n".utf8).write(to: npx)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: npx.path)
        let browser = makeBrowser(
            server: AgentBrowserServer(name: "browser", commandLine: ["npx", "-y", "agent-browser", "mcp"]),
            searchPath: [root.appendingPathComponent("nothing").path, bin.path])
        let lease = try await XCTUnwrapAsync(await browser.lease(sessionId: "S1", agent: .claude, cwd: "/tmp/project"))

        browser.release(sessionId: "S1")
        await browser.settle()

        XCTAssertEqual(runner.calls, [[npx.path, "-y", "agent-browser", "--session", lease.sessionName, "close", "--json"]])
    }

    func testADaemonThatCannotBeStoppedSaysWhatAgentBrowserAnswered() async throws {
        runner.result = ProcessResult(status: 1, stdout: #"{"success":false,"error":"daemon socket refused"}"#, stderr: "")
        let browser = makeBrowser()
        _ = await browser.lease(sessionId: "S1", agent: .claude, cwd: "/tmp/project")

        browser.release(sessionId: "S1")
        await browser.settle()

        XCTAssertEqual(notices.count, 1)
        XCTAssertTrue(notices[0].contains("daemon socket refused"), notices[0])
    }

    func testAnAgentBrowserThatIsNotOnThePathSaysSo() async throws {
        let browser = makeBrowser(server: AgentBrowserServer(name: "browser", commandLine: ["agent-browser", "mcp"]))
        _ = await browser.lease(sessionId: "S1", agent: .claude, cwd: "/tmp/project")

        browser.release(sessionId: "S1")
        await browser.settle()

        XCTAssertTrue(runner.calls.isEmpty)
        XCTAssertTrue(notices.first?.contains("agent-browser") == true, notices.first ?? "no notice")
    }

    func testQuittingStopsEveryChromeAndEverySessionsDaemon() async throws {
        let browser = makeBrowser()
        let lease = try await XCTUnwrapAsync(await browser.lease(sessionId: "S1", agent: .claude, cwd: "/tmp/project"))
        try pin(lease, to: "T1")

        browser.stopAll()

        XCTAssertEqual(launcher.processes[0].isRunning, false)
        XCTAssertEqual(launcher.detached, [["/bin/agent-browser", "--session", lease.sessionName, "close", "--json"]])
        XCTAssertFalse(targetFileExists(lease))
    }
}

/// `XCTUnwrap` for a value an `await` produced.
func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}

/// The live seams' own parsing.
final class SharedBrowserLiveTests: XCTestCase {
    func testOnlyPageTargetsAreTabs() throws {
        let list = #"""
        [{"id":"A","type":"page","url":"about:blank"},
         {"id":"B","type":"service_worker","url":"chrome-extension://x/sw.js"},
         {"id":"C","type":"page","url":"data:text/html,x"},
         {"id":"D","type":"iframe","url":"chrome-untrusted://new-tab-page/x"}]
        """#
        XCTAssertEqual(try LiveSharedBrowserDevTools.pageIds(in: Data(list.utf8)), ["A", "C"])
        XCTAssertThrowsError(try LiveSharedBrowserDevTools.pageIds(in: Data(#"{"id":"A"}"#.utf8)))
    }

    func testTheArgumentsOfAProcessAreItsArgv() throws {
        let argv = try XCTUnwrap(ProcessSnooper.arguments(of: getpid()))
        XCTAssertEqual(argv, CommandLine.arguments)
        XCTAssertNil(ProcessSnooper.arguments(of: 999_999))
    }
}

import XCTest
import os
@testable import LinkCKit

/// `sampleAgentStates` and the agent probes: which sessions are probed, how often, and that a
/// freshly launched agent is still promoted from `.starting` on the tick it appears.
final class AgentProbeSweepTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-agent-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    /// Scripted answers for every probe, and a record of each call. The clock is the test's.
    private final class ScriptedProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var _treeCalls = 0, _bootCalls = 0
        private var _tree: AgentKind?, _boot: AgentKind?
        private var _foreground: pid_t = 4242
        private var _now = Date(timeIntervalSince1970: 1_000_000)

        var treeCalls: Int { lock.withLock { _treeCalls } }
        var bootCalls: Int { lock.withLock { _bootCalls } }
        var tree: AgentKind? { get { lock.withLock { _tree } } set { lock.withLock { _tree = newValue } } }
        var boot: AgentKind? { get { lock.withLock { _boot } } set { lock.withLock { _boot = newValue } } }
        var foreground: pid_t { get { lock.withLock { _foreground } } set { lock.withLock { _foreground = newValue } } }
        func advance(_ seconds: TimeInterval) { lock.withLock { _now = _now.addingTimeInterval(seconds) } }

        var probe: AgentProbe {
            AgentProbe(
                inTree: { [self] _ in lock.withLock { _treeCalls += 1; return _tree } },
                atOrUnder: { [self] _ in lock.withLock { _bootCalls += 1; return _boot } },
                foregroundGroup: { [self] _ in lock.withLock { _foreground } },
                now: { [self] in lock.withLock { _now } }
            )
        }
    }

    @MainActor
    private func makeCoordinator() -> AppCoordinator {
        let script = tempDir.appendingPathComponent("mock_agent.sh")
        if !FileManager.default.fileExists(atPath: script.path) {
            try? "#!/bin/sh\nstty -echo 2>/dev/null\nprintf '\\033[?2004h'\nexec /bin/cat\n".write(to: script, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        }
        let settingsDir = tempDir.appendingPathComponent("settings")
        try? FileManager.default.createDirectory(at: settingsDir, withIntermediateDirectories: true)
        return AppCoordinator(
            terminals: TerminalSessionManager(),
            hookServer: HookServer(port: 0),
            notifications: NotificationManager(sink: NullSink(), now: { Date() }),
            claudePath: script.path,
            settingsDir: settingsDir,
            userSettingsURL: tempDir.appendingPathComponent("user-settings.json"),
            manifestDir: tempDir.appendingPathComponent("manifest"),
            agentPathResolver: { _ in script.path },
            deliverySettle: 0,
            turnEndQuietPeriod: 0,
            isWatching: { _ in false }
        )
    }

    private struct NullSink: NotificationSink {
        func deliver(id: String, title: String, body: String) {}
    }

    /// A session running the mock agent, its terminal probing through `script`.
    @MainActor
    private func launch(_ coordinator: AppCoordinator, agent: AgentKind, script: ScriptedProbe) throws -> (Session, TerminalSession) {
        let session = try coordinator.newSession(cwd: tempDir.path, agent: agent)
        let term = try XCTUnwrap(coordinator.terminals.session(id: session.id))
        term.agentProbe = script.probe
        return (session, term)
    }

    @MainActor
    func testAHookedSessionsProcessTreeIsNeverWalked() throws {
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }
        let script = ScriptedProbe()
        script.tree = .codex
        let (session, _) = try launch(coordinator, agent: .claude, script: script)

        for _ in 0..<3 { coordinator.sampleAgentStates() }

        XCTAssertEqual(script.treeCalls, 0, "its kind comes from hook events; the walk's answer was thrown away")
        XCTAssertEqual(coordinator.store.session(id: session.id)?.agentKind, .claude)
    }

    @MainActor
    func testAnotherSessionsTreeIsWalkedOnceWhileItsForegroundStaysPut() throws {
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }
        let script = ScriptedProbe()
        let (_, _) = try launch(coordinator, agent: .codex, script: script)

        for _ in 0..<5 {
            coordinator.sampleAgentStates()
            script.advance(1)
        }

        XCTAssertEqual(script.treeCalls, 1)
    }

    @MainActor
    func testTheTreeIsWalkedAgainWhenTheForegroundMovesOrTenSecondsPass() throws {
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }
        let script = ScriptedProbe()
        let (_, _) = try launch(coordinator, agent: .codex, script: script)
        coordinator.sampleAgentStates()
        XCTAssertEqual(script.treeCalls, 1)

        script.foreground = 5151
        script.advance(1)
        coordinator.sampleAgentStates()
        XCTAssertEqual(script.treeCalls, 2, "the terminal's foreground command changed")

        script.advance(9)
        coordinator.sampleAgentStates()
        XCTAssertEqual(script.treeCalls, 2, "nine seconds on: not yet")

        script.advance(1)
        coordinator.sampleAgentStates()
        XCTAssertEqual(script.treeCalls, 3, "ten seconds since the last walk")
    }

    /// A minute of sweeps over a mix of hooked and other sessions, the shape of a working day.
    @MainActor
    func testAMinuteOfSweepsWalksTheTreeOnceEveryTenSecondsPerUnhookedSession() throws {
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }
        let script = ScriptedProbe()
        for agent in [AgentKind.claude, .claude, .codex, .cursor, .agy] {
            _ = try launch(coordinator, agent: agent, script: script)
        }

        for _ in 0..<60 {
            coordinator.sampleAgentStates()
            script.advance(1)
        }

        // Three unhooked sessions, walked at 0, 10, ... 50 seconds. Before: five sessions x 60 sweeps.
        XCTAssertEqual(script.treeCalls, 3 * 6)
    }

    @MainActor
    func testADifferentAgentInTheTreeStillChangesTheSessionsKind() throws {
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }
        let script = ScriptedProbe()
        script.tree = .cursor
        let (session, _) = try launch(coordinator, agent: .agy, script: script)

        coordinator.sampleAgentStates()
        XCTAssertEqual(coordinator.store.session(id: session.id)?.agentKind, .cursor)

        script.tree = .codex
        script.foreground = 9000
        script.advance(1)
        coordinator.sampleAgentStates()
        XCTAssertEqual(coordinator.store.session(id: session.id)?.agentKind, .codex)
    }

    /// An agent that runs a child binary named `claude` reads as Claude while the child lives. Its
    /// session was not launched as Claude, so nothing but the tree walk can tell it is back to
    /// itself once the child exits.
    @MainActor
    func testASessionReadAsClaudeGoesBackToItsAgentOnceTheClaudeProcessIsGone() throws {
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }
        let script = ScriptedProbe()
        script.tree = .claude
        let (session, _) = try launch(coordinator, agent: .codex, script: script)

        coordinator.sampleAgentStates()
        XCTAssertEqual(coordinator.store.session(id: session.id)?.agentKind, .claude, "a claude process runs beneath it")

        script.tree = nil
        script.advance(10)
        coordinator.sampleAgentStates()

        XCTAssertEqual(coordinator.store.session(id: session.id)?.agentKind, .codex, "the child exited, so it is the launched agent again")
    }

    @MainActor
    func testShuttingDownSavesAHookedSessionAsClaudeWhateverRunsInsideIt() throws {
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }
        let script = ScriptedProbe()
        script.tree = .codex
        let (session, _) = try launch(coordinator, agent: .claude, script: script)

        coordinator.prepareForShutdown()

        let saved = coordinator.manifest.entries.first { $0.linkcId == session.id }
        XCTAssertEqual(saved?.agentKind, .claude, "its kind comes from hook events, not from what it runs")
        XCTAssertEqual(script.treeCalls, 0)
    }

    @MainActor
    func testABootingSessionIsPromotedOnTheTickItsAgentAppearsWhateverTheTreeWalkKept() throws {
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }
        let script = ScriptedProbe()
        let (session, _) = try launch(coordinator, agent: .codex, script: script)
        XCTAssertEqual(coordinator.store.session(id: session.id)?.state, .starting)

        coordinator.sampleAgentStates()
        XCTAssertEqual(coordinator.store.session(id: session.id)?.state, .starting, "no agent process yet")

        script.boot = .codex
        script.advance(1)
        coordinator.sampleAgentStates()

        XCTAssertEqual(coordinator.store.session(id: session.id)?.state, .ready, "the very next tick promotes it")
        XCTAssertEqual(script.bootCalls, 2)
        XCTAssertEqual(script.treeCalls, 1, "the kept tree walk did not delay the promotion")
    }

    @MainActor
    func testShuttingDownSavesAFreshAnswerNotAKeptOne() throws {
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }
        let script = ScriptedProbe()
        let (session, _) = try launch(coordinator, agent: .codex, script: script)
        coordinator.sampleAgentStates()

        // A wrapper execs another agent: same process group, so nothing tells the sweep yet.
        script.tree = .cursor
        script.advance(1)
        coordinator.prepareForShutdown()

        let saved = coordinator.manifest.entries.first { $0.linkcId == session.id }
        XCTAssertEqual(saved?.agentKind, .cursor)
    }

    /// The real probe on a real PTY: the foreground group is the shell while it waits, and a
    /// different group once it runs a command as a job.
    @MainActor
    func testTheLiveProbeReadsThePtysForegroundProcessGroup() async throws {
        let session = TerminalSession(id: "pty", cwd: tempDir.path, title: "pty")
        defer { session.terminate() }
        try session.start(executable: "/bin/sh", args: ["-ic", "sleep 5; true"], env: [:])
        let shell = session.processId

        var group: pid_t?
        for _ in 0..<100 {
            group = AgentProbe.live.foregroundGroup(shell)
            if let group, group != shell { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        let foreground = try XCTUnwrap(group)
        XCTAssertNotEqual(foreground, shell, "the sleep runs as its own job, so the terminal's foreground group moved off the shell")
        XCTAssertGreaterThan(foreground, 0)
    }
}

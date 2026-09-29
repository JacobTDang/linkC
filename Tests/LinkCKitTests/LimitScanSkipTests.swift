import XCTest
@testable import LinkCKit

/// `checkLimitsAndReroute` runs the whole limit-rule battery over a session's recent output. It
/// does that once for each distinct screen, not once a second for a screen that has not moved —
/// without changing what a stale banner, a new banner or an already recorded limit does.
///
/// Banner phrases are joined from words here so that reading or printing this file never puts a
/// live limit banner on a terminal linkC is watching.
final class LimitScanSkipTests: XCTestCase {
    private var workspace: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-limit-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workspace)
        try super.tearDownWithError()
    }

    /// The phrase Codex, Cursor and agy all read as a limit.
    private var rateLimitBanner: String { ["Rate", "limit", "exceeded"].joined(separator: " ") }
    /// A phrase only Claude's rules read as a limit.
    private var creditBanner: String { ["credit", "balance", "too", "low"].joined(separator: " ") }

    /// One session on a terminal that was never given a process, showing `screen` exactly.
    @MainActor
    private func makeSession(agent: AgentKind, screen: String) -> (AppCoordinator, TerminalSession, String) {
        let coordinator = AppCoordinator(workspaceDir: workspace)
        let id = "S1"
        _ = coordinator.store.create(cwd: workspace.path, title: id, id: id, agentKind: agent)
        coordinator.store.updateState(id: id, to: .ready)
        let term = coordinator.terminals.makeSession(id: id, cwd: workspace.path, title: id, agentKind: agent)
        term.terminalView.getTerminal().resize(cols: 120, rows: ScreenFixture.height)
        term.terminalView.feed(text: screen)
        return (coordinator, term, id)
    }

    /// Counts every scan the detector is asked for, and answers with the real rules.
    @MainActor
    private func countingScans(_ coordinator: AppCoordinator) -> ScanCounter {
        let counter = ScanCounter()
        coordinator.limitDetection = { output, agent, injected in
            counter.count += 1
            return LimitDetector.detectLimit(inOutput: output, agent: agent, ignoringInjected: injected)
        }
        return counter
    }

    private final class ScanCounter: @unchecked Sendable { var count = 0 }

    @MainActor
    func testAnUnchangedScreenIsScannedOnceNoMatterHowManyTicksSeeIt() {
        let (coordinator, _, _) = makeSession(agent: .codex, screen: ScreenFixture.terminalInput(spinnerSeconds: nil))
        defer { coordinator.shutdown() }
        let scans = countingScans(coordinator)

        for _ in 0..<5 { coordinator.sampleAgentStates() }

        XCTAssertEqual(scans.count, 1, "the screen never changed, so the rules had nothing new to read")
    }

    @MainActor
    func testAScreenThatChangedIsScannedAgain() {
        let (coordinator, term, _) = makeSession(agent: .codex, screen: ScreenFixture.terminalInput(spinnerSeconds: nil))
        defer { coordinator.shutdown() }
        let scans = countingScans(coordinator)
        coordinator.sampleAgentStates()

        term.terminalView.feed(text: "\r\n⏺ Bash(swift build)")
        coordinator.sampleAgentStates()
        coordinator.sampleAgentStates()

        XCTAssertEqual(scans.count, 2, "one scan for each distinct screen")
    }

    @MainActor
    func testAnUnchangedScreenChangesNoRecordedLimit() throws {
        let (coordinator, term, id) = makeSession(agent: .codex, screen: ScreenFixture.terminalInput(spinnerSeconds: nil))
        defer { coordinator.shutdown() }
        let inbox = InboxStore(workspaceRoot: workspace.path)
        coordinator.sampleAgentStates()
        XCTAssertNil(try inbox.isAgentLimited(agent: .codex), "nothing on the screen yet")

        term.terminalView.feed(text: "\r\n\(rateLimitBanner)")
        coordinator.sampleAgentStates()
        let recorded = try XCTUnwrap(try inbox.isAgentLimited(agent: .codex), "a banner on a changed screen must still be found")
        XCTAssertEqual(coordinator.store.session(id: id)?.state, .error, "no peer to reroute to, so the session is held")

        // The cooldown lapses while the banner is still the last thing on the screen: the session
        // recovers, and the same old banner must not arm a new one.
        var seeded = try inbox.load()
        let index = try XCTUnwrap(seeded.agentLimits.firstIndex { $0.agent == .codex })
        seeded.agentLimits[index] = AgentLimitStatus(
            agent: .codex, reason: recorded.reason, limitedAt: recorded.limitedAt,
            cooldownExpiresAt: Date().addingTimeInterval(-1)
        )
        try inbox.saveRaw(seeded)
        for _ in 0..<3 { coordinator.sampleAgentStates() }

        XCTAssertNotEqual(coordinator.store.session(id: id)?.state, .error, "the session recovers once its cooldown ends")
        XCTAssertNil(try inbox.isAgentLimited(agent: .codex), "an unchanged screen must not re-arm a lapsed limit")
    }

    /// A redraw can change the screen without changing the rows the rules read: a frame drawn over
    /// a blank row is chrome, which the rules never see. The screen scan then runs again and finds
    /// the same old banner, and only the per-session banner signature stops it re-arming a limit
    /// whose cooldown has lapsed.
    @MainActor
    func testAFrameDrawnOverABlankRowDoesNotRearmALapsedLimitFromTheSameOldBanner() throws {
        let (coordinator, term, id) = makeSession(
            agent: .codex, screen: "\u{1b}[2J\u{1b}[H\(rateLimitBanner)\r\n\r\n\r\n"
        )
        defer { coordinator.shutdown() }
        let inbox = InboxStore(workspaceRoot: workspace.path)
        coordinator.sampleAgentStates()
        let recorded = try XCTUnwrap(try inbox.isAgentLimited(agent: .codex), "the banner is a limit")

        var seeded = try inbox.load()
        let index = try XCTUnwrap(seeded.agentLimits.firstIndex { $0.agent == .codex })
        seeded.agentLimits[index] = AgentLimitStatus(
            agent: .codex, reason: recorded.reason, limitedAt: recorded.limitedAt,
            cooldownExpiresAt: Date().addingTimeInterval(-1)
        )
        try inbox.saveRaw(seeded)
        for _ in 0..<3 { coordinator.sampleAgentStates() }
        XCTAssertNotEqual(coordinator.store.session(id: id)?.state, .error, "the session recovers once its cooldown ends")
        XCTAssertNil(try inbox.isAgentLimited(agent: .codex))
        let screenBefore = term.screenSnapshot().fingerprint

        term.terminalView.feed(text: "\u{1b}[3;1H╭──────────────────╮")
        XCTAssertNotEqual(term.screenSnapshot().fingerprint, screenBefore, "the screen changed")
        XCTAssertEqual(
            term.screenSnapshot().recentOutput(lines: 50), rateLimitBanner,
            "and the rows the rules read did not"
        )
        let scans = countingScans(coordinator)
        coordinator.sampleAgentStates()

        XCTAssertEqual(scans.count, 1, "a changed screen is scanned again")
        XCTAssertNil(try inbox.isAgentLimited(agent: .codex), "the same old banner must not arm a new limit")
        XCTAssertNotEqual(coordinator.store.session(id: id)?.state, .error)
    }

    @MainActor
    func testANewBannerOnAChangedScreenIsFoundAfterAQuietStretch() throws {
        let (coordinator, term, _) = makeSession(agent: .cursor, screen: ScreenFixture.terminalInput(spinnerSeconds: nil))
        defer { coordinator.shutdown() }
        let inbox = InboxStore(workspaceRoot: workspace.path)
        for _ in 0..<4 { coordinator.sampleAgentStates() }
        XCTAssertNil(try inbox.isAgentLimited(agent: .cursor))

        term.terminalView.feed(text: "\r\n\(rateLimitBanner)")
        coordinator.sampleAgentStates()

        XCTAssertNotNil(try inbox.isAgentLimited(agent: .cursor))
    }

    @MainActor
    func testAnAgentKindChangeScansTheUnchangedScreenWithTheNewRules() throws {
        let (coordinator, term, id) = makeSession(agent: .codex, screen: ScreenFixture.terminalInput(spinnerSeconds: nil))
        defer { coordinator.shutdown() }
        let inbox = InboxStore(workspaceRoot: workspace.path)
        term.terminalView.feed(text: "\r\n\(creditBanner)")
        coordinator.sampleAgentStates()
        XCTAssertNil(try inbox.isAgentLimited(agent: .codex), "not one of Codex's phrases")

        coordinator.store.updateAgentKind(id: id, to: .claude)
        coordinator.sampleAgentStates()

        XCTAssertNotNil(try inbox.isAgentLimited(agent: .claude), "the same screen reads differently to Claude's rules")
    }

    @MainActor
    func testANewInjectionScansTheUnchangedScreenAgain() {
        let (coordinator, _, id) = makeSession(agent: .codex, screen: ScreenFixture.terminalInput(spinnerSeconds: nil))
        defer { coordinator.shutdown() }
        let scans = countingScans(coordinator)
        coordinator.sampleAgentStates()

        coordinator.recordInjection(sessionId: id, text: "a brief typed into the session")
        coordinator.sampleAgentStates()

        XCTAssertEqual(scans.count, 2, "what linkC typed decides what counts as the agent's own words")
    }
}

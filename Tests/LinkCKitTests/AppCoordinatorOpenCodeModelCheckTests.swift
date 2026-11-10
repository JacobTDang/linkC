import XCTest
import os
@testable import LinkCKit

/// A wall clock a test moves by hand, so the listing's cache can be aged without sleeping.
private final class ControllableClock: Sendable {
    private let box = OSAllocatedUnfairLock(initialState: Date())
    func advance(_ seconds: TimeInterval) { box.withLock { $0 = $0.addingTimeInterval(seconds) } }
    func now() -> Date { box.withLock { $0 } }
}

/// An injected `opencode models` listing: counts its calls, answers with `answer`, and while
/// `held` waits to be released, so a test decides when a listing finishes.
private final class ModelLister: @unchecked Sendable {
    enum Answer {
        case models([String])
        case failure(String)
    }

    private let lock = NSLock()
    private var answer: Answer
    private var held: Bool
    private var count = 0

    init(_ answer: Answer, held: Bool = false) {
        self.answer = answer
        self.held = held
    }

    var calls: Int { lock.withLock { count } }
    func release() { lock.withLock { held = false } }

    func list(_ folder: String) async throws -> [String] {
        lock.withLock { count += 1 }
        while lock.withLock({ held }) { try await Task.sleep(nanoseconds: 5_000_000) }
        switch lock.withLock({ answer }) {
        case .models(let models): return models
        case .failure(let message): throw LinkCError.process(message)
        }
    }
}

private final class CapturingSink: NotificationSink, @unchecked Sendable {
    private let lock = NSLock()
    private var all: [(id: String, title: String, body: String)] = []
    var deliveries: [(id: String, title: String, body: String)] { lock.withLock { all } }
    func deliver(id: String, title: String, body: String) { lock.withLock { all.append((id, title, body)) } }
    func refusals() -> [(id: String, title: String, body: String)] {
        deliveries.filter { $0.title == "linkC: OpenCode could not start" }
    }
}

/// What linkC does when the model a tier names may not be one OpenCode lists: on a limit reroute,
/// and wherever a queued task or message would start an OpenCode worker. The listing is injected,
/// so a test says what OpenCode lists and when it answers.
@MainActor
final class AppCoordinatorOpenCodeModelCheckTests: XCTestCase {
    nonisolated(unsafe) private var tempDir: URL!
    private var folder: String { ProjectPath.canonical(tempDir.path) }
    private let sink = CapturingSink()

    /// The phrase Codex's limit rules read as a limit, joined so this file never prints one.
    private var banner: String { ["Rate", "limit", "exceeded"].joined(separator: " ") }

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-opencode-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    /// A stand-in agent that negotiates bracketed paste and waits for input, like a TUI.
    private var mockAgent: String {
        let script = tempDir.appendingPathComponent("mock_agent.sh")
        if !FileManager.default.fileExists(atPath: script.path) {
            try? "#!/bin/sh\nstty -echo 2>/dev/null\nprintf '\\033[?2004h'\nexec /bin/cat\n"
                .write(to: script, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        }
        return script.path
    }

    /// Only OpenCode is installed, so it is the one peer a limited agent's task can move to. Claude's
    /// own path does not exist, so it is not a peer either.
    private func makeCoordinator(
        lister: ModelLister,
        now: @escaping @MainActor @Sendable () -> Date = Date.init,
        installed: Set<AgentKind> = [.opencode],
        sweepClock: any Clock<Duration> = ContinuousClock(),
        mcpWorkspaces: @escaping @MainActor @Sendable () -> Set<String> = { [] }
    ) -> AppCoordinator {
        let agent = mockAgent
        let settingsDir = tempDir.appendingPathComponent("settings")
        try? FileManager.default.createDirectory(at: settingsDir, withIntermediateDirectories: true)
        return AppCoordinator(
            terminals: TerminalSessionManager(),
            hookServer: HookServer.forTesting(),
            notifications: NotificationManager(sink: sink, now: { Date() }),
            claudePath: "/x/claude",
            settingsDir: settingsDir,
            userSettingsURL: tempDir.appendingPathComponent("user-settings.json"),
            manifestDir: tempDir.appendingPathComponent("manifest"),
            agentPathResolver: { installed.contains($0) ? agent : nil },
            modelSettings: { .seeded },
            deliverySettle: 0,
            injectionGap: 0,
            now: now,
            sweepClock: sweepClock,
            mcpWorkspaces: mcpWorkspaces,
            openCodeModels: { try await lister.list($0) },
            isWatching: { _ in false }
        )
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws -> Bool {
        for _ in 0..<TestWait.polls {
            if predicate() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return predicate()
    }

    /// Waits for the listing a pass started to be stored: the next pass then reads its answer.
    private func waitForListing(_ coordinator: AppCoordinator, after checks: Int = 0) async throws {
        let listed = try await waitUntil { coordinator.openCodeModelCheckCount > checks }
        XCTAssertTrue(listed, "the listing never finished")
    }

    private func stopAll(_ coordinator: AppCoordinator) {
        coordinator.store.sessions.forEach { coordinator.stopSession($0.id) }
        coordinator.shutdown()
    }

    // MARK: - A limit reroute that waits for the listing

    /// A Codex session on a terminal with no process, showing `screen`, whose turn is over and which
    /// carries a delivered task from Claude.
    private func limitedCodexSession(
        in coordinator: AppCoordinator, screen: String
    ) throws -> (terminal: TerminalSession, task: TaskRecord, inbox: InboxStore) {
        let id = "S1"
        _ = coordinator.store.create(cwd: folder, title: id, id: id, agentKind: .codex)
        coordinator.store.updateState(id: id, to: .finished)
        let terminal = coordinator.terminals.makeSession(id: id, cwd: folder, title: id, agentKind: .codex)
        terminal.terminalView.getTerminal().resize(cols: 120, rows: ScreenFixture.height)
        terminal.terminalView.feed(text: screen)
        let inbox = InboxStore(workspaceRoot: folder)
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "carry this", files: [])
        try inbox.markTaskDelivered(taskId: task.id, sessionId: id)
        return (terminal, task, inbox)
    }

    /// Ends Codex's recorded cooldown and returns its session to ready: what `sampleAgentStates`
    /// does once a limit has lapsed.
    private func lapseCodexCooldown(_ coordinator: AppCoordinator, inbox: InboxStore) throws {
        var seeded = try inbox.load()
        let index = try XCTUnwrap(seeded.agentLimits.firstIndex { $0.agent == .codex })
        let recorded = seeded.agentLimits[index]
        seeded.agentLimits[index] = AgentLimitStatus(
            agent: .codex, reason: recorded.reason, limitedAt: recorded.limitedAt,
            cooldownExpiresAt: Date().addingTimeInterval(-1))
        try inbox.saveRaw(seeded)
        coordinator.store.updateState(id: "S1", to: .ready)
    }

    /// The listing was still running when the session's task ended: when it finishes, the unchanged
    /// screen is read again from the start, finds nothing in flight, and holds the session. Once the
    /// cooldown has lapsed, the same old banner (redrawn over, so the screen is read again) must
    /// not arm a new limit.
    func testAnOldBannerDoesNotRearmALimitWhenTheTaskEndedWhileTheListingRan() async throws {
        let lister = ModelLister(.models(["opencode/big-pickle"]), held: true)
        let coordinator = makeCoordinator(lister: lister)
        defer { stopAll(coordinator) }
        let (terminal, task, inbox) = try limitedCodexSession(
            in: coordinator, screen: "\u{1b}[2J\u{1b}[H\(banner)\r\n\r\n\r\n")

        XCTAssertFalse(coordinator.checkLimitsAndReroute(for: "S1", screen: terminal.screenSnapshot()),
                       "the listing starts off the main actor")
        try inbox.cancelTask(taskId: task.id, reason: "the delegator withdrew it")
        lister.release()
        try await waitForListing(coordinator)
        XCTAssertTrue(coordinator.checkLimitsAndReroute(for: "S1", screen: terminal.screenSnapshot()),
                      "nothing is in flight, so the limit is recorded and the session held")
        XCTAssertEqual(coordinator.store.session(id: "S1")?.state, .error)

        try lapseCodexCooldown(coordinator, inbox: inbox)
        terminal.terminalView.feed(text: "\u{1b}[3;1H╭──────────────────╮")
        XCTAssertFalse(coordinator.checkLimitsAndReroute(for: "S1", screen: terminal.screenSnapshot()))

        XCTAssertNil(try inbox.isAgentLimited(agent: .codex), "the same old banner must not arm a new limit")
        XCTAssertNotEqual(coordinator.store.session(id: "S1")?.state, .error)
        XCTAssertTrue(try inbox.load().tasks.filter { $0.hop == 1 }.isEmpty, "and must not reroute anything")
    }

    private final class ScanCounter: @unchecked Sendable { var count = 0 }

    private func countScans(_ coordinator: AppCoordinator) -> ScanCounter {
        let counter = ScanCounter()
        coordinator.limitDetection = { output, agent, injected in
            counter.count += 1
            return LimitDetector.detectLimit(inOutput: output, agent: agent, ignoringInjected: injected)
        }
        return counter
    }

    /// Reading a screen again because a listing was pending must not outlast that listing: after the
    /// task ended during it, the unchanged screen is skipped by the scan cache on every later tick.
    func testAnUnchangedScreenIsSkippedAgainAfterTheTaskEndedWhileTheListingRan() async throws {
        let lister = ModelLister(.models(["opencode/big-pickle"]), held: true)
        let coordinator = makeCoordinator(lister: lister)
        defer { stopAll(coordinator) }
        let (terminal, task, inbox) = try limitedCodexSession(in: coordinator, screen: banner)
        let scans = countScans(coordinator)
        let screen = terminal.screenSnapshot()

        XCTAssertFalse(coordinator.checkLimitsAndReroute(for: "S1", screen: screen))
        try inbox.cancelTask(taskId: task.id, reason: "the delegator withdrew it")
        lister.release()
        try await waitForListing(coordinator)
        XCTAssertTrue(coordinator.checkLimitsAndReroute(for: "S1", screen: screen))
        XCTAssertEqual(scans.count, 2, "the pass that waited for the listing, and the one that read its answer")

        try lapseCodexCooldown(coordinator, inbox: inbox)
        for _ in 0..<3 { _ = coordinator.checkLimitsAndReroute(for: "S1", screen: screen) }

        XCTAssertEqual(scans.count, 2, "the screen has not changed since, so the rules have nothing new to read")
    }

    /// The same when the listing resolves with the task still in flight: the reroute goes ahead, and
    /// the unchanged screen is skipped again afterwards.
    func testAnUnchangedScreenIsSkippedAgainAfterAListingResolvedTheReroute() async throws {
        let lister = ModelLister(.models(["opencode/big-pickle"]), held: true)
        let coordinator = makeCoordinator(lister: lister)
        defer { stopAll(coordinator) }
        let (terminal, _, inbox) = try limitedCodexSession(in: coordinator, screen: banner)
        let scans = countScans(coordinator)
        let screen = terminal.screenSnapshot()

        XCTAssertFalse(coordinator.checkLimitsAndReroute(for: "S1", screen: screen))
        lister.release()
        try await waitForListing(coordinator)
        XCTAssertTrue(coordinator.checkLimitsAndReroute(for: "S1", screen: screen))
        XCTAssertEqual(try inbox.load().tasks.first { $0.hop == 1 }?.toAgent, .opencode)
        XCTAssertEqual(scans.count, 2)

        try lapseCodexCooldown(coordinator, inbox: inbox)
        for _ in 0..<3 { _ = coordinator.checkLimitsAndReroute(for: "S1", screen: screen) }

        XCTAssertEqual(scans.count, 2, "the screen has not changed since, so the rules have nothing new to read")
    }
}

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

    private func waitUntil(polls: Int = TestWait.polls, _ predicate: @MainActor () -> Bool) async throws -> Bool {
        for _ in 0..<polls {
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

    // MARK: - The listing's own limits

    /// `linkc` waits for the app's answer to its open request, and gives up when that takes too long.
    /// The app's own listing gives up sooner, so the command hears "could not check" and not silence.
    func testTheAppGivesUpListingModelsBeforeTheCommandGivesUpWaiting() {
        let command = LinkCCommand.Environment(
            store: OpenRequestStore(directory: tempDir.appendingPathComponent("open-requests")), folder: folder,
            caller: { nil }, isLinkCRunning: { true }, launchLinkC: {}, now: Date.init, sleep: { _ in })

        XCTAssertLessThan(AppCoordinator.openCodeModelListingTimeout, command.timeout)
    }

    /// A listing that finishes wakes the sweep: the pass that waited for it need not wait out an idle
    /// interval, which can be longer than the five seconds the answer is kept.
    func testAFinishedListingWakesTheSweepForThePassThatWaitedForIt() async throws {
        let clock = ManualClock()
        let lister = ModelLister(.models(["opencode/big-pickle"]), held: true)
        let watched = folder
        let coordinator = makeCoordinator(lister: lister, sweepClock: clock, mcpWorkspaces: { [watched] })
        defer { stopAll(coordinator) }
        _ = try queueTask()
        try coordinator.start()
        let asked = try await waitUntil(polls: 250) { lister.calls > 0 }
        XCTAssertTrue(asked, "the first pass never asked for the listing")
        let asleep = try await waitUntil(polls: 250) { !clock.pendingSleeps.isEmpty }
        XCTAssertTrue(asleep, "the first pass never finished")

        lister.release()
        try await waitForListing(coordinator)
        clock.advance(by: TickCadence.minimumWakeGap)   // a woken pass waits out the gap since the last one

        let served = try await waitUntil(polls: 250) {
            coordinator.store.sessions.contains { $0.agentKind == .opencode && $0.isWorker }
        }
        XCTAssertTrue(served, "nothing woke the sweep when the listing finished, so no worker was started")
    }

    // MARK: - A limit reroute that waits for the listing

    /// A Codex session on a terminal with no process, showing `screen`, whose turn is over and which
    /// carries a delivered task from Claude.
    private func limitedCodexSession(
        in coordinator: AppCoordinator, screen: String, hop: Int = 0
    ) throws -> (terminal: TerminalSession, task: TaskRecord, inbox: InboxStore) {
        let id = "S1"
        _ = coordinator.store.create(cwd: folder, title: id, id: id, agentKind: .codex)
        coordinator.store.updateState(id: id, to: .finished)
        let terminal = coordinator.terminals.makeSession(id: id, cwd: folder, title: id, agentKind: .codex)
        terminal.terminalView.getTerminal().resize(cols: 120, rows: ScreenFixture.height)
        terminal.terminalView.feed(text: screen)
        let inbox = InboxStore(workspaceRoot: folder)
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "carry this", files: [], hop: hop, force: true)
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

    // MARK: - A reroute OpenCode cannot take

    /// What a listing that proves nothing, or a model it does not list, leaves of a limit reroute: the
    /// task stays with the agent that hit its limit, and the delegator is told so in as many words.
    private func assertTheTaskStaysAndTheDelegatorIsTold(
        _ task: TaskRecord, inbox: InboxStore, reason: String, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        XCTAssertNil(try inbox.load().tasks.first { $0.hop == 1 }, "nothing moved", file: file, line: line)
        XCTAssertEqual(try inbox.task(id: task.id)?.state, .delivered, "the original stays with its assignee", file: file, line: line)
        let notices = try inbox.load().messages.filter { $0.kind == .notice && $0.toAgent == .claude }
        XCTAssertEqual(notices.count, 1, file: file, line: line)
        let expected = "Codex reached its usage limit, and task \(task.shortId) stays with it: OpenCode can't take it — "
        XCTAssertTrue(notices.first?.prompt.contains(expected + reason) ?? false, notices.first?.prompt ?? "no notice", file: file, line: line)
    }

    func testAModelOpenCodeDoesNotListLeavesTheTaskWithItsAgentAndSaysSo() async throws {
        let lister = ModelLister(.models(["opencode/deepseek-v4.1-flash-free"]))
        let coordinator = makeCoordinator(lister: lister)
        defer { stopAll(coordinator) }
        let (terminal, task, inbox) = try limitedCodexSession(in: coordinator, screen: banner)
        let screen = terminal.screenSnapshot()

        XCTAssertFalse(coordinator.checkLimitsAndReroute(for: "S1", screen: screen))
        try await waitForListing(coordinator)
        XCTAssertTrue(coordinator.checkLimitsAndReroute(for: "S1", screen: screen))

        try assertTheTaskStaysAndTheDelegatorIsTold(
            task, inbox: inbox, reason: "opencode/big-pickle (opencode tier standard) is not among the models OpenCode lists")
        XCTAssertEqual(coordinator.store.session(id: "S1")?.state, .error)
        XCTAssertEqual(sink.refusals().count, 1)
    }

    func testAListingThatFailedLeavesTheTaskWithItsAgentAndSaysSo() async throws {
        let lister = ModelLister(.failure("`opencode models` did not answer within 10.0 seconds"))
        let coordinator = makeCoordinator(lister: lister)
        defer { stopAll(coordinator) }
        let (terminal, task, inbox) = try limitedCodexSession(in: coordinator, screen: banner)
        let screen = terminal.screenSnapshot()

        XCTAssertFalse(coordinator.checkLimitsAndReroute(for: "S1", screen: screen))
        try await waitForListing(coordinator)
        XCTAssertTrue(coordinator.checkLimitsAndReroute(for: "S1", screen: screen))

        try assertTheTaskStaysAndTheDelegatorIsTold(
            task, inbox: inbox,
            reason: "could not check opencode tier standard's model opencode/big-pickle against the models OpenCode lists — "
                + "`opencode models` did not answer within 10.0 seconds")
        XCTAssertEqual(coordinator.store.session(id: "S1")?.state, .error)
    }

    /// A task on its last hop cannot move whatever OpenCode lists: the hop-exhausted path runs at
    /// once, with no listing to wait for and no OpenCode refusal to report.
    func testATaskOnItsLastHopRunsTheHopExhaustedPathNotTheOpenCodeRefusal() async throws {
        let lister = ModelLister(.models(["opencode/deepseek-v4.1-flash-free"]))
        let coordinator = makeCoordinator(lister: lister)
        defer { stopAll(coordinator) }
        let (terminal, task, inbox) = try limitedCodexSession(in: coordinator, screen: banner, hop: 2)

        XCTAssertTrue(coordinator.checkLimitsAndReroute(for: "S1", screen: terminal.screenSnapshot()),
                      "no listing to wait for: the task is out of hops")
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(lister.calls, 0, "OpenCode's models are not listed for a task that cannot move")
        let notices = try inbox.load().messages.filter { $0.kind == .notice && $0.toAgent == .claude }
        XCTAssertEqual(notices.count, 1)
        XCTAssertTrue(notices.first?.prompt.contains("Task \(task.shortId) paused.") ?? false, notices.first?.prompt ?? "no notice")
        XCTAssertFalse(notices.first?.prompt.contains("OpenCode") ?? true, "the OpenCode refusal is not what the delegator is told")
        XCTAssertTrue(sink.refusals().isEmpty)
        XCTAssertTrue(sink.deliveries.contains { $0.title == "linkC: Swarm Rate Limited" })
        XCTAssertEqual(coordinator.store.session(id: "S1")?.state, .error)
    }

    // MARK: - A queued task for OpenCode

    private func queueTask(
        from delegator: AgentKind = .claude, to agent: AgentKind = .opencode, prompt: String = "carry this"
    ) throws -> (task: TaskRecord, inbox: InboxStore) {
        let inbox = InboxStore(workspaceRoot: folder)
        return (try inbox.createTask(from: delegator, to: agent, tier: .standard, prompt: prompt, files: []), inbox)
    }

    /// The notices `inbox` holds for `agent` about `task`.
    private func notices(in inbox: InboxStore, for agent: AgentKind, about task: TaskRecord) throws -> [PendingMessage] {
        try inbox.load().messages.filter { $0.kind == .notice && $0.toAgent == agent && $0.taskId == task.id }
    }

    /// A model OpenCode does not list will not appear by waiting: the task ends at once with the
    /// reason, rather than sitting queued for an hour behind a generic "undelivered" line.
    func testAQueuedTaskWhoseTierModelIsNotListedExpiresAtOnceWithTheReason() async throws {
        let lister = ModelLister(.models(["opencode/deepseek-v4.1-flash-free"]))
        let coordinator = makeCoordinator(lister: lister)
        defer { stopAll(coordinator) }
        let (task, inbox) = try queueTask()

        coordinator.dispatchTasks(workspacePath: folder, inboxStore: inbox)
        try await waitForListing(coordinator)
        coordinator.dispatchTasks(workspacePath: folder, inboxStore: inbox)

        let reason = "opencode/big-pickle (opencode tier standard) is not among the models OpenCode lists"
        let ended = try XCTUnwrap(try inbox.task(id: task.id))
        XCTAssertEqual(ended.state, .expired)
        XCTAssertTrue(ended.cancelReason?.contains(reason) ?? false, ended.cancelReason ?? "no reason")
        let lines = try inbox.load().messages.filter { $0.toAgent == .claude && $0.taskId == task.id }
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines.first?.prompt.contains("expired — \(reason)") ?? false, lines.first?.prompt ?? "no line")
        XCTAssertEqual(sink.refusals().count, 1, "the user hears once")
        XCTAssertTrue(sink.refusals().first?.body.contains(reason) ?? false)
        XCTAssertTrue(coordinator.store.sessions.isEmpty, "no session was spawned")

        coordinator.dispatchTasks(workspacePath: folder, inboxStore: inbox)
        XCTAssertEqual(sink.refusals().count, 1, "the task is over: later passes say nothing more")
    }

    /// A listing that fails says nothing about the model, so the task waits (it expires on its own
    /// like any queued task). It is reported once, and OpenCode is asked again at most once a minute.
    func testAFailedListingLeavesTheTaskQueuedReportsItOnceAndRelistsAtMostOncePerMinute() async throws {
        let clock = ControllableClock()
        let lister = ModelLister(.failure("`opencode models` exited 1"))
        let coordinator = makeCoordinator(lister: lister, now: clock.now)
        defer { stopAll(coordinator) }
        let (task, inbox) = try queueTask()
        func tick() { coordinator.dispatchTasks(workspacePath: folder, inboxStore: inbox) }

        tick()
        try await waitForListing(coordinator)
        tick()
        XCTAssertEqual(try inbox.task(id: task.id)?.state, .queued)
        XCTAssertEqual(try notices(in: inbox, for: .claude, about: task).count, 1)
        XCTAssertEqual(sink.refusals().count, 1)
        XCTAssertTrue(try XCTUnwrap(sink.refusals().first).body.contains("`opencode models` exited 1"))

        for _ in 0..<11 {
            clock.advance(5)
            tick()
        }
        clock.advance(4)
        tick()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(lister.calls, 1, "59 seconds on, the failed listing is still the answer")
        XCTAssertEqual(try notices(in: inbox, for: .claude, about: task).count, 1)
        XCTAssertEqual(sink.refusals().count, 1)

        clock.advance(2)
        tick()
        try await waitForListing(coordinator, after: 1)
        tick()
        XCTAssertEqual(lister.calls, 2, "a minute on, OpenCode is asked again")
        XCTAssertEqual(try inbox.task(id: task.id)?.state, .queued)
        XCTAssertEqual(try notices(in: inbox, for: .claude, about: task).count, 1, "the same task is not reported twice")
        XCTAssertEqual(sink.refusals().count, 1)
    }

    /// Each task is reported on its own: a second delegator waiting in the same workspace hears too.
    func testTwoQueuedTasksFromDifferentDelegatorsAreEachReported() async throws {
        let lister = ModelLister(.failure("`opencode models` exited 1"))
        let coordinator = makeCoordinator(lister: lister)
        defer { stopAll(coordinator) }
        let (first, inbox) = try queueTask(from: .claude, prompt: "first")
        let (second, _) = try queueTask(from: .codex, prompt: "second")

        coordinator.dispatchTasks(workspacePath: folder, inboxStore: inbox)
        try await waitForListing(coordinator)
        for _ in 0..<3 { coordinator.dispatchTasks(workspacePath: folder, inboxStore: inbox) }

        XCTAssertEqual(try notices(in: inbox, for: .claude, about: first).count, 1)
        XCTAssertEqual(try notices(in: inbox, for: .codex, about: second).count, 1)
        XCTAssertEqual(sink.refusals().count, 2, "one for each task, and no more on later passes")
    }

    /// Another agent's spawn failure in the same workspace must not make the report fire again.
    func testAnotherAgentsSpawnFailureDoesNotMakeTheReportRepeatEveryPass() async throws {
        let lister = ModelLister(.failure("`opencode models` exited 1"))
        let coordinator = makeCoordinator(lister: lister)   // Codex is not installed: its spawn fails
        defer { stopAll(coordinator) }
        let (openCodeTask, inbox) = try queueTask(from: .claude, to: .opencode, prompt: "for opencode")
        _ = try queueTask(from: .claude, to: .codex, prompt: "for codex")

        coordinator.dispatchTasks(workspacePath: folder, inboxStore: inbox)
        try await waitForListing(coordinator)
        for _ in 0..<4 { coordinator.dispatchTasks(workspacePath: folder, inboxStore: inbox) }

        XCTAssertEqual(coordinator.lastSpawnFailure?.agent, .codex, "the other agent's spawn did fail")
        XCTAssertEqual(try notices(in: inbox, for: .claude, about: openCodeTask).count, 1)
        XCTAssertEqual(sink.refusals().count, 1)
    }

    /// A report is remembered only while its task is queued: once the task is over, nothing is kept.
    func testAReportIsForgottenOnceItsTaskIsNoLongerQueued() async throws {
        let lister = ModelLister(.failure("`opencode models` exited 1"))
        let coordinator = makeCoordinator(lister: lister)
        defer { stopAll(coordinator) }
        let (task, inbox) = try queueTask()

        coordinator.dispatchTasks(workspacePath: folder, inboxStore: inbox)
        try await waitForListing(coordinator)
        coordinator.dispatchTasks(workspacePath: folder, inboxStore: inbox)
        XCTAssertEqual(coordinator.openCodeRefusalsReported.count, 1)

        try inbox.cancelTask(taskId: task.id, reason: "the delegator withdrew it")
        coordinator.dispatchTasks(workspacePath: folder, inboxStore: inbox)

        XCTAssertTrue(coordinator.openCodeRefusalsReported.isEmpty)
    }

    // MARK: - A queued message for OpenCode

    /// Seeds one queued legacy brief to OpenCode from each of `senders`: the one message kind that still
    /// spawns an agent.
    private func queueLegacyBriefs(from senders: [AgentKind] = [.claude]) throws -> InboxStore {
        let inbox = InboxStore(workspaceRoot: folder)
        var seeded = Inbox(workspacePath: folder)
        seeded.messages = senders.map {
            PendingMessage(id: "legacy-\($0.rawValue)", fromAgent: $0, toAgent: .opencode,
                           prompt: "Old style brief from \($0.rawValue)", status: .queued, kind: .task)
        }
        try inbox.saveRaw(seeded)
        return inbox
    }

    func testAMessageForOpenCodeWhoseModelIsNotListedFailsAndItsSenderIsToldOnce() async throws {
        let lister = ModelLister(.models(["opencode/deepseek-v4.1-flash-free"]))
        let coordinator = makeCoordinator(lister: lister)
        defer { stopAll(coordinator) }
        let inbox = try queueLegacyBriefs()

        coordinator.dispatchMessages(workspacePath: folder, inboxStore: inbox)
        try await waitForListing(coordinator)
        for _ in 0..<3 { coordinator.dispatchMessages(workspacePath: folder, inboxStore: inbox) }

        let reason = "opencode/big-pickle (opencode tier standard) is not among the models OpenCode lists"
        let messages = try inbox.load().messages
        XCTAssertEqual(messages.first { $0.id == "legacy-claude" }?.status, .failed)
        let told = messages.filter { $0.kind == .notice && $0.toAgent == .claude }
        XCTAssertEqual(told.count, 1)
        XCTAssertTrue(told.first?.prompt.contains(reason) ?? false, told.first?.prompt ?? "no notice")
        XCTAssertEqual(sink.refusals().count, 1)
        XCTAssertTrue(coordinator.store.sessions.isEmpty, "no session was spawned")
    }

    func testMessagesForOpenCodeWhoseListingFailedStayQueuedAndEachSenderIsToldOnce() async throws {
        let lister = ModelLister(.failure("`opencode models` exited 1"))
        let coordinator = makeCoordinator(lister: lister)
        defer { stopAll(coordinator) }
        let inbox = try queueLegacyBriefs(from: [.claude, .codex])

        coordinator.dispatchMessages(workspacePath: folder, inboxStore: inbox)
        try await waitForListing(coordinator)
        for _ in 0..<3 { coordinator.dispatchMessages(workspacePath: folder, inboxStore: inbox) }

        let messages = try inbox.load().messages
        XCTAssertEqual(messages.filter { $0.kind == .task }.map(\.status), [.queued, .queued])
        XCTAssertEqual(messages.filter { $0.kind == .notice && $0.toAgent == .claude }.count, 1)
        XCTAssertEqual(messages.filter { $0.kind == .notice && $0.toAgent == .codex }.count, 1)
        XCTAssertEqual(sink.refusals().count, 2, "one for each message, and no more on later passes")
    }

    /// A pass over the tasks forgets only the tasks' reports, and one over the messages only the
    /// messages': a message and a task waiting in one workspace are each reported once, however
    /// the passes alternate.
    func testATaskPassAndAMessagePassDoNotForgetEachOthersReports() async throws {
        let lister = ModelLister(.failure("`opencode models` exited 1"))
        let coordinator = makeCoordinator(lister: lister)
        defer { stopAll(coordinator) }
        let (task, taskInbox) = try queueTask(from: .claude, prompt: "for opencode")
        var inbox = try taskInbox.load()
        inbox.messages = [PendingMessage(
            id: "legacy-codex", fromAgent: .codex, toAgent: .opencode, prompt: "Old style brief", status: .queued, kind: .task)]
        try taskInbox.saveRaw(inbox)

        coordinator.dispatchTasks(workspacePath: folder, inboxStore: taskInbox)
        try await waitForListing(coordinator)
        for _ in 0..<3 {
            coordinator.dispatchTasks(workspacePath: folder, inboxStore: taskInbox)
            coordinator.dispatchMessages(workspacePath: folder, inboxStore: taskInbox)
        }

        XCTAssertEqual(try notices(in: taskInbox, for: .claude, about: task).count, 1)
        XCTAssertEqual(try taskInbox.load().messages.filter { $0.kind == .notice && $0.toAgent == .codex }.count, 1)
        XCTAssertEqual(sink.refusals().count, 2)
    }
}

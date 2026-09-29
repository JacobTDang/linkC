import XCTest
@testable import LinkCKit

/// The coordinator's sweep loop, driven by a clock the test moves by hand: how long it sleeps
/// in each situation, and what wakes it early.
@MainActor
final class AppCoordinatorTickerTests: XCTestCase {
    private var tempDir: URL!
    private let clock = ManualClock()

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-ticker-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    private func makeCoordinator(injectionGap: TimeInterval = AppCoordinator.injectionGap) throws -> AppCoordinator {
        let script = tempDir.appendingPathComponent("mock_agent.sh")
        try "#!/bin/sh\nstty -echo 2>/dev/null\nprintf '\\033[?2004h'\nexec /bin/cat\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let settingsDir = tempDir.appendingPathComponent("settings")
        try FileManager.default.createDirectory(at: settingsDir, withIntermediateDirectories: true)
        return AppCoordinator(
            terminals: TerminalSessionManager(),
            hookServer: HookServer.forTesting(),
            notifications: NotificationManager(sink: NullSink(), now: { Date() }),
            claudePath: script.path,
            settingsDir: settingsDir,
            userSettingsURL: tempDir.appendingPathComponent("user-settings.json"),
            manifestDir: tempDir.appendingPathComponent("manifest"),
            agentPathResolver: { _ in script.path },
            deliverySettle: 0,
            injectionGap: injectionGap,
            sweepClock: clock,
            isWatching: { _ in false }
        )
    }

    private struct NullSink: NotificationSink {
        func deliver(id: String, title: String, body: String) {}
    }

    /// A started coordinator with one idle session in `tempDir`, sleeping its first interval.
    private func startIdleCoordinator() async throws -> AppCoordinator {
        let coordinator = try makeCoordinator()
        _ = coordinator.store.create(cwd: tempDir.path, title: "idle", id: "L1")
        coordinator.store.updateState(id: "L1", to: .ready)
        try coordinator.start()
        try await waitForSleep(of: .seconds(5))
        return coordinator
    }

    /// A started coordinator with one ready Claude session whose terminal is running, sleeping its
    /// first interval. Text was typed into it a moment ago and the injection gap is an hour, so a
    /// message for it stays queued however the session is doing: what a test sees is the cadence
    /// alone, not a delivery. The session is marked ready in the same turn it is launched, before
    /// the sweep that the launch woke reads the interval.
    private func startCoordinatorWithLiveSession() async throws -> (coordinator: AppCoordinator, session: Session) {
        let coordinator = try makeCoordinator(injectionGap: 3600)
        try coordinator.start()
        try await waitForSleep(of: .seconds(5))
        let session = try coordinator.newSession(cwd: tempDir.path, agent: .claude)
        coordinator.store.updateState(id: session.id, to: .ready)
        coordinator.lastInjectionAt[session.id] = Date()
        let terminal = try XCTUnwrap(coordinator.terminals.session(id: session.id))
        let running = try await waitUntil { terminal.isRunning }
        XCTAssertTrue(running, "the mock agent never started")
        try await waitForSleep(of: .seconds(5))
        return (coordinator, session)
    }

    /// Waits until the loop is asleep for `interval`. A sleep that has just ended is gone from the
    /// clock until the loop starts the next one, so this also waits out a pass.
    private func waitForSleep(of interval: Duration, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<250 {
            if clock.pendingSleeps.first?.requested == interval { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("the sweep never slept for \(interval); it is sleeping for \(String(describing: clock.pendingSleeps.first?.requested))",
                file: file, line: line)
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws -> Bool {
        for _ in 0..<100 {
            if predicate() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return predicate()
    }

    /// Runs a minute of one-second steps, letting the loop settle into its next sleep after each.
    private func runAMinute() async throws {
        for _ in 0..<60 {
            clock.advance(by: .seconds(1))
            for _ in 0..<250 where clock.pendingSleeps.isEmpty { try await Task.sleep(for: .milliseconds(4)) }
        }
    }

    /// The count this work exists to lower. Two loops used to wake every second whatever was going
    /// on, 120 wakeups a minute. Now a hidden, idle app wakes 12 times, and an open panel 60 (one
    /// loop, not two).
    func testAHiddenIdleMinuteIsTwelvePassesAndAnOpenPanelMinuteIsSixty() async throws {
        let coordinator = try await startIdleCoordinator()
        defer { coordinator.shutdown() }

        try await runAMinute()
        XCTAssertEqual(clock.completedSleeps, 12, "hidden and idle: one pass every five seconds")

        coordinator.setPanelVisible(true)
        try await waitForSleep(of: .seconds(1))
        let before = clock.completedSleeps
        try await runAMinute()
        XCTAssertEqual(clock.completedSleeps - before, 60, "panel open: one pass every second")
    }

    func testAnIdleHiddenCoordinatorSleepsFiveSecondsWithATenthAsTolerance() async throws {
        let coordinator = try await startIdleCoordinator()
        defer { coordinator.shutdown() }
        let sleep = try XCTUnwrap(clock.pendingSleeps.first)
        XCTAssertEqual(sleep.requested, .seconds(5))
        XCTAssertEqual(sleep.tolerance, .milliseconds(500))
    }

    /// The panel is set visible before its window shows, so whatever runs on show runs in the middle
    /// of the 0.22 s opening animation, on the main thread. Only the panel's own sampling runs then;
    /// the session sweep and the relay (a full pass, ~20 ms per pass with many sessions) wait for the
    /// next tick, which the visible panel has brought forward to one second.
    func testShowingThePanelRunsOnlyThePanelSweepAtOnceAndTheFullPassFollowsWithinASecond() async throws {
        let coordinator = try await startIdleCoordinator()
        defer { coordinator.shutdown() }
        // A notice leaves the queue only in a full pass, and nothing watches this workspace yet, so
        // writing it wakes nothing.
        let inbox = InboxStore(workspaceRoot: tempDir.path)
        _ = try inbox.enqueue(from: .codex, to: .claude, kind: .notice, body: "look at this")
        var sweeps = 0
        coordinator.panelSweep = { sweeps += 1 }

        coordinator.setPanelVisible(true)
        let ran = try await waitUntil { sweeps == 1 }
        XCTAssertTrue(ran, "opening the panel must run the panel sweep without waiting out the interval")
        try await waitForSleep(of: .seconds(1))
        XCTAssertEqual(clock.now.offset, .zero)
        XCTAssertEqual(try inbox.fetchPending().count, 1, "the session sweep and the relay did not run on show")

        clock.advance(by: .seconds(1))
        // At least two: delivering the notice writes the inbox, which now wakes one more pass.
        let again = try await waitUntil { sweeps >= 2 }
        XCTAssertTrue(again, "and the panel sweep keeps running every second while the panel stays open")
        let delivered = try await waitUntil { (try? inbox.fetchPending().isEmpty) == true }
        XCTAssertTrue(delivered, "the full pass follows one second after the panel opened")
    }

    /// The show-time panel sweep is a task of its own; a panel already hidden again by the time it
    /// gets to run has nothing to sample for.
    func testAPanelHiddenBeforeTheShowSweepGetsToRunIsNotSampled() async throws {
        let coordinator = try await startIdleCoordinator()
        defer { coordinator.shutdown() }
        var sweeps = 0
        coordinator.panelSweep = { sweeps += 1 }

        coordinator.setPanelVisible(true)
        coordinator.setPanelVisible(false)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(sweeps, 0)
    }

    func testThePanelSweepStaysQuietWhileThePanelIsHidden() async throws {
        let coordinator = try await startIdleCoordinator()
        defer { coordinator.shutdown() }
        var sweeps = 0
        coordinator.panelSweep = { sweeps += 1 }

        clock.advance(by: .seconds(5))
        try await waitForSleep(of: .seconds(5))
        clock.advance(by: .seconds(5))
        try await waitForSleep(of: .seconds(5))
        XCTAssertEqual(sweeps, 0)
    }

    func testHidingThePanelReturnsToFiveSecondsAfterTheNextPass() async throws {
        let coordinator = try await startIdleCoordinator()
        defer { coordinator.shutdown() }
        coordinator.setPanelVisible(true)
        try await waitForSleep(of: .seconds(1))

        coordinator.setPanelVisible(false)
        clock.advance(by: .seconds(1))
        try await waitForSleep(of: .seconds(5))
    }

    func testAnOpenTaskBringsBackOneSecondAndClosingItReturnsToFive() async throws {
        let coordinator = try await startIdleCoordinator()
        defer { coordinator.shutdown() }
        let inbox = InboxStore(workspaceRoot: tempDir.path)
        let task = try inbox.createTask(from: .codex, to: .claude, prompt: "work", files: [])
        try inbox.markTaskDelivered(taskId: task.id, sessionId: "L1")

        clock.advance(by: .seconds(5))
        try await waitForSleep(of: .seconds(1))

        try inbox.cancelTask(taskId: task.id, reason: "done with it")
        clock.advance(by: TickCadence.minimumWakeGap)   // the write's wake waits out the gap since the last pass
        try await waitForSleep(of: .seconds(5))
    }

    func testAQueuedMessageASessionCouldTakeKeepsOneSecond() async throws {
        let (coordinator, _) = try await startCoordinatorWithLiveSession()
        defer { coordinator.shutdown() }
        _ = try InboxStore(workspaceRoot: tempDir.path)
            .enqueue(from: .codex, to: .claude, kind: .peerNote, body: "done")

        clock.advance(by: .seconds(5))
        try await waitForSleep(of: .seconds(1))
        XCTAssertEqual(try InboxStore(workspaceRoot: tempDir.path).fetchPending().count, 1, "it waits for the injection gap")
    }

    /// A session in `.error` (a usage limit; the cooldown can last hours) takes nothing until it
    /// recovers, and recovering is a state change the sweep sees. A message waiting for it must not
    /// pin the fast cadence for the whole cooldown.
    func testAQueuedMessageForASessionInErrorLeavesTheCadenceAtFive() async throws {
        let (coordinator, session) = try await startCoordinatorWithLiveSession()
        defer { coordinator.shutdown() }
        // The sweep returns a session to ready once its recorded cooldown is over, so it has one.
        try InboxStore(workspaceRoot: tempDir.path).recordLimit(agent: .claude, reason: "cooling down", cooldown: 3600)
        coordinator.store.updateState(id: session.id, to: .error)
        _ = try InboxStore(workspaceRoot: tempDir.path)
            .enqueue(from: .codex, to: .claude, kind: .peerNote, body: "done")

        clock.advance(by: .seconds(5))
        try await waitForSleep(of: .seconds(5))
        XCTAssertEqual(try InboxStore(workspaceRoot: tempDir.path).fetchPending().count, 1, "it stays queued")
    }

    /// A session with no running process cannot be typed into: the relay leaves the message queued
    /// ("child exited"), and so it holds no more than a message with no session at all.
    func testAQueuedMessageForASessionWhoseProcessIsGoneLeavesTheCadenceAtFive() async throws {
        let coordinator = try await startIdleCoordinator()   // "L1" has no terminal behind it
        defer { coordinator.shutdown() }
        _ = try InboxStore(workspaceRoot: tempDir.path)
            .enqueue(from: .codex, to: .claude, kind: .peerNote, body: "done")

        clock.advance(by: .seconds(5))
        try await waitForSleep(of: .seconds(5))
        XCTAssertEqual(try InboxStore(workspaceRoot: tempDir.path).fetchPending().count, 1, "it stays queued")
    }

    /// A note for an agent with no live session in the workspace waits for one to be
    /// launched, and launching wakes the sweep. It must not pin the fast cadence in the meantime.
    func testAQueuedMessageNoSessionCanTakeLeavesTheCadenceAtFive() async throws {
        let coordinator = try await startIdleCoordinator()
        defer { coordinator.shutdown() }
        _ = try InboxStore(workspaceRoot: tempDir.path)
            .enqueue(from: .claude, to: .codex, kind: .peerNote, body: "done")

        clock.advance(by: .seconds(5))
        try await waitForSleep(of: .seconds(5))
        XCTAssertEqual(try InboxStore(workspaceRoot: tempDir.path).fetchPending().count, 1, "it stays queued")
    }

    /// A pass that gave up on a held inbox lock retries on the next tick, so it must not sleep long.
    /// A read of an unchanged inbox takes no lock, so the file is written by someone else after the
    /// coordinator started: the pass has never seen it and has to read it under the lock.
    func testAPassThatFoundTheInboxLockHeldRetriesInOneSecond() async throws {
        let coordinator = try await startIdleCoordinator()
        defer { coordinator.shutdown() }
        let workspace = tempDir.path
        _ = try InboxStore(workspaceRoot: workspace)
            .enqueue(from: .claude, to: .codex, kind: .peerNote, body: "for a session that is not here")
        let held = expectation(description: "lock held")
        let released = expectation(description: "lock released")
        DispatchQueue.global().async {
            try? InboxStore(workspaceRoot: workspace).withFileLock(timeout: 2) {
                held.fulfill()
                Thread.sleep(forTimeInterval: 1.5)
            }
            released.fulfill()
        }
        await fulfillment(of: [held], timeout: 5)

        clock.advance(by: .seconds(5))
        try await waitForSleep(of: .seconds(1))
        await fulfillment(of: [released], timeout: 5)
    }

    /// The whole point of the slow interval: a delegation written while everything sleeps is still
    /// picked up within the wake gap, not at the next tick. A notice is marked delivered by the
    /// relay the moment it sees it, so its leaving the queue shows a pass ran, and the clock moved
    /// by the gap only, nowhere near the five seconds.
    func testAnInboxWriteWakesTheTickWithinTheGapNotAtTheNextTick() async throws {
        let coordinator = try await startIdleCoordinator()
        defer { coordinator.shutdown() }
        // The first pass starts watching this workspace; it has to have run before the write.
        clock.advance(by: .seconds(5))
        try await waitForSleep(of: .seconds(5))
        let advanced = clock.now.offset

        let inbox = InboxStore(workspaceRoot: tempDir.path)
        _ = try inbox.enqueue(from: .codex, to: .claude, kind: .notice, body: "look at this")
        clock.advance(by: TickCadence.minimumWakeGap)

        let delivered = try await waitUntil { (try? inbox.fetchPending().isEmpty) == true }
        XCTAssertTrue(delivered, "a write to the inbox must not wait out the five second sleep")
        XCTAssertEqual(clock.now.offset, advanced + TickCadence.minimumWakeGap)
    }

    /// Writes come in bursts (one agent, a dozen rows), and a pass that follows every one of them
    /// would cost more than the old one-second tick. They make one pass, after the gap.
    func testABurstOfInboxWritesMakesOnePassAfterTheGap() async throws {
        let coordinator = try await startIdleCoordinator()
        defer { coordinator.shutdown() }
        clock.advance(by: .seconds(5))
        try await waitForSleep(of: .seconds(5))

        let inbox = InboxStore(workspaceRoot: tempDir.path)
        for index in 0..<5 {
            _ = try inbox.enqueue(from: .codex, to: .claude, kind: .notice, body: "note \(index)")
            clock.advance(by: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(try inbox.fetchPending().count, 5, "no pass runs inside the gap")

        clock.advance(by: TickCadence.minimumWakeGap)
        let delivered = try await waitUntil { (try? inbox.fetchPending().isEmpty) == true }
        XCTAssertTrue(delivered, "the pass after the gap reads every write, the last included")
    }

    func testAStartingSessionIsNotLeftToASlowSleep() async throws {
        let coordinator = try makeCoordinator()
        try coordinator.start()
        defer { coordinator.shutdown() }
        try await waitForSleep(of: .seconds(5))

        _ = try coordinator.newSession(cwd: tempDir.path, agent: .claude)
        try await waitForSleep(of: .seconds(1))
        XCTAssertEqual(clock.now.offset, .zero)
    }
}

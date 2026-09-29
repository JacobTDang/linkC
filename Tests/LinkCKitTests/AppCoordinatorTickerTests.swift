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

    private func makeCoordinator() throws -> AppCoordinator {
        let script = tempDir.appendingPathComponent("mock_agent.sh")
        try "#!/bin/sh\nstty -echo 2>/dev/null\nprintf '\\033[?2004h'\nexec /bin/cat\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let settingsDir = tempDir.appendingPathComponent("settings")
        try FileManager.default.createDirectory(at: settingsDir, withIntermediateDirectories: true)
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

    func testShowingThePanelRunsThePanelSweepAtOnceAndKeepsTheCadenceAtOneSecond() async throws {
        let coordinator = try await startIdleCoordinator()
        defer { coordinator.shutdown() }
        var sweeps = 0
        coordinator.panelSweep = { sweeps += 1 }

        coordinator.setPanelVisible(true)
        let ran = try await waitUntil { sweeps == 1 }
        XCTAssertTrue(ran, "opening the panel must run the panel sweep without waiting out the interval")
        XCTAssertEqual(clock.now.offset, .zero)
        try await waitForSleep(of: .seconds(1))

        clock.advance(by: .seconds(1))
        let again = try await waitUntil { sweeps == 2 }
        XCTAssertTrue(again, "and it keeps running every second while the panel stays open")
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
        try await waitForSleep(of: .seconds(5))
    }

    func testAQueuedMessageASessionCouldTakeKeepsOneSecond() async throws {
        let coordinator = try await startIdleCoordinator()
        defer { coordinator.shutdown() }
        _ = try InboxStore(workspaceRoot: tempDir.path)
            .enqueue(from: .codex, to: .claude, kind: .peerNote, body: "done")

        clock.advance(by: .seconds(5))
        try await waitForSleep(of: .seconds(1))
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
    func testAPassThatFoundTheInboxLockHeldRetriesInOneSecond() async throws {
        let coordinator = try await startIdleCoordinator()
        defer { coordinator.shutdown() }
        let workspace = tempDir.path
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
    /// picked up at once. A notice is marked delivered by the relay the moment it sees it, so its
    /// leaving the queue shows a pass ran, and the clock never moved to make it.
    func testAnInboxWriteWakesTheTickAtOnce() async throws {
        let coordinator = try await startIdleCoordinator()
        defer { coordinator.shutdown() }
        // The first pass starts watching this workspace; it has to have run before the write.
        clock.advance(by: .seconds(5))
        try await waitForSleep(of: .seconds(5))
        let advanced = clock.now.offset

        let inbox = InboxStore(workspaceRoot: tempDir.path)
        _ = try inbox.enqueue(from: .codex, to: .claude, kind: .notice, body: "look at this")

        let delivered = try await waitUntil { (try? inbox.fetchPending().isEmpty) == true }
        XCTAssertTrue(delivered, "a write to the inbox must not wait out the five second sleep")
        XCTAssertEqual(clock.now.offset, advanced)
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

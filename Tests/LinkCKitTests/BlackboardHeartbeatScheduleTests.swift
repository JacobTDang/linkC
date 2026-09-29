import XCTest
import os
@testable import LinkCKit

/// The app heartbeats every live session once a second, and `linkc-mcp` heartbeats on every tool
/// call. A heartbeat only ever writes when it inserts a record, refreshes one that has gone
/// `heartbeatRefreshInterval` without a beat, or prunes an agent past the stale age — so it must
/// not open, lock, read and decode `blackboard.json` in between. Each process remembers, per file
/// and pid, when the next of those is due.
final class BlackboardHeartbeatScheduleTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-heartbeat-schedule-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    /// A wall clock and a monotonic clock that a test moves separately: `advance` is time passing,
    /// `setWallClock` is someone changing the date.
    private final class Clock: Sendable {
        private struct Times: Sendable {
            var wall: Date
            var monotonic: ContinuousClock.Instant
        }

        private let box: OSAllocatedUnfairLock<Times>

        init(_ start: Date = Date()) {
            box = OSAllocatedUnfairLock(initialState: Times(wall: start, monotonic: .now))
        }

        func now() -> Date {
            box.withLock { $0.wall }
        }

        func monotonicNow() -> ContinuousClock.Instant {
            box.withLock { $0.monotonic }
        }

        func advance(_ seconds: TimeInterval) {
            box.withLock {
                $0.wall = $0.wall.addingTimeInterval(seconds)
                $0.monotonic = $0.monotonic.advanced(by: .seconds(seconds))
            }
        }

        func setWallClock(by seconds: TimeInterval) {
            box.withLock { $0.wall = $0.wall.addingTimeInterval(seconds) }
        }
    }

    /// A store built fresh for every call, as `sampleAgentStates` does.
    private func freshStore(_ clock: Clock) -> BlackboardStore {
        BlackboardStore(workspaceRoot: tempDir.path, now: clock.now, monotonicNow: clock.monotonicNow)
    }

    private func diskLoads() -> Int {
        StateFileReadCounter.shared.count(path: BlackboardStore(workspaceRoot: tempDir.path).blackboardURL.path)
    }

    private var boardFile: URL {
        tempDir.appendingPathComponent(".linkc/blackboard.json")
    }

    func testHeartbeatsInsideTheRefreshIntervalNeitherReadNorWriteTheFile() throws {
        let clock = Clock()
        try freshStore(clock).heartbeat(agentKind: .cursor, pid: 4242)
        let before = diskLoads()
        let bytes = try Data(contentsOf: boardFile)

        let beats = Int(BlackboardStore.heartbeatRefreshInterval) - 1
        for _ in 0..<beats {
            clock.advance(1)
            try freshStore(clock).heartbeat(agentKind: .cursor, pid: 4242)
        }

        XCTAssertEqual(diskLoads() - before, 0, "\(beats) once-a-second heartbeats should not decode the board")
        XCTAssertEqual(try Data(contentsOf: boardFile), bytes)
    }

    func testTheHeartbeatThatReachesTheRefreshIntervalReadsAndRefreshesTheRecord() throws {
        let clock = Clock()
        try freshStore(clock).heartbeat(agentKind: .cursor, pid: 4242)
        let inserted = clock.now()
        clock.advance(BlackboardStore.heartbeatRefreshInterval)
        let before = diskLoads()

        try freshStore(clock).heartbeat(agentKind: .cursor, pid: 4242)

        XCTAssertEqual(diskLoads() - before, 1)
        let record = try XCTUnwrap(try freshStore(clock).load().activeAgents.first { $0.pid == 4242 })
        XCTAssertGreaterThan(record.lastHeartbeat, inserted.addingTimeInterval(BlackboardStore.heartbeatRefreshInterval - 1))
    }

    func testEachPidIsScheduledOnItsOwnAndANewPidStillInsertsItsRecord() throws {
        let clock = Clock()
        try freshStore(clock).heartbeat(agentKind: .cursor, pid: 1)
        clock.advance(30)

        try freshStore(clock).heartbeat(agentKind: .codex, pid: 2)

        XCTAssertEqual(Set(try freshStore(clock).load().activeAgents.map(\.pid)), [1, 2])
        let before = diskLoads()
        for _ in 0..<20 {
            clock.advance(1)
            try freshStore(clock).heartbeat(agentKind: .cursor, pid: 1)
            try freshStore(clock).heartbeat(agentKind: .codex, pid: 2)
        }
        XCTAssertEqual(diskLoads() - before, 0)
    }

    func testAStaleAgentIsStillPrunedOnTimeWithoutAReadEverySecond() throws {
        let clock = Clock()
        let store = freshStore(clock)
        try store.heartbeat(agentKind: .cursor, pid: 1)
        var board = try store.load()
        board.activeAgents.append(AgentRecord(
            agentId: "agent-codex-99", agentKind: .codex, pid: 99, goal: "(idle)", claimedFiles: [],
            lastHeartbeat: clock.now().addingTimeInterval(-(BlackboardStore.staleAgentAge - 100)), status: "active"
        ))
        try store.saveRaw(board)
        try freshStore(clock).heartbeat(agentKind: .cursor, pid: 1) // sees agent 99, due to go stale in 100s

        let before = diskLoads()
        clock.advance(99)
        try freshStore(clock).heartbeat(agentKind: .cursor, pid: 1)
        XCTAssertEqual(diskLoads() - before, 0, "nothing is due yet")

        clock.advance(2)
        try freshStore(clock).heartbeat(agentKind: .cursor, pid: 1)
        XCTAssertEqual(diskLoads() - before, 1, "the prune is due, so the heartbeat reads")
        XCTAssertEqual(try freshStore(clock).load().activeAgents.map(\.pid), [1], "the stale agent is pruned")
    }

    /// Any save through this process — a broadcast, a raw save — can change what a heartbeat has to
    /// do, so the next one starts from the file again.
    func testASaveByThisProcessMakesTheNextHeartbeatReadAgain() throws {
        let clock = Clock()
        let store = freshStore(clock)
        try store.heartbeat(agentKind: .cursor, pid: 4242)
        var board = try store.load()
        board.activeAgents.removeAll()
        try store.saveRaw(board)

        try freshStore(clock).heartbeat(agentKind: .cursor, pid: 4242)

        XCTAssertEqual(try freshStore(clock).load().activeAgents.map(\.pid), [4242], "the missing record is inserted again")
    }

    /// A board that will not decode is an error on every heartbeat. A failed one must not schedule
    /// the next as if it had succeeded.
    func testAHeartbeatThatFailedIsNotScheduledAsIfItHadSucceeded() throws {
        let clock = Clock()
        try freshStore(clock).heartbeat(agentKind: .cursor, pid: 4242)
        let garbage = Data("{ not a board".utf8)
        try garbage.write(to: boardFile)
        clock.advance(BlackboardStore.heartbeatRefreshInterval)

        XCTAssertThrowsError(try freshStore(clock).heartbeat(agentKind: .cursor, pid: 4242))
        clock.advance(1)
        XCTAssertThrowsError(try freshStore(clock).heartbeat(agentKind: .cursor, pid: 4242))
        XCTAssertEqual(try Data(contentsOf: boardFile), garbage, "the unreadable board is left untouched")
    }

    // MARK: - The schedule follows a monotonic clock

    /// The due times are in-memory and only mean "this much real time has passed", so setting the
    /// date back must not hold this process off the board until the date catches up.
    func testSettingTheWallClockBackDoesNotDelayTheNextHeartbeatRead() throws {
        let clock = Clock()
        try freshStore(clock).heartbeat(agentKind: .cursor, pid: 4242)
        clock.setWallClock(by: -3600)
        let before = diskLoads()

        clock.advance(BlackboardStore.heartbeatRefreshInterval - 1)
        try freshStore(clock).heartbeat(agentKind: .cursor, pid: 4242)
        XCTAssertEqual(diskLoads() - before, 0, "not due yet")

        clock.advance(1)
        try freshStore(clock).heartbeat(agentKind: .cursor, pid: 4242)
        XCTAssertEqual(diskLoads() - before, 1, "due after the refresh interval of real time, whatever the date says")
    }

    func testSettingTheWallClockForwardDoesNotMakeHeartbeatsReadEarly() throws {
        let clock = Clock()
        try freshStore(clock).heartbeat(agentKind: .cursor, pid: 4242)
        clock.setWallClock(by: 3600)
        let before = diskLoads()

        for _ in 0..<30 {
            clock.advance(1)
            try freshStore(clock).heartbeat(agentKind: .cursor, pid: 4242)
        }

        XCTAssertEqual(diskLoads() - before, 0)
    }

    /// After the date is set back, the board holds timestamps in the future. The next read must not
    /// be scheduled as far out as they are: it comes at most one refresh interval later.
    func testATimestampInTheFutureDoesNotPushTheNextReadOutWithIt() throws {
        let clock = Clock()
        try freshStore(clock).heartbeat(agentKind: .cursor, pid: 4242)
        clock.setWallClock(by: -3600)
        clock.advance(BlackboardStore.heartbeatRefreshInterval)
        try freshStore(clock).heartbeat(agentKind: .cursor, pid: 4242) // due: reads, finds its record an hour ahead
        let before = diskLoads()

        clock.advance(BlackboardStore.heartbeatRefreshInterval - 1)
        try freshStore(clock).heartbeat(agentKind: .cursor, pid: 4242)
        XCTAssertEqual(diskLoads() - before, 0, "not due yet")

        clock.advance(1)
        try freshStore(clock).heartbeat(agentKind: .cursor, pid: 4242)
        XCTAssertEqual(diskLoads() - before, 1, "reads again one refresh interval after the last read")
    }
}

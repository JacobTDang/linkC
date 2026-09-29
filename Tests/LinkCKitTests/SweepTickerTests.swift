import XCTest
@testable import LinkCKit

@MainActor
final class SweepTickerTests: XCTestCase {
    private let clock = ManualClock()
    private var passes = 0
    private var writes = 0
    private var writesSeenByPass: [Int] = []
    private var passStarts: [Duration] = []
    private var nextInterval: Duration = .seconds(5)
    private var ticker: SweepTicker!

    override func setUp() async throws {
        try await super.setUp()
        ticker = SweepTicker(
            clock: clock,
            interval: { [unowned self] in nextInterval },
            pass: { [unowned self] in passes += 1 }
        )
    }

    override func tearDown() async throws {
        ticker.stop()
        try await super.tearDown()
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("condition never held")
    }

    private func waitForSleep() async throws {
        try await waitUntil { self.clock.pendingSleeps.count == 1 }
    }

    func testSleepsForTheIntervalWithATenthOfItAsTolerance() async throws {
        ticker.start()
        try await waitForSleep()
        let sleep = try XCTUnwrap(clock.pendingSleeps.first)
        XCTAssertEqual(sleep.requested, .seconds(5))
        XCTAssertEqual(sleep.tolerance, .milliseconds(500))
        XCTAssertEqual(passes, 0, "nothing runs before the first interval ends")
    }

    func testRunsAPassWhenTheIntervalEndsAndReadsTheIntervalAgain() async throws {
        ticker.start()
        try await waitForSleep()
        clock.advance(by: .seconds(4.9))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(passes, 0)

        nextInterval = .seconds(1)
        clock.advance(by: .seconds(0.1))
        try await waitUntil { self.passes == 1 }
        try await waitForSleep()
        let sleep = try XCTUnwrap(clock.pendingSleeps.first)
        XCTAssertEqual(sleep.requested, .seconds(1), "the interval is chosen anew after every pass")
        XCTAssertEqual(sleep.tolerance, .milliseconds(100))
    }

    /// The interval can change under a sleeping loop (the panel opens while it waits out five
    /// seconds). Rescheduling ends that sleep and starts one with the new interval, and runs nothing.
    func testRescheduleEndsTheSleepWithoutAPassAndReadsTheIntervalAgain() async throws {
        ticker.start()
        try await waitForSleep()
        nextInterval = .seconds(1)
        ticker.reschedule()
        try await waitUntil { self.clock.pendingSleeps.first?.requested == .seconds(1) }
        XCTAssertEqual(passes, 0)
        XCTAssertEqual(clock.now.offset, .zero)

        clock.advance(by: .seconds(1))
        try await waitUntil { self.passes == 1 }
    }

    func testAWakeRunsAPassAtOnceWithoutTimeMoving() async throws {
        ticker.start()
        try await waitForSleep()
        ticker.wake()
        try await waitUntil { self.passes == 1 }
        try await waitForSleep()
        XCTAssertEqual(clock.now.offset, .zero, "the pass came from the wake, not from the clock")
    }

    func testWakesBeforeTheLoopResumesMakeOnePass() async throws {
        ticker.start()
        try await waitForSleep()
        ticker.wake()
        ticker.wake()
        ticker.wake()
        try await waitUntil { self.passes >= 1 }
        try await waitForSleep()
        XCTAssertEqual(passes, 1)
    }

    func testAWakeDuringAPassRunsAnotherAfterItOnceTheGapHasPassed() async throws {
        let pass = HeldPass()
        let slow = SweepTicker(clock: clock, interval: { .seconds(5) }, pass: { await pass.run() })
        defer { slow.stop() }
        slow.start()
        try await waitForSleep()
        slow.wake()
        try await waitUntil { pass.entered == 1 }

        slow.wake()   // lands while the first pass is still running
        pass.release()
        try await waitUntil { self.clock.pendingSleeps.first?.requested == TickCadence.minimumWakeGap }
        XCTAssertEqual(pass.entered, 1, "the second pass is held until the gap since the first one's start has passed")

        clock.advance(by: TickCadence.minimumWakeGap)
        try await waitUntil { pass.entered == 2 }
        try await waitForSleep()
        XCTAssertEqual(clock.now.offset, TickCadence.minimumWakeGap, "the second pass was the wake's, not an interval's")
    }

    /// The gap is only a floor between two passes: a wake that comes after it has gone runs at once.
    func testAWakeAfterTheGapHasPassedRunsAtOnce() async throws {
        ticker.start()
        try await waitForSleep()
        ticker.wake()
        try await waitUntil { self.passes == 1 }
        try await waitForSleep()

        clock.advance(by: TickCadence.minimumWakeGap)
        ticker.wake()
        try await waitUntil { self.passes == 2 }
        try await waitForSleep()
        XCTAssertEqual(clock.now.offset, TickCadence.minimumWakeGap, "no time had to move for the second pass")
    }

    /// Every write to an inbox wakes the sweep, and one agent can write a dozen times in a moment.
    /// The first wake runs a pass, the rest are held to the end of the gap and run as one, and the
    /// last write is in what that pass reads.
    func testABurstOfWakesWithinTheGapMakesTwoPassesAndTheLastWriteIsProcessed() async throws {
        let burst = SweepTicker(
            clock: clock, interval: { .seconds(5) },
            pass: { [unowned self] in
                writesSeenByPass.append(writes)
                passStarts.append(clock.now.offset)
            })
        defer { burst.stop() }
        burst.start()
        try await waitForSleep()
        writes = 1
        burst.wake()
        try await waitUntil { self.writesSeenByPass.count == 1 }
        try await waitForSleep()

        for _ in 0..<10 {   // ten more writes over the next 100 ms
            writes += 1
            burst.wake()
            clock.advance(by: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(writesSeenByPass.count, 1, "nothing runs inside the gap")

        clock.advance(by: TickCadence.minimumWakeGap)
        try await waitUntil { self.writesSeenByPass.count == 2 }
        try await waitForSleep()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(writesSeenByPass, [1, 11], "the held pass reads every write made while it waited")
        let held = try XCTUnwrap(passStarts.last) - XCTUnwrap(passStarts.first)
        XCTAssertGreaterThanOrEqual(held, TickCadence.minimumWakeGap)
    }

    func testStopDuringTheGapEndsItAndNoFurtherPassRuns() async throws {
        ticker.start()
        try await waitForSleep()
        ticker.wake()
        try await waitUntil { self.passes == 1 }
        try await waitForSleep()
        ticker.wake()
        try await waitUntil { self.clock.pendingSleeps.first?.requested == TickCadence.minimumWakeGap }

        ticker.stop()
        try await waitUntil { self.clock.pendingSleeps.isEmpty }
        clock.advance(by: .seconds(60))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(passes, 1)
    }

    func testStopEndsTheSleepAndNoFurtherPassRuns() async throws {
        ticker.start()
        try await waitForSleep()
        ticker.stop()
        try await waitUntil { self.clock.pendingSleeps.isEmpty }
        clock.advance(by: .seconds(60))
        ticker.wake()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(passes, 0)
    }
}

/// A pass whose first run stays open until `release()`, so a test can act while it is running.
@MainActor
private final class HeldPass {
    private(set) var entered = 0
    private var held: CheckedContinuation<Void, Never>?
    private var released = false

    func run() async {
        entered += 1
        guard entered == 1, !released else { return }
        await withCheckedContinuation { held = $0 }
    }

    func release() {
        released = true
        held?.resume()
        held = nil
    }
}

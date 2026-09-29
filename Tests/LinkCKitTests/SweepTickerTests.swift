import XCTest
@testable import LinkCKit

@MainActor
final class SweepTickerTests: XCTestCase {
    private let clock = ManualClock()
    private var passes = 0
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

    func testAWakeDuringAPassRunsAnotherAfterIt() async throws {
        let pass = HeldPass()
        let slow = SweepTicker(clock: clock, interval: { .seconds(5) }, pass: { await pass.run() })
        defer { slow.stop() }
        slow.start()
        try await waitForSleep()
        slow.wake()
        try await waitUntil { pass.entered == 1 }

        slow.wake()   // lands while the first pass is still running
        pass.release()
        try await waitUntil { pass.entered == 2 }
        try await waitForSleep()
        XCTAssertEqual(clock.now.offset, .zero, "the second pass was the wake's, not an interval's")
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

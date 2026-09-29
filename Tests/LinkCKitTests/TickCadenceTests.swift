import XCTest
@testable import LinkCKit

final class TickCadenceTests: XCTestCase {
    private func interval(
        panelVisible: Bool = false, states: [SessionState] = [], relayWork: Bool = false
    ) -> Duration {
        TickCadence.interval(panelVisible: panelVisible, sessionStates: states, hasRelayWork: relayWork)
    }

    func testHiddenAndIdleTicksEveryFiveSeconds() {
        XCTAssertEqual(interval(), .seconds(5), "no sessions at all")
        XCTAssertEqual(interval(states: [.ready, .finished, .waitingIdle, .error, .ended]), .seconds(5))
    }

    func testAVisiblePanelTicksEverySecond() {
        XCTAssertEqual(interval(panelVisible: true), .seconds(1))
        XCTAssertEqual(interval(panelVisible: true, states: [.ready]), .seconds(1))
    }

    func testAStartingWorkingOrPromptWaitingSessionTicksEverySecond() {
        for state in [SessionState.starting, .working, .waitingPermission] {
            XCTAssertEqual(interval(states: [.ready, state, .finished]), .seconds(1), "\(state)")
        }
    }

    func testOpenTasksOrQueuedMessagesTickEverySecond() {
        XCTAssertEqual(interval(states: [.ready], relayWork: true), .seconds(1))
    }

    /// The turn-end debounce polls a session only while its bucket is `.active`. Those polls were
    /// spaced one second apart and must stay so, whatever the panel does.
    func testEveryStateTheDebouncePollsKeepsTheOneSecondCadence() {
        for state in SessionState.allCases where state.bucket == .active {
            XCTAssertEqual(interval(states: [state]), .seconds(1), "\(state)")
        }
    }

    func testToleranceIsATenthOfTheInterval() {
        XCTAssertEqual(TickCadence.tolerance(for: .seconds(1)), .milliseconds(100))
        XCTAssertEqual(TickCadence.tolerance(for: .seconds(5)), .milliseconds(500))
    }
}

final class RelayWorkTests: XCTestCase {
    func testStartsEmpty() {
        XCTAssertTrue(RelayWork().isEmpty)
    }

    func testOpenTasksAndQueuedMessagesEachCount() {
        var work = RelayWork()
        work.noteOpenTasks(true, in: "/a")
        XCTAssertFalse(work.isEmpty)
        work.noteOpenTasks(false, in: "/a")
        XCTAssertTrue(work.isEmpty)
        work.noteQueuedMessages(true, in: "/a")
        XCTAssertFalse(work.isEmpty)
        work.noteQueuedMessages(false, in: "/a")
        XCTAssertTrue(work.isEmpty)
    }

    func testAContendedPassCountsUntilTheNextPassBegins() {
        var work = RelayWork()
        work.noteContention(in: "/a")
        XCTAssertFalse(work.isEmpty, "a pass that gave up on the lock retries on the next tick")
        work.beginPass(in: "/a")
        XCTAssertTrue(work.isEmpty)
    }

    func testABeginningPassClearsOnlyItsOwnWorkspace() {
        var work = RelayWork()
        work.noteOpenTasks(true, in: "/a")
        work.noteQueuedMessages(true, in: "/b")
        work.beginPass(in: "/a")
        XCTAssertFalse(work.isEmpty, "/b still has queued messages")
        work.beginPass(in: "/b")
        XCTAssertTrue(work.isEmpty)
    }

    func testWorkspacesWithoutASessionAreForgotten() {
        var work = RelayWork()
        work.noteOpenTasks(true, in: "/gone")
        work.noteQueuedMessages(true, in: "/gone")
        work.noteContention(in: "/gone")
        work.noteOpenTasks(true, in: "/kept")
        work.retain(only: ["/kept"])
        XCTAssertFalse(work.isEmpty)
        work.retain(only: [])
        XCTAssertTrue(work.isEmpty)
    }
}

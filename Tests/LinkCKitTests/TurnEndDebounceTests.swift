import XCTest
@testable import LinkCKit

final class TurnEndDebounceTests: XCTestCase {
    func testOnePollBlipNeverReturnsTrue() {
        var debounce = TurnEndDebounce(quietPeriod: 5.0)
        let now = Date()
        XCTAssertFalse(debounce.poll(sessionId: "a", isWorking: true, now: now))
        XCTAssertFalse(debounce.poll(sessionId: "a", isWorking: false, now: now.addingTimeInterval(1.0)))
        XCTAssertFalse(debounce.poll(sessionId: "a", isWorking: true, now: now.addingTimeInterval(2.0)))
    }

    func testContinuousAbsenceReturnsTrueExactlyOnce() {
        var debounce = TurnEndDebounce(quietPeriod: 5.0)
        let now = Date()
        XCTAssertFalse(debounce.poll(sessionId: "a", isWorking: false, now: now))
        XCTAssertFalse(debounce.poll(sessionId: "a", isWorking: false, now: now.addingTimeInterval(4.9)))
        XCTAssertTrue(debounce.poll(sessionId: "a", isWorking: false, now: now.addingTimeInterval(5.0)), "Should return true exactly once after 5s")
    }

    func testLineComingBackResetsClock() {
        var debounce = TurnEndDebounce(quietPeriod: 5.0)
        let now = Date()
        XCTAssertFalse(debounce.poll(sessionId: "a", isWorking: false, now: now))
        XCTAssertFalse(debounce.poll(sessionId: "a", isWorking: false, now: now.addingTimeInterval(4.0)))
        XCTAssertFalse(debounce.poll(sessionId: "a", isWorking: true, now: now.addingTimeInterval(4.5)))
        XCTAssertFalse(debounce.poll(sessionId: "a", isWorking: false, now: now.addingTimeInterval(5.0)))
        XCTAssertFalse(debounce.poll(sessionId: "a", isWorking: false, now: now.addingTimeInterval(9.0)))
        XCTAssertTrue(debounce.poll(sessionId: "a", isWorking: false, now: now.addingTimeInterval(10.0)))
    }

    func testTwoSessionsAreIndependent() {
        var debounce = TurnEndDebounce(quietPeriod: 5.0)
        let now = Date()
        XCTAssertFalse(debounce.poll(sessionId: "a", isWorking: false, now: now))
        XCTAssertFalse(debounce.poll(sessionId: "b", isWorking: false, now: now.addingTimeInterval(2.0)))
        XCTAssertTrue(debounce.poll(sessionId: "a", isWorking: false, now: now.addingTimeInterval(5.0)))
        XCTAssertFalse(debounce.poll(sessionId: "b", isWorking: false, now: now.addingTimeInterval(5.0)))
        XCTAssertTrue(debounce.poll(sessionId: "b", isWorking: false, now: now.addingTimeInterval(7.0)))
    }

    func testAfterFiringTheNextAbsenceStartsFresh() {
        var debounce = TurnEndDebounce(quietPeriod: 5.0)
        let now = Date()
        XCTAssertFalse(debounce.poll(sessionId: "a", isWorking: false, now: now))
        XCTAssertTrue(debounce.poll(sessionId: "a", isWorking: false, now: now.addingTimeInterval(5.0)))
        XCTAssertFalse(debounce.poll(sessionId: "a", isWorking: false, now: now.addingTimeInterval(60.0)),
                       "a turn that already ended must not fire again on the next task's first idle poll")
    }
}

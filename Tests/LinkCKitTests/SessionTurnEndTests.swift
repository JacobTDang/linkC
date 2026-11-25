import XCTest
@testable import LinkCKit

/// When a session last left `.working`: the moment its last request to the model went out, which
/// the cache clock counts from. Only leaving a turn moves it.
final class SessionTurnEndTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func testAHookDrivenSessionsTurnEndsWhenItLeavesWorking() {
        var session = Session(id: "s1", cwd: "/p", title: "p", state: .ready, stateChangedAt: t0)
        func apply(_ kind: HookEventKind, at seconds: TimeInterval) {
            session = SessionReducer.apply(
                HookEvent(kind: kind, linkcSessionId: "s1", claudeSessionId: "c1", cwd: "/p"),
                to: session, now: t0.addingTimeInterval(seconds)).session
        }
        XCTAssertNil(session.turnEndedAt, "no turn has run")
        apply(.userPromptSubmit, at: 10)
        XCTAssertNil(session.turnEndedAt, "the turn is still running")
        apply(.notificationPermission, at: 100)
        XCTAssertEqual(session.turnEndedAt, t0.addingTimeInterval(100), "a permission prompt follows the last request")
        apply(.toolFinished, at: 130)
        apply(.stop, at: 200)
        XCTAssertEqual(session.turnEndedAt, t0.addingTimeInterval(200))
        apply(.notificationIdle, at: 260)
        XCTAssertEqual(session.turnEndedAt, t0.addingTimeInterval(200), "the idle nudge is not a turn")
    }

    @MainActor
    func testAScreenReadSessionsTurnEndsWhenItLeavesWorkingAndNotOnALaterFlip() throws {
        let store = SessionStore()
        let id = store.create(cwd: "/p", title: "p", agentKind: .codex).id
        store.updateState(id: id, to: .ready)
        XCTAssertNil(store.session(id: id)?.turnEndedAt, "a launch is not a turn")
        store.updateState(id: id, to: .working)
        store.updateState(id: id, to: .finished)
        let ended = try XCTUnwrap(store.session(id: id)?.turnEndedAt)
        store.updateState(id: id, to: .ready)
        store.updateState(id: id, to: .error)
        XCTAssertEqual(store.session(id: id)?.turnEndedAt, ended, "focusing a finished tab or an error is not a turn")
    }
}

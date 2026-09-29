import XCTest
@testable import LinkCKit

@MainActor
final class SessionAttentionTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func status(
        _ state: SessionState, lastSeen: Date? = nil, onScreen: Bool = false, rateLimited: Bool = false
    ) -> SessionRowStatus {
        SessionAttention.status(
            state: state, stateChangedAt: t0, lastSeen: lastSeen, onScreen: onScreen,
            rateLimited: rateLimited, now: t0.addingTimeInterval(240))
    }

    func testEachStateReadsAsTheSpecTableSays() {
        XCTAssertEqual(status(.starting), SessionRowStatus(text: "starting", tone: .quiet))
        XCTAssertEqual(status(.ready), SessionRowStatus(text: "idle 4m", tone: .quiet))
        XCTAssertEqual(status(.working), SessionRowStatus(text: "working", tone: .working))
        XCTAssertEqual(status(.waitingPermission), SessionRowStatus(text: "needs you · 4m", tone: .attention))
        XCTAssertEqual(status(.error), SessionRowStatus(text: "error", tone: .error))
        XCTAssertEqual(status(.error, rateLimited: true), SessionRowStatus(text: "rate limited", tone: .error))
    }

    func testAFinishedTurnIsCoralUntilSeen() {
        for state in [SessionState.finished, .waitingIdle] {
            XCTAssertEqual(status(state), SessionRowStatus(text: "done · 4m", tone: .attention))
            XCTAssertEqual(
                status(state, lastSeen: t0.addingTimeInterval(-1)),
                SessionRowStatus(text: "done · 4m", tone: .attention), "seen only before this state began")
            XCTAssertEqual(status(state, lastSeen: t0), SessionRowStatus(text: "idle 4m", tone: .quiet))
            XCTAssertEqual(status(state, onScreen: true), SessionRowStatus(text: "idle 4m", tone: .quiet))
        }
    }

    func testCoralMeansAttentionOrError() {
        XCTAssertTrue(SessionRowStatus(text: "", tone: .attention).isCoral)
        XCTAssertTrue(SessionRowStatus(text: "", tone: .error).isCoral)
        XCTAssertFalse(SessionRowStatus(text: "", tone: .working).isCoral)
        XCTAssertFalse(SessionRowStatus(text: "", tone: .quiet).isCoral)
    }

    func testMarkSeenClearsTheCurrentStateAndANewStateStartsUnseen() {
        let attention = SessionAttention()
        var s = Session(id: "s1", cwd: "/p", title: "p", state: .finished, stateChangedAt: t0)
        let now = t0.addingTimeInterval(60)
        XCTAssertTrue(attention.status(for: s, onScreen: false, rateLimited: false, now: now).isCoral)
        attention.markSeen(s, at: t0.addingTimeInterval(30))
        XCTAssertFalse(attention.status(for: s, onScreen: false, rateLimited: false, now: now).isCoral)
        s.stateChangedAt = t0.addingTimeInterval(90)   // finished again, a later turn
        XCTAssertTrue(attention.status(for: s, onScreen: false, rateLimited: false, now: t0.addingTimeInterval(120)).isCoral)
    }

    func testMarkSeenWritesOncePerState() {
        let attention = SessionAttention()
        let s = Session(id: "s1", cwd: "/p", title: "p", state: .finished, stateChangedAt: t0)
        attention.markSeen(s, at: t0.addingTimeInterval(5))
        attention.markSeen(s, at: t0.addingTimeInterval(6))
        XCTAssertEqual(attention.lastSeen["s1"], t0.addingTimeInterval(5))
    }

    func testRetainDropsGoneSessions() {
        let attention = SessionAttention()
        attention.markSeen(Session(id: "a", cwd: "/p", title: "p", stateChangedAt: t0), at: t0)
        attention.markSeen(Session(id: "b", cwd: "/p", title: "p", stateChangedAt: t0), at: t0)
        attention.retain(only: ["a"])
        XCTAssertEqual(Set(attention.lastSeen.keys), ["a"])
    }

    func testATurnSeenBeforeTheIdleNudgeStaysSeenAfterIt() {
        let attention = SessionAttention()
        let working = Session(id: "s1", cwd: "/p", title: "p", state: .working, stateChangedAt: t0)
        let finished = SessionReducer.apply(
            HookEvent(kind: .stop, linkcSessionId: "s1", claudeSessionId: "c1", cwd: "/p"), to: working, now: t0).session
        attention.markSeen(finished, at: t0.addingTimeInterval(5))
        let nudged = SessionReducer.apply(
            HookEvent(kind: .notificationIdle, linkcSessionId: "s1", claudeSessionId: "c1", cwd: "/p"),
            to: finished, now: t0.addingTimeInterval(60)).session
        XCTAssertFalse(attention.status(for: nudged, onScreen: false, rateLimited: false,
                                        now: t0.addingTimeInterval(90)).isCoral)
    }

    func testCadenceForFixedStatusIsHourly() {
        XCTAssertEqual(status(.starting).cadence(), 3600.0)
        XCTAssertEqual(status(.working).cadence(), 3600.0)
        XCTAssertEqual(status(.error).cadence(), 3600.0)
        XCTAssertEqual(status(.error, rateLimited: true).cadence(), 3600.0)
        XCTAssertEqual(SessionAttention.status(
            state: .ended, stateChangedAt: t0, lastSeen: nil, onScreen: false, rateLimited: false, now: t0
        ).cadence(), 3600.0)
    }

    func testCadenceForRecentAgeIsOneSecond() {
        let readyStatus = SessionAttention.status(
            state: .ready, stateChangedAt: t0, lastSeen: nil, onScreen: false, rateLimited: false, now: t0
        )
        // At 15 seconds elapsed, seconds resolution text ("15s") is visible -> must tick every 1s
        XCTAssertEqual(readyStatus.cadence(now: t0.addingTimeInterval(15)), 1.0)
        // At 59 seconds elapsed, still seconds resolution
        XCTAssertEqual(readyStatus.cadence(now: t0.addingTimeInterval(59)), 1.0)
    }

    func testCadenceForMinuteResolutionAgeIsCoarse() {
        let readyStatus = SessionAttention.status(
            state: .ready, stateChangedAt: t0, lastSeen: nil, onScreen: false, rateLimited: false, now: t0
        )
        // At 60 seconds (1m) elapsed, minute resolution -> coarse tick <= 15s
        let cadence60 = readyStatus.cadence(now: t0.addingTimeInterval(60))
        XCTAssertLessThanOrEqual(cadence60, 15.0)
        XCTAssertGreaterThan(cadence60, 1.0)

        // At 120 seconds (2m)
        let cadence120 = readyStatus.cadence(now: t0.addingTimeInterval(120))
        XCTAssertEqual(cadence120, 15.0)

        // At 3600 seconds (1h)
        let cadenceHour = readyStatus.cadence(now: t0.addingTimeInterval(3600))
        XCTAssertEqual(cadenceHour, 15.0)
    }

    func testStatusTextRendersAccuratelyAtGivenNow() {
        let readyStatus = SessionAttention.status(
            state: .ready, stateChangedAt: t0, lastSeen: nil, onScreen: false, rateLimited: false, now: t0
        )
        XCTAssertEqual(readyStatus.text(now: t0.addingTimeInterval(15)), "idle 15s")
        XCTAssertEqual(readyStatus.text(now: t0.addingTimeInterval(125)), "idle 2m")
        XCTAssertEqual(readyStatus.text(now: t0.addingTimeInterval(7200)), "idle 2h")

        let permStatus = SessionAttention.status(
            state: .waitingPermission, stateChangedAt: t0, lastSeen: nil, onScreen: false, rateLimited: false, now: t0
        )
        XCTAssertEqual(permStatus.text(now: t0.addingTimeInterval(30)), "needs you · 30s")
        XCTAssertEqual(permStatus.text(now: t0.addingTimeInterval(240)), "needs you · 4m")
    }
}


import XCTest
@testable import LinkCKit

@MainActor
final class SessionAttentionTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func status(
        _ state: SessionState, lastSeen: Date? = nil, onScreen: Bool = false, rateLimited: Bool = false
    ) -> SessionRowStatus {
        SessionAttention.status(
            state: state, stateChangedAt: t0, turnStartedAt: t0.addingTimeInterval(-60), lastSeen: lastSeen,
            onScreen: onScreen, rateLimited: rateLimited, now: t0.addingTimeInterval(240))
    }

    func testEachStateReadsAsTheSpecTableSays() {
        let t240 = t0.addingTimeInterval(240)
        XCTAssertEqual(status(.starting), SessionRowStatus(format: .fixed("starting"), tone: .quiet, marker: .none, now: t240))
        XCTAssertEqual(status(.ready), SessionRowStatus(format: .age(prefix: "", since: t0), tone: .quiet, marker: .none, now: t240))
        XCTAssertEqual(status(.working), SessionRowStatus(format: .elapsed(since: t0.addingTimeInterval(-60)), tone: .working, marker: .none, now: t240),
                       "a working row counts from the turn's start, not the last state change")
        XCTAssertEqual(status(.waitingPermission), SessionRowStatus(format: .age(prefix: "", since: t0), tone: .attention, marker: .pingDot, now: t240))
        XCTAssertEqual(status(.error), SessionRowStatus(format: .fixed("error"), tone: .error, marker: .none, now: t240))
        XCTAssertEqual(status(.error, rateLimited: true), SessionRowStatus(format: .fixed("rate limited"), tone: .error, marker: .none, now: t240))
        XCTAssertEqual(status(.ended), SessionRowStatus(format: .fixed("ended"), tone: .quiet, marker: .none, now: t240))
    }

    func testAFinishedTurnIsCoralUntilSeen() {
        let t240 = t0.addingTimeInterval(240)
        for state in [SessionState.finished, .waitingIdle] {
            XCTAssertEqual(status(state), SessionRowStatus(format: .age(prefix: "", since: t0), tone: .attention, marker: .dot, now: t240))
            XCTAssertEqual(
                status(state, lastSeen: t0.addingTimeInterval(-1)),
                SessionRowStatus(format: .age(prefix: "", since: t0), tone: .attention, marker: .dot, now: t240), "seen only before this state began")
            XCTAssertEqual(status(state, lastSeen: t0), SessionRowStatus(format: .age(prefix: "", since: t0), tone: .quiet, marker: .none, now: t240))
            XCTAssertEqual(status(state, onScreen: true), SessionRowStatus(format: .age(prefix: "", since: t0), tone: .quiet, marker: .none, now: t240))
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

    func testStatusTextRendersAccuratelyAtGivenNow() {
        let readyStatus = SessionAttention.status(
            state: .ready, stateChangedAt: t0, turnStartedAt: t0, lastSeen: nil, onScreen: false, rateLimited: false, now: t0
        )
        XCTAssertEqual(readyStatus.text(now: t0.addingTimeInterval(15)), "15s")
        XCTAssertEqual(readyStatus.text(now: t0.addingTimeInterval(125)), "2m")
        XCTAssertEqual(readyStatus.text(now: t0.addingTimeInterval(7200)), "2h")

        let permStatus = SessionAttention.status(
            state: .waitingPermission, stateChangedAt: t0, turnStartedAt: t0, lastSeen: nil, onScreen: false, rateLimited: false, now: t0
        )
        XCTAssertEqual(permStatus.text(now: t0.addingTimeInterval(30)), "30s")
        XCTAssertEqual(permStatus.text(now: t0.addingTimeInterval(240)), "4m")
    }

    func testTimeSpentFormatter() {
        XCTAssertEqual(SessionRowStatus(format: .elapsed(since: t0), tone: .working).text(now: t0), "0s")
        XCTAssertEqual(SessionRowStatus(format: .elapsed(since: t0), tone: .working).text(now: t0.addingTimeInterval(59)), "59s")
        XCTAssertEqual(SessionRowStatus(format: .elapsed(since: t0), tone: .working).text(now: t0.addingTimeInterval(60)), "1m 00s")
        XCTAssertEqual(SessionRowStatus(format: .elapsed(since: t0), tone: .working).text(now: t0.addingTimeInterval(185)), "3m 05s")
        XCTAssertEqual(SessionRowStatus(format: .elapsed(since: t0), tone: .working).text(now: t0.addingTimeInterval(3599)), "59m 59s")
        XCTAssertEqual(SessionRowStatus(format: .elapsed(since: t0), tone: .working).text(now: t0.addingTimeInterval(3600)), "1h 00m")
        XCTAssertEqual(SessionRowStatus(format: .elapsed(since: t0), tone: .working).text(now: t0.addingTimeInterval(3840)), "1h 04m")
        XCTAssertEqual(SessionRowStatus(format: .elapsed(since: t0), tone: .working).text(now: t0.addingTimeInterval(-10)), "0s")
    }

    func testAgeScheduleRuleNextTickWithinFirstMinuteTicksEverySecond() {
        let next10 = AgeScheduleRule.nextTick(after: t0.addingTimeInterval(10), since: t0)
        XCTAssertEqual(next10, t0.addingTimeInterval(11))

        let next58 = AgeScheduleRule.nextTick(after: t0.addingTimeInterval(58), since: t0)
        XCTAssertEqual(next58, t0.addingTimeInterval(59))

        let next59 = AgeScheduleRule.nextTick(after: t0.addingTimeInterval(59), since: t0)
        XCTAssertEqual(next59, t0.addingTimeInterval(60))

        let next595 = AgeScheduleRule.nextTick(after: t0.addingTimeInterval(59.5), since: t0)
        XCTAssertEqual(next595, t0.addingTimeInterval(60))
    }

    func testAgeScheduleRuleNextTickPastSixtySecondsTicksEveryFifteenSeconds() {
        let next60 = AgeScheduleRule.nextTick(after: t0.addingTimeInterval(60), since: t0)
        XCTAssertEqual(next60, t0.addingTimeInterval(75))

        let next75 = AgeScheduleRule.nextTick(after: t0.addingTimeInterval(75), since: t0)
        XCTAssertEqual(next75, t0.addingTimeInterval(90))

        let next120 = AgeScheduleRule.nextTick(after: t0.addingTimeInterval(120), since: t0)
        XCTAssertEqual(next120, t0.addingTimeInterval(135))
    }

    func testAgeScheduleRuleBacksOffPastSixtySecondsInsteadOfTickingEverySecond() {
        var current = t0.addingTimeInterval(52)
        var ticksPast60 = 0

        while current < t0.addingTimeInterval(76) {
            let next = AgeScheduleRule.nextTick(after: current, since: t0)
            XCTAssertGreaterThan(next, current)
            current = next
            if current > t0.addingTimeInterval(60) && current <= t0.addingTimeInterval(76) {
                ticksPast60 += 1
            }
        }

        XCTAssertEqual(ticksPast60, 1, "Only 1 tick should occur in the 16s window between 60s and 76s, got \(ticksPast60)")
    }

    /// The label's text is derived from its format and the clock, so it must not count: an idle
    /// session that nothing happened to reads "the same" every second, across the minute boundary
    /// too, and a publisher guarding on equality stays quiet.
    func testAnUnchangedAgeStatusIsEqualAtEveryLaterTime() {
        func idle(at offset: TimeInterval) -> SessionRowStatus {
            SessionAttention.status(
                state: .ready, stateChangedAt: t0, turnStartedAt: t0, lastSeen: nil, onScreen: false, rateLimited: false,
                now: t0.addingTimeInterval(offset))
        }
        XCTAssertNotEqual(idle(at: 59).text, idle(at: 60).text, "the derived text does move with the clock")
        XCTAssertEqual(idle(at: 30), idle(at: 31))
        XCTAssertEqual(idle(at: 59), idle(at: 60))
        XCTAssertEqual(idle(at: 300), idle(at: 301))
    }

    func testAnAgeStatusDiffersWhenItsSinceOrToneDoes() {
        let now = t0.addingTimeInterval(30)
        let idle = SessionRowStatus(format: .age(prefix: "", since: t0), tone: .quiet, now: now)
        XCTAssertNotEqual(idle, SessionRowStatus(format: .age(prefix: "", since: t0.addingTimeInterval(1)), tone: .quiet, now: now))
        XCTAssertNotEqual(idle, SessionRowStatus(format: .age(prefix: "", since: t0), tone: .attention, marker: .dot, now: now))
        XCTAssertNotEqual(idle, SessionRowStatus(format: .age(prefix: "", since: t0), tone: .attention, now: now))
    }

    func testSessionRowStatusEqualityIncludesFormat() {
        let s1 = SessionRowStatus(format: .fixed("0s"), tone: .quiet)
        let s2 = SessionRowStatus(format: .age(prefix: "", since: t0), tone: .quiet, now: t0)
        XCTAssertEqual(s1.text, s2.text)
        XCTAssertNotEqual(s1, s2)
    }

    func testSessionRowStatusEqualityIncludesMarker() {
        let s1 = SessionRowStatus(format: .age(prefix: "", since: t0), tone: .attention, marker: .none, now: t0)
        let s2 = SessionRowStatus(format: .age(prefix: "", since: t0), tone: .attention, marker: .dot, now: t0)
        let s3 = SessionRowStatus(format: .age(prefix: "", since: t0), tone: .attention, marker: .pingDot, now: t0)
        XCTAssertNotEqual(s1, s2)
        XCTAssertNotEqual(s2, s3)
        XCTAssertNotEqual(s1, s3)
    }

    /// A permission prompt answered mid-turn is still the same turn: the clock counts from the prompt the user
    /// sent, not from the answer. A new prompt starts a new turn.
    func testTheTurnClockSurvivesAnAnsweredPermissionPrompt() {
        var session = Session(id: "s1", cwd: "/p", title: "p", state: .ready, stateChangedAt: t0)
        func apply(_ kind: HookEventKind, at seconds: TimeInterval) {
            session = SessionReducer.apply(
                HookEvent(kind: kind, linkcSessionId: "s1", claudeSessionId: "c1", cwd: "/p"),
                to: session, now: t0.addingTimeInterval(seconds)).session
        }
        apply(.userPromptSubmit, at: 10)
        apply(.notificationPermission, at: 100)
        apply(.toolFinished, at: 130)
        XCTAssertEqual(session.state, .working)
        XCTAssertEqual(session.turnStartedAt, t0.addingTimeInterval(10))
        let now = t0.addingTimeInterval(195)
        XCTAssertEqual(SessionAttention().status(for: session, onScreen: false, rateLimited: false, now: now).text(now: now),
                       "3m 05s")

        apply(.stop, at: 200)
        apply(.userPromptSubmit, at: 300)
        XCTAssertEqual(session.turnStartedAt, t0.addingTimeInterval(300), "a new prompt is a new turn")
    }

    /// Agents read off the screen change state through the store, not hooks: the same rule holds there.
    func testTheStoreKeepsTheTurnClockAcrossAPermissionPrompt() throws {
        let store = SessionStore()
        let id = store.create(cwd: "/p", title: "p", agentKind: .codex).id
        store.updateState(id: id, to: .working)
        let started = try XCTUnwrap(store.session(id: id)?.turnStartedAt)
        store.updateState(id: id, to: .waitingPermission)
        store.updateState(id: id, to: .working)
        XCTAssertEqual(store.session(id: id)?.turnStartedAt, started)

        store.updateState(id: id, to: .finished)
        store.updateState(id: id, to: .working)
        let next = try XCTUnwrap(store.session(id: id))
        XCTAssertEqual(next.turnStartedAt, next.stateChangedAt, "a turn after a finished one starts when it starts")
    }

    /// Declining a permission prompt (Esc) and typing a new instruction is a new turn: the clock starts again.
    func testANewPromptWhileAPromptWaitsStartsANewTurn() {
        var session = Session(id: "s1", cwd: "/p", title: "p", state: .ready, stateChangedAt: t0)
        func apply(_ kind: HookEventKind, at seconds: TimeInterval) {
            session = SessionReducer.apply(
                HookEvent(kind: kind, linkcSessionId: "s1", claudeSessionId: "c1", cwd: "/p"),
                to: session, now: t0.addingTimeInterval(seconds)).session
        }
        apply(.userPromptSubmit, at: 10)
        apply(.notificationPermission, at: 100)
        apply(.userPromptSubmit, at: 150)
        XCTAssertEqual(session.state, .working)
        XCTAssertEqual(session.turnStartedAt, t0.addingTimeInterval(150))
    }
}

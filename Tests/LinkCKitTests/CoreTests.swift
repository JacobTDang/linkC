import XCTest
@testable import LinkCKit

final class SessionReducerTests: XCTestCase {
    private func event(_ kind: HookEventKind, claude: String? = "c1") -> HookEvent {
        HookEvent(kind: kind, linkcSessionId: "L1", claudeSessionId: claude, cwd: "/tmp")
    }

    func testTransitionsCoverEveryEventKind() {
        let cases: [(HookEventKind, SessionState)] = [
            (.sessionStart, .ready),
            (.userPromptSubmit, .working),
            (.notificationPermission, .waitingPermission),
            (.notificationIdle, .waitingIdle),
            (.stop, .finished),
            (.stopFailure, .error),
            (.sessionEnd, .ended),
            (.toolFinished, .working),
        ]
        for (kind, expected) in cases {
            XCTAssertEqual(SessionReducer.nextState(current: .working, event: kind), expected)
        }
    }

    /// A question or plan approval shows a permission prompt even under
    /// `--dangerously-skip-permissions`. Once it is answered the tool finishes and the turn goes
    /// on with no prompt submit to say so, so a finished tool is the only signal it is working
    /// again. Any other state stays put: a late tool event must not revive a finished turn.
    func testToolFinishedReturnsAPermissionPromptToWorkingAndLeavesOtherStatesAlone() {
        XCTAssertEqual(SessionReducer.nextState(current: .waitingPermission, event: .toolFinished), .working)
        for state in SessionState.allCases where state != .waitingPermission {
            XCTAssertEqual(SessionReducer.nextState(current: state, event: .toolFinished), state,
                           "a finished tool must not move a session out of \(state)")
        }
    }

    /// A subagent's tool calls fire the same PostToolUse hook, and a subagent cannot ask the user
    /// anything, so its finished tool says nothing about a prompt the main turn is waiting on.
    func testASubagentsFinishedToolDoesNotClearAPermissionPrompt() {
        let waiting = Session(id: "L1", cwd: "/tmp", title: "api", state: .waitingPermission)

        let fromSubagent = HookEvent(kind: .toolFinished, linkcSessionId: "L1", claudeSessionId: "c1", cwd: "/tmp", agentId: "agent-7")
        XCTAssertEqual(SessionReducer.apply(fromSubagent, to: waiting).session.state, .waitingPermission)

        let fromMainTurn = HookEvent(kind: .toolFinished, linkcSessionId: "L1", claudeSessionId: "c1", cwd: "/tmp")
        XCTAssertEqual(SessionReducer.apply(fromMainTurn, to: waiting).session.state, .working)
    }

    func testBuckets() {
        XCTAssertEqual(SessionState.working.bucket, .active)
        XCTAssertEqual(SessionState.finished.bucket, .needsYou)
        XCTAssertEqual(SessionState.waitingPermission.bucket, .needsYou)
        XCTAssertEqual(SessionState.ready.bucket, .idle)
        XCTAssertEqual(SessionState.ended.bucket, .idle)
    }

    func testEnteringNotifiableIsATransitionNotARepeat() {
        let s = Session(id: "L1", cwd: "/tmp", title: "api", state: .working)
        let first = SessionReducer.apply(event(.stop), to: s)
        XCTAssertEqual(first.session.state, .finished)
        XCTAssertTrue(first.enteredNotifiable, "working → finished should be notifiable")

        let again = SessionReducer.apply(event(.stop), to: first.session)
        XCTAssertFalse(again.enteredNotifiable, "finished → finished must not re-notify")
    }

    func testApplyBindsClaudeSessionId() {
        let s = Session(id: "L1", cwd: "/tmp", title: "api")
        let out = SessionReducer.apply(event(.userPromptSubmit, claude: "abc"), to: s)
        XCTAssertEqual(out.session.claudeSessionId, "abc")
    }

    /// The idle-prompt nudge arrives about 60 s into any idle prompt. On a session that has not
    /// run a turn it is not news: the session stays ready.
    func testTheIdleNudgeLeavesAFreshSessionReady() {
        XCTAssertEqual(SessionReducer.nextState(current: .ready, event: .notificationIdle), .ready)
    }

    /// After a turn, the nudge is a reminder about the turn that already ended: the state moves
    /// to waiting-for-input but keeps the turn's clock, so a turn the user already saw stays seen.
    func testTheIdleNudgeAfterATurnKeepsTheTurnsClock() {
        let t1 = Date(timeIntervalSince1970: 1_000_000)
        let working = Session(id: "L1", cwd: "/tmp", title: "api", state: .working)
        let finished = SessionReducer.apply(event(.stop), to: working, now: t1).session
        let nudged = SessionReducer.apply(event(.notificationIdle), to: finished, now: t1.addingTimeInterval(60)).session
        XCTAssertEqual(nudged.state, .waitingIdle)
        XCTAssertEqual(nudged.stateChangedAt, t1)
    }
}

@MainActor
final class SessionStoreTests: XCTestCase {
    func testApplyBindsByLinkcId() {
        let store = SessionStore()
        let s = store.create(cwd: "/tmp", title: "api", id: "L1")
        XCTAssertEqual(s.state, .starting)

        let out = store.apply(HookEvent(kind: .userPromptSubmit, linkcSessionId: "L1", claudeSessionId: "c1", cwd: "/tmp"))
        XCTAssertEqual(out.session?.state, .working)
        XCTAssertEqual(store.session(id: "L1")?.claudeSessionId, "c1")
        XCTAssertEqual(store.activeCount, 1)
    }

    func testRebindByClaudeIdWhenLinkcIdMissing() {
        let store = SessionStore()
        store.create(cwd: "/tmp", title: "api", id: "L1")
        // First event binds claude id.
        store.apply(HookEvent(kind: .userPromptSubmit, linkcSessionId: "L1", claudeSessionId: "c1", cwd: "/tmp"))
        // A later event with only the claude id still routes to the session.
        let out = store.apply(HookEvent(kind: .stop, linkcSessionId: nil, claudeSessionId: "c1", cwd: "/tmp"))
        XCTAssertEqual(out.session?.state, .finished)
        XCTAssertTrue(out.shouldConsiderNotifying)
    }

    func testExternalEventIsIgnored() {
        let store = SessionStore()
        store.create(cwd: "/tmp", title: "api", id: "L1")
        let out = store.apply(HookEvent(kind: .stop, linkcSessionId: nil, claudeSessionId: "unknown", cwd: "/x"))
        XCTAssertNil(out.session)
        XCTAssertFalse(out.shouldConsiderNotifying)
    }

    func testAggregateCounts() {
        let store = SessionStore()
        store.create(cwd: "/a", title: "a", id: "A")
        store.create(cwd: "/b", title: "b", id: "B")
        store.apply(HookEvent(kind: .userPromptSubmit, linkcSessionId: "A", claudeSessionId: "ca", cwd: "/a"))
        store.apply(HookEvent(kind: .stop, linkcSessionId: "B", claudeSessionId: "cb", cwd: "/b"))
        XCTAssertEqual(store.activeCount, 1)
        XCTAssertEqual(store.needsYouCount, 1)
    }
}

final class HookEventKindTests: XCTestCase {
    func testRawValuesAreStableHeaderTokens() {
        XCTAssertEqual(HookEventKind.stop.rawValue, "stop")
        XCTAssertEqual(HookEventKind.notificationPermission.rawValue, "notification_permission")
        XCTAssertEqual(HookEventKind(rawValue: "session_end"), .sessionEnd)
        XCTAssertEqual(HookEventKind(rawValue: "tool_finished"), .toolFinished)
    }

    func testExternalSessionIdNormalizedToNil() {
        let e = HookEvent(kind: .stop, linkcSessionId: "", claudeSessionId: "c", cwd: nil)
        XCTAssertNil(e.linkcSessionId, "empty header must normalize to nil (external session)")
    }
}

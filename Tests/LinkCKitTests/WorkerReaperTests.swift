import XCTest
@testable import LinkCKit

final class WorkerReaperTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func session(
        _ id: String, _ state: SessionState, idleFor minutes: Double, worker: Bool = true,
        agent: AgentKind = .codex, tier: ModelTier? = nil
    ) -> Session {
        Session(
            id: id, cwd: "/p", title: "p", state: state,
            stateChangedAt: now.addingTimeInterval(-minutes * 60), agentKind: agent,
            modelTier: tier, isWorker: worker)
    }

    /// A task assigned to `assignee`, in `state`, that reached that state `endedAgo` seconds ago.
    private func task(
        _ state: TaskState, assignee: String?, endedAgo seconds: TimeInterval = 0,
        to agent: AgentKind = .codex, tier: ModelTier? = nil, from sessionId: String? = nil
    ) -> TaskRecord {
        let ended = now.addingTimeInterval(-seconds)
        return TaskRecord(
            fromAgent: .claude, fromSessionId: sessionId, tier: tier, toAgent: agent,
            assigneeSessionId: assignee, prompt: "p", state: state,
            createdAt: now.addingTimeInterval(-3600), finishedAt: state.isOpen ? nil : ended)
    }

    /// `typed` is when linkC last typed into each session, in seconds before `now`.
    private func closable(
        _ sessions: [Session], tasks: [TaskRecord] = [], typed: [String: TimeInterval] = [:]
    ) -> [String] {
        WorkerReaper.closable(
            sessions: sessions, tasks: tasks, lastTypedAt: typed.mapValues { now.addingTimeInterval(-$0) }, now: now)
    }

    // MARK: - The idle backstop

    func testAWorkerIdlePastTheGraceIsClosed() {
        for state in [SessionState.ready, .finished, .waitingIdle] {
            XCTAssertEqual(closable([session("W", state, idleFor: 10)]), ["W"], "\(state)")
        }
    }

    func testAWorkerInsideTheGraceIsKept() {
        XCTAssertEqual(closable([session("W", .finished, idleFor: 9)]), [])
    }

    func testAWorkerThatIsNotIdleIsKept() {
        for state in [SessionState.starting, .working, .waitingPermission, .error] {
            XCTAssertEqual(closable([session("W", state, idleFor: 60)]), [], "\(state)")
        }
    }

    func testAWorkerHoldingATaskIsKept() {
        XCTAssertEqual(
            closable([session("W", .finished, idleFor: 60)], tasks: [task(.started, assignee: "W")]), [])
    }

    func testTheUsersSessionIsNeverClosed() {
        XCTAssertEqual(closable([session("U", .finished, idleFor: 600, worker: false)]), [])
    }

    func testTheGraceIsTenMinutes() {
        XCTAssertEqual(WorkerReaper.idleGrace, 600)
    }

    // MARK: - Close on completion

    func testTheCompletionGraceIsSixtySeconds() {
        XCTAssertEqual(WorkerReaper.completionGrace, 60)
    }

    func testAWorkerIsClosedAMinuteAfterEachFinalStateOfItsTask() {
        for state in [TaskState.done, .failed, .cancelled, .expired] {
            let tasks = [task(state, assignee: "W", endedAgo: 61)]
            XCTAssertEqual(closable([session("W", .finished, idleFor: 2)], tasks: tasks), ["W"], "\(state)")
        }
    }

    func testAWorkerInsideTheCompletionGraceIsKept() {
        for state in [TaskState.done, .failed, .cancelled, .expired] {
            let tasks = [task(state, assignee: "W", endedAgo: 59)]
            XCTAssertEqual(closable([session("W", .finished, idleFor: 2)], tasks: tasks), [], "\(state)")
        }
    }

    func testAnOpenTaskDoesNotStartTheCompletionGrace() {
        for state in [TaskState.delivered, .started, .reported] {
            let tasks = [task(state, assignee: "W")]
            XCTAssertEqual(closable([session("W", .finished, idleFor: 2)], tasks: tasks), [], "\(state)")
        }
    }

    func testAWorkerStillHoldingAnotherOpenTaskIsKeptAfterOneEnds() {
        let tasks = [task(.done, assignee: "W", endedAgo: 120), task(.started, assignee: "W")]
        XCTAssertEqual(closable([session("W", .finished, idleFor: 2)], tasks: tasks), [])
    }

    func testTheCompletionGraceRunsFromTheLatestFinishedTask() {
        let tasks = [task(.done, assignee: "W", endedAgo: 600), task(.done, assignee: "W", endedAgo: 10)]
        XCTAssertEqual(closable([session("W", .finished, idleFor: 2)], tasks: tasks), [])
    }

    func testAFinishedWorkerThatIsNotIdleIsKept() {
        let tasks = [task(.done, assignee: "W", endedAgo: 120)]
        for state in [SessionState.starting, .working, .waitingPermission, .error] {
            XCTAssertEqual(closable([session("W", state, idleFor: 2)], tasks: tasks), [], "\(state)")
        }
    }

    func testTheUsersSessionIsNotClosedWhenATaskItCarriedEnds() {
        let tasks = [task(.done, assignee: "U", endedAgo: 120)]
        XCTAssertEqual(closable([session("U", .finished, idleFor: 2, worker: false)], tasks: tasks), [])
    }

    func testAnEndedTaskOfAnotherSessionDoesNotCloseThisWorker() {
        let tasks = [task(.done, assignee: "other", endedAgo: 120)]
        XCTAssertEqual(closable([session("W", .finished, idleFor: 2)], tasks: tasks), [])
    }

    // MARK: - Only after a whole grace of quiet

    /// A worker that looked busy a moment ago is not one that has finished, however long ago its
    /// task ended: a peer note or a lapsed lease can leave it working after the task is over,
    /// and a screen read can call a long tool call a turn end.
    func testAWorkerThatWentIdleInsideTheGraceIsKeptEvenThoughItsTaskEndedLongAgo() {
        let tasks = [task(.done, assignee: "W", endedAgo: 120)]
        XCTAssertEqual(closable([session("W", .finished, idleFor: 1.0 / 60)], tasks: tasks), [])
        XCTAssertEqual(closable([session("W", .finished, idleFor: 59.0 / 60)], tasks: tasks), [])
    }

    func testAWorkerIsClosedOnceItHasBeenIdleForTheWholeGrace() {
        let tasks = [task(.done, assignee: "W", endedAgo: 120)]
        XCTAssertEqual(closable([session("W", .finished, idleFor: 61.0 / 60)], tasks: tasks), ["W"])
    }

    func testAWorkerTypedIntoAfterItsTaskEndedIsLeftToTheIdleBackstop() {
        let tasks = [task(.done, assignee: "W", endedAgo: 120)]
        XCTAssertEqual(
            closable([session("W", .finished, idleFor: 5)], tasks: tasks, typed: ["W": 30]), [],
            "a note typed in after the task ended: it may be acting on it, and its idle reading predates it")
    }

    func testTypingBeforeTheTaskEndedDoesNotKeepTheWorker() {
        let tasks = [task(.done, assignee: "W", endedAgo: 120)]
        XCTAssertEqual(closable([session("W", .finished, idleFor: 5)], tasks: tasks, typed: ["W": 300]), ["W"])
    }

    func testTypingIntoAnotherSessionDoesNotKeepThisWorker() {
        let tasks = [task(.done, assignee: "W", endedAgo: 120)]
        XCTAssertEqual(closable([session("W", .finished, idleFor: 5)], tasks: tasks, typed: ["other": 30]), ["W"])
    }

    func testTypingRestartsTheIdleBackstop() {
        XCTAssertEqual(closable([session("W", .finished, idleFor: 11)], typed: ["W": 2 * 60]), [], "typed 2 min ago")
        XCTAssertEqual(closable([session("W", .finished, idleFor: 11)], typed: ["W": 10 * 60 + 1]), ["W"])
    }

    func testATaskWithoutAFinishTimeCountsFromItsCreation() {
        var ended = task(.cancelled, assignee: "W")
        ended.finishedAt = nil
        XCTAssertEqual(closable([session("W", .finished, idleFor: 2)], tasks: [ended]), ["W"])
    }

    // MARK: - A follow-up reuses the worker

    func testAWorkerThatAQueuedTaskCouldTakeIsKeptInsteadOfClosed() {
        let ended = task(.done, assignee: "W", endedAgo: 120)
        for state in [TaskState.queued, .gating] {
            let followUp = task(state, assignee: nil)
            XCTAssertEqual(
                closable([session("W", .finished, idleFor: 2)], tasks: [ended, followUp]), [], "\(state)")
        }
    }

    func testAQueuedTaskForAnotherAgentKindDoesNotKeepTheWorker() {
        let tasks = [task(.done, assignee: "W", endedAgo: 120), task(.queued, assignee: nil, to: .claude)]
        XCTAssertEqual(closable([session("W", .finished, idleFor: 2)], tasks: tasks), ["W"])
    }

    func testAQueuedTaskForAnotherTierDoesNotKeepTheWorker() {
        let tasks = [
            task(.done, assignee: "W", endedAgo: 120),
            task(.queued, assignee: nil, tier: .deep)
        ]
        XCTAssertEqual(
            closable([session("W", .finished, idleFor: 2, tier: .light)], tasks: tasks), ["W"])
        XCTAssertEqual(
            closable([session("W", .finished, idleFor: 2, tier: .deep)], tasks: tasks), [])
    }

    func testATaskTheWorkerDelegatedItselfDoesNotKeepIt() {
        let tasks = [
            task(.done, assignee: "W", endedAgo: 120),
            task(.queued, assignee: nil, from: "W")
        ]
        XCTAssertEqual(closable([session("W", .finished, idleFor: 2)], tasks: tasks), ["W"])
    }

    func testAQueuedTaskDoesNotKeepAWorkerPastTheIdleBackstop() {
        let tasks = [task(.queued, assignee: nil)]
        XCTAssertEqual(closable([session("W", .finished, idleFor: 10)], tasks: tasks), ["W"])
    }

    // MARK: - Close requests

    /// `typed` is when linkC last typed into the session, in seconds before `now`.
    private func decide(
        _ by: CloseRequest.Requester = .delegator, task: TaskRecord? = nil, among: [TaskRecord] = [],
        session: Session?, onScreen: Bool = false, typed: TimeInterval? = nil
    ) -> CloseDecision {
        let asked = task ?? self.task(.reported, assignee: "W")
        return WorkerReaper.decision(
            for: CloseRequest(by: by), task: asked, among: [asked] + among, session: session, onScreen: onScreen,
            lastTypedAt: typed.map { now.addingTimeInterval(-$0) })
    }

    func testAnIdleWorkerIsClosedOnRequest() {
        for state in [SessionState.ready, .finished, .waitingIdle] {
            for by in [CloseRequest.Requester.delegator, .worker] {
                XCTAssertEqual(
                    decide(by, session: session("W", state, idleFor: 0)), .close(sessionId: "W"), "\(state) \(by)")
            }
        }
    }

    func testARequestClosesAWorkerWithoutWaitingOutAGrace() {
        let ended = task(.done, assignee: "W", endedAgo: 1)
        XCTAssertEqual(
            decide(task: ended, session: session("W", .finished, idleFor: 0)), .close(sessionId: "W"))
    }

    func testARequestIsRefusedForASessionTheUserOpened() {
        guard case .refuse(let reason) = decide(session: session("W", .finished, idleFor: 0, worker: false)) else {
            return XCTFail("a user-opened session must be refused")
        }
        XCTAssertTrue(reason.contains("not a worker linkC launched"), reason)
    }

    func testARequestIsRefusedForTheSessionOnScreen() {
        guard case .refuse(let reason) = decide(session: session("W", .finished, idleFor: 0), onScreen: true) else {
            return XCTFail("the session on screen must be refused")
        }
        XCTAssertTrue(reason.contains("on screen"), reason)
    }

    func testTheDelegatorsRequestIsRefusedWhileTheWorkerIsBusy() {
        for state in [SessionState.starting, .working, .waitingPermission, .error] {
            guard case .refuse(let reason) = decide(.delegator, session: session("W", state, idleFor: 0)) else {
                return XCTFail("\(state) must be refused")
            }
            XCTAssertTrue(reason.contains("idle"), reason)
        }
    }

    func testTheWorkersOwnRequestWaitsForItsTurnToEnd() {
        for state in [SessionState.starting, .working, .waitingPermission, .error] {
            XCTAssertEqual(decide(.worker, session: session("W", state, idleFor: 0)), .wait, "\(state)")
        }
    }

    /// linkC types only into a session that reads as idle, so what it typed is not yet reflected
    /// in the reading: the worker may be acting on it.
    func testARequestIsRefusedForASessionTypedIntoAfterItsTaskEnded() {
        let ended = task(.done, assignee: "W", endedAgo: 120)
        let idle = session("W", .finished, idleFor: 5)
        guard case .refuse(let reason) = decide(.delegator, task: ended, session: idle, typed: 30) else {
            return XCTFail("a session typed into after its task ended must be refused")
        }
        XCTAssertTrue(reason.contains("typed"), reason)
        XCTAssertEqual(decide(.worker, task: ended, session: idle, typed: 30), .wait)
    }

    func testARequestOnAReportedTaskIsRefusedWhileTheIdleReadingIsOlderThanTheTyping() {
        let idle = session("W", .finished, idleFor: 1)
        guard case .refuse = decide(.delegator, session: idle, typed: 10) else {
            return XCTFail("typed into after it last went idle: the reading is stale")
        }
        XCTAssertEqual(decide(.worker, session: idle, typed: 10), .wait)
        XCTAssertEqual(decide(.delegator, session: idle, typed: 300), .close(sessionId: "W"), "typed before it went idle")
    }

    /// The frame that delivered a later task is typed after an earlier one ended, and says nothing
    /// about it.
    func testARequestIgnoresTheFrameThatDeliveredALaterTaskThatEndedToo() {
        let first = task(.done, assignee: "W", endedAgo: 600)
        let second = task(.done, assignee: "W", endedAgo: 120)
        XCTAssertEqual(
            decide(task: first, among: [second], session: session("W", .finished, idleFor: 5), typed: 300),
            .close(sessionId: "W"))
    }

    func testARequestIgnoresTypingThatCameBeforeTheTaskEnded() {
        let ended = task(.done, assignee: "W", endedAgo: 120)
        XCTAssertEqual(
            decide(task: ended, session: session("W", .finished, idleFor: 5), typed: 300), .close(sessionId: "W"))
    }

    func testARequestIsRefusedWhileTheWorkerHoldsAnotherOpenTask() {
        let other = task(.started, assignee: "W")
        guard case .refuse(let reason) = decide(among: [other], session: session("W", .finished, idleFor: 0)) else {
            return XCTFail("another open task must refuse")
        }
        XCTAssertTrue(reason.contains(other.shortId), reason)
    }

    func testARequestOnATaskStillRunningIsRefused() {
        let running = task(.started, assignee: "W")
        guard case .refuse = decide(task: running, session: session("W", .finished, idleFor: 0)) else {
            return XCTFail("a running task must refuse")
        }
    }

    func testARequestForASessionThatIsGoneIsAlreadyDone() {
        XCTAssertEqual(decide(session: nil), .alreadyClosed)
        XCTAssertEqual(decide(.worker, among: [task(.started, assignee: "W")], session: nil), .alreadyClosed)
    }

    func testARequestOnATaskNeverDeliveredIsRefused() {
        guard case .refuse = decide(task: task(.queued, assignee: nil), session: nil) else {
            return XCTFail("an undelivered task has no worker")
        }
    }
}

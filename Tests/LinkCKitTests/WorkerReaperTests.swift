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

    private func closable(_ sessions: [Session], tasks: [TaskRecord] = []) -> [String] {
        WorkerReaper.closable(sessions: sessions, tasks: tasks, now: now)
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
}

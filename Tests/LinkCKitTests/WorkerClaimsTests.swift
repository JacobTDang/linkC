import XCTest
@testable import LinkCKit

final class WorkerClaimsTests: XCTestCase {
    private let folder = "/tmp/linkc-worker-claims"
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func session(_ id: String, _ state: SessionState, agent: AgentKind = .codex, tier: ModelTier? = nil,
                         model: String? = nil,
                         worker: Bool = true, for duration: TimeInterval = 0) -> Session {
        Session(id: id, cwd: folder, title: id, state: state, stateChangedAt: now.addingTimeInterval(-duration),
                agentKind: agent, model: model, modelTier: tier, isWorker: worker)
    }

    private func task(_ id: String, to agent: AgentKind = .codex, tier: ModelTier? = nil,
                      model: String? = nil,
                      from sessionId: String? = nil, pinnedTo target: String? = nil) -> TaskRecord {
        TaskRecord(id: id, fromAgent: .claude, fromSessionId: sessionId, tier: tier, model: model, toAgent: agent,
                   prompt: id, targetSessionId: target)
    }

    private func plan(_ tasks: [TaskRecord], _ sessions: [Session],
                      holding: Set<String> = [], ready: Set<String>? = nil) -> [String: WorkerClaim] {
        let idle = sessions.filter { [.ready, .finished, .waitingIdle].contains($0.state) }.map(\.id)
        return WorkerClaims.plan(queued: tasks, sessions: sessions, holdingUnreported: holding,
                                 ready: ready ?? Set(idle), now: now)
    }

    func testAnIdleWorkerIsReused() {
        let claims = plan([task("T1")], [session("A", .ready)])
        XCTAssertEqual(claims["T1"], .deliver(to: "A"))
    }

    func testAWorkerBusyWithItsTaskMeansANewOneStarts() {
        let claims = plan([task("T1")], [session("A", .working)], holding: ["A"])
        XCTAssertEqual(claims["T1"], .spawn)
    }

    func testAWorkerWaitingOnAPermissionForItsTaskMeansANewOneStarts() {
        let claims = plan([task("T1")], [session("A", .waitingPermission)], holding: ["A"])
        XCTAssertEqual(claims["T1"], .spawn)
    }

    func testABusySessionTheUserOpenedMeansANewWorkerStarts() {
        let claims = plan([task("T1")], [session("A", .working, worker: false)])
        XCTAssertEqual(claims["T1"], .spawn)
    }

    func testAWorkerHeldAtADialogWithNoTaskIsWaitedForNotStartedPast() {
        // A trust dialog at boot: starting a worker past it would hit the same dialog, pass after pass.
        let claims = plan([task("T1"), task("T2")], [session("A", .waitingPermission)])
        XCTAssertEqual(claims["T1"], .awaitBusy("A"))
        XCTAssertEqual(claims["T2"], .spawn)
    }

    func testAWorkerBusyWithNoTaskIsWaitedFor() {
        let claims = plan([task("T1")], [session("A", .working)])
        XCTAssertEqual(claims["T1"], .awaitBusy("A"))
    }

    func testAWorkerStuckWithNoTaskIsWaitedForOnlySoLong() {
        // A screen misread as working, or a dialog nobody answers, must not hold the agent's tasks for an hour.
        let patience = WorkerClaims.busyWorkerPatience
        let within = plan([task("T1")], [session("A", .waitingPermission, for: patience - 1)])
        XCTAssertEqual(within["T1"], .awaitBusy("A"))
        let past = plan([task("T1")], [session("A", .working, for: patience + 1)])
        XCTAssertEqual(past["T1"], .spawn)
    }

    func testARateLimitedSessionThatCouldCarryTheTaskHoldsItBack() {
        let claims = plan([task("T1"), task("T2")], [session("A", .error)], holding: ["A"])
        XCTAssertEqual(claims["T1"], .awaitLimited("A"))
        XCTAssertEqual(claims["T2"], .awaitLimited("A"))
    }

    func testARateLimitedSessionOnAnotherTierDoesNotHoldTheTaskBack() {
        let claims = plan([task("T1", tier: .deep)], [session("A", .error, tier: .light)])
        XCTAssertEqual(claims["T1"], .spawn)
    }

    func testAModelTaskNeedsASessionRunningThatModel() {
        let matching = plan(
            [task("T1", model: "claude-opus-4-6-thinking")],
            [session("A", .ready, model: "claude-opus-4-6-thinking")])
        XCTAssertEqual(matching["T1"], .deliver(to: "A"))
        let other = plan(
            [task("T1", model: "claude-opus-4-6-thinking")],
            [session("A", .ready, model: "gemini-3.8-flash-medium")])
        XCTAssertEqual(other["T1"], .spawn)
    }



    func testAStartingWorkerIsClaimedRatherThanStartingAnother() {
        let claims = plan([task("T1")], [session("A", .starting)])
        XCTAssertEqual(claims["T1"], .awaitStart("A"))
    }

    func testTwoTasksWithNoWorkersEachNeedOne() {
        let claims = plan([task("T1"), task("T2")], [])
        XCTAssertEqual(claims["T1"], .spawn)
        XCTAssertEqual(claims["T2"], .spawn)
    }

    func testWithOneWorkerStartingTheSecondTaskStillNeedsOne() {
        let claims = plan([task("T1"), task("T2")], [session("A", .starting)])
        XCTAssertEqual(claims["T1"], .awaitStart("A"))
        XCTAssertEqual(claims["T2"], .spawn)
    }

    func testTwoTasksWithTwoStartingWorkersStartNoMoreAndEachClaimsItsOwn() {
        let claims = plan([task("T1"), task("T2")], [session("A", .starting), session("B", .starting)])
        XCTAssertEqual(claims["T1"], .awaitStart("A"))
        XCTAssertEqual(claims["T2"], .awaitStart("B"))
    }

    func testOneIdleWorkerTakesOneTaskAndTheNextTaskStartsAnother() {
        let claims = plan([task("T1"), task("T2")], [session("A", .ready)])
        XCTAssertEqual(claims["T1"], .deliver(to: "A"))
        XCTAssertEqual(claims["T2"], .spawn)
    }

    func testAWorkerHoldingAnUnreportedTaskGetsNoNewTask() {
        let claims = plan([task("T1")], [session("A", .waitingIdle)], holding: ["A"])
        XCTAssertEqual(claims["T1"], .spawn)
    }

    func testAPinnedTaskKeepsItsSessionAheadOfAnEarlierUnpinnedTask() {
        let claims = plan([task("T1"), task("T2", pinnedTo: "A")], [session("A", .ready)])
        XCTAssertEqual(claims["T2"], .deliver(to: "A"))
        XCTAssertEqual(claims["T1"], .spawn)
    }

    func testAPinnedTaskGoesToItsSessionEvenWhileItHoldsAnUnreportedTask() {
        let claims = plan([task("T1", pinnedTo: "A")], [session("A", .ready)], holding: ["A"])
        XCTAssertEqual(claims["T1"], .deliver(to: "A"))
    }

    func testAPinnedTaskWaitsForItsBusySessionAndNeverStartsOne() {
        let claims = plan([task("T1", pinnedTo: "A")], [session("A", .working), session("B", .ready)])
        XCTAssertEqual(claims["T1"], .awaitPinned)
    }

    func testAPinnedTaskWhoseSessionIsAbsentWaits() {
        let claims = plan([task("T1", pinnedTo: "GONE")], [session("A", .ready)])
        XCTAssertEqual(claims["T1"], .awaitPinned)
    }

    func testTwoTasksPinnedToOneSessionTakeItOneAtATime() {
        let claims = plan([task("T1", pinnedTo: "A"), task("T2", pinnedTo: "A")], [session("A", .ready)])
        XCTAssertEqual(claims["T1"], .deliver(to: "A"))
        XCTAssertEqual(claims["T2"], .awaitPinned)
    }

    func testAWorkerOnAnotherTierIsNotClaimed() {
        let claims = plan([task("T1", tier: .deep)], [session("A", .ready, tier: .light)])
        XCTAssertEqual(claims["T1"], .spawn)
    }

    func testAWorkerOfAnotherAgentIsNotClaimed() {
        let claims = plan([task("T1", to: .codex)], [session("A", .ready, agent: .cursor)])
        XCTAssertEqual(claims["T1"], .spawn)
    }

    func testTheDelegatorsOwnSessionIsNotClaimed() {
        let claims = plan([task("T1", from: "A")], [session("A", .ready)])
        XCTAssertEqual(claims["T1"], .spawn)
    }

    func testAnEndedSessionIsNotClaimed() {
        let claims = plan([task("T1")], [session("A", .ended)])
        XCTAssertEqual(claims["T1"], .spawn)
    }

    func testAnIdleWorkerIsPreferredToAStartingOne() {
        let claims = plan([task("T1")], [session("A", .starting), session("B", .finished)])
        XCTAssertEqual(claims["T1"], .deliver(to: "B"))
    }

    func testAReadyIdleWorkerIsPreferredToOneNotYetReady() {
        let claims = plan([task("T1")], [session("A", .ready), session("B", .ready)], ready: ["B"])
        XCTAssertEqual(claims["T1"], .deliver(to: "B"))
    }

    func testAnIdleWorkerNotYetReadyIsClaimedAndWaitedFor() {
        let claims = plan([task("T1")], [session("A", .ready)], ready: [])
        XCTAssertEqual(claims["T1"], .awaitReady("A"))
    }

    func testAPinnedTaskWaitsForItsIdleSessionToBeReady() {
        let claims = plan([task("T1", pinnedTo: "A")], [session("A", .ready)], ready: [])
        XCTAssertEqual(claims["T1"], .awaitReady("A"))
    }

    func testAPinnedTaskWaitsForItsStartingSession() {
        let claims = plan([task("T1", pinnedTo: "A")], [session("A", .starting)])
        XCTAssertEqual(claims["T1"], .awaitStart("A"))
    }
}

import XCTest
@testable import LinkCKit

final class WorkerClaimsTests: XCTestCase {
    private let folder = "/tmp/linkc-worker-claims"

    private func session(_ id: String, _ state: SessionState, agent: AgentKind = .codex, tier: ModelTier? = nil) -> Session {
        Session(id: id, cwd: folder, title: id, state: state, agentKind: agent, modelTier: tier, isWorker: true)
    }

    private func task(_ id: String, to agent: AgentKind = .codex, tier: ModelTier? = nil,
                      from sessionId: String? = nil, pinnedTo target: String? = nil) -> TaskRecord {
        TaskRecord(id: id, fromAgent: .claude, fromSessionId: sessionId, tier: tier, toAgent: agent,
                   prompt: id, targetSessionId: target)
    }

    private func plan(_ tasks: [TaskRecord], _ sessions: [Session],
                      holding: Set<String> = [], ready: Set<String>? = nil) -> [String: WorkerClaim] {
        let idle = sessions.filter { [.ready, .finished, .waitingIdle].contains($0.state) }.map(\.id)
        return WorkerClaims.plan(queued: tasks, sessions: sessions, holdingUnreported: holding,
                                 ready: ready ?? Set(idle))
    }

    func testAnIdleWorkerIsReused() {
        let claims = plan([task("T1")], [session("A", .ready)])
        XCTAssertEqual(claims["T1"], .deliver(to: "A"))
    }

    func testABusyWorkerMeansANewOneStarts() {
        let claims = plan([task("T1")], [session("A", .working)])
        XCTAssertEqual(claims["T1"], .spawn)
    }

    func testWorkersWaitingOnAPermissionOrInErrorAreNotClaimed() {
        let claims = plan([task("T1"), task("T2")], [session("A", .waitingPermission), session("B", .error)])
        XCTAssertEqual(claims["T1"], .spawn)
        XCTAssertEqual(claims["T2"], .spawn)
    }

    func testAStartingWorkerIsClaimedRatherThanStartingAnother() {
        let claims = plan([task("T1")], [session("A", .starting)])
        XCTAssertEqual(claims["T1"], .awaitStart("A"))
    }

    func testTwoTasksWithNoWorkersStartTwo() {
        let claims = plan([task("T1"), task("T2")], [])
        XCTAssertEqual(claims["T1"], .spawn)
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

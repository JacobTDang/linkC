import XCTest
@testable import LinkCKit

final class WorkerReaperTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func session(
        _ id: String, _ state: SessionState, idleFor minutes: Double, worker: Bool = true
    ) -> Session {
        Session(
            id: id, cwd: "/p", title: "p", state: state,
            stateChangedAt: now.addingTimeInterval(-minutes * 60), isWorker: worker)
    }

    private func closable(_ sessions: [Session], holding: Set<String> = []) -> [String] {
        WorkerReaper.closable(sessions: sessions, taskAssignees: holding, now: now)
    }

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
        XCTAssertEqual(closable([session("W", .finished, idleFor: 60)], holding: ["W"]), [])
    }

    func testTheUsersSessionIsNeverClosed() {
        XCTAssertEqual(closable([session("U", .finished, idleFor: 600, worker: false)]), [])
    }

    func testTheGraceIsTenMinutes() {
        XCTAssertEqual(WorkerReaper.idleGrace, 600)
    }
}

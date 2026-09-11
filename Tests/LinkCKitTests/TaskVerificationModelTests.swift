import XCTest
@testable import LinkCKit

final class TaskVerificationModelTests: XCTestCase {
    private let base = String(repeating: "b", count: 40)

    func testGatingAndReportedAreOpen() {
        XCTAssertTrue(TaskState.gating.isOpen)
        XCTAssertTrue(TaskState.reported.isOpen)
    }

    func testNewTransitions() {
        XCTAssertTrue(TaskState.gating.canTransition(to: .queued))
        XCTAssertTrue(TaskState.gating.canTransition(to: .cancelled))
        XCTAssertTrue(TaskState.gating.canTransition(to: .expired))
        XCTAssertFalse(TaskState.gating.canTransition(to: .delivered))
        XCTAssertTrue(TaskState.delivered.canTransition(to: .reported))
        XCTAssertTrue(TaskState.started.canTransition(to: .reported))
        XCTAssertFalse(TaskState.queued.canTransition(to: .reported))
        for next: TaskState in [.done, .failed, .cancelled, .expired] {
            XCTAssertTrue(TaskState.reported.canTransition(to: next), "reported -> \(next)")
        }
        XCTAssertFalse(TaskState.reported.canTransition(to: .started))
    }

    func testVerificationValidation() {
        func v(branch: String = "task/x", sha: String? = nil, command: String = "./check.sh",
               paths: [String] = ["check.sh"], timeout: Int = 600) -> Verification {
            Verification(branch: branch, baseSha: sha ?? base, command: command, testPaths: paths, timeoutSeconds: timeout)
        }
        XCTAssertNil(v().validationError)
        XCTAssertEqual(v(branch: " ").validationError, "branch is empty")
        XCTAssertEqual(v(command: "").validationError, "command is empty")
        XCTAssertEqual(v(paths: []).validationError, "test_paths is empty")
        XCTAssertEqual(v(sha: "3f9e2c1").validationError, "base_sha must be a full 40-character lowercase SHA")
        XCTAssertEqual(v(sha: String(repeating: "B", count: 40)).validationError, "base_sha must be a full 40-character lowercase SHA")
        XCTAssertEqual(v(timeout: 0).validationError, "timeout_seconds must be between 1 and 3600")
        XCTAssertEqual(v(timeout: 3601).validationError, "timeout_seconds must be between 1 and 3600")
        XCTAssertEqual(Verification(branch: "b", baseSha: base, command: "c", testPaths: ["t"]).timeoutSeconds, 600)
    }

    func testNotRunVerdict() {
        let verdict = Verdict.notRun(reason: "worker reported failure")
        XCTAssertFalse(verdict.passed)
        XCTAssertNil(verdict.sha)
        XCTAssertNil(verdict.exitStatus)
        XCTAssertEqual(verdict.reason, "worker reported failure")
    }

    /// An inbox written by v2 — reports carry `tests`, tasks carry no verification — must decode.
    func testInboxWrittenBeforeVerificationDecodes() throws {
        let json = """
        {"version":2,"workspacePath":"/w","updatedAt":"2026-09-09T12:00:00Z","messages":[],"agentLimits":[],
         "tasks":[{"id":"t1","fromAgent":"claude","toAgent":"codex","prompt":"p","files":[],"state":"done","hop":0,
         "createdAt":"2026-09-09T12:00:00Z","leaseExpiresAt":"2026-09-09T16:00:00Z",
         "report":{"status":"done","summary":"s","commits":["abc"],"tests":["swift test"]},
         "unreportedTurnEndNotified":false}]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let task = try XCTUnwrap(decoder.decode(Inbox.self, from: Data(json.utf8)).tasks.first)
        XCTAssertNil(task.verification)
        XCTAssertNil(task.gate)
        XCTAssertNil(task.verdict)
        XCTAssertNil(task.report?.sha)
        XCTAssertEqual(task.report?.commits, ["abc"])
    }

    func testNewErrorDescriptions() {
        XCTAssertEqual(InboxError.summaryTooLong(count: 1001).localizedDescription,
                       "Rejected: summary is 1001 characters; the limit is 1,000.")
        XCTAssertEqual(InboxError.shaRequired.localizedDescription,
                       "Rejected: this task is verified; report the sha of your commit.")
        XCTAssertEqual(InboxError.invalidVerification("command is empty").localizedDescription,
                       "Rejected: invalid verify — command is empty.")
    }
}

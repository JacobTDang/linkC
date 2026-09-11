import XCTest
@testable import LinkCKit

final class InboxVerificationTests: XCTestCase {
    private var tempDir: URL!
    private var store: InboxStore!
    private let base = String(repeating: "b", count: 40)
    private let sha = String(repeating: "d", count: 40)

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-verify-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = InboxStore(workspaceRoot: tempDir.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private func verification(base other: String? = nil) -> Verification {
        Verification(branch: "task/x", baseSha: other ?? base, command: "./check.sh", testPaths: ["check.sh"])
    }

    private func verdict(passed: Bool, sha: String? = nil, exit: Int32? = nil, reason: String? = nil) -> Verdict {
        Verdict(passed: passed, sha: sha, exitStatus: exit, reason: reason, stdoutTail: "", stderrTail: "")
    }

    /// A verified task past its gate and delivered to session "s".
    private func deliveredVerifiedTask(_ prompt: String = "Make check pass") throws -> TaskRecord {
        let task = try store.createTask(from: .claude, to: .codex, prompt: prompt, files: [], verification: verification())
        try store.resolveGate(taskId: task.id, verdict: verdict(passed: true, sha: base, exit: 1))
        try store.markTaskDelivered(taskId: task.id, sessionId: "s")
        return try XCTUnwrap(store.task(id: task.id))
    }

    private func deliveredPlainTask(_ prompt: String = "Plain") throws -> TaskRecord {
        let task = try store.createTask(from: .claude, to: .codex, prompt: prompt, files: [])
        try store.markTaskDelivered(taskId: task.id, sessionId: "s")
        return task
    }

    func testVerifiedTaskStartsGatingAndPlainTaskStartsQueued() throws {
        XCTAssertEqual(try store.createTask(from: .claude, to: .codex, prompt: "V", files: [], verification: verification()).state, .gating)
        XCTAssertEqual(try store.createTask(from: .claude, to: .codex, prompt: "P", files: []).state, .queued)
    }

    func testInvalidVerificationIsRejected() {
        let bad = Verification(branch: "task/x", baseSha: base, command: " ", testPaths: ["check.sh"])
        XCTAssertThrowsError(try store.createTask(from: .claude, to: .codex, prompt: "V", files: [], verification: bad)) {
            XCTAssertEqual($0 as? InboxError, .invalidVerification("command is empty"))
        }
    }

    func testDedupeKeyIncludesTheBase() throws {
        let first = try store.createTask(from: .claude, to: .codex, prompt: "Same", files: [], verification: verification())
        let again = try store.createTask(from: .claude, to: .codex, prompt: "Same", files: [], verification: verification())
        let rebased = try store.createTask(from: .claude, to: .codex, prompt: "Same", files: [],
                                           verification: verification(base: String(repeating: "e", count: 40)))
        XCTAssertEqual(again.id, first.id)
        XCTAssertNotEqual(rebased.id, first.id)
    }

    func testResolveGate() throws {
        let red = try store.createTask(from: .claude, to: .codex, prompt: "Red", files: [], verification: verification())
        try store.resolveGate(taskId: red.id, verdict: verdict(passed: true, sha: base, exit: 1))
        let queued = try XCTUnwrap(store.task(id: red.id))
        XCTAssertEqual(queued.state, .queued)
        XCTAssertEqual(queued.gate?.exitStatus, 1)

        let green = try store.createTask(from: .claude, to: .codex, prompt: "Green", files: [], verification: verification())
        try store.resolveGate(taskId: green.id, verdict: verdict(passed: false, sha: base, exit: 0,
                                                                  reason: "tests already pass at bbbbbbb; brief refused"))
        let cancelled = try XCTUnwrap(store.task(id: green.id))
        XCTAssertEqual(cancelled.state, .cancelled)
        XCTAssertEqual(cancelled.cancelReason, "tests already pass at bbbbbbb; brief refused")
        XCTAssertNotNil(cancelled.finishedAt)

        XCTAssertThrowsError(try store.resolveGate(taskId: red.id, verdict: verdict(passed: true)), "only a gating task has a gate")
    }

    func testReportTaskMovesToReportedAndExtendsTheLease() throws {
        let task = try deliveredVerifiedTask()
        let before = Date()
        try store.reportTask(taskId: task.id, report: TaskReport(status: "done", summary: "did it", sha: sha))
        let reported = try XCTUnwrap(store.task(id: task.id))
        XCTAssertEqual(reported.state, .reported)
        XCTAssertEqual(reported.report?.sha, sha)
        XCTAssertGreaterThanOrEqual(reported.leaseExpiresAt.timeIntervalSince(before), TaskRecord.leaseDuration - 1)
        XCTAssertTrue(try store.load().messages.isEmpty, "reporting sends nothing")
    }

    func testSummaryLimit() throws {
        let ok = try deliveredPlainTask("Ok")
        XCTAssertNoThrow(try store.reportTask(taskId: ok.id, report: TaskReport(status: "done", summary: String(repeating: "a", count: 1_000))))
        let long = try deliveredPlainTask("Long")
        XCTAssertThrowsError(try store.reportTask(taskId: long.id, report: TaskReport(status: "done", summary: String(repeating: "a", count: 1_001)))) {
            XCTAssertEqual($0 as? InboxError, .summaryTooLong(count: 1_001))
        }
    }

    func testShaIsRequiredOnlyForAVerifiedDoneReport() throws {
        let verified = try deliveredVerifiedTask()
        XCTAssertThrowsError(try store.reportTask(taskId: verified.id, report: TaskReport(status: "done", summary: "x"))) {
            XCTAssertEqual($0 as? InboxError, .shaRequired)
        }
        XCTAssertEqual(try store.task(id: verified.id)?.state, .delivered)
        XCTAssertNoThrow(try store.reportTask(taskId: verified.id, report: TaskReport(status: "failed", summary: "gave up")))
        let plain = try deliveredPlainTask()
        XCTAssertNoThrow(try store.reportTask(taskId: plain.id, report: TaskReport(status: "done", summary: "x")))
    }

    func testReportStatusMustBeDoneOrFailed() throws {
        let task = try deliveredPlainTask()
        XCTAssertThrowsError(try store.reportTask(taskId: task.id, report: TaskReport(status: "maybe", summary: "x"))) {
            XCTAssertEqual($0 as? InboxError, .invalidReportStatus("maybe"))
        }
    }

    func testAdjudicate() throws {
        let pass = try deliveredVerifiedTask("Pass")
        try store.reportTask(taskId: pass.id, report: TaskReport(status: "done", summary: "x", sha: sha))
        try store.adjudicate(taskId: pass.id, verdict: verdict(passed: true, sha: sha, exit: 0))
        let done = try XCTUnwrap(store.task(id: pass.id))
        XCTAssertEqual(done.state, .done)
        XCTAssertEqual(done.verdict?.sha, sha)
        XCTAssertNotNil(done.finishedAt)

        let fail = try deliveredVerifiedTask("Fail")
        try store.reportTask(taskId: fail.id, report: TaskReport(status: "done", summary: "x", sha: sha))
        try store.adjudicate(taskId: fail.id, verdict: verdict(passed: false, sha: sha, exit: 1, reason: "tests failed at ddddddd (exit 1)"))
        XCTAssertEqual(try store.task(id: fail.id)?.state, .failed)

        let plain = try deliveredPlainTask()
        try store.reportTask(taskId: plain.id, report: TaskReport(status: "done", summary: "x"))
        XCTAssertThrowsError(try store.adjudicate(taskId: plain.id, verdict: verdict(passed: true))) {
            XCTAssertEqual($0 as? InboxError, .notVerified(plain.id))
        }

        let early = try deliveredVerifiedTask("Early")
        XCTAssertThrowsError(try store.adjudicate(taskId: early.id, verdict: verdict(passed: true)), "only a reported task can be adjudicated")
    }

    func testAcceptUnverified() throws {
        let done = try deliveredPlainTask("Done")
        try store.reportTask(taskId: done.id, report: TaskReport(status: "done", summary: "x"))
        try store.acceptUnverified(taskId: done.id)
        XCTAssertEqual(try store.task(id: done.id)?.state, .done)

        let failed = try deliveredPlainTask("Failed")
        try store.reportTask(taskId: failed.id, report: TaskReport(status: "failed", summary: "x"))
        try store.acceptUnverified(taskId: failed.id)
        XCTAssertEqual(try store.task(id: failed.id)?.state, .failed)

        let verified = try deliveredVerifiedTask()
        try store.reportTask(taskId: verified.id, report: TaskReport(status: "done", summary: "x", sha: sha))
        XCTAssertThrowsError(try store.acceptUnverified(taskId: verified.id)) {
            XCTAssertEqual($0 as? InboxError, .verificationPresent(verified.id))
        }
    }

    func testFailTask() throws {
        let task = try deliveredPlainTask()
        try store.markTaskStarted(taskId: task.id)
        try store.failTask(taskId: task.id, reason: "assignee session ended before reporting")
        let failed = try XCTUnwrap(store.task(id: task.id))
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.cancelReason, "assignee session ended before reporting")

        let reported = try deliveredPlainTask("Reported")
        try store.reportTask(taskId: reported.id, report: TaskReport(status: "done", summary: "x"))
        XCTAssertThrowsError(try store.failTask(taskId: reported.id, reason: "x"), "the relay settles a reported task")
    }

    func testCreateTaskWithAPassedGateStartsQueuedAndKeepsTheGate() throws {
        let gate = verdict(passed: true, sha: base, exit: 1)
        let task = try store.createTask(from: .claude, to: .codex, prompt: "Rerouted", files: [], verification: verification(), gate: gate)
        XCTAssertEqual(task.state, .queued)
        XCTAssertEqual(task.gate, gate)
        let stored = try XCTUnwrap(store.task(id: task.id))
        XCTAssertEqual(stored.state, .queued)
        XCTAssertEqual(stored.gate?.passed, true)
    }

    func testCreateTaskRejectsAGateThatDidNotPass() throws {
        let refused = verdict(passed: false, sha: base, exit: 0, reason: "tests already pass at bbbbbbb; brief refused")
        XCTAssertThrowsError(try store.createTask(from: .claude, to: .codex, prompt: "Rerouted", files: [], verification: verification(), gate: refused)) {
            XCTAssertEqual($0 as? InboxError, .invalidVerification("the gate did not pass"))
        }
        XCTAssertThrowsError(try store.createTask(from: .claude, to: .codex, prompt: "Plain", files: [], gate: verdict(passed: true, sha: base, exit: 1))) {
            XCTAssertEqual($0 as? InboxError, .invalidVerification("a gate needs a verification"))
        }
        XCTAssertTrue(try store.load().tasks.isEmpty, "a rejected gate creates no task")
    }
}

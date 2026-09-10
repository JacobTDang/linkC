import XCTest
@testable import LinkCKit

final class InboxTaskLifecycleTests: XCTestCase {
    var tempDir: URL!
    var store: InboxStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-task-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = InboxStore(workspaceRoot: tempDir.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    func testCreateTaskStoresQueuedRecordWithLease() throws {
        let before = Date()
        let task = try store.createTask(from: .claude, to: .codex, prompt: "Build parser", files: ["Sources/P.swift"])
        XCTAssertEqual(task.state, .queued)
        XCTAssertEqual(task.fromAgent, .claude)
        XCTAssertEqual(task.toAgent, .codex)
        XCTAssertEqual(task.files, ["Sources/P.swift"])
        XCTAssertEqual(task.hop, 0)
        XCTAssertGreaterThanOrEqual(task.leaseExpiresAt.timeIntervalSince(before), TaskRecord.leaseDuration - 1)
        XCTAssertEqual(try store.load().tasks.count, 1)
        XCTAssertEqual(try store.task(id: task.id)?.id, task.id)
    }

    func testCreateTaskIsIdempotentForSameAssigneeAndPrompt() throws {
        let a = try store.createTask(from: .claude, to: .codex, prompt: "Same brief", files: [])
        let b = try store.createTask(from: .claude, to: .codex, prompt: "Same brief", files: [])
        XCTAssertEqual(a.id, b.id)
        XCTAssertEqual(try store.load().tasks.count, 1)
    }

    func testCreateTaskRefusesLeaseConflictAndForceOverrides() throws {
        let holder = try store.createTask(from: .claude, to: .codex, prompt: "Own Auth", files: ["Auth.swift", "Other.swift"])
        XCTAssertThrowsError(try store.createTask(from: .claude, to: .cursor, prompt: "Also Auth", files: ["Auth.swift"])) { error in
            guard case InboxError.leaseConflict(let holders) = error else { return XCTFail("Expected leaseConflict, got \(error)") }
            XCTAssertEqual(holders.map(\.id), [holder.id])
        }
        // Same assignee on the same files queues behind
        XCTAssertNoThrow(try store.createTask(from: .claude, to: .codex, prompt: "More Auth", files: ["Auth.swift"]))
        // force overrides
        let forced = try store.createTask(from: .claude, to: .cursor, prompt: "Also Auth", files: ["Auth.swift"], force: true)
        XCTAssertEqual(forced.toAgent, .cursor)
    }

    func testTerminalTasksReleaseLease() throws {
        let holder = try store.createTask(from: .claude, to: .codex, prompt: "Own Auth", files: ["Auth.swift"])
        try store.cancelTask(taskId: holder.id, reason: "test")
        XCTAssertNoThrow(try store.createTask(from: .claude, to: .cursor, prompt: "Also Auth", files: ["Auth.swift"]))
    }

    func testCreateTaskRejectsFramedPromptAndHopLimit() throws {
        XCTAssertThrowsError(try store.createTask(from: .claude, to: .codex, prompt: "[linkC task abcd1234 from Claude]\nx", files: [])) {
            XCTAssertEqual($0 as? InboxError, .framedBody)
        }
        XCTAssertThrowsError(try store.createTask(from: .claude, to: .codex, prompt: "ok", files: [], hop: 3)) {
            XCTAssertEqual($0 as? InboxError, .hopLimit(3))
        }
    }

    func testHappyPathTransitionsStampDates() throws {
        let task = try store.createTask(from: .claude, to: .codex, prompt: "Do it", files: [])
        try store.markTaskDelivered(taskId: task.id, sessionId: "sess-1")
        var t = try XCTUnwrap(store.task(id: task.id))
        XCTAssertEqual(t.state, .delivered)
        XCTAssertEqual(t.assigneeSessionId, "sess-1")
        XCTAssertNotNil(t.deliveredAt)

        let leaseBefore = t.leaseExpiresAt
        try store.markTaskStarted(taskId: task.id)
        t = try XCTUnwrap(store.task(id: task.id))
        XCTAssertEqual(t.state, .started)
        XCTAssertNotNil(t.startedAt)
        XCTAssertGreaterThanOrEqual(t.leaseExpiresAt, leaseBefore)

        try store.completeTask(taskId: task.id, report: TaskReport(status: "done", summary: "Shipped", commits: ["abc123"], tests: ["swift test"]))
        t = try XCTUnwrap(store.task(id: task.id))
        XCTAssertEqual(t.state, .done)
        XCTAssertEqual(t.report?.summary, "Shipped")
        XCTAssertNotNil(t.finishedAt)
    }

    func testCompleteWithFailedStatusSetsFailedState() throws {
        let task = try store.createTask(from: .claude, to: .codex, prompt: "Do it", files: [])
        try store.markTaskDelivered(taskId: task.id, sessionId: "s")
        try store.completeTask(taskId: task.id, report: TaskReport(status: "failed", summary: "Build broke"))
        XCTAssertEqual(try store.task(id: task.id)?.state, .failed)
    }

    func testIllegalTransitionsThrow() throws {
        let task = try store.createTask(from: .claude, to: .codex, prompt: "Do it", files: [])
        XCTAssertThrowsError(try store.markTaskStarted(taskId: task.id)) {
            XCTAssertEqual($0 as? InboxError, .illegalTransition(taskId: task.id, from: .queued, to: .started))
        }
        try store.cancelTask(taskId: task.id, reason: "nah")
        XCTAssertThrowsError(try store.markTaskDelivered(taskId: task.id, sessionId: "s"))
        XCTAssertThrowsError(try store.completeTask(taskId: task.id, report: TaskReport(status: "done", summary: "x")))
        XCTAssertNil(try store.task(id: "missing"))
        XCTAssertThrowsError(try store.markTaskStarted(taskId: "missing")) {
            XCTAssertEqual($0 as? InboxError, .taskNotFound("missing"))
        }
    }

    func testCompleteRejectsEmptySummary() throws {
        let task = try store.createTask(from: .claude, to: .codex, prompt: "Do it", files: [])
        try store.markTaskDelivered(taskId: task.id, sessionId: "s")
        XCTAssertThrowsError(try store.completeTask(taskId: task.id, report: TaskReport(status: "done", summary: "   "))) {
            XCTAssertEqual($0 as? InboxError, .emptySummary)
        }
    }

    func testOpenTasksFiltersByAssigneeAndOrdersOldestFirst() throws {
        let a = try store.createTask(from: .claude, to: .codex, prompt: "A", files: [])
        let b = try store.createTask(from: .claude, to: .cursor, prompt: "B", files: [])
        let c = try store.createTask(from: .agy, to: .codex, prompt: "C", files: [])
        try store.cancelTask(taskId: b.id, reason: "x")
        XCTAssertEqual(try store.openTasks().map(\.id), [a.id, c.id])
        XCTAssertEqual(try store.openTasks(for: .codex).map(\.id), [a.id, c.id])
        XCTAssertEqual(try store.openTasks(for: .cursor), [])
    }

    func testExpireAndUnreportedFlag() throws {
        let task = try store.createTask(from: .claude, to: .codex, prompt: "Do it", files: [])
        try store.markUnreportedTurnEndNotified(taskId: task.id)
        XCTAssertTrue(try XCTUnwrap(store.task(id: task.id)).unreportedTurnEndNotified)
        try store.expireTask(taskId: task.id, reason: "workspace missing")
        let t = try XCTUnwrap(store.task(id: task.id))
        XCTAssertEqual(t.state, .expired)
        XCTAssertEqual(t.cancelReason, "workspace missing")
    }

    func testTerminalTasksOlderThan24hArePrunedOnSave() throws {
        var inbox = Inbox(workspacePath: tempDir.path)
        let old = Date().addingTimeInterval(-26 * 3600)
        inbox.tasks = [
            TaskRecord(id: "old-done", fromAgent: .claude, toAgent: .codex, prompt: "x", state: .done, createdAt: old, finishedAt: old),
            TaskRecord(id: "old-open", fromAgent: .claude, toAgent: .codex, prompt: "y", state: .started, createdAt: old),
            TaskRecord(id: "new-done", fromAgent: .claude, toAgent: .codex, prompt: "z", state: .done, finishedAt: Date())
        ]
        try store.saveRaw(inbox)
        let ids = Set(try store.load().tasks.map(\.id))
        XCTAssertEqual(ids, ["old-open", "new-done"])
    }
}

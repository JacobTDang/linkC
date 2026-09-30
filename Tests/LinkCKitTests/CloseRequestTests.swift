import XCTest
@testable import LinkCKit

final class CloseRequestTests: XCTestCase {
    var tempDir: URL!
    var store: InboxStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-close-request-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = InboxStore(workspaceRoot: tempDir.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    /// A task delivered to session "W" and left in `state`.
    private func delivered(_ state: TaskState = .reported, prompt: String = "brief") throws -> TaskRecord {
        let task = try store.createTask(from: .claude, to: .codex, prompt: prompt, files: [])
        try store.markTaskDelivered(taskId: task.id, sessionId: "W")
        switch state {
        case .delivered: break
        case .started: try store.markTaskStarted(taskId: task.id)
        case .reported:
            try store.reportTask(taskId: task.id, report: TaskReport(status: "done", summary: "did it"))
        case .cancelled: try store.cancelTask(taskId: task.id, reason: "not needed")
        case .done:
            try store.reportTask(taskId: task.id, report: TaskReport(status: "done", summary: "did it"))
            try store.acceptUnverified(taskId: task.id)
        default: XCTFail("unsupported state \(state)")
        }
        return try XCTUnwrap(store.task(id: task.id))
    }

    // MARK: - Recording a request

    func testARequestIsRecordedOnTheTaskAndStartsPending() throws {
        let task = try delivered()

        let request = try store.requestClose(taskId: task.id, by: .delegator)

        let stored = try XCTUnwrap(store.task(id: task.id)?.closeRequest)
        XCTAssertEqual(stored.id, request.id)
        XCTAssertEqual(stored.by, .delegator)
        XCTAssertTrue(stored.isPending)
    }

    func testARequestIsAcceptedOnAReportedOrEndedTask() throws {
        for state in [TaskState.reported, .done, .cancelled] {
            let task = try delivered(state, prompt: "brief \(state)")
            XCTAssertNoThrow(try store.requestClose(taskId: task.id, by: .delegator), "\(state)")
            if state.isOpen { try store.cancelTask(taskId: task.id, reason: "next case") }
        }
    }

    func testARequestIsRefusedWhileTheTaskIsStillRunning() throws {
        for state in [TaskState.delivered, .started] {
            let task = try delivered(state, prompt: "brief \(state)")
            XCTAssertThrowsError(try store.requestClose(taskId: task.id, by: .delegator), "\(state)") { error in
                let text = error.localizedDescription
                XCTAssertTrue(text.contains(state.rawValue), text)
                XCTAssertTrue(text.contains("linkc_cancel_task"), text)
            }
            XCTAssertNil(try store.task(id: task.id)?.closeRequest, "a refused request must leave no trace")
            try store.cancelTask(taskId: task.id, reason: "next case")
        }
    }

    func testARequestIsRefusedForATaskThatWasNeverDelivered() throws {
        let queued = try store.createTask(from: .claude, to: .codex, prompt: "never delivered", files: [])

        XCTAssertThrowsError(try store.requestClose(taskId: queued.id, by: .delegator)) { error in
            XCTAssertTrue(error.localizedDescription.contains("never delivered"), "\(error)")
        }
    }

    func testARequestIsRefusedWhileTheWorkerHoldsAnotherOpenTask() throws {
        let ended = try delivered(.cancelled, prompt: "first")
        let other = try delivered(.started, prompt: "second")

        XCTAssertThrowsError(try store.requestClose(taskId: ended.id, by: .delegator)) { error in
            XCTAssertTrue(error.localizedDescription.contains(other.shortId), "\(error)")
        }
        XCTAssertNil(try store.task(id: ended.id)?.closeRequest)
    }

    func testAnotherSessionsOpenTaskDoesNotBlockTheRequest() throws {
        let mine = try delivered(.cancelled, prompt: "mine")
        let theirs = try store.createTask(from: .claude, to: .codex, prompt: "theirs", files: [])
        try store.markTaskDelivered(taskId: theirs.id, sessionId: "other")

        XCTAssertNoThrow(try store.requestClose(taskId: mine.id, by: .delegator))
    }

    func testAnUnknownTaskIsAnError() throws {
        XCTAssertThrowsError(try store.requestClose(taskId: "nope", by: .delegator)) {
            XCTAssertEqual($0 as? InboxError, .taskNotFound("nope"))
        }
    }

    func testAnIdenticalPendingRequestIsNotRecordedTwice() throws {
        let task = try delivered()
        let first = try store.requestClose(taskId: task.id, by: .worker)

        let second = try store.requestClose(taskId: task.id, by: .worker)

        XCTAssertEqual(second.id, first.id)
    }

    func testARequestFromTheOtherSideReplacesAPendingOne() throws {
        let task = try delivered()
        let fromWorker = try store.requestClose(taskId: task.id, by: .worker)

        let fromDelegator = try store.requestClose(taskId: task.id, by: .delegator)

        XCTAssertNotEqual(fromDelegator.id, fromWorker.id)
        XCTAssertEqual(try store.task(id: task.id)?.closeRequest?.by, .delegator)
    }

    func testAResolvedRequestCanBeAskedAgain() throws {
        let task = try delivered()
        let first = try store.requestClose(taskId: task.id, by: .delegator)
        try store.resolveCloseRequest(taskId: task.id, outcome: .refused("busy"))

        let again = try store.requestClose(taskId: task.id, by: .delegator)

        XCTAssertNotEqual(again.id, first.id)
        XCTAssertTrue(try XCTUnwrap(store.task(id: task.id)?.closeRequest).isPending)
    }

    // MARK: - Recording the outcome

    func testTheOutcomeIsRecordedOnceAndKeptOnceResolved() throws {
        let task = try delivered()
        _ = try store.requestClose(taskId: task.id, by: .delegator)
        let at = Date(timeIntervalSince1970: 1_800_000_000)

        try store.resolveCloseRequest(taskId: task.id, outcome: .closed(at: at))
        try store.resolveCloseRequest(taskId: task.id, outcome: .refused("late"))

        let stored = try XCTUnwrap(store.task(id: task.id)?.closeRequest)
        XCTAssertEqual(stored.closedAt, at)
        XCTAssertNil(stored.refusal, "an answered request keeps its first answer")
        XCTAssertFalse(stored.isPending)
    }

    func testARefusalIsRecordedWithItsReason() throws {
        let task = try delivered()
        _ = try store.requestClose(taskId: task.id, by: .delegator)

        try store.resolveCloseRequest(taskId: task.id, outcome: .refused("the user has it open"))

        let stored = try XCTUnwrap(store.task(id: task.id)?.closeRequest)
        XCTAssertEqual(stored.refusal, "the user has it open")
        XCTAssertNil(stored.closedAt)
        XCTAssertFalse(stored.isPending)
    }

    func testResolvingAnUnknownTaskIsAnError() throws {
        XCTAssertThrowsError(try store.resolveCloseRequest(taskId: "nope", outcome: .refused("x"))) {
            XCTAssertEqual($0 as? InboxError, .taskNotFound("nope"))
        }
    }

    // MARK: - The file format

    private func rewriteTasks(_ change: (inout [String: Any]) -> Void) throws {
        let path = tempDir.appendingPathComponent(".linkc/inbox.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        var tasks = try XCTUnwrap(json["tasks"] as? [[String: Any]])
        for i in tasks.indices { change(&tasks[i]) }
        json["tasks"] = tasks
        try JSONSerialization.data(withJSONObject: json).write(to: path)
    }

    /// A record written before this field existed decodes through the store's own decoder: a
    /// decode failure there takes the whole inbox down.
    func testARowWrittenBeforeCloseRequestsDecodes() throws {
        let task = try delivered()
        _ = try store.requestClose(taskId: task.id, by: .delegator)
        try rewriteTasks { $0.removeValue(forKey: "closeRequest") }

        let reloaded = try XCTUnwrap(store.load().tasks.first)

        XCTAssertNil(reloaded.closeRequest)
        XCTAssertEqual(reloaded.id, task.id)
    }

    /// A task with no request writes exactly the fields an older build reads, so a workspace that
    /// never closes a worker stays byte-compatible with it. An older build ignores the key on a
    /// task that has one; it loses the request when it next saves, and the caller sees no answer.
    func testATaskWithoutARequestWritesNoCloseRequestKey() throws {
        _ = try delivered()

        let raw = try String(contentsOf: tempDir.appendingPathComponent(".linkc/inbox.json"), encoding: .utf8)

        XCTAssertFalse(raw.contains("closeRequest"))
    }

    func testARequestSurvivesAReload() throws {
        let task = try delivered()
        let request = try store.requestClose(taskId: task.id, by: .worker)
        try store.resolveCloseRequest(taskId: task.id, outcome: .refused("why"))

        let reloaded = try XCTUnwrap(InboxStore(workspaceRoot: tempDir.path).task(id: task.id)?.closeRequest)

        XCTAssertEqual(reloaded.id, request.id)
        XCTAssertEqual(reloaded.by, .worker)
        XCTAssertEqual(reloaded.refusal, "why")
    }
}

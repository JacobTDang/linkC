import XCTest
@testable import LinkCKit

final class MCPServerTaskTests: XCTestCase {
    var tempDir: URL!
    var inbox: InboxStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-mcp-task-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        inbox = InboxStore(workspaceRoot: tempDir.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private func server(as agent: AgentKind) -> MCPServer {
        MCPServer(workspaceRoot: tempDir.path, environment: ["LINKC_AGENT": agent.rawValue], ancestorResolver: { _ in nil })
    }

    private func call(_ server: MCPServer, _ name: String, _ args: [String: Any] = [:]) throws -> (text: String, isError: Bool) {
        let req: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": args]]
        let data = try JSONSerialization.data(withJSONObject: req)
        let res = try XCTUnwrap(server.handleMessage(data))
        let json = try JSONSerialization.jsonObject(with: res) as? [String: Any]
        let result = json?["result"] as? [String: Any]
        let text = ((result?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        return (text, result?["isError"] as? Bool ?? false)
    }

    func testStartTaskMovesDeliveredToStarted() throws {
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "Build", files: [])
        try inbox.markTaskDelivered(taskId: task.id, sessionId: "s1")
        let res = try call(server(as: .codex), "linkc_start_task", ["task_id": task.id])
        XCTAssertFalse(res.isError, res.text)
        XCTAssertEqual(try inbox.task(id: task.id)?.state, .started)
        XCTAssertTrue(res.text.contains(task.shortId))
    }

    func testStartTaskOnQueuedTaskIsAnError() throws {
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "Build", files: [])
        let res = try call(server(as: .codex), "linkc_start_task", ["task_id": task.id])
        XCTAssertTrue(res.isError)
        XCTAssertTrue(res.text.contains("queued"))
    }

    func testStartTaskByNonAssigneeIsRejected() throws {
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "Build", files: [])
        try inbox.markTaskDelivered(taskId: task.id, sessionId: "s1")

        let res = try call(server(as: .agy), "linkc_start_task", ["task_id": task.id])

        XCTAssertTrue(res.isError)
        XCTAssertTrue(res.text.contains("assigned to Codex"))
        XCTAssertEqual(try inbox.task(id: task.id)?.state, .delivered)
    }

    func testCompleteTaskRecordsReportEnqueuesOneLineAndPostsNote() throws {
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "Build the very long brief that must not be echoed back in full " + String(repeating: "x", count: 500), files: [])
        try inbox.markTaskDelivered(taskId: task.id, sessionId: "s1")
        let srv = server(as: .codex)
        let res = try call(srv, "linkc_complete_task", [
            "task_id": task.id, "status": "done", "summary": "Implemented and tested.",
            "commits": ["abc1234"], "tests": ["swift test --filter Foo"]
        ])
        XCTAssertFalse(res.isError, res.text)

        let t = try XCTUnwrap(inbox.task(id: task.id))
        XCTAssertEqual(t.state, .done)
        XCTAssertEqual(t.report?.commits, ["abc1234"])

        let msgs = try inbox.load().messages
        XCTAssertEqual(msgs.count, 1)
        let echo = try XCTUnwrap(msgs.first)
        XCTAssertEqual(echo.kind, .completion)
        XCTAssertEqual(echo.toAgent, .claude)
        XCTAssertEqual(echo.fromAgent, .codex)
        XCTAssertEqual(echo.taskId, task.id)
        XCTAssertTrue(echo.prompt.hasPrefix("[linkC task \(task.shortId)] done by Codex"))
        XCTAssertFalse(echo.prompt.contains("xxxxxxxxxx"), "echo must not carry the brief")
        XCTAssertLessThan(echo.prompt.count, 400)

        let notes = try srv.store.load().sharedNotes
        XCTAssertTrue(notes.contains { $0.title == "Task \(task.shortId) done" && $0.content.contains("abc1234") })
    }

    func testCompleteTaskByNonAssigneeIsRejected() throws {
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "Build", files: [])
        try inbox.markTaskDelivered(taskId: task.id, sessionId: "s1")

        let res = try call(server(as: .agy), "linkc_complete_task", [
            "task_id": task.id,
            "status": "done",
            "summary": "Implemented."
        ])

        XCTAssertTrue(res.isError)
        XCTAssertTrue(res.text.contains("assigned to Codex"))
        XCTAssertEqual(try inbox.task(id: task.id)?.state, .delivered)
        XCTAssertFalse(try inbox.load().messages.contains { $0.kind == .completion })
    }

    func testCompleteTaskSucceedsWhenEchoEnqueueFails() throws {
        let task = try inbox.createTask(from: .codex, to: .codex, prompt: "Build", files: [])
        try inbox.markTaskDelivered(taskId: task.id, sessionId: "s1")

        let res = try call(server(as: .codex), "linkc_complete_task", [
            "task_id": task.id,
            "status": "done",
            "summary": "Implemented."
        ])

        XCTAssertFalse(res.isError, res.text)
        XCTAssertTrue(res.text.hasPrefix("Reported done"))
        XCTAssertEqual(try inbox.task(id: task.id)?.state, .done)
    }

    func testCompleteTaskRequiresSummaryAndValidStatus() throws {
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "Build", files: [])
        try inbox.markTaskDelivered(taskId: task.id, sessionId: "s1")
        let srv = server(as: .codex)
        XCTAssertTrue(try call(srv, "linkc_complete_task", ["task_id": task.id, "status": "done", "summary": ""]).isError)
        XCTAssertTrue(try call(srv, "linkc_complete_task", ["task_id": task.id, "status": "maybe", "summary": "x"]).isError)
        XCTAssertTrue(try call(srv, "linkc_complete_task", ["task_id": "nope", "status": "done", "summary": "x"]).isError)
        XCTAssertEqual(try inbox.task(id: task.id)?.state, .delivered)
    }

    func testCancelTaskByDelegatorInjectsOneLineToAssignee() throws {
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "Build", files: [])
        try inbox.markTaskDelivered(taskId: task.id, sessionId: "s1")
        let res = try call(server(as: .claude), "linkc_cancel_task", ["task_id": task.id, "reason": "scope changed"])
        XCTAssertFalse(res.isError, res.text)
        XCTAssertEqual(try inbox.task(id: task.id)?.state, .cancelled)
        let msg = try XCTUnwrap(inbox.load().messages.first)
        XCTAssertEqual(msg.toAgent, .codex)
        XCTAssertEqual(msg.kind, .completion)
        XCTAssertTrue(msg.prompt.contains("cancelled: scope changed"))
    }

    func testCancelQueuedTaskIsSilentAndThirdPartyNeedsForce() throws {
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "Build", files: [])
        let denied = try call(server(as: .cursor), "linkc_cancel_task", ["task_id": task.id])
        XCTAssertTrue(denied.isError)
        let forced = try call(server(as: .cursor), "linkc_cancel_task", ["task_id": task.id, "force": true])
        XCTAssertFalse(forced.isError, forced.text)
        XCTAssertTrue(try inbox.load().messages.isEmpty, "queued cancel must not inject anything")
    }

    func testGetTaskAndMyTasks() throws {
        let mine = try inbox.createTask(from: .claude, to: .codex, prompt: "Assigned to me", files: ["A.swift"])
        let delegated = try inbox.createTask(from: .codex, to: .cursor, prompt: "I delegated this", files: [])
        _ = try inbox.createTask(from: .claude, to: .agy, prompt: "Unrelated", files: [])

        let get = try call(server(as: .codex), "linkc_get_task", ["task_id": mine.id])
        XCTAssertFalse(get.isError)
        XCTAssertTrue(get.text.contains("Assigned to me"))
        XCTAssertTrue(get.text.contains("A.swift"))
        XCTAssertTrue(get.text.contains("queued"))

        let list = try call(server(as: .codex), "linkc_my_tasks")
        XCTAssertTrue(list.text.contains(mine.shortId))
        XCTAssertTrue(list.text.contains(delegated.shortId))
        XCTAssertFalse(list.text.contains("Unrelated"))
    }
}

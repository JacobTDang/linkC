import XCTest
@testable import LinkCKit

/// `linkc_send_message` and `linkc_switch_model` with a `task_id` reach the worker that holds that
/// task, not the first session of its agent (spec 2026-11-11 §5).
final class MCPServerTaskRoutingTests: XCTestCase {
    private var tempDir: URL!
    private var inbox: InboxStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-mcp-routing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        inbox = InboxStore(workspaceRoot: tempDir.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private func server(modelSwitcher: MCPServer.ModelSwitcher? = nil) -> MCPServer {
        MCPServer(workspaceRoot: tempDir.path, inboxStore: inbox, modelSwitcher: modelSwitcher,
                  environment: ["LINKC_AGENT": "claude"], ancestorResolver: { _ in nil },
                  modelSettings: { .seeded }, sessionResolver: { nil }, usageReaders: [:], kiloModels: { _ in [] }, modelLists: TestModelLists.none)
    }

    private func call(_ server: MCPServer, _ tool: String, _ arguments: [String: Any]) throws -> (text: String, isError: Bool) {
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                      "params": ["name": tool, "arguments": arguments]]
        let response = try XCTUnwrap(server.handleMessage(try JSONSerialization.data(withJSONObject: request)))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: response) as? [String: Any])
        let result = try XCTUnwrap(json["result"] as? [String: Any])
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        return (text, result["isError"] as? Bool ?? false)
    }

    private func codexTask(heldBy worker: String?) throws -> TaskRecord {
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "part \(UUID().uuidString)", files: [])
        if let worker { try inbox.markTaskDelivered(taskId: task.id, sessionId: worker) }
        return task
    }

    // MARK: - linkc_send_message

    func testAMessageWithATaskIdIsAddressedToThatTasksWorker() throws {
        _ = try codexTask(heldBy: "W1")
        let task = try codexTask(heldBy: "W2")

        let result = try call(server(), "linkc_send_message", ["to": "codex", "message": "also cover the edge case", "task_id": task.shortId])

        XCTAssertFalse(result.isError, result.text)
        let message = try XCTUnwrap(inbox.fetchPending().first)
        XCTAssertEqual(message.toSessionId, "W2")
        XCTAssertEqual(message.toAgent, .codex)
        XCTAssertNil(message.taskId, "taskId routes a notice to the delegator; a message to a worker must not set it")
    }

    func testAMessageWithoutATaskIdIsAddressedToNoSessionInParticular() throws {
        _ = try codexTask(heldBy: "W1")
        let result = try call(server(), "linkc_send_message", ["to": "codex", "message": "hello"])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertNil(try XCTUnwrap(inbox.fetchPending().first).toSessionId)
    }

    func testAMessageForAnUnknownTaskIsRefused() throws {
        let result = try call(server(), "linkc_send_message", ["to": "codex", "message": "hi", "task_id": "deadbeef"])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(try inbox.fetchPending().isEmpty)
    }

    func testAMessageForATaskNoWorkerHoldsYetIsRefusedWithTheReason() throws {
        let task = try codexTask(heldBy: nil)
        let result = try call(server(), "linkc_send_message", ["to": "codex", "message": "hi", "task_id": task.id])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("no worker"), result.text)
        XCTAssertTrue(try inbox.fetchPending().isEmpty)
    }

    func testAMessageForATaskOfAnotherAgentIsRefused() throws {
        let task = try codexTask(heldBy: "W1")
        let result = try call(server(), "linkc_send_message", ["to": "cursor", "message": "hi", "task_id": task.id])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("Codex"), result.text)
        XCTAssertTrue(try inbox.fetchPending().isEmpty)
    }

    func testTwoIdenticalMessagesForDifferentWorkersAreBothQueued() throws {
        let first = try codexTask(heldBy: "W1")
        let second = try codexTask(heldBy: "W2")
        _ = try call(server(), "linkc_send_message", ["to": "codex", "message": "rebase on main", "task_id": first.id])
        _ = try call(server(), "linkc_send_message", ["to": "codex", "message": "rebase on main", "task_id": second.id])
        XCTAssertEqual(Set(try inbox.fetchPending().compactMap(\.toSessionId)), ["W1", "W2"])
    }

    func testAMessageWrittenBeforeToSessionIdExistedStillDecodes() throws {
        let json = #"{"id":"M1","fromAgent":"claude","toAgent":"codex","prompt":"hi","status":"queued","createdAt":0}"#
        let message = try JSONDecoder().decode(PendingMessage.self, from: Data(json.utf8))
        XCTAssertNil(message.toSessionId)
    }

    // MARK: - linkc_switch_model

    func testAModelSwitchWithATaskIdIsAddressedToThatTasksWorkerAndTakesItsAgent() throws {
        let model = try XCTUnwrap(AgentModelSettings.seeded.model(for: .codex, tier: .light))
        let task = try codexTask(heldBy: "W2")

        let result = try call(server(), "linkc_switch_model", ["model": model, "task_id": task.id])

        XCTAssertFalse(result.isError, result.text)
        let command = try XCTUnwrap(inbox.fetchPending().first)
        XCTAssertEqual(command.kind, .command)
        XCTAssertEqual(command.toAgent, .codex)
        XCTAssertEqual(command.toSessionId, "W2")
    }

    func testTheInAppSwitcherIsGivenTheTasksWorker() throws {
        final class Seen: @unchecked Sendable { var sessionId: String?? }
        let seen = Seen()
        let model = try XCTUnwrap(AgentModelSettings.seeded.model(for: .codex, tier: .light))
        let task = try codexTask(heldBy: "W2")
        let switching = server(modelSwitcher: { _, _, sessionId, _ in
            seen.sessionId = sessionId
            return "switched"
        })

        let result = try call(switching, "linkc_switch_model", ["model": model, "task_id": task.id])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(seen.sessionId, .some("W2"))
    }

    func testAModelSwitchForATaskNoWorkerHoldsYetIsRefused() throws {
        let model = try XCTUnwrap(AgentModelSettings.seeded.model(for: .codex, tier: .light))
        let task = try codexTask(heldBy: nil)
        let result = try call(server(), "linkc_switch_model", ["model": model, "task_id": task.id])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(try inbox.fetchPending().isEmpty)
    }

    func testAModelSwitchNamingAnotherAgentThanItsTasksIsRefused() throws {
        let model = try XCTUnwrap(AgentModelSettings.seeded.model(for: .codex, tier: .light))
        let task = try codexTask(heldBy: "W1")
        let result = try call(server(), "linkc_switch_model", ["agent": "claude", "model": model, "task_id": task.id])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(try inbox.fetchPending().isEmpty)
    }
}

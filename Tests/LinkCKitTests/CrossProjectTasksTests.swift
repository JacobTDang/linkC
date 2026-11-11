import XCTest
@testable import LinkCKit

/// Cross-project tasks: return address, pointers, ask, and (later) pointer-following tools.
final class CrossProjectTasksTests: XCTestCase {
    private var tempDir: URL!
    private var home: URL!
    private var away: URL!
    private var file: KnownProjectsFile!
    private var homeInbox: InboxStore!
    private var awayInbox: InboxStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-xproj-tasks-\(UUID().uuidString)")
        home = tempDir.appendingPathComponent("money-printer")
        away = tempDir.appendingPathComponent("away")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: away, withIntermediateDirectories: true)
        file = KnownProjectsFile(url: tempDir.appendingPathComponent("projects.json"))
        homeInbox = InboxStore(workspaceRoot: home.path)
        awayInbox = InboxStore(workspaceRoot: away.path)
        try file.write([
            KnownProject(path: ProjectPath.canonical(home.path), sessions: [
                .init(id: "home-claude", agent: "claude", activity: .idle)
            ]),
            KnownProject(path: ProjectPath.canonical(away.path), sessions: [
                .init(id: "away-codex", agent: "codex", activity: .idle)
            ])
        ])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private func homeServer() -> MCPServer {
        MCPServer(workspaceRoot: home.path, inboxStore: homeInbox,
                  environment: ["LINKC_AGENT": "claude", "LINKC_SESSION": "home-claude"],
                  ancestorResolver: { _ in nil }, modelSettings: { .seeded },
                  sessionResolver: { nil }, usageReaders: [:], knownProjects: file)
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

    // MARK: - Model / store

    func testOldInboxWithoutSentTasksOrFromProjectStillLoads() throws {
        let json = """
        {"version":2,"workspacePath":"/p","updatedAt":"2026-01-01T00:00:00Z","messages":[],"agentLimits":[],"tasks":[{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","fromAgent":"claude","toAgent":"codex","prompt":"hi","files":[],"state":"queued","hop":0,"createdAt":"2026-01-01T00:00:00Z","leaseExpiresAt":"2026-01-01T04:00:00Z","unreportedTurnEndNotified":false}]}
        """
        let url = home.appendingPathComponent(".linkc/inbox.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
        let inbox = try homeInbox.load()
        XCTAssertTrue(inbox.sentTasks.isEmpty)
        XCTAssertNil(inbox.tasks.first?.fromProject)
        XCTAssertFalse(inbox.tasks.first?.isQuestion ?? true)
    }

    func testCreateTaskStoresFromProjectAndQuestion() throws {
        let task = try awayInbox.createTask(
            from: .claude, to: .codex, prompt: "q", files: [],
            fromProject: ProjectPath.canonical(home.path), isQuestion: true
        )
        XCTAssertEqual(task.fromProject, ProjectPath.canonical(home.path))
        XCTAssertTrue(task.isQuestion)
        XCTAssertEqual(task.question, true)
    }

    func testSentTaskPointerRoundTrip() throws {
        let id = UUID().uuidString
        try homeInbox.recordSent(SentTask(taskId: id, project: ProjectPath.canonical(away.path), fromSessionId: "home-claude"))
        let found = try XCTUnwrap(homeInbox.sentTask(matching: String(id.prefix(8))))
        XCTAssertEqual(found.taskId, id)
        XCTAssertEqual(try homeInbox.sentTasks().count, 1)
        try homeInbox.dropSent(taskId: id)
        XCTAssertTrue(try homeInbox.sentTasks().isEmpty)

        let a = "aaaaaaaa-1111-4111-8111-111111111111"
        let b = "aaaaaaaa-2222-4222-8222-222222222222"
        try homeInbox.recordSent(SentTask(taskId: a, project: "/p/a"))
        try homeInbox.recordSent(SentTask(taskId: b, project: "/p/b"))
        XCTAssertThrowsError(try homeInbox.sentTask(matching: "aaaaaaaa")) { error in
            guard case InboxError.ambiguousTaskId = error else {
                return XCTFail("expected ambiguousTaskId, got \(error)")
            }
        }
    }

    // MARK: - deliveryFrame

    @MainActor
    func testDeliveryFrameNamesTheSendingProjectAndQuestionInstructions() {
        let task = TaskRecord(
            fromAgent: .claude, toAgent: .codex, prompt: "What is the ledger?",
            fromProject: "/p/money-printer", isQuestion: true
        )
        let frame = AppCoordinator.deliveryFrame(for: task)
        XCTAssertTrue(frame.hasPrefix("\(LinkCFrame.taskPrefix) \(task.shortId) from money-printer · Claude Code]"), frame)
        XCTAssertTrue(frame.contains("This is a question from money-printer."), frame)
        XCTAssertTrue(frame.contains("linkc_complete_task(\"\(task.id)\""), frame)
        XCTAssertFalse(frame.contains("commit your work"), frame)

        let local = TaskRecord(fromAgent: .claude, toAgent: .codex, prompt: "work")
        let localFrame = AppCoordinator.deliveryFrame(for: local)
        XCTAssertTrue(localFrame.hasPrefix("\(LinkCFrame.taskPrefix) \(local.shortId) from Claude Code]"), localFrame)
        XCTAssertTrue(localFrame.contains("commit your work"), localFrame)
    }

    // MARK: - linkc_delegate_task(project:)

    func testDelegateTaskWithProjectWritesTargetAndPointer() throws {
        let result = try call(homeServer(), "linkc_delegate_task", [
            "project": "away", "to": "codex", "prompt": "fix the ledger"
        ])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("away") || result.text.lowercased().contains("away"), result.text)

        let task = try XCTUnwrap(awayInbox.openTasks().first)
        XCTAssertEqual(task.fromProject, ProjectPath.canonical(home.path))
        XCTAssertEqual(task.fromSessionId, "home-claude")
        XCTAssertEqual(task.toAgent, .codex)
        XCTAssertTrue(try homeInbox.fetchPending().isEmpty)

        let pointer = try XCTUnwrap(homeInbox.sentTasks().first)
        XCTAssertEqual(pointer.taskId, task.id)
        XCTAssertEqual(pointer.project, ProjectPath.canonical(away.path))
        XCTAssertEqual(pointer.fromSessionId, "home-claude")
        XCTAssertTrue(result.text.contains(task.shortId), result.text)
    }

    func testDelegateTaskUnknownProjectWritesNothing() throws {
        let result = try call(homeServer(), "linkc_delegate_task", [
            "project": "ghost", "to": "codex", "prompt": "nope"
        ])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(try awayInbox.openTasks().isEmpty)
        XCTAssertTrue(try homeInbox.sentTasks().isEmpty)
        XCTAssertTrue(try homeInbox.openTasks().isEmpty)
    }

    func testDelegateTaskRespectsLeaseInTargetProject() throws {
        _ = try awayInbox.createTask(from: .claude, to: .cursor, prompt: "hold", files: ["Sources/A.swift"])
        let result = try call(homeServer(), "linkc_delegate_task", [
            "project": "away", "to": "codex", "prompt": "also A", "files": ["Sources/A.swift"]
        ])
        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(result.text.lowercased().contains("lease") || result.text.lowercased().contains("refused"), result.text)
        XCTAssertEqual(try awayInbox.openTasks().count, 1)
        XCTAssertTrue(try homeInbox.sentTasks().isEmpty)
    }

    // MARK: - linkc_ask

    func testAskCreatesQuestionTaskAndPointer() throws {
        let result = try call(homeServer(), "linkc_ask", [
            "project": "away", "question": "How is the ledger?"
        ])
        XCTAssertFalse(result.isError, result.text)
        let task = try XCTUnwrap(awayInbox.openTasks().first)
        XCTAssertTrue(task.isQuestion)
        XCTAssertEqual(task.toAgent, .claude)
        XCTAssertTrue(task.files.isEmpty)
        XCTAssertEqual(task.fromProject, ProjectPath.canonical(home.path))
        XCTAssertEqual(try homeInbox.sentTasks().first?.taskId, task.id)
    }

    func testAskRefusesMissingArgsAndVerify() throws {
        XCTAssertTrue(try call(homeServer(), "linkc_ask", ["question": "x"]).isError)
        XCTAssertTrue(try call(homeServer(), "linkc_ask", ["project": "away"]).isError)
        let verified = try call(homeServer(), "linkc_ask", [
            "project": "away", "question": "x",
            "verify": ["branch": "b", "base_sha": "deadbeef", "command": "true", "test_paths": ["t"]]
        ])
        XCTAssertTrue(verified.isError)
        XCTAssertTrue(verified.text.lowercased().contains("verified") || verified.text.lowercased().contains("verify"), verified.text)
    }
}

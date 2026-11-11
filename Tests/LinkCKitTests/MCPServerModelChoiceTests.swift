import XCTest
@testable import LinkCKit

final class MCPServerModelChoiceTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-mcp-model-choice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private func lists(_ agents: [AgentKind: AgentModelList]) -> [AgentKind: AgentModelList] { agents }

    private func server(
        lists: [AgentKind: AgentModelList] = [:],
        openCodeModels: @escaping MCPServer.OpenCodeModelLister = { _ in
            ["opencode/big-pickle", "opencode/beam-free"]
        }
    ) -> MCPServer {
        MCPServer(
            workspaceRoot: tempDir.path,
            inboxStore: InboxStore(workspaceRoot: tempDir.path),
            environment: ["LINKC_AGENT": "claude"],
            ancestorResolver: { _ in nil },
            sessionResolver: { nil },
            usageReaders: [:],
            openCodeModels: openCodeModels,
            modelLists: { lists })
    }

    private func call(_ server: MCPServer, _ name: String, _ arguments: [String: Any] = [:]) throws -> (text: String, isError: Bool) {
        let request: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": name, "arguments": arguments],
        ]
        let data = try XCTUnwrap(server.handleMessage(try JSONSerialization.data(withJSONObject: request)))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try XCTUnwrap(json["result"] as? [String: Any])
        let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        return (text, result["isError"] as? Bool ?? false)
    }

    func testDelegateTaskWithModelCreatesTaskWithoutTier() throws {
        let lists = lists([
            .agy: AgentModelList(
                models: [ListedModel(id: "claude-opus-4-6-thinking", name: "Opus")],
                fetchedAt: Date(), error: nil),
        ])
        let result = try call(server(lists: lists), "linkc_delegate_task", [
            "to": "agy", "prompt": "Use Opus.", "model": "claude-opus-4-6-thinking",
        ])
        XCTAssertFalse(result.isError, result.text)
        let tasks = try InboxStore(workspaceRoot: tempDir.path).openTasks()
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?.model, "claude-opus-4-6-thinking")
        XCTAssertNil(tasks.first?.tier)
    }

    func testTierAndModelTogetherAreRefused() throws {
        let result = try call(server(), "linkc_delegate_task", [
            "to": "agy", "prompt": "x", "tier": "standard", "model": "claude-opus-4-6-thinking",
        ])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("pass tier or model, not both"), result.text)
        XCTAssertTrue(try InboxStore(workspaceRoot: tempDir.path).openTasks().isEmpty)
    }

    func testUnknownModelIsRefusedAndListsAvailable() throws {
        let lists = lists([
            .agy: AgentModelList(
                models: [
                    ListedModel(id: "gemini-3.8-flash-medium", name: "Flash"),
                    ListedModel(id: "claude-opus-4-6-thinking", name: "Opus"),
                ],
                fetchedAt: Date(), error: nil),
        ])
        let result = try call(server(lists: lists), "linkc_delegate_task", [
            "to": "agy", "prompt": "x", "model": "no-such-model",
        ])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("no-such-model"), result.text)
        XCTAssertTrue(result.text.contains("gemini-3.8-flash-medium"), result.text)
        XCTAssertTrue(result.text.contains("claude-opus-4-6-thinking"), result.text)
    }

    func testNonFreeOpenCodeModelIsRefusedAndListsFreeOnes() throws {
        let lists = lists([
            .opencode: AgentModelList(
                models: [
                    ListedModel(id: "opencode/big-pickle", name: "opencode/big-pickle"),
                    ListedModel(id: "opencode/beam-free", name: "opencode/beam-free"),
                ],
                fetchedAt: Date(), error: nil),
        ])
        let result = try call(server(lists: lists), "linkc_delegate_task", [
            "to": "opencode", "prompt": "x", "model": "opencode/claude-sonnet-5",
        ])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("not free"), result.text)
        XCTAssertTrue(result.text.contains("opencode/big-pickle"), result.text)
        XCTAssertTrue(result.text.contains("opencode/beam-free"), result.text)
    }

    func testGetModelsListsIdNameTierPoolAgeAndError() throws {
        let fetched = Date().addingTimeInterval(-120)
        let lists = lists([
            .agy: AgentModelList(
                models: [
                    ListedModel(id: "gemini-3.8-flash-medium", name: "Flash"),
                    ListedModel(id: "claude-opus-4-6-thinking", name: "Opus"),
                ],
                fetchedAt: fetched, error: "stale listing"),
        ])
        let result = try call(server(lists: lists), "linkc_get_models", ["agent": "agy"])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("gemini-3.8-flash-medium"), result.text)
        XCTAssertTrue(result.text.contains("Flash"), result.text)
        XCTAssertTrue(result.text.contains("tier standard"), result.text)
        XCTAssertTrue(result.text.contains("[pool Gemini]"), result.text)
        XCTAssertTrue(result.text.contains("[pool Claude/GPT]"), result.text)
        XCTAssertTrue(result.text.contains("ago"), result.text)
        XCTAssertTrue(result.text.contains("stale listing"), result.text)
    }

    func testSwitchModelRefusesAnIdNotListed() throws {
        let lists = lists([
            .claude: AgentModelList(
                models: [ListedModel(id: "haiku", name: "haiku"), ListedModel(id: "sonnet", name: "sonnet")],
                fetchedAt: Date(), error: nil),
        ])
        let result = try call(server(lists: lists), "linkc_switch_model", [
            "agent": "claude", "model": "luna",
        ])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("luna"), result.text)
        XCTAssertTrue(result.text.contains("haiku"), result.text)
        XCTAssertTrue(result.text.contains("sonnet"), result.text)
    }
}

final class SessionCanCarryModelTests: XCTestCase {
    func testCanCarryRequiresMatchingModel() {
        let task = TaskRecord(fromAgent: .claude, model: "claude-opus-4-6-thinking",
                              toAgent: .agy, prompt: "x")
        let matching = Session(id: "a", cwd: "/p", title: "a", agentKind: .agy,
                               model: "claude-opus-4-6-thinking")
        let other = Session(id: "b", cwd: "/p", title: "b", agentKind: .agy,
                            model: "gemini-3.8-flash-medium")
        XCTAssertTrue(matching.canCarry(task))
        XCTAssertFalse(other.canCarry(task))
    }
}

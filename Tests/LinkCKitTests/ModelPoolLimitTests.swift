import XCTest
@testable import LinkCKit

final class ModelPoolLimitTests: XCTestCase {
    private var tempDir: URL!
    private var store: InboxStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-pool-limit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = InboxStore(workspaceRoot: tempDir.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    func testAgyGeminiLimitDoesNotLimitClaudePool() throws {
        try store.recordLimit(agent: .agy, reason: "quota", cooldown: 3600, pool: "gemini")
        XCTAssertNotNil(try store.isAgentLimited(agent: .agy, model: "gemini-3.8-flash-medium"))
        XCTAssertNil(try store.isAgentLimited(agent: .agy, model: "claude-opus-4-6-thinking"))
        XCTAssertNil(try store.isAgentLimited(agent: .agy, model: "claude-sonnet-4-6"))
        XCTAssertNil(try store.isAgentLimited(agent: .agy, model: "gpt-oss-120b-medium"))
    }

    func testNilPoolLimitAppliesToEveryModel() throws {
        try store.recordLimit(agent: .agy, reason: "old row", cooldown: 3600, pool: nil)
        XCTAssertNotNil(try store.isAgentLimited(agent: .agy, model: "claude-opus-4-6-thinking"))
        XCTAssertNotNil(try store.isAgentLimited(agent: .agy, model: "gemini-3.8-flash-medium"))
        try store.recordLimit(agent: .codex, reason: "cap", cooldown: 3600)
        XCTAssertNotNil(try store.isAgentLimited(agent: .codex, model: "gpt-6-astra"))
    }

    func testDelegationRefusalNamesWhatIsNotLimited() throws {
        try store.recordLimit(agent: .agy, reason: "weekly", cooldown: 3600, pool: "gemini")
        let lists: [AgentKind: AgentModelList] = [
            .agy: AgentModelList(
                models: [
                    ListedModel(id: "claude-opus-4-6-thinking", name: "Opus"),
                    ListedModel(id: "claude-sonnet-4-6", name: "Sonnet"),
                    ListedModel(id: "gpt-oss-120b-medium", name: "GPT"),
                    ListedModel(id: "gemini-3.8-flash-medium", name: "Flash"),
                ],
                fetchedAt: Date(), error: nil),
        ]
        let server = MCPServer(
            workspaceRoot: tempDir.path,
            inboxStore: store,
            environment: ["LINKC_AGENT": "claude"],
            ancestorResolver: { _ in nil },
            sessionResolver: { nil },
            usageReaders: [:],
            modelLists: { lists })
        let request: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": [
                "name": "linkc_delegate_task",
                "arguments": ["to": "agy", "prompt": "x", "model": "gemini-3.8-flash-medium"],
            ],
        ]
        let data = try XCTUnwrap(server.handleMessage(try JSONSerialization.data(withJSONObject: request)))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try XCTUnwrap(json["result"] as? [String: Any])
        let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertTrue(text.contains("agy's Gemini pool is limited"), text)
        XCTAssertTrue(text.contains("Not limited:"), text)
        XCTAssertTrue(text.contains("agy's Claude/GPT pool"), text)
        XCTAssertTrue(text.contains("claude-opus-4-6-thinking"), text)
        XCTAssertTrue(text.contains("cursor"), text)
        XCTAssertTrue(text.contains("opencode"), text)
        XCTAssertTrue(try store.openTasks().isEmpty)
    }
}

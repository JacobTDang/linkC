import XCTest
@testable import LinkCKit

final class MCPServerEffortAndRouterTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-mcp-effort-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private func server(settings: AgentModelSettings = .seeded) -> MCPServer {
        MCPServer(
            workspaceRoot: tempDir.path,
            inboxStore: InboxStore(workspaceRoot: tempDir.path),
            environment: ["LINKC_AGENT": "claude"],
            ancestorResolver: { _ in nil },
            modelSettings: { settings },
            sessionResolver: { nil },
            usageReaders: [:],
            openCodeModels: { _ in [
                "opencode/deepseek-v4.1-flash-free", "opencode/big-pickle", "opencode/nemotron-3.5-super-vl-free"
            ] },
            kiloModels: { _ in [] },
            modelLists: { [:] })
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

    func testDelegateTaskWithEffortPersistsIt() throws {
        let result = try call(server(), "linkc_delegate_task", [
            "to": "claude", "prompt": "Think hard.", "tier": "deep", "effort": "xhigh",
        ])
        XCTAssertFalse(result.isError, result.text)
        let task = try XCTUnwrap(try InboxStore(workspaceRoot: tempDir.path).openTasks().first)
        XCTAssertEqual(task.effort, .xhigh)
        XCTAssertEqual(task.tier, .deep)
    }

    func testDelegateTaskDefaultsEffortFromTierSettings() throws {
        let result = try call(server(), "linkc_delegate_task", [
            "to": "claude", "prompt": "Ordinary work.", "tier": "light",
        ])
        XCTAssertFalse(result.isError, result.text)
        let task = try XCTUnwrap(try InboxStore(workspaceRoot: tempDir.path).openTasks().first)
        XCTAssertEqual(task.effort, .low)
    }

    func testEffortOnUnsupportedAgentIsRefused() throws {
        let result = try call(server(), "linkc_delegate_task", [
            "to": "opencode", "prompt": "x", "tier": "light", "effort": "high",
        ])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.lowercased().contains("not supported"), result.text)
    }

    func testAutoRouteOmittingToPicksAgentAndReportsReason() throws {
        let result = try call(server(), "linkc_delegate_task", [
            "prompt": "Rename a typo in the header",
        ])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("Routed:"), result.text)
        let task = try XCTUnwrap(try InboxStore(workspaceRoot: tempDir.path).openTasks().first)
        XCTAssertEqual(task.tier, .light)
        XCTAssertEqual(task.effort, .low)
    }

    func testAutoRouteWithExplicitTierIsRefused() throws {
        let result = try call(server(), "linkc_delegate_task", [
            "to": "auto", "prompt": "Implement a feature", "tier": "deep",
        ])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("omit tier"), result.text)
    }
}

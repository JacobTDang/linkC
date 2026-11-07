import XCTest
@testable import LinkCKit

/// OpenCode through linkC's tool server: its place in every list of agents, and (Task 7) the
/// checks that keep a task off a model OpenCode no longer offers.
final class MCPServerOpenCodeTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-mcp-opencode-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    /// A server whose caller is Claude, on `models`, with no real usage readers.
    private func makeServer(models: AgentModelSettings = .seeded) -> MCPServer {
        MCPServer(workspaceRoot: tempDir.path, inboxStore: InboxStore(workspaceRoot: tempDir.path),
                  environment: ["LINKC_AGENT": "claude"], ancestorResolver: { _ in nil },
                  modelSettings: { models }, sessionResolver: { nil }, usageReaders: [:])
    }

    /// Calls `name` with `arguments`, returning the result's text and whether it is an error.
    private func call(_ server: MCPServer, _ name: String, _ arguments: [String: Any] = [:]) throws -> (text: String, isError: Bool) {
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                      "params": ["name": name, "arguments": arguments]]
        let data = try XCTUnwrap(server.handleMessage(try JSONSerialization.data(withJSONObject: request)))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try XCTUnwrap(json["result"] as? [String: Any], "\(json)")
        let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        return (text, result["isError"] as? Bool ?? false)
    }

    func testAnUnidentifiedCallerIsToldOpenCodeIsAnAgent() {
        XCTAssertTrue(MCPServer.unidentifiedCallerMessage.contains("\"opencode\""), MCPServer.unidentifiedCallerMessage)
    }

    func testTheModelReportListsOpenCodesTiers() throws {
        let report = try call(makeServer(), "linkc_get_models")
        XCTAssertFalse(report.isError, report.text)
        XCTAssertTrue(report.text.contains("## OpenCode\n"), report.text)
        XCTAssertTrue(report.text.contains("- **light**: opencode/deepseek-v4.1-flash-free\n"), report.text)
        XCTAssertTrue(report.text.contains("- **standard**: opencode/big-pickle — default\n"), report.text)
        XCTAssertTrue(report.text.contains("- **deep**: opencode/crouton-alpha-free\n"), report.text)
    }

    func testTheUsageReportHasAnOpenCodeSection() throws {
        let report = try call(makeServer(), "linkc_get_usage_status")
        XCTAssertTrue(report.text.contains("## OpenCode"), report.text)
    }

    func testOpenCodesDefaultUsageReaderSaysWhyItHasNoFigures() throws {
        let usage = try XCTUnwrap(MCPServer.defaultUsageReaders()[.opencode])()
        XCTAssertEqual(usage.agent, .opencode)
        XCTAssertEqual(usage.unavailableReason, "OpenCode's free models publish no quota locally")
    }
}

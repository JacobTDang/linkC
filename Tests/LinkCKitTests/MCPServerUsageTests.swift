import XCTest
@testable import LinkCKit

final class MCPServerUsageTests: XCTestCase {
    var tempDir: URL!
    var inbox: InboxStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-mcp-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        inbox = InboxStore(workspaceRoot: tempDir.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private func server(readers: [AgentKind: MCPServer.UsageReader]) -> MCPServer {
        MCPServer(workspaceRoot: tempDir.path, inboxStore: inbox,
                  environment: ["LINKC_AGENT": "claude"], ancestorResolver: { _ in nil },
                  modelSettings: { .seeded }, sessionResolver: { nil }, usageReaders: readers)
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

    func testItReportsWhatEachAgentHasLeft() throws {
        let codex = AgentUsage(agent: .codex,
                               windows: [UsageWindow(label: "5h", usedPercent: 23, tokens: nil, resetsAt: Date().addingTimeInterval(3600)),
                                         UsageWindow(label: "7d", usedPercent: 39, tokens: nil, resetsAt: nil)],
                               planType: "plus", observedAt: Date(), unavailableReason: nil)
        let agy = AgentUsage(agent: .agy, windows: [], planType: nil, observedAt: nil,
                             unavailableReason: "agy writes no local session records")
        let res = try call(server(readers: [.codex: { codex }, .agy: { agy }]), "linkc_get_usage_status")

        XCTAssertFalse(res.isError, res.text)
        XCTAssertTrue(res.text.contains("23%"), res.text)
        XCTAssertTrue(res.text.contains("plan plus"), res.text)
        XCTAssertTrue(res.text.contains("agy writes no local session records"), res.text)
        XCTAssertFalse(res.text.contains("gpt-4o"), "the stale catalog must not appear: \(res.text)")
        XCTAssertFalse(res.text.contains("Default Model"), "the default-model line is gone: \(res.text)")
    }

    func testAThrowingReaderStillReturnsAResult() throws {
        let res = try call(server(readers: [.codex: { AgentUsage.unavailable(.codex, reason: "reader failed") }]),
                           "linkc_get_usage_status")
        XCTAssertFalse(res.isError, "usage is informational; it never fails the call")
        XCTAssertTrue(res.text.contains("reader failed"), res.text)
    }

    func testAStaleReadingSaysSo() throws {
        let old = AgentUsage(agent: .codex,
                             windows: [UsageWindow(label: "5h", usedPercent: 23, tokens: nil, resetsAt: nil)],
                             planType: nil, observedAt: Date().addingTimeInterval(-3 * 3600), unavailableReason: nil)
        let res = try call(server(readers: [.codex: { old }]), "linkc_get_usage_status")
        XCTAssertTrue(res.text.lowercased().contains("stale"), res.text)
    }

    /// Task 10's transcript usage reader sets `tokensAreLowerBound` when its byte budget ran out
    /// before it could prove a window's total complete — the figure is then a floor, not the
    /// true count, and must say so rather than presenting a truncated read as exact.
    func testALowerBoundTokenCountSaysAtLeast() throws {
        let claude = AgentUsage(agent: .claude,
                                windows: [UsageWindow(label: "7d", usedPercent: nil, tokens: 443_000_000,
                                                       resetsAt: nil, tokensAreLowerBound: true)],
                                planType: nil, observedAt: Date(), unavailableReason: nil)
        let res = try call(server(readers: [.claude: { claude }]), "linkc_get_usage_status")
        XCTAssertFalse(res.isError, res.text)
        XCTAssertTrue(res.text.contains("at least"), res.text)
    }

    func testANonLowerBoundTokenCountDoesNotSayAtLeast() throws {
        let claude = AgentUsage(agent: .claude,
                                windows: [UsageWindow(label: "7d", usedPercent: nil, tokens: 443_000_000,
                                                       resetsAt: nil, tokensAreLowerBound: false)],
                                planType: nil, observedAt: Date(), unavailableReason: nil)
        let res = try call(server(readers: [.claude: { claude }]), "linkc_get_usage_status")
        XCTAssertFalse(res.isError, res.text)
        XCTAssertFalse(res.text.contains("at least"), res.text)
    }
}

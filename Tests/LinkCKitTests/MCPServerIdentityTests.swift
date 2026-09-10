import XCTest
@testable import LinkCKit

final class MCPServerIdentityTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-mcp-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
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

    func testExplicitAgentArgumentWins() throws {
        let server = MCPServer(workspaceRoot: tempDir.path, environment: ["LINKC_AGENT": "codex"], ancestorResolver: { _ in (.agy, 77) })
        let caller = server.resolveCaller(["agent": "cursor", "pid": 5])
        XCTAssertEqual(caller.agent, .cursor)
        XCTAssertEqual(caller.pid, 5)
    }

    func testEnvironmentIsUsedWhenNoArgument() throws {
        let server = MCPServer(workspaceRoot: tempDir.path, environment: ["LINKC_AGENT": "codex"], ancestorResolver: { _ in nil })
        let caller = server.resolveCaller([:])
        XCTAssertEqual(caller.agent, .codex)
        XCTAssertEqual(caller.pid, getppid())
    }

    func testAncestorResolverIsUsedWhenNoArgumentOrEnvironment() throws {
        let server = MCPServer(workspaceRoot: tempDir.path, environment: [:], ancestorResolver: { _ in (.agy, 77) })
        let caller = server.resolveCaller([:])
        XCTAssertEqual(caller.agent, .agy)
        XCTAssertEqual(caller.pid, 77)
    }

    func testUnidentifiedCallerIsShellNotClaude() throws {
        let server = MCPServer(workspaceRoot: tempDir.path, environment: [:], ancestorResolver: { _ in nil })
        let caller = server.resolveCaller([:])
        XCTAssertEqual(caller.agent, .shell)
        XCTAssertFalse(caller.isIdentified)
    }

    func testUnidentifiedCallerCanReadButNotWrite() throws {
        let server = MCPServer(workspaceRoot: tempDir.path, environment: [:], ancestorResolver: { _ in nil })
        let read = try call(server, "linkc_get_project_context")
        XCTAssertFalse(read.isError)
        let write = try call(server, "linkc_broadcast_intent", ["goal": "x"])
        XCTAssertTrue(write.isError)
        XCTAssertTrue(write.text.contains("Cannot identify calling agent"))
        let note = try call(server, "linkc_post_note", ["title": "t", "content": "c"])
        XCTAssertTrue(note.isError)
    }

    func testEveryIdentifiedCallHeartbeatsTheBlackboard() throws {
        let server = MCPServer(workspaceRoot: tempDir.path, environment: ["LINKC_AGENT": "cursor"], ancestorResolver: { _ in nil })
        _ = try call(server, "linkc_get_models")
        let board = try server.store.load()
        let rec = try XCTUnwrap(board.activeAgents.first { $0.agentKind == .cursor })
        XCTAssertEqual(rec.pid, getppid())
        XCTAssertEqual(rec.goal, "(idle)")
    }
}

import XCTest
@testable import LinkCKit

final class MCPServerTests: XCTestCase {
    var tempDir: URL!
    var server: MCPServer!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-mcp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        server = MCPServer(workspaceRoot: tempDir.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    func testInitializeReturnsProtocolAndCapabilities() throws {
        let req = """
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2024-11-05"}}
        """.data(using: .utf8)!

        let resData = try XCTUnwrap(server.handleMessage(req))
        let resJson = try JSONSerialization.jsonObject(with: resData) as? [String: Any]
        XCTAssertEqual(resJson?["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(resJson?["id"] as? Int, 1)

        let result = resJson?["result"] as? [String: Any]
        XCTAssertEqual(result?["protocolVersion"] as? String, "2024-11-05")
        let serverInfo = result?["serverInfo"] as? [String: Any]
        XCTAssertEqual(serverInfo?["name"] as? String, "linkc-multiplier")
    }

    func testToolsListDeclaresFourTools() throws {
        let req = """
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list"}
        """.data(using: .utf8)!

        let resData = try XCTUnwrap(server.handleMessage(req))
        let resJson = try JSONSerialization.jsonObject(with: resData) as? [String: Any]
        let result = resJson?["result"] as? [String: Any]
        let tools = result?["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.count, 4)

        let toolNames = Set(tools?.compactMap { $0["name"] as? String } ?? [])
        XCTAssertTrue(toolNames.contains("linkc_broadcast_intent"))
        XCTAssertTrue(toolNames.contains("linkc_get_project_context"))
        XCTAssertTrue(toolNames.contains("linkc_check_conflicts"))
        XCTAssertTrue(toolNames.contains("linkc_post_note"))
    }

    func testToolsCallBroadcastIntentAndCheckConflicts() throws {
        let broadcastReq = """
        {
          "jsonrpc": "2.0",
          "id": 3,
          "method": "tools/call",
          "params": {
            "name": "linkc_broadcast_intent",
            "arguments": {
              "agent": "claude",
              "pid": 555,
              "goal": "Refactor router",
              "files": ["Sources/Router.swift"]
            }
          }
        }
        """.data(using: .utf8)!

        let resData = try XCTUnwrap(server.handleMessage(broadcastReq))
        let resJson = try JSONSerialization.jsonObject(with: resData) as? [String: Any]
        let result = resJson?["result"] as? [String: Any]
        let content = result?["content"] as? [[String: Any]]
        XCTAssertEqual(content?.first?["type"] as? String, "text")
        let text = content?.first?["text"] as? String ?? ""
        XCTAssertTrue(text.contains("recorded"), "Expected broadcast confirmation in text: \(text)")

        // Now test check_conflicts for the same file from a different PID
        let checkReq = """
        {
          "jsonrpc": "2.0",
          "id": 4,
          "method": "tools/call",
          "params": {
            "name": "linkc_check_conflicts",
            "arguments": {
              "files": ["Sources/Router.swift"],
              "pid": 666
            }
          }
        }
        """.data(using: .utf8)!

        let checkRes = try XCTUnwrap(server.handleMessage(checkReq))
        let checkJson = try JSONSerialization.jsonObject(with: checkRes) as? [String: Any]
        let checkContent = (checkJson?["result"] as? [String: Any])?["content"] as? [[String: Any]]
        let checkText = checkContent?.first?["text"] as? String ?? ""
        XCTAssertTrue(checkText.contains("Collision Warning"), "Expected collision warning in: \(checkText)")
    }

    func testToolsCallPostNoteAndGetContext() throws {
        let noteReq = """
        {
          "jsonrpc": "2.0",
          "id": 5,
          "method": "tools/call",
          "params": {
            "name": "linkc_post_note",
            "arguments": {
              "agent": "agy",
              "title": "Config format",
              "content": "Using yaml instead of json",
              "tags": ["config"]
            }
          }
        }
        """.data(using: .utf8)!

        _ = try XCTUnwrap(server.handleMessage(noteReq))

        let contextReq = """
        {
          "jsonrpc": "2.0",
          "id": 6,
          "method": "tools/call",
          "params": {
            "name": "linkc_get_project_context"
          }
        }
        """.data(using: .utf8)!

        let ctxRes = try XCTUnwrap(server.handleMessage(contextReq))
        let ctxJson = try JSONSerialization.jsonObject(with: ctxRes) as? [String: Any]
        let ctxContent = (ctxJson?["result"] as? [String: Any])?["content"] as? [[String: Any]]
        let ctxText = ctxContent?.first?["text"] as? String ?? ""
        XCTAssertTrue(ctxText.contains("Config format"), "Context should include the note: \(ctxText)")
    }
}

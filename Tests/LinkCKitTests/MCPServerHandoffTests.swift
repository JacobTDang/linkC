import XCTest
@testable import LinkCKit

final class MCPServerHandoffTests: XCTestCase {
    private var tempDir: URL!
    private var requestStore: OpenRequestStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-mcp-handoff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        requestStore = OpenRequestStore(directory: tempDir.appendingPathComponent("open-requests"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private func makeServer(session: String? = "source-sess-123",
                            store: OpenRequestStore? = nil,
                            wait: MCPServer.CloseAnswerWait = MCPServer.CloseAnswerWait(timeout: 0.5, interval: 0.01, sleep: { _ in })) -> MCPServer {
        var env: [String: String] = ["LINKC_AGENT": "claude"]
        if let session {
            env["LINKC_SESSION"] = session
        }
        return MCPServer(
            workspaceRoot: tempDir.path,
            environment: env,
            ancestorResolver: { _ in nil },
            sessionResolver: { nil },
            usageReaders: [:],
            closeAnswerWait: wait,
            kiloModels: { _ in [] },
            modelLists: TestModelLists.none,
            handoffRequests: store ?? requestStore
        )
    }

    func testToolsListIncludesLinkcHandoff() throws {
        let srv = makeServer()
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": [:]]
        let responseData = try XCTUnwrap(srv.handleMessage(try JSONSerialization.data(withJSONObject: request)))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        let result = try XCTUnwrap(json["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        let handoffTool = try XCTUnwrap(tools.first { ($0["name"] as? String) == "linkc_handoff" })
        XCTAssertEqual(handoffTool["name"] as? String, "linkc_handoff")

        let schema = try XCTUnwrap(handoffTool["inputSchema"] as? [String: Any])
        let props = try XCTUnwrap(schema["properties"] as? [String: Any])
        XCTAssertNotNil(props["to"])
        XCTAssertNotNil(props["tier"])
        XCTAssertNotNil(props["model"])
        XCTAssertNotNil(props["goal"])
        let required = try XCTUnwrap(schema["required"] as? [String])
        XCTAssertEqual(required, ["to"])
    }

    /// The tool writes where only a linkC that knows handoffs reads.
    func testTheToolWritesToTheHandoffFolder() {
        let srv = MCPServer(workspaceRoot: tempDir.path, environment: ["LINKC_AGENT": "claude"])
        XCTAssertEqual(srv.handoffRequests.directory, OpenRequestStore.handoffApplicationSupport.directory)
    }

    /// A linkC that predates handoffs never answers one; the agent hears that it may need updating.
    func testAnUnansweredHandoffSaysLinkCMayNeedUpdating() throws {
        let srv = makeServer()
        let res = try mcpCall(srv, "linkc_handoff", ["to": "codex"])

        XCTAssertTrue(res.isError)
        XCTAssertTrue(res.text.contains("linkC did not answer"), res.text)
        XCTAssertTrue(res.text.contains("update"), res.text)
        XCTAssertTrue(requestStore.pending().isEmpty, "the request is withdrawn")
    }

    func testHandoffWithoutCallingSessionFails() throws {
        let srv = makeServer(session: nil)
        let res = try mcpCall(srv, "linkc_handoff", ["to": "codex"])
        XCTAssertTrue(res.isError)
        XCTAssertTrue(res.text.contains("calling session") || res.text.contains("active session") || res.text.contains("LINKC_SESSION"))
    }

    func testHandoffMissingToArgumentFails() throws {
        let srv = makeServer()
        let res = try mcpCall(srv, "linkc_handoff", [:])
        XCTAssertTrue(res.isError)
        XCTAssertTrue(res.text.contains("Missing required argument 'to'"))
    }

    func testHandoffToShellFails() throws {
        let srv = makeServer()
        let res = try mcpCall(srv, "linkc_handoff", ["to": "shell"])
        XCTAssertTrue(res.isError)
        XCTAssertTrue(res.text.contains("shell"))
    }

    func testHandoffBothTierAndModelFails() throws {
        let srv = makeServer()
        let res = try mcpCall(srv, "linkc_handoff", ["to": "codex", "tier": "standard", "model": "o3-mini"])
        XCTAssertTrue(res.isError)
        XCTAssertTrue(res.text.contains("pass tier or model, not both"))
    }

    func testHandoffSubmitsOpenRequestAndReturnsNewSessionIdOnSuccess() throws {
        let store = requestStore!
        // Polling answerer in background
        let srv = makeServer(store: store, wait: MCPServer.CloseAnswerWait(timeout: 2.0, interval: 0.05, sleep: { Thread.sleep(forTimeInterval: $0) }))

        let backgroundThread = Thread {
            for _ in 0..<40 {
                let pending = store.pending()
                if let req = pending.first {
                    try? store.answer(req.id, with: .opened(sessionId: "new-sess-999", message: "Handed off to Codex"))
                    break
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        backgroundThread.start()

        let res = try mcpCall(srv, "linkc_handoff", [
            "to": "codex",
            "tier": "standard",
            "goal": "Migrate database"
        ])

        XCTAssertFalse(res.isError, res.text)
        XCTAssertEqual(res.text, "new-sess-999")
    }

    func testHandoffReturnsRefusalTextOnRefusal() throws {
        let store = requestStore!
        let srv = makeServer(store: store, wait: MCPServer.CloseAnswerWait(timeout: 2.0, interval: 0.05, sleep: { Thread.sleep(forTimeInterval: $0) }))

        let backgroundThread = Thread {
            for _ in 0..<40 {
                let pending = store.pending()
                if let req = pending.first {
                    try? store.answer(req.id, with: .refused("cursor cannot be pinned to a model"))
                    break
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        backgroundThread.start()

        let res = try mcpCall(srv, "linkc_handoff", [
            "to": "cursor",
            "model": "gpt-4o"
        ])

        XCTAssertTrue(res.isError)
        XCTAssertTrue(res.text.contains("cursor cannot be pinned to a model"))
    }
}

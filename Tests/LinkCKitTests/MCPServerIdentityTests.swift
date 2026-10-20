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
        let server = MCPServer(workspaceRoot: tempDir.path, environment: ["LINKC_AGENT": "codex"], ancestorResolver: { _ in (.agy, 77) }, sessionResolver: { nil })
        let caller = server.resolveCaller(["agent": "cursor", "pid": 5])
        XCTAssertEqual(caller.agent, .cursor)
        XCTAssertEqual(caller.pid, 5)
    }

    func testEnvironmentIsUsedWhenNoArgument() throws {
        let server = MCPServer(workspaceRoot: tempDir.path, environment: ["LINKC_AGENT": "codex"], ancestorResolver: { _ in nil }, sessionResolver: { nil })
        let caller = server.resolveCaller([:])
        XCTAssertEqual(caller.agent, .codex)
        XCTAssertEqual(caller.pid, getppid())
    }

    func testAncestorResolverIsUsedWhenNoArgumentOrEnvironment() throws {
        let server = MCPServer(workspaceRoot: tempDir.path, environment: [:], ancestorResolver: { _ in (.agy, 77) }, sessionResolver: { nil })
        let caller = server.resolveCaller([:])
        XCTAssertEqual(caller.agent, .agy)
        XCTAssertEqual(caller.pid, 77)
    }

    func testUnidentifiedCallerIsShellNotClaude() throws {
        let server = MCPServer(workspaceRoot: tempDir.path, environment: [:], ancestorResolver: { _ in nil }, sessionResolver: { nil })
        let caller = server.resolveCaller([:])
        XCTAssertEqual(caller.agent, .shell)
        XCTAssertFalse(caller.isIdentified)
    }

    func testUnidentifiedCallerCanReadButNotWrite() throws {
        let server = MCPServer(workspaceRoot: tempDir.path, environment: [:], ancestorResolver: { _ in nil }, sessionResolver: { nil })
        let read = try call(server, "linkc_get_project_context")
        XCTAssertFalse(read.isError)
        let write = try call(server, "linkc_broadcast_intent", ["goal": "x"])
        XCTAssertTrue(write.isError)
        XCTAssertTrue(write.text.contains("Cannot identify calling agent"))
        let note = try call(server, "linkc_post_note", ["title": "t", "content": "c"])
        XCTAssertTrue(note.isError)
    }

    func testEveryIdentifiedCallHeartbeatsTheBlackboard() throws {
        let server = MCPServer(workspaceRoot: tempDir.path, environment: ["LINKC_AGENT": "cursor"], ancestorResolver: { _ in nil }, sessionResolver: { nil })
        _ = try call(server, "linkc_get_models")
        let board = try server.store.load()
        let rec = try XCTUnwrap(board.activeAgents.first { $0.agentKind == .cursor })
        XCTAssertEqual(rec.pid, getppid())
        XCTAssertEqual(rec.goal, "(idle)")
    }

    /// A tool server in a terminal linkC marked as Grok, whose CLI loaded Cursor's registration.
    private func serverInGrokTerminal(environment: [String: String] = ["LINKC_AGENT": "cursor"],
                                      worker: String? = "grok",
                                      ancestor: (agent: AgentKind, pid: pid_t)? = nil) -> MCPServer {
        MCPServer(workspaceRoot: tempDir.path, environment: environment,
                  ancestorResolver: { _ in ancestor }, sessionResolver: { nil }, workerResolver: { worker })
    }

    func testCursorsRegistrationInsideAGrokTerminalIsGrok() {
        let caller = serverInGrokTerminal().resolveCaller([:])
        XCTAssertEqual(caller.agent, .grok)
        XCTAssertEqual(caller.pid, getppid())
    }

    /// A Grok model running in Cursor's CLI may well call itself cursor; the terminal's mark wins.
    func testAGrokModelThatCallsItselfCursorIsGrok() {
        let caller = serverInGrokTerminal().resolveCaller(["agent": "cursor", "pid": 5])
        XCTAssertEqual(caller.agent, .grok)
        XCTAssertEqual(caller.pid, 5)
    }

    func testACursorProcessFoundAboveAGrokServerIsGrok() {
        let caller = serverInGrokTerminal(environment: [:], ancestor: (.cursor, 77)).resolveCaller([:])
        XCTAssertEqual(caller.agent, .grok)
        XCTAssertEqual(caller.pid, 77)
    }

    /// An empty mark in the server's own environment says nothing; the ancestor's mark decides,
    /// as the ancestor walk itself passes over empty values.
    func testAnEmptyMarkInTheServersOwnEnvironmentFallsBackToTheAncestors() {
        let server = serverInGrokTerminal(environment: ["LINKC_AGENT": "cursor", "LINKC_WORKER": ""], worker: "grok")
        XCTAssertEqual(server.resolveCaller([:]).agent, .grok)
    }

    func testTheMarkIsReadFromTheServersOwnEnvironmentFirst() {
        let server = serverInGrokTerminal(environment: ["LINKC_AGENT": "cursor", "LINKC_WORKER": "grok"], worker: nil)
        XCTAssertEqual(server.resolveCaller([:]).agent, .grok)
    }

    /// Another agent started from inside a Grok terminal is still itself.
    func testTheMarkLeavesEveryOtherAgentAlone() {
        XCTAssertEqual(serverInGrokTerminal(environment: ["LINKC_AGENT": "codex"]).resolveCaller([:]).agent, .codex)
        XCTAssertEqual(serverInGrokTerminal().resolveCaller(["agent": "agy"]).agent, .agy)
    }

    func testAMarkThatIsNotGrokIsIgnored() {
        XCTAssertEqual(serverInGrokTerminal(worker: "bogus").resolveCaller([:]).agent, .cursor)
        XCTAssertEqual(serverInGrokTerminal(worker: "codex").resolveCaller([:]).agent, .cursor)
    }

    func testOutsideAGrokTerminalCursorIsCursor() {
        XCTAssertEqual(serverInGrokTerminal(worker: nil).resolveCaller([:]).agent, .cursor)
    }

    /// The default resolver reads no real process under XCTest: a test that never injected one is
    /// simply not in a Grok terminal.
    func testTheDefaultWorkerResolverReadsNoRealProcessUnderXCTest() {
        let server = MCPServer(workspaceRoot: tempDir.path, environment: ["LINKC_AGENT": "cursor"],
                               ancestorResolver: { _ in nil }, sessionResolver: { nil })
        XCTAssertEqual(server.resolveCaller([:]).agent, .cursor)
    }
}

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

    /// The app's list of open sessions, which a test writes when it needs one. Absent, it reads as
    /// linkC not running: no session is open anywhere.
    private var knownProjects: KnownProjectsFile {
        KnownProjectsFile(url: tempDir.appendingPathComponent("projects.json"))
    }

    private func server(
        settings: AgentModelSettings = .seeded,
        installed: Set<AgentKind> = [.claude, .codex, .cursor, .agy, .grok, .opencode, .kilo, .crush],
        callerSession: String? = nil,
        lists: @escaping @Sendable () throws -> [AgentKind: AgentModelList] = TestModelLists.none
    ) -> MCPServer {
        MCPServer(
            workspaceRoot: tempDir.path,
            inboxStore: InboxStore(workspaceRoot: tempDir.path),
            environment: ["LINKC_AGENT": "claude"],
            ancestorResolver: { _ in nil },
            modelSettings: { settings },
            sessionResolver: { callerSession },
            usageReaders: [:],
            isAgentInstalled: { installed.contains($0) },
            openCodeModels: { _ in [
                "opencode/deepseek-v4.1-flash-free", "opencode/big-pickle", "opencode/nemotron-3.5-super-vl-free"
            ] },
            kiloModels: { _ in [] },
            modelLists: lists,
            knownProjects: knownProjects)
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

    /// With no effort given, the task takes its tier's effort from Settings, here not light's default.
    func testDelegateTaskDefaultsEffortFromTierSettings() throws {
        var settings = AgentModelSettings.seeded
        settings.setEffort(.high, for: .claude, tier: .light)
        let result = try call(server(settings: settings), "linkc_delegate_task", [
            "to": "claude", "prompt": "Ordinary work.", "tier": "light",
        ])
        XCTAssertFalse(result.isError, result.text)
        let task = try XCTUnwrap(try InboxStore(workspaceRoot: tempDir.path).openTasks().first)
        XCTAssertEqual(task.effort, .high)
    }

    func testAnEffortThatIsNotALevelIsRefused() throws {
        for effort in ["hgih", "extreme"] as [Any] + [3] {
            let result = try call(server(), "linkc_delegate_task", [
                "to": "claude", "prompt": "x", "tier": "deep", "effort": effort,
            ])
            XCTAssertTrue(result.isError, "\(effort)")
            XCTAssertEqual(result.text, "Error: effort must be low, medium, high, xhigh or max.", "\(effort)")
        }
        XCTAssertTrue(try InboxStore(workspaceRoot: tempDir.path).openTasks().isEmpty)
    }

    /// `to: "auto"` routes like an omitted `to`: the task is queued for the router's pick, at its tier
    /// and effort, and the result says why.
    func testAutoRouteWithToAutoQueuesTheRoutersPick() throws {
        let result = try call(server(installed: [.claude, .codex]), "linkc_delegate_task", [
            "to": "auto", "prompt": "Fix the typo in the migration guide",
        ])
        XCTAssertFalse(result.isError, result.text)
        let task = try XCTUnwrap(try InboxStore(workspaceRoot: tempDir.path).openTasks().first)
        XCTAssertEqual(task.toAgent, .claude)
        XCTAssertEqual(task.tier, .light)
        XCTAssertEqual(task.effort, .low)
        XCTAssertTrue(result.text.contains("Routed: trivial edit → claude light; effort low."), result.text)
    }

    /// The schema offers effort's levels as an enum and says an effort the agent cannot take is refused.
    func testTheDelegateSchemaListsTheEffortLevels() throws {
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/list"]
        let data = try XCTUnwrap(server().handleMessage(try JSONSerialization.data(withJSONObject: request)))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let tools = try XCTUnwrap((json["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let delegate = try XCTUnwrap(tools.first { $0["name"] as? String == "linkc_delegate_task" })
        let properties = try XCTUnwrap((delegate["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])
        let effort = try XCTUnwrap(properties["effort"] as? [String: Any])
        XCTAssertEqual(effort["enum"] as? [String], ["low", "medium", "high", "xhigh", "max"])
        let description = try XCTUnwrap(effort["description"] as? String)
        XCTAssertTrue(description.contains("Refused"), description)
        XCTAssertFalse(description.contains("Ignored"), description)
    }

    /// agy refuses at launch an effort it does not list for the model, which kills the worker, so an
    /// explicit one is refused when the task is delegated. A level agy lists is kept.
    func testAnAgyEffortTheModelDoesNotListIsRefused() throws {
        var settings = AgentModelSettings.seeded
        settings.setModel("claude-opus-4-6-thinking", for: .agy, tier: .deep)
        let server = server(settings: settings, lists: TestModelLists.agy)

        let opus = try call(server, "linkc_delegate_task", ["to": "agy", "prompt": "x", "tier": "deep", "effort": "high"])
        XCTAssertTrue(opus.isError)
        XCTAssertEqual(opus.text, "Error: effort high is refused for agy's claude-opus-4-6-thinking: agy lists no effort levels for claude-opus-4-6-thinking, so it runs as configured.")

        let flash = try call(server, "linkc_delegate_task", ["to": "agy", "prompt": "x", "tier": "light", "effort": "xhigh"])
        XCTAssertTrue(flash.isError)
        XCTAssertEqual(flash.text, "Error: effort xhigh is refused for agy's gemini-3.8-flash-low: agy lists low, medium, high for it.")

        let listed = try call(server, "linkc_delegate_task", ["to": "agy", "prompt": "x", "tier": "light", "effort": "high"])
        XCTAssertFalse(listed.isError, listed.text)
        XCTAssertEqual(try InboxStore(workspaceRoot: tempDir.path).openTasks().map(\.effort), [.high])
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
        XCTAssertTrue(result.text.contains("Routed: trivial edit → claude light; effort low."), result.text)
        let task = try XCTUnwrap(try InboxStore(workspaceRoot: tempDir.path).openTasks().first)
        XCTAssertEqual(task.toAgent, .claude)
        XCTAssertEqual(task.tier, .light)
        XCTAssertEqual(task.effort, .low)
    }

    /// The tie-break reads the folder's open sessions from the app's list. The caller's own session
    /// is mid-turn and cannot take the task, so its agent does not count as active.
    func testAutoRouteTiesToAnotherAgentOpenInTheFolderNotTheCallersOwn() throws {
        try knownProjects.write([
            KnownProject(path: ProjectPath.canonical(tempDir.path), sessions: [
                .init(id: "S-caller", agent: "codex", activity: .busy),
                .init(id: "S-other", agent: "opencode", activity: .idle),
            ])
        ])
        let result = try call(server(callerSession: "S-caller"), "linkc_delegate_task", [
            "prompt": "Implement the login form and add unit tests",
        ])
        XCTAssertFalse(result.isError, result.text)
        let task = try XCTUnwrap(try InboxStore(workspaceRoot: tempDir.path).openTasks().first)
        XCTAssertEqual(task.toAgent, .opencode)
        XCTAssertTrue(
            result.text.contains("Routed: implementation → opencode standard; tie → already active in folder."),
            result.text)
    }

    func testAutoRouteWithNoInstalledAgentsReportsError() throws {
        let result = try call(server(installed: []), "linkc_delegate_task", [
            "prompt": "Rename a typo in the header",
        ])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(
            result.text.contains("no agent CLI is installed to route to"),
            result.text)
    }

    func testAutoRouteWithExplicitTierIsRefused() throws {
        let result = try call(server(), "linkc_delegate_task", [
            "to": "auto", "prompt": "Implement a feature", "tier": "deep",
        ])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("omit tier"), result.text)
    }
}

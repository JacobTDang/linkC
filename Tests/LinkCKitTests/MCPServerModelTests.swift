import XCTest
@testable import LinkCKit

final class MCPServerModelTests: XCTestCase {
    private var tempDir: URL!
    private var server: MCPServer!
    private var inboxStore: InboxStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-mcp-model-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        inboxStore = InboxStore(workspaceRoot: tempDir.path)
        server = MCPServer(workspaceRoot: tempDir.path, inboxStore: inboxStore, environment: ["LINKC_AGENT": "claude"], ancestorResolver: { _ in nil })
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    // MARK: - Tools List

    func testToolsListIncludesModelSwitchingTools() throws {
        let req = """
        {"jsonrpc": "2.0", "id": 1, "method": "tools/list"}
        """.data(using: .utf8)!

        let resData = try XCTUnwrap(server.handleMessage(req))
        let resJson = try JSONSerialization.jsonObject(with: resData) as? [String: Any]
        let result = resJson?["result"] as? [String: Any]
        let tools = result?["tools"] as? [[String: Any]]

        let toolNames = Set(tools?.compactMap { $0["name"] as? String } ?? [])
        XCTAssertTrue(toolNames.contains("linkc_switch_model"), "Expected linkc_switch_model in tools/list")
        XCTAssertTrue(toolNames.contains("linkc_get_models"), "Expected linkc_get_models in tools/list")
        XCTAssertTrue(toolNames.contains("linkc_get_usage_status"), "Expected linkc_get_usage_status in tools/list")
    }

    // MARK: - linkc_get_models

    func testGetModelsListsFreeModelsAndIdentifiesDefaults() throws {
        let req = """
        {
          "jsonrpc": "2.0",
          "id": 2,
          "method": "tools/call",
          "params": {
            "name": "linkc_get_models"
          }
        }
        """.data(using: .utf8)!

        let resData = try XCTUnwrap(server.handleMessage(req))
        let resJson = try JSONSerialization.jsonObject(with: resData) as? [String: Any]
        let result = resJson?["result"] as? [String: Any]
        XCTAssertFalse(result?["isError"] as? Bool ?? false)

        let content = result?["content"] as? [[String: Any]]
        let text = content?.first?["text"] as? String ?? ""

        // Header and agent sections
        XCTAssertTrue(text.contains("Configured Models by Tier"), "Missing title: \(text)")
        XCTAssertTrue(text.contains("Claude"), "Missing Claude section: \(text)")
        XCTAssertTrue(text.contains("Codex"), "Missing Codex section: \(text)")

        // Default marker
        XCTAssertTrue(text.contains("— default"), "Expected a default-tier marker in: \(text)")
        XCTAssertTrue(text.contains("sonnet"), "Expected sonnet model in Claude: \(text)")
        XCTAssertTrue(text.contains("gpt-6-sol"), "Expected gpt-6-sol model in Codex: \(text)")
    }

    func testGetModelsForSpecificAgentFiltersOutOthers() throws {
        let req = """
        {
          "jsonrpc": "2.0",
          "id": 3,
          "method": "tools/call",
          "params": {
            "name": "linkc_get_models",
            "arguments": {
              "agent": "claude"
            }
          }
        }
        """.data(using: .utf8)!

        let resData = try XCTUnwrap(server.handleMessage(req))
        let resJson = try JSONSerialization.jsonObject(with: resData) as? [String: Any]
        let result = resJson?["result"] as? [String: Any]
        let content = result?["content"] as? [[String: Any]]
        let text = content?.first?["text"] as? String ?? ""

        XCTAssertTrue(text.contains("Claude"), "Should contain Claude: \(text)")
        XCTAssertFalse(text.contains("Codex"), "Should not contain Codex when agent is claude: \(text)")
    }

    func testGetModelsForSpecificAgentAndShowsRateLimit() throws {
        // Record rate limit for Claude
        try inboxStore.recordLimit(agent: .claude, reason: "Claude 3.5 Sonnet limit reached", cooldown: 600)

        let req = """
        {
          "jsonrpc": "2.0",
          "id": 3,
          "method": "tools/call",
          "params": {
            "name": "linkc_get_models",
            "arguments": {
              "agent": "claude"
            }
          }
        }
        """.data(using: .utf8)!

        let resData = try XCTUnwrap(server.handleMessage(req))
        let resJson = try JSONSerialization.jsonObject(with: resData) as? [String: Any]
        let result = resJson?["result"] as? [String: Any]
        let content = result?["content"] as? [[String: Any]]
        let text = content?.first?["text"] as? String ?? ""

        XCTAssertTrue(text.contains("Claude"), "Should contain Claude: \(text)")
        XCTAssertFalse(text.contains("Codex"), "Should not contain Codex when agent is claude: \(text)")
        XCTAssertTrue(text.contains("Rate Limited"), "Should indicate rate limit cooldown: \(text)")
        XCTAssertTrue(text.contains("Claude 3.5 Sonnet limit reached"), "Should include limit reason: \(text)")
    }

    // MARK: - modelSettings freshness

    /// The refusal text ("set it in linkC settings") is a lie unless a later call actually sees
    /// an edit made after the server was constructed. `linkc-mcp` builds one `MCPServer` for the
    /// life of the CLI process, so a stored snapshot would never notice a settings change.
    private final class SettingsBox: @unchecked Sendable {
        private let lock = NSLock()
        private var current: AgentModelSettings
        init(_ initial: AgentModelSettings) { current = initial }
        var value: AgentModelSettings {
            get { lock.lock(); defer { lock.unlock() }; return current }
            set { lock.lock(); current = newValue; lock.unlock() }
        }
    }

    private func getModelsText(_ server: MCPServer, agent: String = "codex") throws -> String {
        let req = """
        {
          "jsonrpc": "2.0",
          "id": 20,
          "method": "tools/call",
          "params": { "name": "linkc_get_models", "arguments": { "agent": "\(agent)" } }
        }
        """.data(using: .utf8)!
        let resData = try XCTUnwrap(server.handleMessage(req))
        let resJson = try JSONSerialization.jsonObject(with: resData) as? [String: Any]
        let result = resJson?["result"] as? [String: Any]
        let content = result?["content"] as? [[String: Any]]
        return content?.first?["text"] as? String ?? ""
    }

    func testModelSettingsIsReadFreshOnEachCallRatherThanFrozenAtConstruction() throws {
        var initial = AgentModelSettings.seeded
        initial.setModel("gpt-6-astra", for: .codex, tier: .deep)
        let box = SettingsBox(initial)

        let liveServer = MCPServer(
            workspaceRoot: tempDir.path,
            inboxStore: inboxStore,
            environment: ["LINKC_AGENT": "claude"],
            ancestorResolver: { _ in nil },
            modelSettings: { box.value }
        )

        let before = try getModelsText(liveServer)
        XCTAssertTrue(before.contains("gpt-6-astra"), "Expected the initial mapping: \(before)")

        var edited = box.value
        edited.setModel("gpt-7-nova", for: .codex, tier: .deep)
        box.value = edited

        let after = try getModelsText(liveServer)
        XCTAssertTrue(after.contains("gpt-7-nova"),
                       "A later call on the same server must see a settings edit, not a snapshot frozen at construction: \(after)")
        XCTAssertFalse(after.contains("gpt-6-astra"), after)
    }

    // MARK: - linkc_switch_model

    func testSwitchModelRejectsPaidOrUnknownModels() throws {
        let req = """
        {
          "jsonrpc": "2.0",
          "id": 4,
          "method": "tools/call",
          "params": {
            "name": "linkc_switch_model",
            "arguments": {
              "agent": "claude",
              "model": "luna"
            }
          }
        }
        """.data(using: .utf8)!

        let resData = try XCTUnwrap(server.handleMessage(req))
        let resJson = try JSONSerialization.jsonObject(with: resData) as? [String: Any]
        let result = resJson?["result"] as? [String: Any]
        XCTAssertEqual(result?["isError"] as? Bool, true)

        let content = result?["content"] as? [[String: Any]]
        let text = content?.first?["text"] as? String ?? ""
        XCTAssertTrue(text.contains("not an allowed free or subscription-tier model"), "Expected rejection: \(text)")
        XCTAssertTrue(text.contains("Allowed models:"), "Expected allowed list in: \(text)")
    }

    func testSwitchModelRejectsShellAgent() throws {
        let req = """
        {
          "jsonrpc": "2.0",
          "id": 5,
          "method": "tools/call",
          "params": {
            "name": "linkc_switch_model",
            "arguments": {
              "agent": "shell",
              "model": "sonnet"
            }
          }
        }
        """.data(using: .utf8)!

        let resData = try XCTUnwrap(server.handleMessage(req))
        let resJson = try JSONSerialization.jsonObject(with: resData) as? [String: Any]
        let result = resJson?["result"] as? [String: Any]
        XCTAssertEqual(result?["isError"] as? Bool, true)

        let content = result?["content"] as? [[String: Any]]
        let text = content?.first?["text"] as? String ?? ""
        XCTAssertTrue(text.contains("Cannot switch model on shell session"), "Expected shell rejection: \(text)")
    }

    func testSwitchModelInvokesModelSwitcherCallbackWhenProvided() throws {
        final class SwitchTracker: @unchecked Sendable {
            var invokedAgent: AgentKind?
            var invokedModel: String?
        }
        let tracker = SwitchTracker()

        let customServer = MCPServer(
            workspaceRoot: tempDir.path,
            inboxStore: inboxStore,
            modelSwitcher: { agent, model in
                tracker.invokedAgent = agent
                tracker.invokedModel = model
                return "Switched \(agent.displayName) to \(model) via test callback."
            },
            environment: ["LINKC_AGENT": "claude"],
            ancestorResolver: { _ in nil }
        )

        let req = """
        {
          "jsonrpc": "2.0",
          "id": 6,
          "method": "tools/call",
          "params": {
            "name": "linkc_switch_model",
            "arguments": {
              "agent": "claude",
              "model": "haiku"
            }
          }
        }
        """.data(using: .utf8)!

        let resData = try XCTUnwrap(customServer.handleMessage(req))
        let resJson = try JSONSerialization.jsonObject(with: resData) as? [String: Any]
        let result = resJson?["result"] as? [String: Any]
        XCTAssertFalse(result?["isError"] as? Bool ?? false)

        let content = result?["content"] as? [[String: Any]]
        let text = content?.first?["text"] as? String ?? ""
        XCTAssertTrue(text.contains("Switched Claude Code to haiku via test callback."))
        XCTAssertEqual(tracker.invokedAgent, .claude)
        XCTAssertEqual(tracker.invokedModel, "haiku")
    }

    func testSwitchModelEnqueuesSwitchCommandWhenModelSwitcherIsNil() throws {
        let req = """
        {
          "jsonrpc": "2.0",
          "id": 7,
          "method": "tools/call",
          "params": {
            "name": "linkc_switch_model",
            "arguments": {
              "agent": "codex",
              "model": "o3-mini"
            }
          }
        }
        """.data(using: .utf8)!

        let resData = try XCTUnwrap(server.handleMessage(req))
        let resJson = try JSONSerialization.jsonObject(with: resData) as? [String: Any]
        let result = resJson?["result"] as? [String: Any]
        XCTAssertFalse(result?["isError"] as? Bool ?? false)

        let content = result?["content"] as? [[String: Any]]
        let text = content?.first?["text"] as? String ?? ""
        XCTAssertTrue(text.contains("Model switch requested: enqueued '/model o3-mini' for Codex"), "Unexpected text: \(text)")

        // Verify message was enqueued into inboxStore
        let pending = try inboxStore.fetchPending()
        XCTAssertEqual(pending.count, 1)
        let msg = try XCTUnwrap(pending.first)
        XCTAssertEqual(msg.fromAgent, .codex)
        XCTAssertEqual(msg.toAgent, .codex)
        XCTAssertEqual(msg.prompt, "/model o3-mini")
    }

    // MARK: - linkc_get_usage_status

    func testGetUsageStatusReportsCooldownAndFallbacksWhenRateLimited() throws {
        // Record rate limit for Claude
        try inboxStore.recordLimit(agent: .claude, reason: "Claude 3.5 Sonnet quota exhausted", cooldown: 1800)

        let req = """
        {
          "jsonrpc": "2.0",
          "id": 8,
          "method": "tools/call",
          "params": {
            "name": "linkc_get_usage_status"
          }
        }
        """.data(using: .utf8)!

        let resData = try XCTUnwrap(server.handleMessage(req))
        let resJson = try JSONSerialization.jsonObject(with: resData) as? [String: Any]
        let result = resJson?["result"] as? [String: Any]
        XCTAssertFalse(result?["isError"] as? Bool ?? false)

        let content = result?["content"] as? [[String: Any]]
        let text = content?.first?["text"] as? String ?? ""

        XCTAssertTrue(text.contains("Workspace Agent Usage & Rate Limits"), "Missing title: \(text)")
        XCTAssertTrue(text.contains("Claude"), "Expected Claude in report: \(text)")
        XCTAssertTrue(text.contains("Claude 3.5 Sonnet quota exhausted"), "Expected reason in: \(text)")
        XCTAssertTrue(text.contains("Available Free Fallback Models:"), "Expected fallback section: \(text)")
        XCTAssertTrue(text.contains("haiku"), "Expected haiku in fallbacks: \(text)")
    }

    // MARK: - AppCoordinator.switchModel

    private final class MockNotificationSink: NotificationSink, @unchecked Sendable {
        func deliver(id: String, title: String, body: String) {}
    }

    @MainActor
    func testAppCoordinatorSwitchModelInjectsPTYCommand() throws {
        let terminals = TerminalSessionManager()
        let settingsDir = tempDir.appendingPathComponent("settings")
        try FileManager.default.createDirectory(at: settingsDir, withIntermediateDirectories: true)

        let coordinator = AppCoordinator(
            terminals: terminals,
            hookServer: HookServer(port: 0),
            notifications: NotificationManager(sink: MockNotificationSink(), now: { Date() }),
            claudePath: "/bin/sh",
            settingsDir: settingsDir,
            userSettingsURL: tempDir.appendingPathComponent("user-settings.json"),
            manifestDir: tempDir.appendingPathComponent("manifest"),
            isWatching: { _ in false }
        )

        let session = coordinator.store.create(cwd: tempDir.path, title: "claude", id: "sess-claude-1", agentKind: .claude)
        coordinator.store.updateState(id: session.id, to: .ready)

        // Make terminal session
        _ = terminals.makeSession(id: session.id, cwd: tempDir.path, title: "claude", agentKind: .claude)
        XCTAssertEqual(terminals.sessions.count, 1)

        let message = try coordinator.switchModel(in: tempDir.path, agent: .claude, to: "haiku")
        XCTAssertTrue(message.contains("Switched Claude Code model to 'haiku' in session sess-claude-1."))

        // Validation errors
        XCTAssertThrowsError(try coordinator.switchModel(in: tempDir.path, agent: .shell, to: "haiku")) { error in
            guard case LinkCError.process(let msg) = error else {
                return XCTFail("Expected LinkCError.process, got: \(error)")
            }
            XCTAssertTrue(msg.contains("Cannot switch model on shell session"))
        }

        XCTAssertThrowsError(try coordinator.switchModel(in: tempDir.path, agent: .claude, to: "luna")) { error in
            guard case LinkCError.process(let msg) = error else {
                return XCTFail("Expected LinkCError.process, got: \(error)")
            }
            XCTAssertTrue(msg.contains("not an allowed free or subscription-tier model"))
        }

        XCTAssertThrowsError(try coordinator.switchModel(in: "/nonexistent/path", agent: .claude, to: "haiku")) { error in
            guard case LinkCError.process(let msg) = error else {
                return XCTFail("Expected LinkCError.process, got: \(error)")
            }
            XCTAssertTrue(msg.contains("No active session found"))
        }
    }
}

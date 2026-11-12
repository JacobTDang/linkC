import XCTest
import os
@testable import LinkCKit

final class MCPServerModelChoiceTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-mcp-model-choice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private func lists(_ agents: [AgentKind: AgentModelList]) -> [AgentKind: AgentModelList] { agents }

    private func server(
        lists: [AgentKind: AgentModelList] = [:],
        openCodeModels: @escaping MCPServer.OpenCodeModelLister = { _ in
            ["opencode/big-pickle", "opencode/beam-free"]
        },
        settings: AgentModelSettings = .seeded,
        modelSwitcher: MCPServer.ModelSwitcher? = nil
    ) -> MCPServer {
        server(readLists: { lists }, openCodeModels: openCodeModels, settings: settings, modelSwitcher: modelSwitcher)
    }

    private func server(
        readLists: @escaping @Sendable () throws -> [AgentKind: AgentModelList],
        openCodeModels: @escaping MCPServer.OpenCodeModelLister = { _ in
            ["opencode/big-pickle", "opencode/beam-free"]
        },
        settings: AgentModelSettings = .seeded,
        modelSwitcher: MCPServer.ModelSwitcher? = nil
    ) -> MCPServer {
        MCPServer(
            workspaceRoot: tempDir.path,
            inboxStore: InboxStore(workspaceRoot: tempDir.path),
            modelSwitcher: modelSwitcher,
            environment: ["LINKC_AGENT": "claude"],
            ancestorResolver: { _ in nil },
            modelSettings: { settings },
            sessionResolver: { nil },
            usageReaders: [:],
            openCodeModels: openCodeModels,
            modelLists: readLists)
    }

    private struct CacheUnreadable: Error, CustomStringConvertible {
        var description: String { "model-lists.json is corrupt" }
    }

    /// agy as its CLI listed it on its last good refresh: no Gemini 3.1 Pro any more.
    private func listedAgy(error: String? = nil, fetchedAt: Date? = Date()) -> [AgentKind: AgentModelList] {
        [.agy: AgentModelList(
            models: [
                ListedModel(id: "gemini-3.8-flash-low", name: "Flash Low"),
                ListedModel(id: "gemini-3.8-flash-medium", name: "Flash"),
                ListedModel(id: "claude-opus-4-6-thinking", name: "Opus"),
            ],
            fetchedAt: fetchedAt, error: error)]
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

    func testDelegateTaskWithModelCreatesTaskWithoutTier() throws {
        let lists = lists([
            .agy: AgentModelList(
                models: [ListedModel(id: "claude-opus-4-6-thinking", name: "Opus")],
                fetchedAt: Date(), error: nil),
        ])
        let result = try call(server(lists: lists), "linkc_delegate_task", [
            "to": "agy", "prompt": "Use Opus.", "model": "claude-opus-4-6-thinking",
        ])
        XCTAssertFalse(result.isError, result.text)
        let tasks = try InboxStore(workspaceRoot: tempDir.path).openTasks()
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?.model, "claude-opus-4-6-thinking")
        XCTAssertNil(tasks.first?.tier)
    }

    // MARK: - Casing

    /// A model typed in another case matches the listed one, and the listed spelling is what is stored.
    func testAModelTypedInAnotherCaseIsStoredAsListed() throws {
        let result = try call(server(lists: listedAgy()), "linkc_delegate_task", [
            "to": "agy", "prompt": "Use Flash.", "model": "Gemini-3.8-Flash-Medium",
        ])
        XCTAssertFalse(result.isError, result.text)
        let task = try XCTUnwrap(try InboxStore(workspaceRoot: tempDir.path).openTasks().first)
        XCTAssertEqual(task.model, "gemini-3.8-flash-medium")
    }

    func testSwitchModelHandsTheListedIdToTheSwitcher() throws {
        let asked = OSAllocatedUnfairLock<[String]>(initialState: [])
        let switcher: MCPServer.ModelSwitcher = { _, model, _, _ in
            asked.withLock { $0.append(model) }
            return "switched"
        }
        let result = try call(server(lists: listedAgy(), modelSwitcher: switcher), "linkc_switch_model", [
            "agent": "agy", "model": "Gemini-3.8-Flash-Medium",
        ])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(asked.withLock { $0 }, ["gemini-3.8-flash-medium"])
    }

    func testAPoolLimitAppliesToAModelTypedInAnotherCase() throws {
        try InboxStore(workspaceRoot: tempDir.path).recordLimit(
            agent: .agy, reason: "quota exceeded", cooldown: 3600, pool: "gemini")
        let result = try call(server(lists: listedAgy()), "linkc_delegate_task", [
            "to": "agy", "prompt": "x", "model": "Gemini-3.8-Flash-Medium",
        ])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("agy's Gemini pool is limited"), result.text)
    }

    // MARK: - A tier whose model the CLI no longer lists

    func testATierSetToAModelTheCLIDoesNotListIsRefusedAtOnce() throws {
        let result = try call(server(lists: listedAgy()), "linkc_delegate_task", [
            "to": "agy", "prompt": "Think hard.", "tier": "deep",
        ])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains(
            "agy's deep tier is set to gemini-3.1-pro-high, which agy no longer offers. Pick another in Settings > Models. Offered: "),
            result.text)
        XCTAssertTrue(result.text.contains("gemini-3.8-flash-medium"), result.text)
        XCTAssertTrue(result.text.contains("claude-opus-4-6-thinking"), result.text)
        XCTAssertTrue(try InboxStore(workspaceRoot: tempDir.path).openTasks().isEmpty)
    }

    func testADefaultTierSetToAModelTheCLIDoesNotListIsRefusedToo() throws {
        var settings = AgentModelSettings.seeded
        settings.setModel("gemini-9-ghost", for: .agy, tier: .standard)
        let result = try call(server(lists: listedAgy(), settings: settings), "linkc_delegate_task", [
            "to": "agy", "prompt": "x",
        ])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("agy's standard tier is set to gemini-9-ghost"), result.text)
    }

    func testAListedTierModelIsDelegated() throws {
        let result = try call(server(lists: listedAgy()), "linkc_delegate_task", [
            "to": "agy", "prompt": "x", "tier": "light",
        ])
        XCTAssertFalse(result.isError, result.text)
    }

    /// An agent never listed has nothing to check against: its tier delegations go through.
    func testAnAgentNeverListedIsNotBlocked() throws {
        let result = try call(server(lists: [:]), "linkc_delegate_task", [
            "to": "agy", "prompt": "x", "tier": "deep",
        ])
        XCTAssertFalse(result.isError, result.text)
        let neverFetched = try call(server(lists: [.agy: AgentModelList(models: [], fetchedAt: nil, error: "agy offline")]),
                                    "linkc_delegate_task", ["to": "agy", "prompt": "y", "tier": "deep"])
        XCTAssertFalse(neverFetched.isError, neverFetched.text)
    }

    /// A list the last refresh failed to renew may be stale: it does not block.
    func testAListWhoseRefreshFailedDoesNotBlockATier() throws {
        let result = try call(server(lists: listedAgy(error: "agy offline")), "linkc_delegate_task", [
            "to": "agy", "prompt": "x", "tier": "deep",
        ])
        XCTAssertFalse(result.isError, result.text)
    }

    /// Claude and Codex have fixed lists, not a CLI's: nothing is checked against a cache for them.
    func testTiersOfAgentsWithFixedListsAreNotChecked() throws {
        let result = try call(server(lists: [:]), "linkc_delegate_task", [
            "to": "claude", "prompt": "x", "tier": "deep",
        ])
        XCTAssertFalse(result.isError, result.text)
    }

    /// The union with tier ids is for display: a model the CLI no longer lists is not accepted by hand either.
    func testAModelOnlyATierNamesIsNotAcceptedWhenTheCLIListsWithoutIt() throws {
        let result = try call(server(lists: listedAgy()), "linkc_delegate_task", [
            "to": "agy", "prompt": "x", "model": "gemini-3.1-pro-high",
        ])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("is not among the models"), result.text)
        let display = try call(server(lists: listedAgy()), "linkc_get_models", ["agent": "agy"])
        XCTAssertTrue(display.text.contains("gemini-3.1-pro-high"), "get_models still shows the tier's id: \(display.text)")
    }

    // MARK: - The cache is read only by a call that needs it

    func testATierDelegationToAFixedListAgentNeverReadsTheCache() throws {
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let result = try call(server(readLists: { reads.withLock { $0 += 1 }; throw CacheUnreadable() }),
                              "linkc_delegate_task", ["to": "claude", "prompt": "x", "tier": "deep"])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(reads.withLock { $0 }, 0)
    }

    func testAnUnreadableCacheFailsAModelArgumentAndAListedAgentsTier() throws {
        let byModel = try call(server(readLists: { throw CacheUnreadable() }), "linkc_delegate_task", [
            "to": "agy", "prompt": "x", "model": "gemini-3.8-flash-medium",
        ])
        XCTAssertTrue(byModel.isError)
        XCTAssertTrue(byModel.text.contains("could not read the live model lists"), byModel.text)
        XCTAssertTrue(byModel.text.contains("model-lists.json is corrupt"), byModel.text)
        let byTier = try call(server(readLists: { throw CacheUnreadable() }), "linkc_delegate_task", [
            "to": "agy", "prompt": "x", "tier": "deep",
        ])
        XCTAssertTrue(byTier.isError)
        XCTAssertTrue(byTier.text.contains("could not read the live model lists"), byTier.text)
        XCTAssertTrue(try InboxStore(workspaceRoot: tempDir.path).openTasks().isEmpty)
    }

    // MARK: - get_models says which pool is limited

    func testGetModelsNamesTheLimitedPoolAndWhatIsAvailable() throws {
        try InboxStore(workspaceRoot: tempDir.path).recordLimit(
            agent: .agy, reason: "quota exceeded", cooldown: 3600, pool: "gemini")
        let result = try call(server(lists: listedAgy()), "linkc_get_models", ["agent": "agy"])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("Rate Limited** (Gemini pool): quota exceeded"), result.text)
        XCTAssertTrue(result.text.contains("Available: Claude/GPT pool"), result.text)
        XCTAssertFalse(result.text.contains("Status: Active / Available"), result.text)
        let lines = result.text.components(separatedBy: "\n")
        XCTAssertTrue(try XCTUnwrap(lines.first { $0.contains("- gemini-3.8-flash-medium") }).contains("limited"), result.text)
        XCTAssertFalse(try XCTUnwrap(lines.first { $0.contains("- claude-opus-4-6-thinking") }).contains("limited"), result.text)
    }

    func testGetModelsReportsAWholeAgentLimitWithoutAPool() throws {
        try InboxStore(workspaceRoot: tempDir.path).recordLimit(agent: .codex, reason: "usage cap", cooldown: 3600)
        let result = try call(server(), "linkc_get_models", ["agent": "codex"])
        XCTAssertTrue(result.text.contains("Rate Limited**: usage cap"), result.text)
    }

    /// A limit that cannot be read is an error, not "not limited".
    func testALimitStatusThatCannotBeReadIsAnError() throws {
        let inbox = InboxStore(workspaceRoot: tempDir.path)
        try inbox.recordLimit(agent: .agy, reason: "quota", cooldown: 3600, pool: "gemini")
        let limit = try XCTUnwrap(try inbox.load().agentLimits.first)
        try Data("{ not json".utf8).write(to: inbox.inboxURL)

        XCTAssertThrowsError(try MCPServer.limitRefusal(
            agent: .agy, limit: limit, model: "gemini-3.8-flash-medium",
            readLists: { [:] }, settings: .seeded, inboxStore: inbox))
    }

    /// A list of models that cannot be read does not hide the limit: the refusal still says what is limited.
    func testARefusalSaysSoWhenTheModelListsCannotBeRead() throws {
        let inbox = InboxStore(workspaceRoot: tempDir.path)
        try inbox.recordLimit(agent: .agy, reason: "quota", cooldown: 3600, pool: "gemini")
        let limit = try XCTUnwrap(try inbox.isAgentLimited(agent: .agy))

        let text = try MCPServer.limitRefusal(
            agent: .agy, limit: limit, model: "gemini-3.8-flash-medium",
            readLists: { throw CacheUnreadable() }, settings: .seeded, inboxStore: inbox)

        XCTAssertTrue(text.contains("agy's Gemini pool is limited until"), text)
        XCTAssertTrue(text.contains("model lists could not be read"), text)
        XCTAssertTrue(text.contains("model-lists.json is corrupt"), text)
    }

    func testLimitRefusalNeverOffersFreebuffAsNotLimited() throws {
        let inbox = InboxStore(workspaceRoot: tempDir.path)
        try inbox.recordLimit(agent: .claude, reason: "quota", cooldown: 3600)
        let limit = try XCTUnwrap(try inbox.isAgentLimited(agent: .claude))

        let text = try MCPServer.limitRefusal(
            agent: .claude, limit: limit, model: nil,
            readLists: { [:] }, settings: .seeded, inboxStore: inbox)

        XCTAssertTrue(text.contains("Not limited:"), text)
        XCTAssertFalse(text.lowercased().contains("freebuff"), text)
    }

    func testTierAndModelTogetherAreRefused() throws {
        let result = try call(server(), "linkc_delegate_task", [
            "to": "agy", "prompt": "x", "tier": "standard", "model": "claude-opus-4-6-thinking",
        ])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("pass tier or model, not both"), result.text)
        XCTAssertTrue(try InboxStore(workspaceRoot: tempDir.path).openTasks().isEmpty)
    }

    func testUnknownModelIsRefusedAndListsAvailable() throws {
        let lists = lists([
            .agy: AgentModelList(
                models: [
                    ListedModel(id: "gemini-3.8-flash-medium", name: "Flash"),
                    ListedModel(id: "claude-opus-4-6-thinking", name: "Opus"),
                ],
                fetchedAt: Date(), error: nil),
        ])
        let result = try call(server(lists: lists), "linkc_delegate_task", [
            "to": "agy", "prompt": "x", "model": "no-such-model",
        ])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("no-such-model"), result.text)
        XCTAssertTrue(result.text.contains("gemini-3.8-flash-medium"), result.text)
        XCTAssertTrue(result.text.contains("claude-opus-4-6-thinking"), result.text)
    }

    func testNonFreeOpenCodeModelIsRefusedAndListsFreeOnes() throws {
        let lists = lists([
            .opencode: AgentModelList(
                models: [
                    ListedModel(id: "opencode/big-pickle", name: "opencode/big-pickle"),
                    ListedModel(id: "opencode/beam-free", name: "opencode/beam-free"),
                ],
                fetchedAt: Date(), error: nil),
        ])
        let result = try call(server(lists: lists), "linkc_delegate_task", [
            "to": "opencode", "prompt": "x", "model": "opencode/claude-sonnet-5",
        ])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("not free"), result.text)
        XCTAssertTrue(result.text.contains("opencode/big-pickle"), result.text)
        XCTAssertTrue(result.text.contains("opencode/beam-free"), result.text)
    }

    func testGetModelsListsIdNameTierPoolAgeAndError() throws {
        let fetched = Date().addingTimeInterval(-120)
        let lists = lists([
            .agy: AgentModelList(
                models: [
                    ListedModel(id: "gemini-3.8-flash-medium", name: "Flash"),
                    ListedModel(id: "claude-opus-4-6-thinking", name: "Opus"),
                ],
                fetchedAt: fetched, error: "stale listing"),
        ])
        let result = try call(server(lists: lists), "linkc_get_models", ["agent": "agy"])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("gemini-3.8-flash-medium"), result.text)
        XCTAssertTrue(result.text.contains("Flash"), result.text)
        XCTAssertTrue(result.text.contains("tier standard"), result.text)
        XCTAssertTrue(result.text.contains("[pool Gemini]"), result.text)
        XCTAssertTrue(result.text.contains("[pool Claude/GPT]"), result.text)
        XCTAssertTrue(result.text.contains("ago"), result.text)
        XCTAssertTrue(result.text.contains("stale listing"), result.text)
    }

    func testSwitchModelRefusesAnIdNotListed() throws {
        let lists = lists([
            .claude: AgentModelList(
                models: [ListedModel(id: "haiku", name: "haiku"), ListedModel(id: "sonnet", name: "sonnet")],
                fetchedAt: Date(), error: nil),
        ])
        let result = try call(server(lists: lists), "linkc_switch_model", [
            "agent": "claude", "model": "luna",
        ])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("luna"), result.text)
        XCTAssertTrue(result.text.contains("haiku"), result.text)
        XCTAssertTrue(result.text.contains("sonnet"), result.text)
    }
}

final class SessionCanCarryModelTests: XCTestCase {
    func testCanCarryRequiresMatchingModel() {
        let task = TaskRecord(fromAgent: .claude, model: "claude-opus-4-6-thinking",
                              toAgent: .agy, prompt: "x")
        let matching = Session(id: "a", cwd: "/p", title: "a", agentKind: .agy,
                               model: "claude-opus-4-6-thinking")
        let other = Session(id: "b", cwd: "/p", title: "b", agentKind: .agy,
                            model: "gemini-3.8-flash-medium")
        XCTAssertTrue(matching.canCarry(task))
        XCTAssertFalse(other.canCarry(task))
    }
}

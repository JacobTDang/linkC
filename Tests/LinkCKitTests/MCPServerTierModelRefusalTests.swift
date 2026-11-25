import XCTest
@testable import LinkCKit

/// Routing and delegation judge a tier's configured model with one check: they give the same
/// reason for an unusable model and treat a model id the same way, case included.
final class MCPServerTierModelRefusalTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-mcp-tiermodel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private struct Crashed: Error, CustomStringConvertible {
        let description = "the CLI crashed"
    }

    private func server(
        settings: AgentModelSettings,
        installed: Set<AgentKind>,
        openCodeModels: @escaping @Sendable (String) throws -> [String] = { _ in [] },
        kiloModels: @escaping @Sendable (String) throws -> [String] = { _ in [] },
        lists: @escaping @Sendable () throws -> [AgentKind: AgentModelList] = TestModelLists.none
    ) -> MCPServer {
        MCPServer(
            workspaceRoot: tempDir.path,
            inboxStore: InboxStore(workspaceRoot: tempDir.path),
            environment: ["LINKC_AGENT": "claude"],
            ancestorResolver: { _ in nil },
            modelSettings: { settings },
            sessionResolver: { nil },
            usageReaders: [:],
            isAgentInstalled: { installed.contains($0) },
            openCodeModels: openCodeModels,
            kiloModels: kiloModels,
            modelLists: lists,
            knownProjects: KnownProjectsFile(url: tempDir.appendingPathComponent("projects.json")))
    }

    private func call(_ server: MCPServer, _ arguments: [String: Any]) throws -> (text: String, isError: Bool) {
        let request: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "linkc_delegate_task", "arguments": arguments],
        ]
        let data = try XCTUnwrap(server.handleMessage(try JSONSerialization.data(withJSONObject: request)))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try XCTUnwrap(json["result"] as? [String: Any])
        let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        return (text, result["isError"] as? Bool ?? false)
    }

    /// One unusable tier model: the agent, how its standard tier is set, and what its CLI or the
    /// cached lists say.
    private struct Scenario {
        let name: String
        let agent: AgentKind
        var model: String?
        var openCodeModels: @Sendable (String) throws -> [String] = { _ in [] }
        var kiloModels: @Sendable (String) throws -> [String] = { _ in [] }
        var lists: @Sendable () throws -> [AgentKind: AgentModelList] = TestModelLists.none
    }

    private var scenarios: [Scenario] {
        [
            Scenario(name: "opencode paid", agent: .opencode, model: "opencode/paid-model"),
            Scenario(name: "kilo paid", agent: .kilo, model: "kilo/paid-model"),
            Scenario(name: "crush paid", agent: .crush, model: "openrouter/anthropic/claude-opus-4.5"),
            Scenario(
                name: "opencode gone", agent: .opencode, model: nil,
                openCodeModels: { _ in ["opencode/other-free"] }),
            Scenario(
                name: "kilo gone", agent: .kilo, model: nil,
                kiloModels: { _ in ["kilo/other:free"] }),
            Scenario(name: "agy gone", agent: .agy, model: "gemini-9-gone", lists: TestModelLists.agy),
            Scenario(
                name: "opencode listing fails", agent: .opencode, model: nil,
                openCodeModels: { _ in throw Crashed() }),
            Scenario(
                name: "kilo listing fails", agent: .kilo, model: nil,
                kiloModels: { _ in throw Crashed() }),
            Scenario(name: "lists unreadable", agent: .agy, model: nil, lists: { throw Crashed() }),
        ]
    }

    /// Whatever refuses a tier model, routing names the agent skipped for that reason and delegation
    /// opens its error with the same words.
    func testRoutingAndDelegationGiveTheSameReasonForAnUnusableTierModel() throws {
        for scenario in scenarios {
            var settings = AgentModelSettings.seeded
            if let model = scenario.model {
                settings.setModel(model, for: scenario.agent, tier: .standard)
            }
            let server = server(
                settings: settings, installed: [scenario.agent],
                openCodeModels: scenario.openCodeModels, kiloModels: scenario.kiloModels, lists: scenario.lists)

            let routed = try call(server, ["prompt": "Implement the login form and add unit tests"])
            XCTAssertTrue(routed.isError, scenario.name)
            let opening = "no installed agent is free to take this task at standard — \(scenario.agent.rawValue) skipped ("
            let closing = "). Name an agent with `to`."
            XCTAssertTrue(routed.text.hasPrefix("Error: " + opening), "\(scenario.name): \(routed.text)")
            XCTAssertTrue(routed.text.hasSuffix(closing), "\(scenario.name): \(routed.text)")
            let reason = String(routed.text.dropFirst("Error: ".count + opening.count).dropLast(closing.count))

            let delegated = try call(server, [
                "to": scenario.agent.rawValue, "prompt": "Implement the login form and add unit tests", "tier": "standard",
            ])
            XCTAssertTrue(delegated.isError, scenario.name)
            XCTAssertTrue(delegated.text.hasPrefix("Error: " + reason), "\(scenario.name): \(delegated.text)")
        }
        XCTAssertTrue(try InboxStore(workspaceRoot: tempDir.path).openTasks().isEmpty)
    }

    /// A tier model that differs from the CLI's listing only in letter case is found by routing and
    /// by delegation alike: the listing's own spelling is not the only one that counts.
    func testATierModelThatDiffersFromTheListingOnlyInCaseIsAcceptedByBothPaths() throws {
        var settings = AgentModelSettings.seeded
        settings.setModel("opencode/DeepSeek-V4.1-Flash-free", for: .opencode, tier: .light)
        settings.setModel("kilo/Nvidia/Nemotron-3.5-Lightning:free", for: .kilo, tier: .light)
        let server = server(
            settings: settings, installed: [.opencode, .kilo],
            openCodeModels: { _ in ["opencode/deepseek-v4.1-flash-free"] },
            kiloModels: { _ in ["kilo/nvidia/nemotron-3.5-lightning:free"] })

        for agent in [AgentKind.opencode, .kilo] {
            let delegated = try call(server, ["to": agent.rawValue, "prompt": "Fix the typo in README", "tier": "light"])
            XCTAssertFalse(delegated.isError, "\(agent.rawValue): \(delegated.text)")
        }
        let routed = try call(server, ["prompt": "Fix the typo in the changelog"])
        XCTAssertFalse(routed.isError, routed.text)
        let tasks = try InboxStore(workspaceRoot: tempDir.path).openTasks()
        XCTAssertEqual(tasks.count, 3)
        XCTAssertEqual(tasks.filter { $0.prompt == "Fix the typo in the changelog" }.map(\.toAgent), [.opencode])
    }
}

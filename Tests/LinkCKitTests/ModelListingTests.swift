import XCTest
@testable import LinkCKit

final class ModelListingTests: XCTestCase {

    private let agyOutput = """
        Fetching available models...
        gemini-3.8-flash-high	Gemini 3.8 Flash (High)
        gemini-3.8-flash-medium	Gemini 3.8 Flash (Medium)
        gemini-3.8-flash-low	Gemini 3.8 Flash (Low)
        claude-sonnet-4-6	Claude Sonnet 4.6 (Thinking)
        claude-opus-4-6-thinking	Claude Opus 4.6 (Thinking)
        gpt-oss-120b-medium	GPT-OSS 120B (Medium)
        """

    private let cursorOutput = """
        Available models

        auto - Auto (current, default)
        gpt-5.3-codex-low - Codex 5.3 Low
        claude-opus-5-thinking-high - Claude Opus 5 1M Thinking
        grok-4.7-low - Grok 4.7  Low
        grok-4.7-low-fast - Grok 4.7  Low Fast\u{200B}\u{200B}
        cursor-grok-4.6-low - Grok 4.6 Low
        """

    private let openCodeOutput = """
        opencode/beam-free
        opencode/big-pickle
        opencode/deepseek-v4.1-flash-free
        opencode/nemotron-3.5-super-vl-free
        ollama/qwen2.5-coder:7b-8k
        ollama/qwen3.8:27b-32k
        opencode/claude-sonnet-5
        anthropic/claude-opus-5
        """

    func testAgyParserSkipsHeaderAndSplitsIdAndName() {
        let models = ModelListParser.agy(agyOutput)
        XCTAssertEqual(models.map(\.id), [
            "gemini-3.8-flash-high",
            "gemini-3.8-flash-medium",
            "gemini-3.8-flash-low",
            "claude-sonnet-4-6",
            "claude-opus-4-6-thinking",
            "gpt-oss-120b-medium",
        ])
        XCTAssertEqual(models.map(\.name), [
            "Gemini 3.8 Flash (High)",
            "Gemini 3.8 Flash (Medium)",
            "Gemini 3.8 Flash (Low)",
            "Claude Sonnet 4.6 (Thinking)",
            "Claude Opus 4.6 (Thinking)",
            "GPT-OSS 120B (Medium)",
        ])
    }

    func testAgyParserSkipsBlankLines() {
        let models = ModelListParser.agy("Fetching available models...\n\n\ngemini-3.8-flash-high\tFlash\n\n")
        XCTAssertEqual(models, [ListedModel(id: "gemini-3.8-flash-high", name: "Flash")])
    }

    /// A line without the tab is not a model: whatever agy prints in place of its list must not become one.
    func testAgyParserIgnoresALineWithoutATab() {
        XCTAssertEqual(ModelListParser.agy("Error: not logged in\n"), [])
        XCTAssertEqual(ModelListParser.agy("Error: not logged in\ngemini-3.8-flash-high\tFlash\nplease run agy login\n"),
                       [ListedModel(id: "gemini-3.8-flash-high", name: "Flash")])
        XCTAssertEqual(ModelListParser.agy("gemini-3.8-flash-high Flash"), [], "a space is not the separator")
        XCTAssertEqual(ModelListParser.agy("gemini-3.8-flash-high\t"), [], "a model with no name is not a line of the list")
        XCTAssertEqual(ModelListParser.agy("Error: not\tlogged in"), [], "an id has no spaces in it")
    }

    func testListingThrowsWhenTheOutputHasNoModels() {
        XCTAssertThrowsError(try ModelListParser.listing("Error: not logged in\n", for: .agy)) { error in
            XCTAssertEqual(String(describing: error), "agy models listed nothing: Error: not logged in")
        }
        XCTAssertThrowsError(try ModelListParser.listing("", for: .opencode)) { error in
            XCTAssertEqual(String(describing: error), "opencode models listed nothing: (no output)")
        }
        XCTAssertThrowsError(try ModelListParser.listing("x", for: .claude))
        XCTAssertEqual(try ModelListParser.listing(agyOutput, for: .agy).count, 6)
    }

    func testCursorParserSkipsHeaderTrimsZeroWidthAndKeepsSpaces() {
        let models = ModelListParser.cursor(cursorOutput)
        XCTAssertEqual(models.map(\.id), [
            "auto",
            "gpt-5.3-codex-low",
            "claude-opus-5-thinking-high",
            "grok-4.7-low",
            "grok-4.7-low-fast",
            "cursor-grok-4.6-low",
        ])
        XCTAssertEqual(models.first(where: { $0.id == "grok-4.7-low" })?.name, "Grok 4.7  Low")
        let fast = try! XCTUnwrap(models.first(where: { $0.id == "grok-4.7-low-fast" }))
        XCTAssertEqual(fast.name, "Grok 4.7  Low Fast")
        XCTAssertFalse(fast.name.contains("\u{200B}"))
        XCTAssertFalse(fast.id.contains("\u{200B}"))
    }

    func testGrokParserKeepsOnlyGrokPrefixedIds() {
        let models = ModelListParser.grok(fromCursor: cursorOutput)
        XCTAssertEqual(models.map(\.id), ["grok-4.7-low", "grok-4.7-low-fast"])
        XCTAssertEqual(models.map(\.name), ["Grok 4.7  Low", "Grok 4.7  Low Fast"])
    }

    func testOpenCodeParserKeepsFreeOnlyAndUsesIdAsName() {
        let models = ModelListParser.openCode(openCodeOutput)
        XCTAssertEqual(models.map(\.id), [
            "opencode/beam-free",
            "opencode/big-pickle",
            "opencode/deepseek-v4.1-flash-free",
            "opencode/nemotron-3.5-super-vl-free",
            "ollama/qwen2.5-coder:7b-8k",
            "ollama/qwen3.8:27b-32k",
        ])
        XCTAssertEqual(models.map(\.name), models.map(\.id))
        XCTAssertFalse(models.contains { $0.id == "opencode/claude-sonnet-5" })
        XCTAssertFalse(models.contains { $0.id == "anthropic/claude-opus-5" })
    }

    func testOpenCodeFreeRule() {
        XCTAssertTrue(OpenCodeFreeModels.isFree("opencode/beam-free"))
        XCTAssertTrue(OpenCodeFreeModels.isFree("opencode/big-pickle"))
        XCTAssertTrue(OpenCodeFreeModels.isFree("ollama/qwen3.8:27b-32k"))
        XCTAssertFalse(OpenCodeFreeModels.isFree("opencode/claude-sonnet-5"))
        XCTAssertFalse(OpenCodeFreeModels.isFree("anthropic/claude-opus-5"))
        XCTAssertFalse(OpenCodeFreeModels.isFree("opencode/big-pickle-paid"))
        XCTAssertFalse(OpenCodeFreeModels.isFree(""))
    }

    private let kiloOutput = """
        kilo/nvidia/nemotron-3.5-super-vl:free
        kilo/reflection/beam-free
        kilo/kilo-auto/free
        kilo/openrouter/free
        kilo/nvidia/nemotron-3.5-lightning:free
        kilo/anthropic/claude-sonnet-5
        anthropic/claude-opus-5
        """

    func testKiloParserKeepsFreeOnlyAndUsesIdAsName() {
        let models = ModelListParser.kilo(kiloOutput)
        XCTAssertEqual(models.map(\.id), [
            "kilo/nvidia/nemotron-3.5-super-vl:free",
            "kilo/reflection/beam-free",
            "kilo/kilo-auto/free",
            "kilo/openrouter/free",
            "kilo/nvidia/nemotron-3.5-lightning:free",
        ])
        XCTAssertEqual(models.map(\.name), models.map(\.id))
        XCTAssertFalse(models.contains { $0.id == "kilo/anthropic/claude-sonnet-5" })
        XCTAssertFalse(models.contains { $0.id == "anthropic/claude-opus-5" })
    }

    func testKiloFreeRule() {
        XCTAssertTrue(KiloFreeModels.isFree("kilo/nvidia/nemotron-3.5-super-vl:free"))
        XCTAssertTrue(KiloFreeModels.isFree("kilo/reflection/beam-free"))
        XCTAssertTrue(KiloFreeModels.isFree("kilo/kilo-auto/free"))
        XCTAssertTrue(KiloFreeModels.isFree("kilo/openrouter/free"))
        XCTAssertFalse(KiloFreeModels.isFree("kilo/anthropic/claude-sonnet-5"))
        XCTAssertFalse(KiloFreeModels.isFree("opencode/beam-free"))
        XCTAssertFalse(KiloFreeModels.isFree("anthropic/claude-opus-5"))
        XCTAssertFalse(KiloFreeModels.isFree(""))
        XCTAssertFalse(KiloFreeModels.isFree("kilo/"))
    }

    func testKiloListingThrowsWhenNothingIsFree() {
        XCTAssertThrowsError(try ModelListParser.listing("kilo/anthropic/claude-sonnet-5\n", for: .kilo)) { error in
            XCTAssertEqual(String(describing: error), "kilo models listed nothing: kilo/anthropic/claude-sonnet-5")
        }
        XCTAssertEqual(try ModelListParser.listing(kiloOutput, for: .kilo).count, 5)
    }

    func testAgyPools() {
        XCTAssertEqual(ModelPool.pool(of: "gemini-3.8-flash-medium", agent: .agy), "gemini")
        XCTAssertEqual(ModelPool.pool(of: "claude-opus-4-6-thinking", agent: .agy), "claude-gpt")
        XCTAssertEqual(ModelPool.pool(of: "claude-sonnet-4-6", agent: .agy), "claude-gpt")
        XCTAssertEqual(ModelPool.pool(of: "gpt-oss-120b-medium", agent: .agy), "claude-gpt")
        XCTAssertNil(ModelPool.pool(of: "something-else", agent: .agy))
        for agent in AgentKind.allCases where agent != .agy {
            XCTAssertNil(ModelPool.pool(of: "gemini-3.8-flash-medium", agent: agent), agent.rawValue)
            XCTAssertNil(ModelPool.pool(of: "claude-opus-4-6-thinking", agent: agent), agent.rawValue)
        }
        XCTAssertEqual(ModelPool.displayName("gemini"), "Gemini")
        XCTAssertEqual(ModelPool.displayName("claude-gpt"), "Claude/GPT")
    }

    func testFixedListsForClaudeAndCodex() {
        XCTAssertEqual(ModelListParser.fixed(for: .claude)?.map(\.id), ["haiku", "sonnet", "opus"])
        XCTAssertEqual(ModelListParser.fixed(for: .codex)?.map(\.id), [
            "gpt-5.6-luna", "gpt-5.6-sol", "gpt-6-astra",
        ])
        for agent: AgentKind in [.agy, .cursor, .grok, .opencode, .kilo, .shell] {
            XCTAssertNil(ModelListParser.fixed(for: agent), agent.rawValue)
        }
        XCTAssertTrue(ModelListParser.listedAgents.contains(.kilo))
    }

    /// A non-free OpenCode id is refused with "not free", even when the listing still names it.
    func testANonFreeOpenCodeModelIsRefusedEvenWhenListed() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-model-listing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        var settings = AgentModelSettings.seeded
        settings.setModel("opencode/claude-sonnet-5", for: .opencode, tier: .standard)
        let frozen = settings
        let server = MCPServer(
            workspaceRoot: temp.path,
            inboxStore: InboxStore(workspaceRoot: temp.path),
            environment: ["LINKC_AGENT": "claude"],
            ancestorResolver: { _ in nil },
            modelSettings: { frozen },
            sessionResolver: { nil },
            usageReaders: [:],
            openCodeModels: { _ in ["opencode/claude-sonnet-5", "opencode/big-pickle"] },
            modelLists: TestModelLists.none)

        let request: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": [
                "name": "linkc_delegate_task",
                "arguments": ["to": "opencode", "prompt": "Add a test.", "tier": "standard"],
            ],
        ]
        let data = try XCTUnwrap(server.handleMessage(try JSONSerialization.data(withJSONObject: request)))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try XCTUnwrap(json["result"] as? [String: Any])
        let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertTrue(text.contains("not free"), text)
        XCTAssertTrue(text.contains("opencode/claude-sonnet-5"), text)
        XCTAssertTrue(try InboxStore(workspaceRoot: temp.path).openTasks().isEmpty)
    }

    private struct NullSink: NotificationSink {
        func deliver(id: String, title: String, body: String) {}
    }

    /// App-side availability refuses a non-free id before it asks OpenCode what it lists.
    @MainActor
    func testAppCoordinatorRefusesANonFreeOpenCodeModelBeforeListing() {
        var settings = AgentModelSettings.seeded
        settings.setModel("opencode/claude-sonnet-5", for: .opencode, tier: .standard)
        let frozen = settings
        let settingsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-model-listing-settings-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: settingsDir, withIntermediateDirectories: true)
        let coordinator = AppCoordinator(
            terminals: TerminalSessionManager(),
            hookServer: HookServer.forTesting(),
            notifications: NotificationManager(sink: NullSink(), now: { Date() }),
            claudePath: "/x/claude",
            settingsDir: settingsDir,
            userSettingsURL: settingsDir.appendingPathComponent("user-settings.json"),
            manifestDir: settingsDir.appendingPathComponent("manifest"),
            modelSettings: { frozen },
            modelLists: TestModelLists.none,
            openCodeModels: { _ in
                XCTFail("OpenCode's models were listed for a non-free id")
                return []
            },
            isWatching: { _ in false })
        let availability = coordinator.openCodeModelAvailability(in: "/tmp", tier: .standard)
        guard case .refused(let reason) = availability else {
            return XCTFail("expected refused, got \(availability)")
        }
        XCTAssertTrue(reason.contains("not free"), reason)
        XCTAssertTrue(reason.contains("opencode/claude-sonnet-5"), reason)
    }

    /// A non-free Kilo id is refused with "not free", even when the listing still names it.
    func testANonFreeKiloModelIsRefusedEvenWhenListed() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-kilo-listing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        var settings = AgentModelSettings.seeded
        settings.setModel("kilo/anthropic/claude-sonnet-5", for: .kilo, tier: .standard)
        let frozen = settings
        let server = MCPServer(
            workspaceRoot: temp.path,
            inboxStore: InboxStore(workspaceRoot: temp.path),
            environment: ["LINKC_AGENT": "claude"],
            ancestorResolver: { _ in nil },
            modelSettings: { frozen },
            sessionResolver: { nil },
            usageReaders: [:],
            kiloModels: { _ in ["kilo/anthropic/claude-sonnet-5", "kilo/kilo-auto/free"] },
            modelLists: TestModelLists.none)

        let request: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": [
                "name": "linkc_delegate_task",
                "arguments": ["to": "kilo", "prompt": "Add a test.", "tier": "standard"],
            ],
        ]
        let data = try XCTUnwrap(server.handleMessage(try JSONSerialization.data(withJSONObject: request)))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try XCTUnwrap(json["result"] as? [String: Any])
        let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertTrue(text.contains("not free"), text)
        XCTAssertTrue(text.contains("kilo/anthropic/claude-sonnet-5"), text)
        XCTAssertTrue(try InboxStore(workspaceRoot: temp.path).openTasks().isEmpty)
    }

    /// App-side availability refuses a non-free id before it asks Kilo what it lists.
    @MainActor
    func testAppCoordinatorRefusesANonFreeKiloModelBeforeListing() {
        var settings = AgentModelSettings.seeded
        settings.setModel("kilo/anthropic/claude-sonnet-5", for: .kilo, tier: .standard)
        let frozen = settings
        let settingsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-kilo-listing-settings-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: settingsDir, withIntermediateDirectories: true)
        let coordinator = AppCoordinator(
            terminals: TerminalSessionManager(),
            hookServer: HookServer.forTesting(),
            notifications: NotificationManager(sink: NullSink(), now: { Date() }),
            claudePath: "/x/claude",
            settingsDir: settingsDir,
            userSettingsURL: settingsDir.appendingPathComponent("user-settings.json"),
            manifestDir: settingsDir.appendingPathComponent("manifest"),
            modelSettings: { frozen },
            modelLists: TestModelLists.none,
            kiloModels: { _ in
                XCTFail("Kilo's models were listed for a non-free id")
                return []
            },
            isWatching: { _ in false })
        let availability = coordinator.kiloModelAvailability(in: "/tmp", tier: .standard)
        guard case .refused(let reason) = availability else {
            return XCTFail("expected refused, got \(availability)")
        }
        XCTAssertTrue(reason.contains("not free"), reason)
        XCTAssertTrue(reason.contains("kilo/anthropic/claude-sonnet-5"), reason)
    }
}

import XCTest
@testable import LinkCKit

/// Crush's free-only rule (spec §4.3): one shared `CrushFreeModels.isFree`, the `crush models` source
/// that keeps only free ids, the seeded tiers, and every place that refuses a paid model.
final class CrushFreeModelsTests: XCTestCase {
    // MARK: - The rule

    func testFreeOpenRouterIdsAreFree() {
        XCTAssertTrue(CrushFreeModels.isFree("openrouter/nvidia/nemotron-3.5-lightning:free"))
        XCTAssertTrue(CrushFreeModels.isFree("openrouter/nvidia/nemotron-3.5-super-vl:free"))
        XCTAssertTrue(CrushFreeModels.isFree("openrouter/nvidia/nemotron-3-ultra-550b-a55b:free"))
        XCTAssertTrue(CrushFreeModels.isFree("  openrouter/x/y:free \n"), "surrounding whitespace is ignored")
    }

    func testPaidAndForeignIdsAreNotFree() {
        XCTAssertFalse(CrushFreeModels.isFree("openrouter/anthropic/claude-opus-4.5"))
        XCTAssertFalse(CrushFreeModels.isFree("openrouter/nvidia/nemotron-3.5-lightning"), "no :free suffix")
        XCTAssertFalse(CrushFreeModels.isFree("anthropic/claude-opus-4.5:free"), "not an openrouter id")
        XCTAssertFalse(CrushFreeModels.isFree("openai/gpt-5:free"))
        XCTAssertFalse(CrushFreeModels.isFree("opencode/big-pickle"), "OpenCode's free rule is not Crush's")
        XCTAssertFalse(CrushFreeModels.isFree("openrouter/:free"), "no model between the provider and :free")
        XCTAssertFalse(CrushFreeModels.isFree("openrouter/x:free-but-paid"))
        XCTAssertFalse(CrushFreeModels.isFree(""))
        XCTAssertFalse(CrushFreeModels.isFree("   "))
    }

    func testOpenCodeRuleDoesNotAdmitCrushIds() {
        XCTAssertFalse(OpenCodeFreeModels.isFree("openrouter/nvidia/nemotron-3.5-lightning:free"))
    }

    func testSessionConfigUsesTheSharedRule() {
        for id in ["openrouter/a/b:free", "openrouter/a/b", "anthropic/x:free", "", "openrouter/:free"] {
            XCTAssertEqual(CrushSessionConfig.isFree(id), CrushFreeModels.isFree(id), id)
        }
    }

    // MARK: - `crush models`

    private let sampleOutput = """
    anthropic/claude-opus-4.5
    openrouter/anthropic/claude-opus-4.5
    openrouter/nvidia/nemotron-3.5-lightning:free
    \u{200B}openrouter/nvidia/nemotron-3.5-super-vl:free
    openai/gpt-5:free

    openrouter/google/gemini-3-pro
    openrouter/nvidia/nemotron-3-ultra-550b-a55b:free
    """

    func testParserKeepsFreeOpenRouterIdsOnly() {
        let models = ModelListParser.crush(sampleOutput)
        XCTAssertEqual(models.map(\.id), [
            "openrouter/nvidia/nemotron-3.5-lightning:free",
            "openrouter/nvidia/nemotron-3.5-super-vl:free",
            "openrouter/nvidia/nemotron-3-ultra-550b-a55b:free",
        ])
        XCTAssertEqual(models.map(\.name), models.map(\.id), "the name is the id")
    }

    func testListingForCrushParsesAndKeepsFreeOnly() throws {
        let models = try ModelListParser.listing(sampleOutput, for: .crush)
        XCTAssertEqual(models.count, 3)
        XCTAssertTrue(models.allSatisfy { CrushFreeModels.isFree($0.id) })
    }

    func testListingWithNoFreeModelIsAnError() {
        XCTAssertThrowsError(try ModelListParser.listing("openrouter/anthropic/claude-opus-4.5\n", for: .crush)) { error in
            XCTAssertEqual(String(describing: error), "crush models listed nothing: openrouter/anthropic/claude-opus-4.5")
        }
        XCTAssertThrowsError(try ModelListParser.listing("", for: .crush))
    }

    func testCrushIsAListedAgent() {
        XCTAssertTrue(ModelListParser.listedAgents.contains(.crush))
        XCTAssertNil(ModelListParser.fixed(for: .crush))
    }

    @MainActor
    func testRefresherListsCrushThroughTheInjectedRunner() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-crush-list-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = ModelListCache(directory: dir)
        let output = sampleOutput
        let refresher = ModelListRefresher(
            cache: cache,
            runner: { agent in
                switch agent {
                case .crush: return output
                case .agy: return "Fetching available models...\ngemini-3.8-flash-medium\tFlash\n"
                case .cursor, .grok: return "Available models\n\nauto - Auto\ngrok-4.7-low - Grok 4.7  Low\n"
                case .opencode: return "opencode/big-pickle\n"
                default: throw LinkCError.process("unexpected agent \(agent)")
                }
            },
            sleep: { _ in })

        await refresher.refreshNow()

        let list = try XCTUnwrap(try cache.read()[.crush])
        XCTAssertNil(list.error)
        XCTAssertEqual(list.models.count, 3)
        XCTAssertTrue(list.models.allSatisfy { CrushFreeModels.isFree($0.id) })
    }

    @MainActor
    func testARefreshWhoseCrushOutputHasNoFreeModelRecordsAnError() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-crush-list-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = ModelListCache(directory: dir)
        let refresher = ModelListRefresher(
            cache: cache,
            runner: { agent in
                if agent == .crush { return "openrouter/anthropic/claude-opus-4.5\n" }
                throw LinkCError.process("offline")
            },
            sleep: { _ in })

        await refresher.refreshNow()

        let list = try XCTUnwrap(try cache.read()[.crush])
        XCTAssertEqual(list.error, "crush models listed nothing: openrouter/anthropic/claude-opus-4.5")
        XCTAssertTrue(list.models.isEmpty)
    }

    // MARK: - Tiers

    func testSeededTiersAreTheSpecsFreeModels() {
        let settings = AgentModelSettings.seeded
        XCTAssertEqual(settings.model(for: .crush, tier: .light), "openrouter/nvidia/nemotron-3.5-lightning:free")
        XCTAssertEqual(settings.model(for: .crush, tier: .standard), "openrouter/nvidia/nemotron-3.5-super-vl:free")
        XCTAssertEqual(settings.model(for: .crush, tier: .deep), "openrouter/nvidia/nemotron-3-ultra-550b-a55b:free")
        XCTAssertEqual(settings.defaultTier(for: .crush), .standard)
        for tier in ModelTier.allCases {
            XCTAssertTrue(CrushFreeModels.isFree(try XCTUnwrap(settings.model(for: .crush, tier: tier))), tier.rawValue)
        }
    }

    // MARK: - Settings picker

    func testCrushPickerOptionsAreFreeOnly() {
        let lists: [AgentKind: AgentModelList] = [
            .crush: AgentModelList(
                models: [
                    ListedModel(id: "openrouter/nvidia/nemotron-3.5-super-vl:free", name: "x"),
                    ListedModel(id: "openrouter/anthropic/claude-opus-4.5", name: "y"),
                ],
                fetchedAt: Date(), error: nil),
        ]
        var settings = AgentModelSettings.seeded
        settings.setModel("openrouter/anthropic/claude-opus-4.5", for: .crush, tier: .deep)
        let choices = TierModelChoices.make(
            agent: .crush, lists: lists, settings: settings,
            current: "openrouter/nvidia/nemotron-3.5-super-vl:free")
        XCTAssertTrue(choices.optionLabels.contains("openrouter/nvidia/nemotron-3.5-super-vl:free"))
        XCTAssertFalse(choices.optionLabels.contains("openrouter/anthropic/claude-opus-4.5"))
    }

    func testTypedPaidCrushIdIsRefused() {
        let paid = "openrouter/anthropic/claude-opus-4.5"
        XCTAssertEqual(TierModelChoices.validationError(forTypedId: paid, agent: .crush),
                       "\(paid) is not a free Crush model")
        XCTAssertEqual(
            TierModelChoices.make(agent: .crush, lists: [:], settings: .seeded, current: paid).validationError,
            "\(paid) is not a free Crush model")
        XCTAssertNil(TierModelChoices.validationError(forTypedId: "openrouter/a/b:free", agent: .crush))
        XCTAssertNil(TierModelChoices.validationError(forTypedId: "", agent: .crush))
    }

    func testPaidCrushIdGetsNoListWarningOnTopOfTheRefusal() {
        let paid = "openrouter/anthropic/claude-opus-4.5"
        let lists: [AgentKind: AgentModelList] = [
            .crush: AgentModelList(
                models: [ListedModel(id: "openrouter/a/b:free", name: "openrouter/a/b:free")],
                fetchedAt: Date(), error: nil),
        ]
        XCTAssertNil(TierModelChoices.warning(forTypedId: paid, agent: .crush, lists: lists))
    }

    // MARK: - Delegation (MCPServer)

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-crush-free-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private func server(lists: [AgentKind: AgentModelList] = [:], settings: AgentModelSettings = .seeded) -> MCPServer {
        MCPServer(
            workspaceRoot: tempDir.path,
            inboxStore: InboxStore(workspaceRoot: tempDir.path),
            environment: ["LINKC_AGENT": "claude"],
            ancestorResolver: { _ in nil },
            modelSettings: { settings },
            sessionResolver: { nil },
            usageReaders: [:],
            openCodeModels: { _ in [] },
            modelLists: { lists })
    }

    private func delegate(_ server: MCPServer, _ arguments: [String: Any]) throws -> (text: String, isError: Bool) {
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

    func testDelegatingAPaidCrushModelIsRefusedAndListsTheFreeOnes() throws {
        let lists: [AgentKind: AgentModelList] = [
            .crush: AgentModelList(
                models: [
                    ListedModel(id: "openrouter/nvidia/nemotron-3.5-super-vl:free", name: "a"),
                    ListedModel(id: "openrouter/anthropic/claude-opus-4.5", name: "b"),
                ],
                fetchedAt: Date(), error: nil),
        ]
        let result = try delegate(server(lists: lists), [
            "to": "crush", "prompt": "x", "model": "openrouter/anthropic/claude-opus-4.5",
        ])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("not free"), result.text)
        XCTAssertTrue(result.text.contains("Crush runs free models only"), result.text)
        XCTAssertTrue(result.text.contains("openrouter/nvidia/nemotron-3.5-super-vl:free"), result.text)
        XCTAssertFalse(result.text.contains("Free models: openrouter/anthropic"), result.text)
        XCTAssertTrue(try InboxStore(workspaceRoot: tempDir.path).openTasks().isEmpty)
    }

    func testDelegatingAFreeCrushModelIsAccepted() throws {
        let lists: [AgentKind: AgentModelList] = [
            .crush: AgentModelList(
                models: [ListedModel(id: "openrouter/nvidia/nemotron-3.5-super-vl:free", name: "a")],
                fetchedAt: Date(), error: nil),
        ]
        let result = try delegate(server(lists: lists), [
            "to": "crush", "prompt": "x", "model": "openrouter/nvidia/nemotron-3.5-super-vl:free",
        ])
        XCTAssertFalse(result.isError, result.text)
        let task = try XCTUnwrap(try InboxStore(workspaceRoot: tempDir.path).openTasks().first)
        XCTAssertEqual(task.model, "openrouter/nvidia/nemotron-3.5-super-vl:free")
    }

    func testDelegatingToACrushTierSetToAPaidModelIsRefused() throws {
        var settings = AgentModelSettings.seeded
        settings.setModel("openrouter/anthropic/claude-opus-4.5", for: .crush, tier: .deep)
        let result = try delegate(server(settings: settings), ["to": "crush", "prompt": "x", "tier": "deep"])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("openrouter/anthropic/claude-opus-4.5 (crush tier deep) is not free"), result.text)
        XCTAssertTrue(result.text.contains("Crush runs free models only"), result.text)
        XCTAssertTrue(try InboxStore(workspaceRoot: tempDir.path).openTasks().isEmpty)
    }

    func testDelegatingToACrushTierWithAFreeModelIsAccepted() throws {
        let result = try delegate(server(), ["to": "crush", "prompt": "x", "tier": "light"])
        XCTAssertFalse(result.isError, result.text)
        let task = try XCTUnwrap(try InboxStore(workspaceRoot: tempDir.path).openTasks().first)
        XCTAssertEqual(task.tier, .light)
    }

    func testACrushTierThatCrushNoLongerListsIsRefused() throws {
        let lists: [AgentKind: AgentModelList] = [
            .crush: AgentModelList(
                models: [ListedModel(id: "openrouter/other/model:free", name: "a")],
                fetchedAt: Date(), error: nil),
        ]
        let result = try delegate(server(lists: lists), ["to": "crush", "prompt": "x", "tier": "standard"])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("no longer offers"), result.text)
    }
}

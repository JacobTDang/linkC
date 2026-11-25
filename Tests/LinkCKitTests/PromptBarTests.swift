import XCTest
import os
@testable import LinkCKit

/// The prompt bar: the user types a task once, and linkC shows which agent, model and effort will take
/// it, then opens that session on Enter.
@MainActor
final class PromptBarTests: XCTestCase {
    nonisolated(unsafe) private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-prompt-bar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private var folder: String { ProjectPath.canonical(tempDir.path) }
    private var inbox: InboxStore { InboxStore(workspaceRoot: tempDir.path) }

    private static let implement = "Implement the login form and add unit tests"

    /// Counts calls, from any thread.
    private final class Count: Sendable {
        private let count = OSAllocatedUnfairLock(initialState: 0)
        var value: Int { count.withLock { $0 } }
        func bump() { count.withLock { $0 += 1 } }
    }

    /// The sessions a fake opener was asked for.
    private final class Launches {
        var all: [PromptBarLaunch] = []
    }

    /// The project a fake app has on screen.
    private final class OnScreen {
        var folder: String?
    }

    private struct Crashed: Error, CustomStringConvertible {
        let description = "the CLI crashed"
    }

    /// A bar on fixture facts, with the folder's real inbox for limits. `gatherings` counts each time the
    /// bar reads the routing facts; `listings` each time it runs an agent's own CLI to list its models.
    private func makeBar(
        installed: [AgentKind],
        settings: AgentModelSettings = .seeded,
        lists: @escaping @Sendable () throws -> [AgentKind: AgentModelList] = TestModelLists.none,
        clock: ManualClock,
        gatherings: Count = Count(),
        listings: Count = Count(),
        listing: [String] = [],
        launches: Launches = Launches()
    ) -> PromptBar {
        let folder = self.folder
        let inbox = self.inbox
        let services = PromptBar.Services(
            folder: { folder },
            settings: { settings },
            inputs: { _ in
                gatherings.bump()
                return RouteInputs(
                    isInstalled: { installed.contains($0) },
                    liveLimits: { try inbox.liveLimits(agent: $0) },
                    usageReaders: [:],
                    agentsOpen: { ([], nil) })
            },
            readLists: lists,
            listFolder: { _, _ in
                listings.bump()
                return listing
            },
            open: { launch in
                launches.all.append(launch)
                return "S-\(launches.all.count)"
            })
        return PromptBar(services: services, clock: clock, debounce: .milliseconds(250))
    }

    /// Waits for the bar's debounce to start sleeping, lets it run out, then waits for the preview.
    private func settle(_ bar: PromptBar, _ clock: ManualClock, file: StaticString = #filePath, line: UInt = #line) async {
        await waitUntil(file: file, line: line) { !clock.pendingSleeps.isEmpty }
        clock.advance(by: .milliseconds(250))
        await bar.previewWork?.value
    }

    private func waitUntil(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("the condition never held", file: file, line: line)
    }

    private func pick(_ bar: PromptBar, file: StaticString = #filePath, line: UInt = #line) -> PromptBarPick? {
        guard case .pick(let pick) = bar.line else {
            XCTFail("expected a pick, the line is \(bar.line)", file: file, line: line)
            return nil
        }
        return pick
    }

    // MARK: - Preview

    func testThePreviewNamesTheAgentTheModelAndTheEffort() async {
        let clock = ManualClock()
        let bar = makeBar(installed: [.codex], clock: clock)

        bar.text = Self.implement
        await settle(bar, clock)

        XCTAssertEqual(pick(bar)?.text, "→ Codex · gpt-5.6-sol · medium — implementation")
    }

    /// The model is named as the agent's own list names it, not by its id.
    func testThePreviewNamesTheModelAsTheAgentListsIt() async {
        let clock = ManualClock()
        let bar = makeBar(installed: [.agy], lists: TestModelLists.agy, clock: clock)

        bar.text = Self.implement
        await settle(bar, clock)

        XCTAssertEqual(pick(bar)?.text, "→ agy · Gemini 3.8 Flash (Medium) · medium — implementation")
    }

    /// The reason says what the task is and why an agent that would have come first was passed over.
    func testThePreviewSaysWhyAnAgentWasPassedOver() async throws {
        try inbox.recordLimit(agent: .claude, reason: "usage cap", cooldown: 3600)
        let clock = ManualClock()
        let bar = makeBar(installed: [.claude, .codex], clock: clock)

        bar.text = Self.implement
        await settle(bar, clock)

        XCTAssertEqual(pick(bar)?.reason, "implementation; claude skipped (limited)")
        XCTAssertEqual(pick(bar)?.text, "→ Codex · gpt-5.6-sol · medium — implementation; claude skipped (limited)")
    }

    /// Nothing free: the line is the router's own refusal.
    func testWithNothingFreeTheLineIsTheRoutersRefusal() async throws {
        try inbox.recordLimit(agent: .claude, reason: "usage cap", cooldown: 3600)
        let clock = ManualClock()
        let bar = makeBar(installed: [.claude], clock: clock)

        bar.text = Self.implement
        await settle(bar, clock)

        XCTAssertEqual(bar.line, .error("no installed agent is free to take this task at standard — claude skipped (limited)"))
    }

    /// A tier model the free-model rules refuse: the line says which model and why.
    func testARefusedModelIsNamedInTheLine() async {
        var settings = AgentModelSettings.seeded
        settings.setModel("opencode/paid-model", for: .opencode, tier: .standard)
        let clock = ManualClock()
        let bar = makeBar(installed: [.opencode], settings: settings, clock: clock)

        bar.text = Self.implement
        await settle(bar, clock)

        XCTAssertEqual(bar.line, .error(
            "no installed agent is free to take this task at standard — opencode skipped (opencode/paid-model (opencode tier standard) is not free — OpenCode runs free models only)"))
    }

    /// Typing reads nothing: the routing facts are read once, after the typing stops for the debounce.
    func testThePreviewWaitsForTheTypingToPause() async {
        let clock = ManualClock()
        let gatherings = Count()
        let bar = makeBar(installed: [.codex], clock: clock, gatherings: gatherings)

        for prefix in ["I", "Im", "Implement", Self.implement] {
            bar.text = prefix
            await waitUntil { clock.pendingSleeps.count == 1 }
        }
        clock.advance(by: .milliseconds(249))
        await Task.yield()
        XCTAssertEqual(gatherings.value, 0)
        XCTAssertEqual(bar.line, .idle)

        clock.advance(by: .milliseconds(1))
        await waitUntil { gatherings.value > 0 }
        await bar.previewWork?.value

        XCTAssertEqual(gatherings.value, 1)
        XCTAssertEqual(pick(bar)?.text, "→ Codex · gpt-5.6-sol · medium — implementation")
    }

    /// The pick is read for the project on screen: moving to another project reads it again there, at once.
    func testAProjectChangeReadsThePickAgainForTheNewProject() async throws {
        let other = tempDir.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try inbox.recordLimit(agent: .claude, reason: "usage cap", cooldown: 3600)
        let current = OnScreen()
        current.folder = folder
        let services = PromptBar.Services(
            folder: { current.folder }, settings: { .seeded },
            inputs: { folder in
                RouteInputs(
                    isInstalled: { [.claude, .codex].contains($0) },
                    liveLimits: { try InboxStore(workspaceRoot: folder).liveLimits(agent: $0) },
                    usageReaders: [:], agentsOpen: { ([], nil) })
            },
            readLists: TestModelLists.none, listFolder: { _, _ in [] }, open: { _ in "S-1" })
        let clock = ManualClock()
        let bar = PromptBar(services: services, clock: clock, debounce: .milliseconds(250))
        bar.text = Self.implement
        await settle(bar, clock)
        XCTAssertEqual(pick(bar)?.agent, .codex)

        current.folder = ProjectPath.canonical(other.path)
        await bar.projectChanged()?.value

        XCTAssertEqual(pick(bar)?.agent, .claude)
    }

    // MARK: - Override

    /// Tab moves to the next agent that could take the task, and back round to the router's own pick.
    /// A limited agent, a refused one, Cursor and Freebuff are never offered.
    func testTabCyclesOnlyThroughTheEligibleAgents() async throws {
        try inbox.recordLimit(agent: .claude, reason: "usage cap", cooldown: 3600)
        var settings = AgentModelSettings.seeded
        settings.setModel("gemini-9-gone", for: .agy, tier: .standard)
        let clock = ManualClock()
        let bar = makeBar(
            installed: [.claude, .agy, .cursor, .codex, .opencode, .freebuff], settings: settings,
            lists: TestModelLists.agy, clock: clock)

        bar.text = Self.implement
        await settle(bar, clock)
        var seen = [pick(bar)?.agent]
        for _ in 0..<3 {
            await bar.cycleAgent()?.value
            seen.append(pick(bar)?.agent)
        }

        XCTAssertEqual(seen, [.codex, .opencode, .codex, .opencode])
        XCTAssertEqual(bar.override, .opencode)
        XCTAssertEqual(pick(bar)?.text, "→ OpenCode · opencode/big-pickle — implementation; your pick")
    }

    /// Esc empties the bar: the text, the agent picked by hand, and the line.
    func testEscClearsTheTextTheOverrideAndTheLine() async {
        let clock = ManualClock()
        let bar = makeBar(installed: [.claude, .codex], clock: clock)
        bar.text = Self.implement
        await settle(bar, clock)
        await bar.cycleAgent()?.value
        XCTAssertEqual(bar.override, .codex)

        bar.clear()

        XCTAssertEqual(bar.text, "")
        XCTAssertNil(bar.override)
        XCTAssertEqual(bar.line, .idle)
    }

    // MARK: - Submit

    /// The folder CLI that lists OpenCode's and Kilo's models runs once, for the agent picked, on Enter.
    /// Typing and cycling never start it.
    func testTheFolderListingRunsOnceOnSubmitAndNeverWhileTyping() async throws {
        let clock = ManualClock()
        let listings = Count()
        let launches = Launches()
        let opencode = AgentModelSettings.seeded.model(for: .opencode, tier: .light)!
        let bar = makeBar(
            installed: [.codex, .opencode], clock: clock, listings: listings, listing: [opencode], launches: launches)

        bar.text = "Browse the docs for this API"
        await settle(bar, clock)
        XCTAssertEqual(pick(bar)?.agent, .opencode)
        await bar.cycleAgent()?.value
        await bar.cycleAgent()?.value
        XCTAssertEqual(pick(bar)?.agent, .opencode)
        XCTAssertEqual(listings.value, 0)

        await bar.submit()?.value

        XCTAssertEqual(listings.value, 1)
        XCTAssertEqual(launches.all, [PromptBarLaunch(
            folder: folder, agent: .opencode, tier: .light, effort: nil, prompt: "Browse the docs for this API")])
    }

    /// The picked agent's own CLI refuses its model: nothing opens, and the line says why.
    func testAModelTheFolderListingRefusesOpensNothing() async {
        let clock = ManualClock()
        let launches = Launches()
        let bar = makeBar(installed: [.opencode], clock: clock, listing: ["opencode/other-free"], launches: launches)
        bar.text = "Browse the docs for this API"
        await settle(bar, clock)

        await bar.submit()?.value

        XCTAssertEqual(launches.all, [])
        XCTAssertEqual(bar.line, .error(
            "no installed agent is free to take this task at light — opencode skipped (opencode/deepseek-v4.1-flash-free (opencode tier light) is not among the models OpenCode lists — free models come and go)"))
        XCTAssertEqual(bar.text, "Browse the docs for this API")
    }

    /// Enter on an agent picked by hand opens that agent, still asking its CLI about the model.
    func testSubmitOpensTheAgentPickedByHand() async {
        let clock = ManualClock()
        let launches = Launches()
        let bar = makeBar(installed: [.claude, .codex], clock: clock, launches: launches)
        bar.text = Self.implement
        await settle(bar, clock)
        await bar.cycleAgent()?.value

        await bar.submit()?.value

        XCTAssertEqual(launches.all.map(\.agent), [.codex])
        XCTAssertEqual(bar.text, "")
        XCTAssertNil(bar.override)
        XCTAssertEqual(bar.line, .idle)
    }

    func testWithNoProjectOnScreenEnterSaysSo() async {
        let services = PromptBar.Services(
            folder: { nil }, settings: { .seeded },
            inputs: { _ in RouteInputs(isInstalled: { _ in true }, liveLimits: { _ in [] }, usageReaders: [:], agentsOpen: { ([], nil) }) },
            readLists: TestModelLists.none, listFolder: { _, _ in [] }, open: { _ in "S-1" })
        let bar = PromptBar(services: services, clock: ManualClock(), debounce: .milliseconds(250))
        bar.text = Self.implement

        await bar.submit()?.value

        XCTAssertEqual(bar.line, .error(PromptBar.noProjectMessage))
    }

    // MARK: - Through the coordinator

    /// A coordinator whose agents are stand-ins that wait like an idle agent.
    private func makeCoordinator(
        settings: AgentModelSettings = .seeded,
        modelLists: @escaping @MainActor @Sendable () throws -> [AgentKind: AgentModelList] = { [:] },
        usageReaders: [AgentKind: MCPServer.UsageReader] = [:]
    ) -> AppCoordinator {
        for kind in AgentKind.allCases {
            let script = tempDir.appendingPathComponent("agents/\(kind.rawValue)")
            try? FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? "#!/bin/sh\nstty -echo 2>/dev/null\nprintf '\\033[?2004h'\nexec /bin/cat\n"
                .write(to: script, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        }
        let settingsDir = tempDir.appendingPathComponent("settings")
        try? FileManager.default.createDirectory(at: settingsDir, withIntermediateDirectories: true)
        return AppCoordinator(
            terminals: TerminalSessionManager(),
            hookServer: HookServer.forTesting(),
            notifications: NotificationManager(sink: SilentSink(), now: { Date() }),
            claudePath: tempDir.appendingPathComponent("agents/claude").path,
            settingsDir: settingsDir,
            userSettingsURL: tempDir.appendingPathComponent("user-settings.json"),
            manifestDir: tempDir.appendingPathComponent("manifest"),
            agentPathResolver: { [tempDir] kind in tempDir!.appendingPathComponent("agents/\(kind.rawValue)").path },
            modelSettings: { settings },
            modelLists: modelLists,
            usageReaders: usageReaders,
            deliverySettle: 0,
            injectionGap: 0,
            isWatching: { _ in false })
    }

    private struct SilentSink: NotificationSink {
        func deliver(id: String, title: String, body: String) {}
    }

    /// Enter opens the user's own session of the pick in the project: unpinned, on the tier's model and
    /// effort, with the text waiting as its opening prompt.
    func testSubmitOpensAUserOwnedUnpinnedSessionWithTheModelEffortAndPrompt() async throws {
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }
        let clock = ManualClock()
        let folder = self.folder
        let bar = PromptBar(
            services: coordinator.promptBarServices(
                folder: { folder }, readLists: TestModelLists.none, listFolder: { _, _ in [] }),
            clock: clock, debounce: .milliseconds(250))
        var opened: [String] = []
        bar.onOpened = { opened.append($0) }

        bar.text = Self.implement
        await settle(bar, clock)
        await bar.submit()?.value

        let id = try XCTUnwrap(opened.first)
        let session = try XCTUnwrap(coordinator.store.session(id: id))
        XCTAssertEqual(session.agentKind, .claude)
        XCTAssertEqual(session.cwd, folder)
        XCTAssertEqual(session.model, "sonnet")
        XCTAssertEqual(session.effort, .medium)
        XCTAssertNil(session.modelTier, "the user's own session runs unpinned")
        XCTAssertFalse(session.isWorker, "the user's own session, not a worker")
        XCTAssertEqual(coordinator.openingPrompts[id]?.text, Self.implement)
        XCTAssertEqual(coordinator.terminals.selectedId, id)
    }

    /// OpenCode launches the Go copy of its tier model when OpenCode lists one: the preview names that
    /// model, the one the session runs.
    func testThePreviewNamesTheOpenCodeGoModelTheSessionLaunchesWith() async throws {
        let configured = try XCTUnwrap(AgentModelSettings.seeded.model(for: .opencode, tier: .light))
        let go = "opencode-go/" + configured.dropFirst("opencode/".count)
        let listed: [AgentKind: AgentModelList] = [.opencode: AgentModelList(
            models: [ListedModel(id: configured, name: configured), ListedModel(id: go, name: go)],
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_000))]
        // Only OpenCode has models, so the task goes to it.
        var settings = AgentModelSettings.seeded
        for agent in AgentKind.allCases where agent != .opencode {
            for tier in ModelTier.allCases { settings.setModel("", for: agent, tier: tier) }
        }
        let coordinator = makeCoordinator(settings: settings, modelLists: { listed })
        defer { coordinator.shutdown() }
        let clock = ManualClock()
        let folder = self.folder
        let bar = PromptBar(
            services: coordinator.promptBarServices(
                folder: { folder }, readLists: { listed }, listFolder: { _, _ in [configured] }),
            clock: clock, debounce: .milliseconds(250))
        var opened: [String] = []
        bar.onOpened = { opened.append($0) }

        bar.text = "Browse the docs for this API"
        await settle(bar, clock)
        XCTAssertEqual(pick(bar)?.model, go)
        await bar.submit()?.value

        let id = try XCTUnwrap(opened.first)
        XCTAssertEqual(coordinator.store.session(id: id)?.model, go)
    }

    /// The tie-break toward an agent already open in the folder compares canonical paths on both
    /// sides, as the MCP tool does: a session opened under another spelling of the folder still counts.
    func testTheTieBreakSeesASessionOpenedUnderAnotherSpellingOfTheFolder() async throws {
        XCTAssertNotEqual(tempDir.path, folder, "the fixture needs a folder spelled two ways")
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }
        try coordinator.newSession(cwd: tempDir.path, agent: .opencode, select: false)
        let clock = ManualClock()
        let folder = self.folder
        let bar = PromptBar(
            services: coordinator.promptBarServices(
                folder: { folder }, readLists: TestModelLists.none, listFolder: { _, _ in [] }),
            clock: clock, debounce: .milliseconds(250))

        bar.text = Self.implement
        await settle(bar, clock)

        XCTAssertEqual(pick(bar)?.agent, .opencode)
        XCTAssertEqual(pick(bar)?.reason, "implementation; tie → already active in folder")
    }

    /// The session opens in the folder's canonical path, whatever spelling the launch was given.
    func testOpenRoutedOpensInTheCanonicalFolder() throws {
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }

        let session = try coordinator.openRouted(PromptBarLaunch(
            folder: tempDir.path, agent: .codex, tier: .standard, effort: nil, prompt: Self.implement))

        XCTAssertEqual(session.cwd, folder)
    }

    /// The MCP tool's auto-route and the bar read the same facts the same way: a usage window near its
    /// limit, a recorded limit and an agent already open in the folder all shape both picks alike.
    func testTheToolAndTheBarRouteAPromptAlike() async throws {
        let tight: MCPServer.UsageReader = {
            AgentUsage(agent: .claude, windows: [UsageWindow(label: "5h", usedPercent: 95, tokens: nil, resetsAt: nil)],
                       planType: nil, observedAt: Date(), unavailableReason: nil)
        }
        try inbox.recordLimit(agent: .agy, reason: "quota", cooldown: 3600)
        let coordinator = makeCoordinator(usageReaders: [.claude: tight])
        defer { coordinator.shutdown() }
        let open = try coordinator.newSession(cwd: folder, agent: .opencode, select: false)
        let knownProjects = KnownProjectsFile(url: tempDir.appendingPathComponent("projects.json"))
        try knownProjects.write([
            KnownProject(path: folder, sessions: [.init(id: open.id, agent: "opencode", activity: .idle)])
        ])
        let server = MCPServer(
            workspaceRoot: tempDir.path,
            inboxStore: inbox,
            environment: ["LINKC_AGENT": "claude"],
            ancestorResolver: { _ in nil },
            modelSettings: { .seeded },
            sessionResolver: { nil },
            usageReaders: [.claude: tight],
            isAgentInstalled: { _ in true },
            openCodeModels: { _ in [AgentModelSettings.seeded.model(for: .opencode, tier: .standard)!] },
            kiloModels: { _ in [] },
            modelLists: TestModelLists.none,
            knownProjects: knownProjects)

        let request: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "linkc_delegate_task", "arguments": ["prompt": Self.implement]],
        ]
        let data = try XCTUnwrap(server.handleMessage(try JSONSerialization.data(withJSONObject: request)))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let text = try XCTUnwrap(((json["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String)
        let task = try XCTUnwrap(try inbox.openTasks().first)

        let clock = ManualClock()
        let folder = self.folder
        let bar = PromptBar(
            services: coordinator.promptBarServices(
                folder: { folder }, readLists: TestModelLists.none, listFolder: { _, _ in [] }),
            clock: clock, debounce: .milliseconds(250))
        bar.text = Self.implement
        await settle(bar, clock)

        let notes = ["claude skipped (usage tight)", "agy skipped (limited)", "tie → already active in folder"]
        XCTAssertTrue(text.contains("Routed: implementation → opencode standard; \(notes.joined(separator: "; "))."), text)
        XCTAssertEqual(task.toAgent, .opencode)
        XCTAssertEqual(pick(bar)?.agent, task.toAgent)
        XCTAssertEqual(pick(bar)?.reason, (["implementation"] + notes).joined(separator: "; "))
    }
}

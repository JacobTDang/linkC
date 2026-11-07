# OpenCode Agent Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** linkC runs OpenCode, on OpenCode's free models, as an agent like the others: menu, `linkc opencode`, delegation, tiers, tools, screen state, limits, usage row.

**Architecture:** A new `AgentKind.opencode` that launches `opencode --standalone --auto` (OpenCode 2.2.5, spec §4.1), with the session's model in `OPENCODE_CONFIG_CONTENT` — the TUI has no model flag. linkC's MCP server reaches it two ways: registered in `~/.config/opencode/opencode.json`, and injected per launch through `OPENCODE_CONFIG_CONTENT`. Session state is read off OpenCode's screen by a dedicated reader (`OpenCodeScreen`). "Continue" opens the folder's own session with `--session <id>`, found by `opencode session list --standalone` off the main thread. `linkc-mcp` refuses delegation to a tier whose model `opencode models --standalone` no longer lists.

**Tech Stack:** Swift 6 (strict concurrency), SwiftPM, XCTest, SwiftUI app target `linkc`, library `LinkCKit`.

**Spec:** `docs/superpowers/specs/2026-11-07-opencode-agent-design.md`. Read it before any task.

## Global Constraints

- Work only in `/Users/jacobdang/Projects/linkC/.worktrees/opencode-agent`. Never touch `.worktrees/discord-notifications`.
- Build and test with the isolated build folder, never the default `.build`:
  - `SP=/private/tmp/claude-501/-Users-jacobdang-Projects-linkC/65d23432-9669-4f94-979d-931668e62d0c/scratchpad/build`
  - one suite: `swift test --scratch-path $SP --filter <SuiteName>`
  - both targets compile: `swift build --scratch-path $SP`
- Never quit, launch, signal or restart linkC. Never run `build-app.sh --install`. Never run the built `linkc` command except with `--help`. Never run the built `linkc-mcp`. Kill a process only by PID, never `pkill -f`.
- Commits: conventional subject (`feat(opencode): …`, `fix(mcp): …`, `test(opencode): …`, `docs: …`). No trailers of any kind (no Co-Authored-By, no Signed-off-by). Never mention any AI, assistant or tool name in a commit.
- TDD: write the test, run it and see it fail for the expected reason, implement, see it pass. After the task is green, prove each new test with a revert: commit, revert the production change for that test (`git stash push -m <tag> -- <file>` is not allowed — instead edit the line back by hand), run the test, see it fail, `git checkout -- <file>` to restore. If a test cannot be made to fail against the old code, say so in the report instead of committing a vacuous test.
- Fail loud: no `try?` that hides an error from the user, no silent fallback.
- No new dependencies.
- `SettingsScreen.swift`, `AppPreferences.swift`, `NotificationManager.swift` and every `AppCoordinator*.swift` file are also changed on another branch: keep edits there to the lines this plan names.
- Test text that an agent's limit rules or linkC's screen reader would match is split with `+` (for example `"Free usage " + "exceeded"`), as the existing tests do, so linkC does not read it off a developer's terminal.
- Model ids are exactly: light `opencode/deepseek-v4.1-flash-free`, standard (default) `opencode/big-pickle`, deep `opencode/crouton-alpha-free`.

---

### Task 1: The OpenCode agent kind

**Files:**
- Modify: `Sources/LinkCKit/Core/AgentKind.swift`
- Modify: `Sources/LinkCKit/Core/AgentLogo.swift`
- Modify: `Sources/LinkCKit/Core/AgentModelCatalog.swift`
- Modify: `Sources/LinkCKit/Core/AgentModelSettings.swift`
- Modify: `Sources/LinkCKit/Core/LimitDetector.swift`
- Modify: `Sources/LinkCKit/Terminal/ProcessSnooper.swift`
- Modify: `Sources/LinkCKit/Usage/UsageRows.swift`
- Modify: `Sources/linkc/Theme.swift`
- Test: `Tests/LinkCKitTests/AgentDescriptorTests.swift`, `AgentLogoTests.swift`, `AgentModelCatalogTests.swift`, `AgentModelStoreTests.swift`, `LimitDetectorTests.swift`, `ProcessSnooperTests.swift`, `UsageRowsTests.swift`

**Interfaces:**
- Produces: `AgentKind.opencode` (raw value `"opencode"`, declared after `.grok`, before `.shell`); `AgentDescriptor.openCodeAutoUpdateKey == "OPENCODE_DISABLE_AUTOUPDATE"`; `AgentDescriptor.openCodeConfigContentKey == "OPENCODE_CONFIG_CONTENT"`; `AgentDescriptor.environment(for: .opencode, home:) == ["OPENCODE_DISABLE_AUTOUPDATE": "1"]`; `AgentDescriptor.arguments(for: .opencode, mode: <any>, sessionId:) == ["--auto"]`.

- [ ] **Step 1: Write the failing tests**

In `AgentDescriptorTests.swift`, add:

```swift
    /// OpenCode runs its own binary with every permission approved. It never gets `--continue`:
    /// that takes the newest session of the whole project, in whatever folder it ran.
    func testOpenCodeIsItsOwnAgentWithEveryPermissionApproved() {
        XCTAssertEqual(AgentKind.opencode.pillText, "OPENCODE")
        XCTAssertEqual(AgentKind.opencode.displayName, "OpenCode")
        XCTAssertEqual(AgentKind.opencode.shortName, "OpenCode")
        XCTAssertEqual(AgentKind.opencode.brandColorHex, "#FAB283")
        let opencode = AgentDescriptor.descriptor(for: .opencode)
        XCTAssertEqual(opencode.kind, .opencode)
        XCTAssertEqual(opencode.binaryName, "opencode")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(opencode.defaultCandidatePaths,
                       ["/opt/homebrew/bin/opencode", "/usr/local/bin/opencode", "\(home)/.opencode/bin/opencode"])
        for mode in [LaunchMode.new, .continueLast, .resume] {
            XCTAssertEqual(AgentDescriptor.arguments(for: .opencode, mode: mode, sessionId: "S-1"), ["--auto"], "\(mode)")
        }
    }

    /// With a newer release out, OpenCode opens on an update dialog, and the first text linkC types
    /// would answer it.
    func testAnOpenCodeTerminalTurnsOffTheUpdateDialog() {
        XCTAssertEqual(AgentDescriptor.openCodeAutoUpdateKey, "OPENCODE_DISABLE_AUTOUPDATE")
        XCTAssertEqual(AgentDescriptor.openCodeConfigContentKey, "OPENCODE_CONFIG_CONTENT")
        XCTAssertEqual(AgentDescriptor.environment(for: .opencode, home: URL(fileURLWithPath: "/Users/someone")),
                       ["OPENCODE_DISABLE_AUTOUPDATE": "1"])
    }
```

In the same file, change `testOnlyGrokGetsItsOwnCursorFolderAndWorkerMark`'s loop to `for kind in AgentKind.allCases where kind != .grok && kind != .opencode {`, and `testPeersAreEveryAgentButAShell` to:

```swift
        XCTAssertEqual(AgentKind.peers, [.claude, .agy, .cursor, .codex, .grok, .opencode])
        XCTAssertEqual(AgentKind.peerList, "claude, agy, cursor, codex, grok, opencode")
```

In `AgentLogoTests.swift`, change the template test's comment to "Cursor's, Grok's and OpenCode's marks are one colour …" and its assertion to `[.cursor, .grok, .opencode]`.

In `AgentModelCatalogTests.swift`, add:

```swift
    func testOpenCodeSuggestsItsFreeTiers() {
        XCTAssertEqual(AgentModelCatalog.models(for: .opencode).map(\.id),
                       ["opencode/big-pickle", "opencode/deepseek-v4.1-flash-free", "opencode/crouton-alpha-free"])
        XCTAssertEqual(AgentModelCatalog.defaultModel(for: .opencode).id, "opencode/big-pickle")
    }
```

In `AgentModelStoreTests.swift`, add:

```swift
    func testOpenCodeIsSeededOnFreeModelsWithStandardAsItsDefault() {
        let seeded = AgentModelSettings.seeded
        XCTAssertEqual(seeded.model(for: .opencode, tier: .light), "opencode/deepseek-v4.1-flash-free")
        XCTAssertEqual(seeded.model(for: .opencode, tier: .standard), "opencode/big-pickle")
        XCTAssertEqual(seeded.model(for: .opencode, tier: .deep), "opencode/crouton-alpha-free")
        XCTAssertEqual(seeded.defaultTier(for: .opencode), .standard)
    }

    /// A models.json saved before OpenCode existed names no OpenCode tiers. Loading it must still
    /// give OpenCode its seeded models, or every delegation to OpenCode would be refused.
    func testAFileSavedBeforeOpenCodeExistedLoadsOpenCodeFromTheSeed() throws {
        let store = AgentModelStore(directory: dir)
        let json = """
        {"models":{"grok":{"light":"grok-4.7-low","standard":"grok-4.7-medium","deep":"grok-4.7-xhigh"}},
         "defaultTiers":{"grok":"standard"}}
        """
        try json.write(toFile: store.path, atomically: true, encoding: .utf8)

        let settings = store.load()
        XCTAssertEqual(settings.model(for: .opencode, tier: .standard), "opencode/big-pickle")
        XCTAssertEqual(settings.defaultTier(for: .opencode), .standard)
    }
```

In `LimitDetectorTests.swift`, add:

```swift
    /// OpenCode's free-tier cap, in the words its own retry code shows. A plain 429 is a retry
    /// OpenCode makes by itself, not a cap.
    func testOpenCodesFreeTierCapIsALimitButA429IsNot() {
        let cap = LimitDetector.detectLimit(inOutput: "Free usage " + "exceeded, subscribe to Go", agent: .opencode)
        XCTAssertEqual(cap?.agent, .opencode)
        XCTAssertEqual(cap?.cooldown, LimitDetector.defaultCooldown)
        XCTAssertNotNil(LimitDetector.detectLimit(inOutput: "Free limit " + "reached", agent: .opencode))
        XCTAssertNil(LimitDetector.detectLimit(inOutput: "429 Too Many " + "Requests, retrying in 2s", agent: .opencode))
        XCTAssertNil(LimitDetector.detectLimit(inOutput: "Free usage " + "exceeded, subscribe to Go", agent: .codex),
                     "the phrase is OpenCode's alone")
    }
```

In `ProcessSnooperTests.swift`, add:

```swift
    /// Homebrew links `opencode` to a versioned Cellar binary; the installer puts it in ~/.opencode/bin.
    func testOpenCodeIsDetectedByItsLinkAndItsRealBinary() {
        XCTAssertEqual(ProcessSnooper.detectAgent(inPath: "/opt/homebrew/bin/opencode"), .opencode)
        XCTAssertEqual(ProcessSnooper.detectAgent(inPath: "/opt/homebrew/Cellar/opencode/1.18.19/bin/opencode"), .opencode)
        XCTAssertEqual(ProcessSnooper.detectAgent(inPath: "/Users/someone/.opencode/bin/opencode"), .opencode)
    }
```

In `UsageRowsTests.swift`, change `testTheRowOrderIsFixed` to add `.opencode: cap(.opencode, clearsIn: 1800),` to its `limits` and expect `[.claude, .codex, .cursor, .grok, .opencode, .agy]`. In `testAgentsWithNoSourceAreListedWithTheirReason`, expect the same order and add:

```swift
        XCTAssertEqual(result.unknown.first { $0.agent == .opencode }?.reason,
                       "OpenCode's free models publish no quota locally — only a cap linkC sees in its terminal")
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `swift test --scratch-path $SP --filter 'AgentDescriptorTests|AgentLogoTests|AgentModelCatalogTests|AgentModelStoreTests|LimitDetectorTests|ProcessSnooperTests|UsageRowsTests'`
Expected: compile error, `type 'AgentKind' has no member 'opencode'`.

- [ ] **Step 3: Implement**

`AgentKind.swift`: add `case opencode` between `case grok` and `case shell`. Add to each switch:

```swift
        case .opencode: return "OPENCODE"            // pillText
        case .opencode: return "#FAB283"             // brandColorHex — the accent of OpenCode's default theme
        case .opencode: return "OpenCode"            // displayName
        case .opencode: return "OpenCode"            // shortName
```

In `AgentDescriptor.descriptor(for:)`, add before `case .shell`:

```swift
        case .opencode:
            return AgentDescriptor(
                kind: .opencode,
                binaryName: "opencode",
                defaultCandidatePaths: [
                    "/opt/homebrew/bin/opencode",
                    "/usr/local/bin/opencode",
                    home.appendingPathComponent(".opencode/bin/opencode")
                ],
                // Every permission approved that the config does not deny.
                yoloFlags: ["--auto"],
                // OpenCode's own `--continue` takes the newest session of the whole project — every
                // worktree of a repo is one project — and moves into that session's folder. linkC
                // passes `--session <id>` for this folder's own session instead (AppCoordinator+OpenCode).
                // OpenCode has no session-picker flag.
                continueArgs: [],
                resumeArgs: []
            )
```

Replace `environment(for:home:)` and its doc comment with:

```swift
    /// The variable that keeps OpenCode from opening on its "Update Available" dialog.
    public static let openCodeAutoUpdateKey = "OPENCODE_DISABLE_AUTOUPDATE"

    /// The variable OpenCode reads inline config from, merged over its `opencode.json`.
    public static let openCodeConfigContentKey = "OPENCODE_CONFIG_CONTENT"

    /// What `kind`'s terminal needs beyond `LINKC_SESSION`. Grok: its own Cursor folder, and the
    /// mark linkC's tool server reads to tell it from Cursor. OpenCode: no update dialog — with a
    /// newer release out, OpenCode opens on one, and the first text linkC types (a worker's task)
    /// would answer it. linkC adds OpenCode's inline tool config at launch (AppCoordinator+OpenCode).
    public static func environment(for kind: AgentKind, home: URL) -> [String: String] {
        switch kind {
        case .grok:
            return [
                "CURSOR_CONFIG_DIR": grokConfigDirectory(home: home).path,
                AgentKind.workerEnvironmentKey: AgentKind.grok.rawValue
            ]
        case .opencode:
            return [openCodeAutoUpdateKey: "1"]
        default:
            return [:]
        }
    }
```

`AgentLogo.swift`: add `case .opencode: return AgentLogo(svg: Self.opencodeSVG, isTemplate: true)` and, beside `grokSVG`:

```swift
    private static let opencodeSVG = ##"<svg fill="currentColor" fill-rule="evenodd" height="24" style="flex:none;line-height:1" viewBox="0 0 24 24" width="24" xmlns="http://www.w3.org/2000/svg"><title>opencode</title><path d="M16 6H8v12h8V6zm4 16H4V2h16v20z"></path></svg>"##
```

(The mark is `icons/opencode.svg` from @lobehub/icons-static-svg 1.95.1, the set the file's header credits, with its `1em` size set to 24.)

`AgentModelCatalog.swift`, before `case .shell`:

```swift
        case .opencode:
            return [
                AgentModelInfo(id: "opencode/big-pickle", displayName: "Big Pickle", isFreeOrSubscription: true, isDefault: true),
                AgentModelInfo(id: "opencode/deepseek-v4.1-flash-free", displayName: "DeepSeek V4.1 Flash Free", isFreeOrSubscription: true, isDefault: false),
                AgentModelInfo(id: "opencode/crouton-alpha-free", displayName: "Crouton Alpha Free", isFreeOrSubscription: true, isDefault: false)
            ]
```

`AgentModelSettings.swift`: add to `seeded.models`

```swift
            AgentKind.opencode.rawValue: [
                "light": "opencode/deepseek-v4.1-flash-free", "standard": "opencode/big-pickle", "deep": "opencode/crouton-alpha-free"
            ]
```

and to `seeded.defaultTiers` `AgentKind.opencode.rawValue: ModelTier.standard.rawValue`. Append to the `seeded` doc comment: "The opencode ids are OpenCode's free models as `opencode models` lists them; each answered a live prompt (2026-11-07)."

`LimitDetector.swift`, beside `cursorRules`:

```swift
    /// OpenCode's free-tier cap, in the words its own retry code gives it (read from the 1.18.19
    /// binary: "Free usage exceeded, subscribe to Go", under a "Free limit reached" title). Its
    /// 429 and overload messages are left out: OpenCode retries those by itself, and one retry
    /// would bench it for the whole cooldown.
    private static let openCodeRules: [LimitRule] = [
        LimitRule(canonicalPattern: "OpenCode free usage exceeded", regexPattern: "\\bfree usage exceeded\\b"),
        LimitRule(canonicalPattern: "OpenCode free limit reached", regexPattern: "\\bfree limit reached\\b")
    ]
```

and `case .opencode: return openCodeRules` in `rules(for:)`.

`ProcessSnooper.swift`, in `detectAgent(inPath:)`: `case "opencode": return .opencode` before `default`.

`UsageRows.swift`: `order` becomes `[.claude, .codex, .cursor, .grok, .opencode, .agy]`; `silentSourceReason` gains

```swift
        case .opencode:
            return "OpenCode's free models publish no quota locally — only a cap linkC sees in its terminal"
```

and the `build` switch's silent case becomes `case .cursor, .grok, .opencode, .agy, .shell:`.

`Sources/linkc/Theme.swift`: `case .opencode: return Color(red: 250/255, green: 178/255, blue: 131/255) // #FAB283`.

Fix any other exhaustive `switch` on `AgentKind` the compiler reports, with the value its neighbours use for a non-Claude, non-Cursor agent.

- [ ] **Step 4: Run the tests to see them pass, and build the app target**

Run: the Step 2 command, then `swift build --scratch-path $SP`.
Expected: all pass; build succeeds.

- [ ] **Step 5: Revert-proof, then commit**

Revert-proof each new test as Global Constraints says (for example, drop `case "opencode"` from `ProcessSnooper` and see `testOpenCodeIsDetectedByItsLinkAndItsRealBinary` fail).

```bash
git add Sources/LinkCKit/Core Sources/LinkCKit/Terminal/ProcessSnooper.swift Sources/LinkCKit/Usage/UsageRows.swift Sources/linkc/Theme.swift Tests/LinkCKitTests
git commit -m "feat(opencode): OpenCode is an agent kind, on its free models"
```

---

### Task 2: Every list of agents names OpenCode

**Files:**
- Modify: `Sources/LinkCKit/App/AppCoordinator+Relay.swift` (the `supportedPeers` line only)
- Modify: `Sources/LinkCKit/MCP/MCPServer.swift` (`unidentifiedCallerMessage`, `defaultUsageReaders`, `targetAgents`, the usage-status loop)
- Modify: `Sources/LinkCKit/Command/LinkCCommand.swift`
- Modify: `Sources/LinkCKit/Board/BoardTech.swift`
- Modify: `Sources/linkc/Screens/SettingsScreen.swift` (the MODELS `ForEach` line only)
- Modify: `Sources/linkc/PanelView.swift`, `Sources/linkc/AgentPill.swift` (doc comment), `Sources/LinkCKit/App/WorkspaceManifest.swift` (doc comment)
- Modify: `README.md`
- Create: `Tests/LinkCKitTests/MCPServerOpenCodeTests.swift`
- Test: `Tests/LinkCKitTests/LinkCCommandTests.swift`, `BoardTechTests.swift`, `AppCoordinatorRelayTests.swift`

**Interfaces:**
- Consumes: `AgentKind.opencode` (Task 1).
- Produces: `MCPServerOpenCodeTests` with helpers `makeServer(models:openCodeModels:) -> MCPServer` and `call(_:_:_:) throws -> (text: String, isError: Bool)` that Task 7 extends.

- [ ] **Step 1: Write the failing tests**

Create `Tests/LinkCKitTests/MCPServerOpenCodeTests.swift`:

```swift
import XCTest
@testable import LinkCKit

/// OpenCode through linkC's tool server: its place in every list of agents, and (Task 7) the
/// checks that keep a task off a model OpenCode no longer offers.
final class MCPServerOpenCodeTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-mcp-opencode-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    /// A server whose caller is Claude, on `models`, with no real usage readers.
    private func makeServer(models: AgentModelSettings = .seeded) -> MCPServer {
        MCPServer(workspaceRoot: tempDir.path, inboxStore: InboxStore(workspaceRoot: tempDir.path),
                  environment: ["LINKC_AGENT": "claude"], ancestorResolver: { _ in nil },
                  modelSettings: { models }, sessionResolver: { nil }, usageReaders: [:])
    }

    /// Calls `name` with `arguments`, returning the result's text and whether it is an error.
    private func call(_ server: MCPServer, _ name: String, _ arguments: [String: Any] = [:]) throws -> (text: String, isError: Bool) {
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                      "params": ["name": name, "arguments": arguments]]
        let data = try XCTUnwrap(server.handleMessage(try JSONSerialization.data(withJSONObject: request)))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try XCTUnwrap(json["result"] as? [String: Any], "\(json)")
        let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        return (text, result["isError"] as? Bool ?? false)
    }

    func testAnUnidentifiedCallerIsToldOpenCodeIsAnAgent() {
        XCTAssertTrue(MCPServer.unidentifiedCallerMessage.contains("\"opencode\""), MCPServer.unidentifiedCallerMessage)
    }

    func testTheModelReportListsOpenCodesTiers() throws {
        let report = try call(makeServer(), "linkc_get_models")
        XCTAssertFalse(report.isError, report.text)
        XCTAssertTrue(report.text.contains("## OpenCode\n"), report.text)
        XCTAssertTrue(report.text.contains("- **light**: opencode/deepseek-v4.1-flash-free\n"), report.text)
        XCTAssertTrue(report.text.contains("- **standard**: opencode/big-pickle — default\n"), report.text)
        XCTAssertTrue(report.text.contains("- **deep**: opencode/crouton-alpha-free\n"), report.text)
    }

    func testTheUsageReportHasAnOpenCodeSection() throws {
        let report = try call(makeServer(), "linkc_get_usage_status")
        XCTAssertTrue(report.text.contains("## OpenCode"), report.text)
    }

    func testOpenCodesDefaultUsageReaderSaysWhyItHasNoFigures() throws {
        let usage = try XCTUnwrap(MCPServer.defaultUsageReaders()[.opencode])()
        XCTAssertEqual(usage.agent, .opencode)
        XCTAssertEqual(usage.unavailableReason, "OpenCode's free models publish no quota locally")
    }
}
```

In `LinkCCommandTests.swift`, change `testEveryAgentCanBeOpened`'s list to `[AgentKind.claude, .codex, .agy, .cursor, .grok, .opencode]` and add:

```swift
    func testTheUsageNamesOpenCode() {
        XCTAssertTrue(LinkCCommand.usage.contains("claude, codex, agy, cursor, grok or opencode"), LinkCCommand.usage)
    }
```

In `BoardTechTests.swift`, add:

```swift
    func testAComponentNamedOpenCodeIsTheOpenCodeAgent() {
        XCTAssertEqual(BoardTech.agent(for: BoardComponent(name: "OpenCode", kind: .service)), .opencode)
        XCTAssertEqual(BoardTech.agent(for: BoardComponent(name: "x", kind: .service, tech: "opencode")), .opencode)
    }
```

In `AppCoordinatorRelayTests.swift`, add right after `testACappedTaskCanRerouteToGrok`, as a copy of it with these differences: test name `testACappedTaskCanRerouteToOpenCode`; folder names `settings_opencode_reroute_test` / `manifest_opencode_reroute_test`; `agentPathResolver: { kind in kind == .opencode ? scriptURL.path : nil }`; final assertion `XCTAssertEqual(copy.toAgent, .opencode)`.

- [ ] **Step 2: Run the tests to see them fail**

Run: `swift test --scratch-path $SP --filter 'MCPServerOpenCodeTests|LinkCCommandTests|BoardTechTests|AppCoordinatorRelayTests/testACappedTaskCanRerouteToOpenCode'`
Expected: the new tests fail (no OpenCode section, unknown agent "opencode", nil agent, copy rerouted elsewhere or none).

- [ ] **Step 3: Implement**

- `AppCoordinator+Relay.swift`: `let supportedPeers: [AgentKind] = [.claude, .codex, .agy, .cursor, .grok, .opencode]`
- `MCPServer.swift`:
  - `unidentifiedCallerMessage`: `"Cannot identify calling agent; pass agent: \"claude\" | \"agy\" | \"cursor\" | \"codex\" | \"grok\" | \"opencode\"."`
  - `defaultUsageReaders()` gains `.opencode: { .unavailable(.opencode, reason: "OpenCode's free models publish no quota locally") }`
  - `linkc_get_models`: `targetAgents = [.claude, .codex, .agy, .cursor, .grok, .opencode]`
  - `linkc_get_usage_status`: `for agent in [AgentKind.codex, .claude, .agy, .cursor, .grok, .opencode] {`
- `LinkCCommand.swift`: `static let agents: [AgentKind] = [.claude, .codex, .agy, .cursor, .grok, .opencode]`; in `usage`, `<agent>   claude, codex, agy, cursor, grok or opencode`.
- `BoardTech.swift`: add `"opencode": .opencode,` to `agentNames`.
- `SettingsScreen.swift`: `ForEach([AgentKind.claude, .codex, .agy, .grok, .opencode], id: \.self) { agent in`
- `PanelView.swift`: after the `New Grok session…` button, `Button("New OpenCode session…") { model.newSession(agent: .opencode, mode: .new) }`; after the Continue last menu's `Grok` button, `Button("OpenCode") { model.newSession(agent: .opencode, mode: .continueLast) }`. Not in Resume…: OpenCode has no picker flag.
- `AgentPill.swift` doc comment: `(CLAUDE, AGY, CURSOR, CODEX, GROK, OPENCODE, SHELL)`. `WorkspaceManifest.swift` doc comment: `(e.g. claude, agy, cursor, codex, grok, opencode)`.
- `README.md`:
  - intro: "It runs Claude Code, Codex, Antigravity, Cursor Agent, Grok and OpenCode in one panel"
  - **Agent** bullet: "Claude Code, Codex, Antigravity, Cursor Agent, Grok (which runs through Cursor Agent), or OpenCode (on its free models)."
  - `linkc <agent>` paragraph: "opens claude, codex, agy, cursor, grok or opencode"
  - Usage paragraph: "Cursor Agent, Grok, OpenCode and Antigravity don't keep local usage records"
  - Supported agents table, after Grok: `| OpenCode | `opencode` | OpenCode on one of its free models, picked per tier in Settings > Models. linkC reads the terminal screen as it does for Codex. |`
  - Requirements: "Optional: Codex (`codex`), Antigravity (`agy`), Cursor Agent (`cursor`) and OpenCode (`opencode`). … OpenCode's free models need no account."
  - Install step 4: "Claude Code, Codex, Antigravity, Cursor Agent and OpenCode."
- Run `grep -rn '\.grok\b\|"grok"' Sources` and account for every hit: each is Grok-only (Cursor's CLI, `LINKC_WORKER`, `.cursor-grok`) or now also lists `.opencode`.

- [ ] **Step 4: Run the tests to see them pass, and build**

Run: the Step 2 command, then `swift build --scratch-path $SP`.
Expected: pass; build succeeds.

- [ ] **Step 5: Revert-proof, then commit**

```bash
git add Sources README.md Tests/LinkCKitTests
git commit -m "feat(opencode): every list of agents names OpenCode"
```

---

### Task 3: linkC's tools in OpenCode's config, and a shared writer that never overwrites what it cannot read

**Files:**
- Modify: `Sources/LinkCKit/MCP/MCPRegistrar.swift`
- Test: `Tests/LinkCKitTests/MCPRegistrarTests.swift`

**Interfaces:**
- Produces:
  - `MCPRegistrar.openCodeConfigFile(home: URL) -> URL` (`<home>/.config/opencode/opencode.json`)
  - `MCPRegistrar.openCodeEntry(binaryPath: String) -> [String: Any]`
  - `MCPRegistrar.registerOpenCodeServer(configFile: URL, serverName: String = serverName, binaryPath: String) throws`
  - `MCPRegistrar.openCodeConfigContent(inherited: String?, binaryPath: String) throws -> String` — used by Task 4.
  - `registerServer` now throws on an existing file that is not a JSON object.

- [ ] **Step 1: Write the failing tests**

Add to `MCPRegistrarTests.swift`:

```swift
    // MARK: - OpenCode

    private var openCodeFile: URL { tempDir.appendingPathComponent(".config/opencode/opencode.json") }

    private func openCodeEntry(in file: URL) throws -> [String: Any]? {
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        return (root["mcp"] as? [String: Any])?["linkc-multiplier"] as? [String: Any]
    }

    func testOpenCodeIsRegisteredInItsOwnShapeInAFileThatDidNotExist() throws {
        try MCPRegistrar.registerOpenCodeServer(configFile: openCodeFile, binaryPath: "/Users/someone/.local/bin/linkc-mcp")

        let entry = try XCTUnwrap(try openCodeEntry(in: openCodeFile))
        XCTAssertEqual(entry["type"] as? String, "local")
        XCTAssertEqual(entry["command"] as? [String], ["/Users/someone/.local/bin/linkc-mcp"])
        XCTAssertEqual(entry["environment"] as? [String: String], ["LINKC_AGENT": "opencode"])
        XCTAssertEqual(entry["enabled"] as? Bool, true)
    }

    /// The user's providers, model and other servers stay; the schema URL stays readable.
    func testRegisteringWithOpenCodeKeepsEveryOtherKey() throws {
        try FileManager.default.createDirectory(at: openCodeFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let initial = """
        {
          "$schema": "https://opencode.ai/config.json",
          "model": "ollama/qwen3.8:27b-32k",
          "provider": {"ollama": {"options": {"baseURL": "http://localhost:11434/v1"}}},
          "mcp": {"jobs": {"type": "local", "command": ["python3", "/x/server.py"], "enabled": true}}
        }
        """
        try initial.write(to: openCodeFile, atomically: true, encoding: .utf8)

        try MCPRegistrar.registerOpenCodeServer(configFile: openCodeFile, binaryPath: "/bin/linkc-mcp")

        let text = try String(contentsOf: openCodeFile, encoding: .utf8)
        XCTAssertTrue(text.contains("\"https://opencode.ai/config.json\""), "slashes are not escaped: \(text)")
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(root["model"] as? String, "ollama/qwen3.8:27b-32k")
        XCTAssertNotNil((root["provider"] as? [String: Any])?["ollama"])
        let mcp = try XCTUnwrap(root["mcp"] as? [String: Any])
        XCTAssertEqual((mcp["jobs"] as? [String: Any])?["command"] as? [String], ["python3", "/x/server.py"])
        XCTAssertNotNil(mcp["linkc-multiplier"])
    }

    func testAnUnchangedOpenCodeEntryIsNotRewritten() throws {
        try MCPRegistrar.registerOpenCodeServer(configFile: openCodeFile, binaryPath: "/bin/linkc-mcp")
        // The same content, laid out by hand: a rewrite would reformat it.
        let compact = #"{"mcp":{"linkc-multiplier":{"command":["/bin/linkc-mcp"],"enabled":true,"environment":{"LINKC_AGENT":"opencode"},"type":"local"}}}"#
        try compact.write(to: openCodeFile, atomically: true, encoding: .utf8)

        try MCPRegistrar.registerOpenCodeServer(configFile: openCodeFile, binaryPath: "/bin/linkc-mcp")

        XCTAssertEqual(try String(contentsOf: openCodeFile, encoding: .utf8), compact)
    }

    /// OpenCode also reads JSON with comments. linkC cannot, so it leaves such a file exactly as it is.
    func testAnOpenCodeFileThatIsNotPlainJSONIsLeftByteForByte() throws {
        try FileManager.default.createDirectory(at: openCodeFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let commented = "{\n  // my default\n  \"model\": \"ollama/qwen3.8:27b-32k\",\n}\n"
        try commented.write(to: openCodeFile, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try MCPRegistrar.registerOpenCodeServer(configFile: openCodeFile, binaryPath: "/bin/linkc-mcp")) { error in
            XCTAssertTrue(String(describing: error).contains(self.openCodeFile.path), "\(error)")
        }
        XCTAssertEqual(try String(contentsOf: openCodeFile, encoding: .utf8), commented)
    }

    func testAnOpenCodeMCPTableThatIsNotATableIsRefused() throws {
        try FileManager.default.createDirectory(at: openCodeFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let odd = #"{"mcp":["not","a","table"]}"#
        try odd.write(to: openCodeFile, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try MCPRegistrar.registerOpenCodeServer(configFile: openCodeFile, binaryPath: "/bin/linkc-mcp"))
        XCTAssertEqual(try String(contentsOf: openCodeFile, encoding: .utf8), odd)
    }

    /// The writer every other agent's JSON config goes through used to read a file it could not
    /// parse as empty, and overwrite it.
    func testTheSharedWriterLeavesAFileItCannotReadUntouched() throws {
        let configFile = tempDir.appendingPathComponent("mcp.json")
        let commented = "{ // servers\n \"mcpServers\": {} }"
        try commented.write(to: configFile, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try MCPRegistrar.registerServer(configFile: configFile, binaryPath: "/bin/linkc-mcp"))
        XCTAssertEqual(try String(contentsOf: configFile, encoding: .utf8), commented)
    }

    func testTheSharedWriterReadsAnEmptyFileAsEmpty() throws {
        let configFile = tempDir.appendingPathComponent("empty.json")
        try " \n".write(to: configFile, atomically: true, encoding: .utf8)

        try MCPRegistrar.registerServer(configFile: configFile, binaryPath: "/bin/linkc-mcp")

        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: configFile)) as? [String: Any])
        XCTAssertNotNil((root["mcpServers"] as? [String: Any])?["linkc-multiplier"])
    }

    func testRegisterAllRegistersWithOpenCode() throws {
        try MCPRegistrar.registerAll(home: tempDir, binaryPath: "/bin/linkc-mcp")
        let entry = try XCTUnwrap(try openCodeEntry(in: MCPRegistrar.openCodeConfigFile(home: tempDir)))
        XCTAssertEqual(entry["environment"] as? [String: String], ["LINKC_AGENT": "opencode"])
    }

    // MARK: - OpenCode's inline config

    private func inlineEntries(_ content: String) throws -> [String: Any] {
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
        return try XCTUnwrap(root["mcp"] as? [String: Any])
    }

    func testTheInlineConfigCarriesLinkCsServer() throws {
        let content = try MCPRegistrar.openCodeConfigContent(inherited: nil, binaryPath: "/bin/linkc-mcp")
        XCTAssertFalse(content.contains("\n"), "one line, so it passes through an environment variable as is")
        let entry = try XCTUnwrap(try inlineEntries(content)["linkc-multiplier"] as? [String: Any])
        XCTAssertEqual(entry["command"] as? [String], ["/bin/linkc-mcp"])
        XCTAssertEqual(entry["environment"] as? [String: String], ["LINKC_AGENT": "opencode"], "no session id: OpenCode passes its own down")
    }

    func testTheInlineConfigKeepsWhatWasAlreadyInTheEnvironment() throws {
        let inherited = #"{"model":"opencode/big-pickle","mcp":{"other":{"type":"remote","url":"https://example.com/mcp"}}}"#
        let content = try MCPRegistrar.openCodeConfigContent(inherited: inherited, binaryPath: "/bin/linkc-mcp")
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
        XCTAssertEqual(root["model"] as? String, "opencode/big-pickle")
        XCTAssertNotNil(try inlineEntries(content)["other"])
        XCTAssertNotNil(try inlineEntries(content)["linkc-multiplier"])
    }

    func testABlankInheritedConfigIsNone() throws {
        let content = try MCPRegistrar.openCodeConfigContent(inherited: "  ", binaryPath: "/bin/linkc-mcp")
        XCTAssertNotNil(try inlineEntries(content)["linkc-multiplier"])
    }

    func testAnInheritedConfigThatIsNotAJSONObjectIsRefused() {
        XCTAssertThrowsError(try MCPRegistrar.openCodeConfigContent(inherited: "model=x", binaryPath: "/bin/linkc-mcp")) { error in
            XCTAssertTrue(String(describing: error).contains("OPENCODE_CONFIG_CONTENT"), "\(error)")
        }
    }
```

If `testRegisterAllWritesToExpectedConfigFiles` or `testRegisterAllThrowsNamingEveryClientWhoseConfigFailed` list every client file, add OpenCode's file to them.

- [ ] **Step 2: Run the tests to see them fail**

Run: `swift test --scratch-path $SP --filter MCPRegistrarTests`
Expected: compile errors for the missing `MCPRegistrar` members. `testTheSharedWriterLeavesAFileItCannotReadUntouched` and `testTheSharedWriterReadsAnEmptyFileAsEmpty` compile against today's `registerServer`; run them first, before Step 3, and see the first fail (today's writer overwrites the file).

- [ ] **Step 3: Implement**

In `MCPRegistrar.swift`, add the helpers and replace `registerServer`'s read and write:

```swift
    /// The JSON object in `configFile`; an empty one when the file is missing or holds only
    /// whitespace. Anything else that is not a JSON object — comments, a trailing comma, a
    /// half-written file — throws, so no caller ever replaces a file it could not read.
    static func readJSONObject(at configFile: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: configFile.path) else { return [:] }
        let data = try Data(contentsOf: configFile)
        if String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [:]
        }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw LinkCError.server("\(configFile.path) is not JSON linkC can read, so it was left untouched — \(error.localizedDescription)")
        }
        guard let object = parsed as? [String: Any] else {
            throw LinkCError.server("\(configFile.path) does not hold a JSON object, so it was left untouched")
        }
        return object
    }

    /// Writes `data` to `configFile` through a temporary file beside it and one rename.
    private static func writeAtomically(_ data: Data, to configFile: URL) throws {
        let parentDir = configFile.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parentDir.path) {
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }
        let tmpFile = parentDir.appendingPathComponent("\(configFile.lastPathComponent).tmp.\(UUID().uuidString)")
        try data.write(to: tmpFile, options: .atomic)
        guard rename(tmpFile.path, configFile.path) == 0 else {
            let failure = errno
            throw LinkCError.server("Failed to rename \(tmpFile.path) to \(configFile.path): errno \(failure)")
        }
    }
```

`registerServer` becomes:

```swift
    public static func registerServer(
        configFile: URL,
        serverName: String = MCPRegistrar.serverName,
        binaryPath: String,
        args: [String] = [],
        env: [String: String] = [:]
    ) throws {
        var root = try readJSONObject(at: configFile)
        var mcpServers = root["mcpServers"] as? [String: Any] ?? [:]
        var entry: [String: Any] = ["command": binaryPath, "args": args]
        if !env.isEmpty { entry["env"] = env }
        mcpServers[serverName] = entry
        root["mcpServers"] = mcpServers
        try writeAtomically(try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]), to: configFile)
    }
```

Add the OpenCode functions:

```swift
    /// OpenCode's global config file.
    public static func openCodeConfigFile(home: URL) -> URL {
        home.appendingPathComponent(".config/opencode/opencode.json")
    }

    /// linkC's server as an entry of OpenCode's `mcp` table — OpenCode's own shape, not `mcpServers`.
    public static func openCodeEntry(binaryPath: String) -> [String: Any] {
        ["type": "local", "command": [binaryPath],
         "environment": ["LINKC_AGENT": AgentKind.opencode.rawValue], "enabled": true]
    }

    /// `root`'s `mcp` table: empty when it has none; throws when it has one that is not a table.
    private static func mcpTable(in root: [String: Any], of source: String) throws -> [String: Any] {
        switch root["mcp"] {
        case nil: return [:]
        case let table as [String: Any]: return table
        default: throw LinkCError.server("\(source) has an \"mcp\" that is not a table, so linkC left it untouched")
        }
    }

    /// Registers linkC's server in OpenCode's config, keeping every other key. Writes only when the
    /// entry differs from the one already there, and never over a file it could not read.
    public static func registerOpenCodeServer(configFile: URL, serverName: String = MCPRegistrar.serverName, binaryPath: String) throws {
        var root = try readJSONObject(at: configFile)
        var mcp = try mcpTable(in: root, of: configFile.path)
        let entry = openCodeEntry(binaryPath: binaryPath)
        if let existing = mcp[serverName] as? [String: Any], NSDictionary(dictionary: existing).isEqual(to: entry) { return }
        mcp[serverName] = entry
        root["mcp"] = mcp
        try writeAtomically(
            try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
            to: configFile)
    }

    /// `OPENCODE_CONFIG_CONTENT` for a terminal linkC starts OpenCode in: `inherited` — a value
    /// already in linkC's own environment — with linkC's server added to its `mcp` table. One line.
    /// Throws when `inherited` is not a JSON object.
    public static func openCodeConfigContent(inherited: String?, binaryPath: String) throws -> String {
        let source = "\(AgentDescriptor.openCodeConfigContentKey) in linkC's environment"
        var root: [String: Any] = [:]
        if let inherited, !inherited.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let parsed: Any
            do {
                parsed = try JSONSerialization.jsonObject(with: Data(inherited.utf8))
            } catch {
                throw LinkCError.process("\(source) is not JSON, so linkC cannot add its tools to it — \(error.localizedDescription)")
            }
            guard let object = parsed as? [String: Any] else {
                throw LinkCError.process("\(source) is not a JSON object, so linkC cannot add its tools to it")
            }
            root = object
        }
        var mcp = try mcpTable(in: root, of: source)
        mcp[serverName] = openCodeEntry(binaryPath: binaryPath)
        root["mcp"] = mcp
        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
```

In `registerAll`, after the Codex entries:

```swift
        // OpenCode: ~/.config/opencode/opencode.json, in its own `mcp` shape
        if let f = attemptRegistration("~/.config/opencode/opencode.json", {
            try registerOpenCodeServer(configFile: openCodeConfigFile(home: home), binaryPath: binaryPath)
        }) { failures.append(f) }
```

Update the type's doc comment to name OpenCode. If `Sources/linkc-mcp` prints which clients `--install` registered, add OpenCode there.

- [ ] **Step 4: Run the tests to see them pass**

Run: `swift test --scratch-path $SP --filter MCPRegistrarTests`
Expected: pass.

- [ ] **Step 5: Check the shape against the real OpenCode**

Let OpenCode read what the real code writes, with a harmless command so nothing of linkC's runs. Add a temporary test that calls `MCPRegistrar.registerOpenCodeServer(configFile: URL(fileURLWithPath: "<scratchpad>/oc-shape/opencode.json"), binaryPath: "/usr/bin/true")`, run it once, delete the test, then:

```bash
OPENCODE_DISABLE_AUTOUPDATE=1 OPENCODE_CONFIG=<scratchpad>/oc-shape/opencode.json opencode mcp list 2>&1 | grep -A2 linkc-multiplier
```

Expected: a `linkc-multiplier` row (it fails to connect, since `/usr/bin/true` is no server). That proves OpenCode parses the entry. Do the same for the inline form: `OPENCODE_CONFIG_CONTENT="$(the string openCodeConfigContent returns, with /usr/bin/true)" opencode mcp list`. Report both outputs. Run these from a scratch folder, never from the repo.

- [ ] **Step 6: Revert-proof, then commit**

```bash
git add Sources/LinkCKit/MCP/MCPRegistrar.swift Sources/linkc-mcp Tests/LinkCKitTests/MCPRegistrarTests.swift
git commit -m "feat(mcp): register linkC with OpenCode, and never overwrite a config linkC cannot read"
```

---

### Task 4: Launching OpenCode on its tier's model, with linkC's tools inline

OpenCode 2.2.5 (installed; spec §4.1) has no `--model` flag on its TUI and runs sessions in a shared background service unless `--standalone` is given. So linkC launches `opencode --standalone --auto` and passes the model inside `OPENCODE_CONFIG_CONTENT`, next to linkC's MCP server.

**Files:**
- Modify: `Sources/LinkCKit/Core/AgentKind.swift` (`alwaysNamesModel`; OpenCode's `yoloFlags`)
- Modify: `Sources/LinkCKit/Core/AgentModelCatalog.swift` (`launchArguments(model:for:)`)
- Modify: `Sources/LinkCKit/MCP/MCPRegistrar.swift` (`openCodeConfigContent` gains `model:`)
- Modify: `Sources/LinkCKit/App/AppCoordinator.swift` (`launch`'s environment lines, `launchModel`)
- Create: `Sources/LinkCKit/App/AppCoordinator+OpenCode.swift`
- Create: `Tests/LinkCKitTests/AppCoordinatorOpenCodeTests.swift`
- Modify: `Tests/LinkCKitTests/AgentDescriptorTests.swift`, `Tests/LinkCKitTests/AgentModelCatalogTests.swift`, `Tests/LinkCKitTests/MCPRegistrarTests.swift`

**Interfaces:**
- Consumes: `AgentDescriptor.environment(for: .opencode, home:)`, `AgentDescriptor.openCodeConfigContentKey` (Task 1); `MCPRegistrar.openCodeConfigContent(inherited:binaryPath:)` (Task 3).
- Produces:
  - `AgentKind.alwaysNamesModel: Set<AgentKind>` (`[.grok, .opencode]`)
  - `AgentDescriptor.arguments(for: .opencode, mode: <any>, sessionId:) == ["--standalone", "--auto"]`
  - `AgentModelCatalog.launchArguments(model:for: .opencode) == []`
  - `MCPRegistrar.openCodeConfigContent(inherited: String?, binaryPath: String, model: String?) throws -> String` (the two-argument form is replaced)
  - `AppCoordinator.openCodeEnvironment(model: String?) throws -> [String: String]` (internal, in `AppCoordinator+OpenCode.swift`)
  - the test file's `makeCoordinator(models:sink:) throws -> AppCoordinator`, `launchedLines(_:of:count:)`, `openCodeConfig(of:) throws -> [String: Any]` and `RecordingSink`, which Task 5 extends.

- [ ] **Step 1: Write the failing tests**

`AgentDescriptorTests.swift`: in `testOpenCodeIsItsOwnAgentWithEveryPermissionApproved`, expect `["--standalone", "--auto"]` for every mode, and change its doc comment's first sentence to "OpenCode runs its own binary, on a private server of its own, with every permission approved."

`AgentModelCatalogTests.swift`, add:

```swift
    /// OpenCode 2.2.5's TUI has no `--model` flag; its model goes in its inline config instead.
    func testOpenCodeTakesNoModelArgument() {
        XCTAssertEqual(AgentModelCatalog.launchArguments(model: "opencode/big-pickle", for: .opencode), [])
        XCTAssertEqual(AgentModelCatalog.launchArguments(model: "gpt-5.6-sol", for: .codex), ["--model", "gpt-5.6-sol"])
    }
```

`MCPRegistrarTests.swift`: change every `openCodeConfigContent(inherited:binaryPath:)` call to pass `model: nil`, and add:

```swift
    func testTheInlineConfigNamesTheSessionsModel() throws {
        let inherited = #"{"model":"ollama/qwen3.8:27b-32k"}"#
        let content = try MCPRegistrar.openCodeConfigContent(inherited: inherited, binaryPath: "/bin/linkc-mcp", model: "opencode/big-pickle")
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
        XCTAssertEqual(root["model"] as? String, "opencode/big-pickle", "the session's model wins over an inherited one")
    }

    func testWithNoModelTheInlineConfigLeavesTheModelAlone() throws {
        let inherited = #"{"model":"ollama/qwen3.8:27b-32k"}"#
        let content = try MCPRegistrar.openCodeConfigContent(inherited: inherited, binaryPath: "/bin/linkc-mcp", model: nil)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
        XCTAssertEqual(root["model"] as? String, "ollama/qwen3.8:27b-32k")
    }
```

Create `Tests/LinkCKitTests/AppCoordinatorOpenCodeTests.swift`:

```swift
import XCTest
@testable import LinkCKit

/// OpenCode sessions as linkC launches them, read back from a stand-in agent that records its
/// argv and environment.
@MainActor
final class AppCoordinatorOpenCodeTests: XCTestCase {
    nonisolated(unsafe) private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-opencode-launch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    final class RecordingSink: NotificationSink, @unchecked Sendable {
        private let lock = NSLock()
        private var _deliveries: [(id: String, title: String, body: String)] = []
        var deliveries: [(id: String, title: String, body: String)] {
            lock.lock(); defer { lock.unlock() }; return _deliveries
        }
        func deliver(id: String, title: String, body: String) {
            lock.lock(); _deliveries.append((id, title, body)); lock.unlock()
        }
    }

    /// The stand-in agent's path: it writes its argv to `argv-<LINKC_SESSION>` and the two
    /// variables an OpenCode terminal adds to `env-<LINKC_SESSION>`, then waits for input like a TUI.
    var stubAgent: URL { tempDir.appendingPathComponent("stub-opencode.sh") }

    func makeCoordinator(models: AgentModelSettings = .seeded, sink: NotificationSink = RecordingSink()) throws -> AppCoordinator {
        let script = "#!/bin/sh\n"
            + "printf '%s\\n' \"$@\" > \"$(dirname \"$0\")/argv-$LINKC_SESSION\"\n"
            + "printf 'OPENCODE_DISABLE_AUTOUPDATE=%s\\nOPENCODE_CONFIG_CONTENT=%s\\n' \"$OPENCODE_DISABLE_AUTOUPDATE\" \"$OPENCODE_CONFIG_CONTENT\" > \"$(dirname \"$0\")/env-$LINKC_SESSION\"\n"
            + "stty -echo 2>/dev/null\nprintf '\\033[?2004h'\nexec /bin/cat\n"
        try script.write(to: stubAgent, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stubAgent.path)
        let settingsDir = tempDir.appendingPathComponent("settings")
        let agent = stubAgent.path
        return AppCoordinator(
            terminals: TerminalSessionManager(),
            hookServer: HookServer(port: 0, statusLineCacheURL: tempDir.appendingPathComponent("status-line.json")),
            notifications: NotificationManager(sink: sink, now: { Date() }),
            claudePath: "/x/claude",
            settingsDir: settingsDir,
            userSettingsURL: tempDir.appendingPathComponent("no-such-settings.json"),
            manifestDir: settingsDir,
            agentPathResolver: { _ in agent },
            modelSettings: { models },
            deliverySettle: 0,
            turnEndQuietPeriod: 0.0,
            isWatching: { _ in false }
        )
    }

    /// The lines the stand-in wrote to `<name>-<session id>`, polled for up to five seconds until
    /// there are `count` of them.
    func launchedLines(_ name: String, of session: Session, count: Int) -> [String] {
        let file = tempDir.appendingPathComponent("\(name)-\(session.id)")
        var lines: [String] = []
        let deadline = Date().addingTimeInterval(5)
        while lines.count < count, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            lines = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }
        return lines
    }

    /// The inline config the session's OpenCode was started with.
    func openCodeConfig(of session: Session) throws -> [String: Any] {
        let env = launchedLines("env", of: session, count: 2)
        XCTAssertEqual(env.first, "OPENCODE_DISABLE_AUTOUPDATE=1")
        let prefix = "OPENCODE_CONFIG_CONTENT="
        let line = try XCTUnwrap(env.last)
        XCTAssertTrue(line.hasPrefix(prefix), line)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(line.dropFirst(prefix.count).utf8)) as? [String: Any])
    }

    /// OpenCode would otherwise run on whatever it picks — for Jacob, possibly a local model — so even
    /// a session the user opens names its model: the default tier's. No tier was asked for, so none
    /// is recorded, and the session is never handed a delegated task.
    func testAnOpenCodeSessionOpenedWithNoTierRunsOnTheDefaultTiersModel() throws {
        let coordinator = try makeCoordinator()
        defer { coordinator.shutdown() }

        let session = try coordinator.newSession(cwd: tempDir.path, agent: .opencode, mode: .new)

        XCTAssertEqual(session.agentKind, .opencode)
        XCTAssertEqual(session.model, "opencode/big-pickle")
        XCTAssertNil(session.modelTier, "a tier the user never asked for must not make their session a task carrier")
        XCTAssertEqual(launchedLines("argv", of: session, count: 2), ["--standalone", "--auto"], "no --model: OpenCode 2.2.5 refuses it")
        XCTAssertEqual(try openCodeConfig(of: session)["model"] as? String, "opencode/big-pickle")
    }

    func testAnOpenCodeSessionOnATierRunsOnThatTiersModel() throws {
        let coordinator = try makeCoordinator()
        defer { coordinator.shutdown() }

        let session = try coordinator.newSession(cwd: tempDir.path, agent: .opencode, mode: .new, tier: .deep)

        XCTAssertEqual(session.model, "opencode/crouton-alpha-free")
        XCTAssertEqual(session.modelTier, .deep)
        XCTAssertEqual(try openCodeConfig(of: session)["model"] as? String, "opencode/crouton-alpha-free")
    }

    func testAnOpenCodeTerminalHasLinkCsToolsInline() throws {
        let coordinator = try makeCoordinator()
        defer { coordinator.shutdown() }

        let session = try coordinator.newSession(cwd: tempDir.path, agent: .opencode, mode: .new)

        let entry = try XCTUnwrap((try openCodeConfig(of: session)["mcp"] as? [String: Any])?["linkc-multiplier"] as? [String: Any])
        XCTAssertEqual(entry["command"] as? [String], [MCPRegistrar.defaultBinaryPath()])
        XCTAssertEqual(entry["environment"] as? [String: String], ["LINKC_AGENT": "opencode"])
    }

    func testAnOpenCodeSessionWithNoModelForItsTierIsRefused() throws {
        var models = AgentModelSettings.seeded
        models.setModel("", for: .opencode, tier: .standard)
        let coordinator = try makeCoordinator(models: models)
        defer { coordinator.shutdown() }

        XCTAssertThrowsError(try coordinator.newSession(cwd: tempDir.path, agent: .opencode, mode: .new)) { error in
            XCTAssertTrue(String(describing: error).contains("no model configured for opencode tier standard — set it in linkC settings"),
                          String(describing: error))
        }
        XCTAssertTrue(coordinator.store.sessions.isEmpty, "a refused launch leaves no session behind")
    }

    func testOnlyAnOpenCodeTerminalGetsOpenCodesVariables() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["OPENCODE_CONFIG_CONTENT"] != nil
                      || ProcessInfo.processInfo.environment["OPENCODE_DISABLE_AUTOUPDATE"] != nil, "run from inside OpenCode")
        let coordinator = try makeCoordinator()
        defer { coordinator.shutdown() }

        let session = try coordinator.newSession(cwd: tempDir.path, agent: .codex, mode: .new)

        XCTAssertEqual(launchedLines("env", of: session, count: 2),
                       ["OPENCODE_DISABLE_AUTOUPDATE=", "OPENCODE_CONFIG_CONTENT="])
    }
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `swift test --scratch-path $SP --filter 'AppCoordinatorOpenCodeTests|AgentDescriptorTests|AgentModelCatalogTests|MCPRegistrarTests'`
Expected: compile error on `model:`; then argv `["--auto", "--model", …]`, no `OPENCODE_*` variables, no refusal.

- [ ] **Step 3: Implement**

`AgentKind.swift`:
- In OpenCode's descriptor, `yoloFlags: ["--standalone", "--auto"]`, with the comment: "A private server for this session, so its environment — the model and linkC's tools in `OPENCODE_CONFIG_CONTENT`, `LINKC_SESSION` — reaches it; the shared background service has the environment of whatever started it. Every permission approved that the config does not deny."
- Beside `peers`:

```swift
    /// Agents every launch names a model for, a tier or not, because their CLI's own default is not
    /// theirs: Grok's Cursor defaults to Auto, and OpenCode runs a session whose model it does not
    /// know on whatever it picks, which may be the user's local model.
    public static let alwaysNamesModel: Set<AgentKind> = [.grok, .opencode]
```

`AgentModelCatalog.swift`, `launchArguments(model:for:)`:

```swift
    /// Generates CLI launch arguments for specifying the model. OpenCode 2.2.5's TUI has no model
    /// flag — it refuses one — so its model goes in its inline config (`MCPRegistrar.openCodeConfigContent`).
    public static func launchArguments(model: String, for agent: AgentKind) -> [String] {
        agent == .opencode ? [] : ["--model", model]
    }
```

`MCPRegistrar.swift`: `openCodeConfigContent(inherited: String?, binaryPath: String, model: String?)` — after adding linkC's server to `mcp`, `if let model { root["model"] = model }`. Update its doc comment: "…with linkC's server added to its `mcp` table and, when given, `model` as the session's model."

`AppCoordinator.swift`, in `launch`, right after the Grok environment lines:

```swift
            if agent == .opencode {
                env.merge(try openCodeEnvironment(model: model)) { _, openCode in openCode }
            }
```

and `launchModel` becomes (its doc comment says "Grok and OpenCode" where it says "Grok"):

```swift
    private func launchModel(for agent: AgentKind, tier: ModelTier?) throws -> (model: String?, tier: ModelTier?) {
        guard AgentKind.alwaysNamesModel.contains(agent) else {
            let model = tier.flatMap { resolvedModel(for: agent, tier: $0) }
            return (model, model == nil ? nil : tier)
        }
        let settings = modelSettings()
        let launchTier = tier ?? settings.defaultTier(for: agent)
        guard let model = settings.model(for: agent, tier: launchTier) else {
            throw LinkCError.process("no model configured for \(agent.rawValue) tier \(launchTier.rawValue) — set it in linkC settings")
        }
        return (model, tier)
    }
```

Create `Sources/LinkCKit/App/AppCoordinator+OpenCode.swift`:

```swift
import Foundation

/// What linkC does differently for OpenCode. See docs/superpowers/specs/2026-11-07-opencode-agent-design.md.
extension AppCoordinator {
    /// What an OpenCode terminal adds to `LINKC_SESSION`: no update dialog, and an inline config
    /// with the session's model — OpenCode's TUI takes no model flag — and linkC's tool server, so
    /// the tools are there even when registering in `opencode.json` failed. The server entry carries
    /// no session id: OpenCode hands its own environment, `LINKC_SESSION` included, to the servers
    /// it starts. A value already in linkC's environment is merged into, not replaced.
    func openCodeEnvironment(model: String?) throws -> [String: String] {
        var env = AgentDescriptor.environment(for: .opencode, home: FileManager.default.homeDirectoryForCurrentUser)
        env[AgentDescriptor.openCodeConfigContentKey] = try MCPRegistrar.openCodeConfigContent(
            inherited: ProcessInfo.processInfo.environment[AgentDescriptor.openCodeConfigContentKey],
            binaryPath: MCPRegistrar.defaultBinaryPath(),
            model: model)
        return env
    }
}
```

Check `grep -rn "launchArguments(model" Sources` and confirm no other caller needs OpenCode's model as a flag.

- [ ] **Step 4: Run the tests to see them pass**

Run: `swift test --scratch-path $SP --filter 'AppCoordinatorOpenCodeTests|AppCoordinatorIntegrationTests|AgentDescriptorTests|AgentModelCatalogTests|MCPRegistrarTests'`
Expected: pass, the Grok launch tests included.

- [ ] **Step 5: Check the argv and config against the real OpenCode**

In a scratch git repo with its own root commit (never the linkC repo), under the scratchpad folder, start exactly what the tests assert, with a harmless stand-in for linkC's server:

```bash
tmux new-session -d -s argv4 -x 92 -y 40 -c <scratch repo> env OPENCODE_DISABLE_AUTOUPDATE=1 \
  OPENCODE_CONFIG_CONTENT='{"model":"opencode/crouton-alpha-free","mcp":{"linkc-multiplier":{"type":"local","command":["/usr/bin/true"],"environment":{"LINKC_AGENT":"opencode"},"enabled":true}}}' \
  /opt/homebrew/bin/opencode --standalone --auto
# wait until the footer shows "Build", then:
tmux capture-pane -p -t argv4 | grep -v '^\s*$' | tail -6; tmux kill-session -t argv4
```

Expected: the box footer names Crouton Alpha Free. Report the capture.

- [ ] **Step 6: Revert-proof, then commit**

```bash
git add Sources/LinkCKit Tests/LinkCKitTests
git commit -m "feat(opencode): launch OpenCode on its tier's model, with linkC's tools inline"
```

---

### Task 5: Continuing OpenCode in the folder's own session

**Files:**
- Create: `Sources/LinkCKit/App/OpenCodeSessions.swift`
- Modify: `Sources/LinkCKit/App/AppCoordinator.swift` (one stored property; in `launch`, the model `store.create` records and the `terminal.start` call; `cleanup` and `sweepTicker` from `private` to internal)
- Modify: `Sources/LinkCKit/App/AppCoordinator+OpenCode.swift`
- Create: `Tests/LinkCKitTests/OpenCodeSessionsTests.swift`
- Modify: `Tests/LinkCKitTests/AppCoordinatorOpenCodeTests.swift`

**Interfaces:**
- Consumes: Task 4's test harness (`makeCoordinator`, `launchedLines`, `openCodeConfig(of:)`, `stubAgent`, `RecordingSink`) and `openCodeEnvironment(model:)`.
- Produces: `OpenCodeSessions.listArguments`, `OpenCodeSessions.newest(in:listing:) throws -> String?`; `AppCoordinator.openCodeSessionList: @Sendable (_ executable: String, _ folder: String) async throws -> String` (settable, internal).

- [ ] **Step 1: Write the failing tests**

Create `Tests/LinkCKitTests/OpenCodeSessionsTests.swift`:

```swift
import XCTest
@testable import LinkCKit

/// OpenCode's `--continue` takes the newest session of the whole project — every worktree of a
/// repo is one project — so linkC picks the session that ran in the very folder it opens.
final class OpenCodeSessionsTests: XCTestCase {
    private var root: URL!
    private var here: String { root.appendingPathComponent("main").path }
    private var worktree: String { root.appendingPathComponent("worktree").path }

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-opencode-sessions-\(UUID().uuidString)")
        for folder in ["main", "worktree"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    /// `opencode session list --format json` output, in the fields OpenCode 2.2.5 (and 1.18.19) prints.
    private func listing(_ entries: [(id: String, directory: String, updated: Double)]) throws -> String {
        let objects: [[String: Any]] = entries.map {
            ["id": $0.id, "title": "a session", "updated": $0.updated, "created": $0.updated - 1000,
             "projectId": "b6c90be0b9fdd46da66b8e571c85ff25336524ce", "directory": $0.directory]
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: objects, options: .prettyPrinted), as: UTF8.self)
    }

    func testTheArgumentsListThisProjectsSessionsWithoutStartingTheSharedService() {
        XCTAssertEqual(OpenCodeSessions.listArguments, ["session", "list", "--format", "json", "--standalone"])
    }

    func testTheNewestSessionInThisFolderIsChosen() throws {
        let out = try listing([("ses_worktree", worktree, 1_794_071_409_000),
                               ("ses_older", here, 1_794_071_301_000),
                               ("ses_newer", here, 1_794_071_408_175)])
        XCTAssertEqual(try OpenCodeSessions.newest(in: here, listing: out), "ses_newer")
    }

    func testASessionInAnotherFolderOfTheSameProjectIsNotChosen() throws {
        let out = try listing([("ses_worktree", worktree, 1_794_071_409_000)])
        XCTAssertNil(try OpenCodeSessions.newest(in: here, listing: out))
    }

    /// OpenCode prints nothing at all for a project with no sessions.
    func testAProjectWithNoSessionsHasNone() throws {
        XCTAssertNil(try OpenCodeSessions.newest(in: here, listing: ""))
        XCTAssertNil(try OpenCodeSessions.newest(in: here, listing: "\n"))
    }

    func testFoldersAreComparedCanonically() throws {
        let out = try listing([("ses_here", here, 1)])
        XCTAssertEqual(try OpenCodeSessions.newest(in: here + "/.", listing: out), "ses_here")
        XCTAssertEqual(try OpenCodeSessions.newest(in: here + "/", listing: out), "ses_here")
    }

    func testOutputThatIsNotTheListingThrows() {
        XCTAssertThrowsError(try OpenCodeSessions.newest(in: here, listing: "Error: no project found"))
        XCTAssertThrowsError(try OpenCodeSessions.newest(in: here, listing: #"{"id":"ses_x"}"#))
    }
}
```

Add to `AppCoordinatorOpenCodeTests.swift`:

```swift
    /// Records every listing linkC asks for and answers with `listing`, or throws `failure`.
    final class SessionLister: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [(executable: String, folder: String)] = []
        let listing: String
        let failure: Error?
        init(listing: String = "", failure: Error? = nil) { self.listing = listing; self.failure = failure }
        var calls: [(executable: String, folder: String)] { lock.lock(); defer { lock.unlock() }; return _calls }
        func list(_ executable: String, _ folder: String) throws -> String {
            lock.lock(); _calls.append((executable, folder)); lock.unlock()
            if let failure { throw failure }
            return listing
        }
    }

    private func listing(id: String, in folder: String) -> String {
        #"[{"id":"\#(id)","title":"t","updated":1794071408175,"created":1794071353260,"projectId":"p","directory":"\#(folder)"}]"#
    }

    private func waitUntil(_ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while !predicate(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        return predicate()
    }

    /// A continued OpenCode session keeps the model it last ran on, so linkC records none for it. The
    /// default tier's model still goes in its config, for a folder where no session ran.
    func testContinuingOpensThisFoldersOwnSession() throws {
        let coordinator = try makeCoordinator()
        defer { coordinator.shutdown() }
        let lister = SessionLister(listing: listing(id: "ses_here", in: ProjectPath.canonical(tempDir.path)))
        coordinator.openCodeSessionList = { try lister.list($0, $1) }

        let session = try coordinator.newSession(cwd: tempDir.path, agent: .opencode, mode: .continueLast)

        XCTAssertEqual(launchedLines("argv", of: session, count: 4), ["--standalone", "--auto", "--session", "ses_here"])
        XCTAssertNil(session.model, "a continued session runs on its own last model, which linkC does not know")
        XCTAssertEqual(try openCodeConfig(of: session)["model"] as? String, "opencode/big-pickle")
        XCTAssertEqual(lister.calls.map(\.executable), [stubAgent.path])
        XCTAssertEqual(lister.calls.map(\.folder), [session.cwd], "the listing runs in the session's own folder")
    }

    func testContinuingWhereNoSessionRanStartsANewOne() throws {
        let coordinator = try makeCoordinator()
        defer { coordinator.shutdown() }
        let lister = SessionLister(listing: listing(id: "ses_elsewhere", in: "/somewhere/else"))
        coordinator.openCodeSessionList = { try lister.list($0, $1) }

        let session = try coordinator.newSession(cwd: tempDir.path, agent: .opencode, mode: .continueLast)

        XCTAssertEqual(launchedLines("argv", of: session, count: 2), ["--standalone", "--auto"])
    }

    /// Continuing must never quietly become a new conversation.
    func testAListingThatFailsEndsTheSessionAndSaysWhy() throws {
        let sink = RecordingSink()
        let coordinator = try makeCoordinator(sink: sink)
        defer { coordinator.shutdown() }
        let lister = SessionLister(failure: LinkCError.process("opencode session list exited 1: no database"))
        coordinator.openCodeSessionList = { try lister.list($0, $1) }

        let session = try coordinator.newSession(cwd: tempDir.path, agent: .opencode, mode: .continueLast)

        XCTAssertTrue(waitUntil { coordinator.store.session(id: session.id) == nil }, "the session is ended")
        let notice = try XCTUnwrap(sink.deliveries.first { $0.title == "linkC: OpenCode could not continue" })
        XCTAssertTrue(notice.body.contains("no database"), notice.body)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("argv-\(session.id)").path),
                       "OpenCode never started")
    }

    func testANewSessionNeverLists() throws {
        let coordinator = try makeCoordinator()
        defer { coordinator.shutdown() }
        let lister = SessionLister()
        coordinator.openCodeSessionList = { try lister.list($0, $1) }

        let session = try coordinator.newSession(cwd: tempDir.path, agent: .opencode, mode: .new)

        XCTAssertEqual(launchedLines("argv", of: session, count: 2).count, 2)
        XCTAssertTrue(lister.calls.isEmpty)
    }
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `swift test --scratch-path $SP --filter 'OpenCodeSessionsTests|AppCoordinatorOpenCodeTests'`
Expected: compile errors for `OpenCodeSessions` and `openCodeSessionList`.

- [ ] **Step 3: Implement**

Create `Sources/LinkCKit/App/OpenCodeSessions.swift`:

```swift
import Foundation

/// OpenCode's session listing, read for the one session linkC may continue in a folder.
///
/// OpenCode's own `--continue` takes the newest session of the whole project and moves into that
/// session's folder. A project is the repo's root commit, so every worktree of one repo is one
/// project, and folders with no commits share one. linkC continues only a session that ran in the
/// very folder it is opening.
public enum OpenCodeSessions {
    /// The arguments that list the sessions of the project `opencode` runs in. `--standalone`, so
    /// listing never starts OpenCode's shared background service when it is not running.
    public static let listArguments = ["session", "list", "--format", "json", "--standalone"]

    private struct Entry: Decodable {
        let id: String
        let directory: String
        let updated: Double
    }

    /// The id of the newest session that ran in `folder`, from `opencode session list --format
    /// json` output; nil when none did. OpenCode prints nothing for a project with no sessions.
    /// Throws on output that is not that listing.
    public static func newest(in folder: String, listing: String) throws -> String? {
        guard !listing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let entries: [Entry]
        do {
            entries = try JSONDecoder().decode([Entry].self, from: Data(listing.utf8))
        } catch {
            throw LinkCError.parse("OpenCode's session list could not be read — \(error)")
        }
        let target = ProjectPath.canonical(folder)
        return entries
            .filter { ProjectPath.canonical($0.directory) == target }
            .max { $0.updated < $1.updated }?
            .id
    }
}
```

`AppCoordinator.swift`:
- Beside the other seams (near `agentPathResolver`):

```swift
    /// Lists OpenCode's sessions as `opencode session list --format json --standalone` run in a
    /// folder prints them. A seam, so a test can play the listing; the real one runs off the main thread.
    var openCodeSessionList: @Sendable (_ executable: String, _ folder: String) async throws -> String = {
        try await AppCoordinator.listOpenCodeSessions(executable: $0, folder: $1)
    }
```

- `private func cleanup(sessionId:)` → `func cleanup(sessionId:)`; `private var sweepTicker` → `var sweepTicker`.
- In `launch`, the `store.create(...)` call records `model: agent == .opencode && mode == .continueLast ? nil : model` (comment: "A continued OpenCode session keeps the model it last ran on, which linkC does not know."). The environment still gets `model`.
- In `launch`, replace the `try terminal.start(executable: executable, args: args, env: env)` call with:

```swift
            if agent == .opencode, mode == .continueLast {
                // OpenCode's own `--continue` can open another folder's session. This folder's is
                // found first; the terminal starts when the listing is back.
                continueOpenCode(session: session, terminal: terminal, executable: executable, args: args, env: env)
            } else {
                try terminal.start(
                    executable: executable,
                    args: args,
                    env: env
                )
            }
```

Add to `AppCoordinator+OpenCode.swift`:

```swift
    /// Starts `terminal` on this folder's newest OpenCode session, or on a new one when none ran
    /// here, once the listing is back. The listing takes about a second, so it runs off the main
    /// thread while the session waits in `.starting`. A listing that fails ends the session and
    /// says why: continuing must never quietly become a new conversation.
    func continueOpenCode(session: Session, terminal: TerminalSession, executable: String, args: [String], env: [String: String]) {
        let list = openCodeSessionList
        let folder = session.cwd
        Task { @MainActor [weak self] in
            do {
                let listing = try await list(executable, folder)
                let id = try OpenCodeSessions.newest(in: folder, listing: listing)
                // Stopped while the listing ran: there is nothing left to start.
                guard let self, self.store.session(id: session.id) != nil else { return }
                try terminal.start(executable: executable, args: Self.openCodeArguments(args, continuing: id), env: env)
                self.sweepTicker?.wake()
            } catch {
                NSLog("[linkC] OpenCode could not continue in %@ — %@", folder, String(describing: error))
                guard let self else { return }
                self.notifications.post(title: "linkC: OpenCode could not continue",
                                        body: "\(session.title): \(error)")
                self.cleanup(sessionId: session.id)
            }
        }
    }

    /// `args` with `--session <id>` after OpenCode's flags, or unchanged when there is no session
    /// to continue.
    static func openCodeArguments(_ args: [String], continuing id: String?) -> [String] {
        guard let id else { return args }
        let flags = AgentDescriptor.descriptor(for: .opencode).yoloFlags
        return flags + ["--session", id] + args.dropFirst(flags.count)
    }

    /// `opencode session list --format json --standalone`, run in `folder` off the main thread.
    nonisolated static func listOpenCodeSessions(executable: String, folder: String) async throws -> String {
        let result = try await LiveProcessRunner().runCapturing(
            executable, args: OpenCodeSessions.listArguments, cwd: URL(fileURLWithPath: folder),
            env: AgentDescriptor.environment(for: .opencode, home: FileManager.default.homeDirectoryForCurrentUser),
            timeout: 30)
        guard result.status == 0 else {
            throw LinkCError.process("`opencode session list` in \(folder) exited \(result.status): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return result.stdout
    }
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `swift test --scratch-path $SP --filter 'OpenCodeSessionsTests|AppCoordinatorOpenCodeTests|AppCoordinatorIntegrationTests|RelaunchPlanTests'`
Expected: pass.

- [ ] **Step 5: Check the argv and listing against the real OpenCode**

In a scratch git repo with its own root commit (never the linkC repo), under the scratchpad folder:

```bash
OPENCODE_DISABLE_AUTOUPDATE=1 opencode run --model opencode/deepseek-v4.1-flash-free "Reply with exactly the word OK."
opencode session list --format json --standalone   # note the id; the output is what OpenCodeSessions.newest parses
tmux new-session -d -s cont -x 92 -y 40 -c <scratch repo> env OPENCODE_DISABLE_AUTOUPDATE=1 /opt/homebrew/bin/opencode --standalone --auto --session <id>
# wait for the footer, then:
tmux capture-pane -p -t cont | grep -v '^\s*$' | tail -10; tmux kill-session -t cont
```

Expected: the earlier "OK" exchange on screen, in this folder. Report both outputs.

- [ ] **Step 6: Revert-proof, then commit**

```bash
git add Sources/LinkCKit/App Tests/LinkCKitTests/OpenCodeSessionsTests.swift Tests/LinkCKitTests/AppCoordinatorOpenCodeTests.swift
git commit -m "feat(opencode): continue an OpenCode session in its own folder only"
```

---

### Task 6: Reading OpenCode's screen

**Files:**
- Create: `Sources/LinkCKit/Terminal/OpenCodeScreen.swift`
- Modify: `Sources/LinkCKit/Terminal/TerminalPreview.swift` (`visibleText` from `private` to internal; one early return in `liveActivity`; one line in `isLiveMarkerRow`)
- Fixtures, captured from the real TUI (in `Tests/LinkCKitTests/Fixtures/`, 92 and 46 columns, 40 rows):
  - OpenCode 2.2.5 (the installed version): `opencode-2.2.5-idle`, `-idle-narrow`, `-working`, `-working-thinking`, `-working-narrow`, `-working-narrow-no-hint`, `-done`, `-done-narrow` — add them to git in this task (they are in the working tree, untracked).
  - OpenCode 1.18.19 (already committed): `opencode-1.18.19-idle`, `-idle-narrow`, `-working`, `-working-context`, `-working-narrow`, `-working-thinking-narrow`, `-done`, `-done-narrow`. Remove `opencode-1.18.19-toast.txt` and `opencode-1.18.19-toast-narrow.txt` with `git rm`: OpenCode 2.2.5 shows no such toast, and linkC does not read it.
- Create: `Tests/LinkCKitTests/OpenCodeScreenTests.swift`

**Interfaces:**
- Consumes: `CodexScreenFixture.rows(_:)` (any fixture name).
- Produces: `OpenCodeScreen.turn(in:) -> OpenCodeScreen.Turn?`, `OpenCodeScreen.isProgressRow(_:)`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/LinkCKitTests/OpenCodeScreenTests.swift`:

```swift
import XCTest
@testable import LinkCKit

/// OpenCode's screens, captured from the real TUI (2.2.5, and 1.18.19 before it) at 92 and 46
/// columns, read the way the once-a-second sweep reads them.
final class OpenCodeScreenTests: XCTestCase {
    private func screen(_ name: String) throws -> [String] { try CodexScreenFixture.rows("opencode-\(name)") }

    func testAnIdleScreenReadsIdle() throws {
        for name in ["2.2.5-idle", "2.2.5-idle-narrow", "1.18.19-idle", "1.18.19-idle-narrow"] {
            XCTAssertNil(TerminalPreview.liveActivity(from: try screen(name)), name)
        }
    }

    func testEveryWorkingStageReadsWorking() throws {
        for name in ["2.2.5-working", "2.2.5-working-narrow", "1.18.19-working", "1.18.19-working-context", "1.18.19-working-narrow"] {
            XCTAssertEqual(TerminalPreview.liveActivity(from: try screen(name)), "Working", name)
        }
    }

    /// At 46 columns, the first seconds of a 2.2.5 turn show the bar with no interrupt hint after it.
    func testTheBarAloneSaysATurnRuns() throws {
        XCTAssertEqual(TerminalPreview.liveActivity(from: try screen("2.2.5-working-narrow-no-hint")), "Working")
    }

    func testTheThinkingSpinnerNamesThePhrase() throws {
        XCTAssertEqual(TerminalPreview.liveActivity(from: try screen("2.2.5-working-thinking")), "Thinking")
        XCTAssertEqual(TerminalPreview.liveActivity(from: try screen("1.18.19-working-thinking-narrow")), "Thinking")
    }

    func testAFinishedTurnReadsIdle() throws {
        for name in ["2.2.5-done", "2.2.5-done-narrow", "1.18.19-done", "1.18.19-done-narrow"] {
            XCTAssertNil(TerminalPreview.liveActivity(from: try screen(name)), name)
        }
    }

    /// OpenCode's input box carries none of the prompt markers the generic scan stops at, so a
    /// finished turn's output above it must not be read as a turn in progress.
    func testOutputAboveAFinishedTurnsInputBoxIsNotATurn() throws {
        var rows = try screen("2.2.5-done")
        let edge = try XCTUnwrap(rows.lastIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("╹") })
        rows.insert(contentsOf: ["     ~ Reading file...", "     Writing tests…", "     ⠋ Thinking", "     press esc " + "interrupt to stop"],
                    at: edge - 3)
        XCTAssertNil(TerminalPreview.liveActivity(from: rows))
    }

    /// The bar animates and the context size ticks while a turn runs; neither is progress.
    func testTheProgressRowIsNotProgress() throws {
        let rows = try screen("2.2.5-working")
        let edge = try XCTUnwrap(rows.lastIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("╹") })
        let footer = edge + 1
        XCTAssertTrue(TerminalPreview.isLiveMarkerRow(rows[footer]), rows[footer])
        var redrawn = rows
        redrawn[footer] = "   ■■⬝⬝⬝⬝⬝⬝  esc " + "interrupt                                     24.9K (13%)  ctrl+p commands"
        XCTAssertEqual(TerminalPreview.progressSignature(rows: rows), TerminalPreview.progressSignature(rows: redrawn))
    }

    func testOtherAgentsScreensAreNotOpenCodes() throws {
        for name in ["codex-0.159-turn-finished", "codex-0.159-working-before-tip", "codex-0.159-working-narrow",
                     "codex-0.159-waiting-for-startup", "codex-0.159-working-tip-under-status"] {
            XCTAssertNil(OpenCodeScreen.turn(in: try CodexScreenFixture.rows(name)), name)
        }
    }
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `swift test --scratch-path $SP --filter OpenCodeScreenTests`
Expected: compile error for `OpenCodeScreen`; once stubbed to return nil, the working fixtures read nil and the done fixture with output above its box reads as working.

- [ ] **Step 3: Implement**

Create `Sources/LinkCKit/Terminal/OpenCodeScreen.swift`:

```swift
import Foundation

/// OpenCode's TUI, read from its screen rows (OpenCode 2.2.5 and 1.18.19; `Fixtures/opencode-*.txt`).
/// Its input box ends on a heavy edge ("╹▀▀▀…") with a footer under it. While a turn runs, the
/// footer opens with an 8-glyph progress bar of "⬝"/"■" — followed by the interrupt hint, though a
/// narrow screen can show the bar alone; once the turn ends, the footer shows the folder path. A
/// Braille spinner row sits just above the box while the model thinks.
enum OpenCodeScreen {
    enum Turn: Equatable {
        case idle
        case working(phrase: String)

        var phrase: String? {
            if case .working(let phrase) = self { return phrase }
            return nil
        }
    }

    /// How far above the box's edge the spinner row can sit: the box's own rows, then the model row.
    private static let spinnerSearchRows = 10

    /// The turn an OpenCode screen shows; nil when `rows` are not OpenCode's.
    static func turn(in rows: [String]) -> Turn? {
        guard let edge = rows.lastIndex(where: isInputBoxEdge) else { return nil }
        let footer = rows[(edge + 1)...].map(TerminalPreview.visibleText).first { !$0.isEmpty }
        guard let footer, isProgressRow(footer) else { return .idle }
        let phrase = rows[..<edge].reversed().prefix(spinnerSearchRows).lazy.compactMap(spinnerPhrase).first
        return .working(phrase: phrase ?? "Working")
    }

    /// The row that closes OpenCode's input box: "╹" and then a run of "▀".
    static func isInputBoxEdge(_ row: String) -> Bool {
        let trimmed = row.trimmingCharacters(in: .whitespaces)
        guard trimmed.first == "╹" else { return false }
        let rest = trimmed.dropFirst()
        return rest.count >= 8 && rest.allSatisfy { $0 == "▀" }
    }

    private static let progressBar = try! NSRegularExpression(pattern: "^[⬝■]{8}")

    /// Whether `text` (a row's visible text) is OpenCode's working footer: it opens with the
    /// 8-glyph progress bar. The hint after it is not required — a narrow screen leaves it out.
    static func isProgressRow(_ text: String) -> Bool {
        progressBar.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// The phrase on a Braille spinner row ("⠋ Thinking" gives "Thinking"); nil for any other row.
    private static func spinnerPhrase(_ row: String) -> String? {
        let text = TerminalPreview.visibleText(row)
        guard let first = text.unicodeScalars.first, (0x2800...0x28FF).contains(first.value) else { return nil }
        let phrase = String(text.unicodeScalars.dropFirst()).trimmingCharacters(in: .whitespaces)
        return phrase.isEmpty ? nil : phrase
    }
}
```

`TerminalPreview.swift`:
- `private static func visibleText(_ row: String) -> String` → `static func visibleText(_ row: String) -> String`.
- First lines of `liveActivity(from:)`:

```swift
        // OpenCode's input box has none of the prompt markers the scan below stops at, so its
        // screens are read on their own.
        if let turn = OpenCodeScreen.turn(in: rows) { return turn.phrase }
```

- In `isLiveMarkerRow`, after `if isWorkingFooter(text) { return true }`: `if OpenCodeScreen.isProgressRow(text) { return true }`.

- [ ] **Step 4: Run the tests to see them pass**

Run: `swift test --scratch-path $SP --filter 'OpenCodeScreenTests|CodexScreenTests|ScreenReadingTests|TerminalPreviewPatternTests|ScreenSweepCostTests|AppCoordinatorWatchdogTests'`
Expected: pass. (If a suite named here does not exist, drop it from the filter.)

- [ ] **Step 5: Revert-proof, then commit**

```bash
git add Sources/LinkCKit/Terminal Tests/LinkCKitTests/OpenCodeScreenTests.swift Tests/LinkCKitTests/Fixtures/opencode-2.2.5-*.txt
git rm Tests/LinkCKitTests/Fixtures/opencode-1.18.19-toast.txt Tests/LinkCKitTests/Fixtures/opencode-1.18.19-toast-narrow.txt
git commit -m "feat(opencode): read OpenCode's turn off its screen"
```

---

### Task 7: Delegation checks OpenCode still offers the tier's model; no model switching

**Files:**
- Modify: `Sources/LinkCKit/MCP/MCPServer.swift`
- Modify: `Tests/LinkCKitTests/MCPServerOpenCodeTests.swift`

**Interfaces:**
- Consumes: Task 2's `makeServer` / `call` helpers.
- Produces: `MCPServer.OpenCodeModelLister = @Sendable (_ folder: String) throws -> [String]`; init parameter `openCodeModels:` (last, default `{ try MCPServer.listOpenCodeModels(in: $0) }`); `MCPServer.listOpenCodeModels(in:) throws -> [String]`.

- [ ] **Step 1: Write the failing tests**

In `MCPServerOpenCodeTests.swift`, give `makeServer` an `openCodeModels:` parameter passed to the new init argument:

```swift
    private func makeServer(models: AgentModelSettings = .seeded,
                            openCodeModels: @escaping MCPServer.OpenCodeModelLister = { _ in
                                XCTFail("OpenCode's models were listed"); return [] }) -> MCPServer {
        MCPServer(workspaceRoot: tempDir.path, inboxStore: InboxStore(workspaceRoot: tempDir.path),
                  environment: ["LINKC_AGENT": "claude"], ancestorResolver: { _ in nil },
                  modelSettings: { models }, sessionResolver: { nil }, usageReaders: [:],
                  openCodeModels: openCodeModels)
    }
```

and add:

```swift
    /// Records the folders OpenCode's models were listed in.
    final class ModelLister: @unchecked Sendable {
        private let lock = NSLock()
        private var _folders: [String] = []
        let models: [String]
        let failure: Error?
        init(_ models: [String] = [], failure: Error? = nil) { self.models = models; self.failure = failure }
        var folders: [String] { lock.lock(); defer { lock.unlock() }; return _folders }
        func list(_ folder: String) throws -> [String] {
            lock.lock(); _folders.append(folder); lock.unlock()
            if let failure { throw failure }
            return models
        }
    }

    private var openTasks: [TaskRecord] { (try? InboxStore(workspaceRoot: tempDir.path).openTasks()) ?? [] }

    /// Free models are offered for a limited time, and OpenCode runs a session whose model it does
    /// not know on whatever it picks, so a delegation to a model it no longer lists is refused.
    func testADelegationToAModelOpenCodeNoLongerListsIsRefused() throws {
        let lister = ModelLister(["opencode/deepseek-v4.1-flash-free"])
        let result = try call(makeServer(openCodeModels: { try lister.list($0) }), "linkc_delegate_task",
                              ["to": "opencode", "prompt": "Add a test."])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("opencode/big-pickle (opencode tier standard) is not among the models OpenCode lists"), result.text)
        XCTAssertTrue(openTasks.isEmpty, "no task is queued")
    }

    func testADelegationIsRefusedWhenOpenCodesModelsCannotBeListed() throws {
        let lister = ModelLister(failure: LinkCError.process("`opencode models` exited 1: offline"))
        let result = try call(makeServer(openCodeModels: { try lister.list($0) }), "linkc_delegate_task",
                              ["to": "opencode", "prompt": "Add a test.", "tier": "deep"])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("opencode/crouton-alpha-free"), result.text)
        XCTAssertTrue(result.text.contains("offline"), result.text)
        XCTAssertTrue(openTasks.isEmpty)
    }

    func testADelegationToAListedModelIsQueuedAndListedInTheWorkspace() throws {
        let lister = ModelLister(["opencode/big-pickle", "opencode/crouton-alpha-free"])
        let result = try call(makeServer(openCodeModels: { try lister.list($0) }), "linkc_delegate_task",
                              ["to": "opencode", "prompt": "Add a test.", "tier": "deep"])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(openTasks.map(\.toAgent), [.opencode])
        XCTAssertEqual(openTasks.first?.tier, .deep)
        XCTAssertEqual(lister.folders, [(tempDir.path as NSString).standardizingPath],
                       "a project's own opencode.json can add models, so the listing runs in the workspace")
    }

    func testADelegationToAnotherAgentNeverListsOpenCodesModels() throws {
        let result = try call(makeServer(), "linkc_delegate_task", ["to": "codex", "prompt": "Add a test."])
        XCTAssertFalse(result.isError, result.text)
    }

    func testOpenCodesModelsAreListedWithoutStartingTheSharedService() {
        XCTAssertEqual(MCPServer.openCodeModelsArguments, ["models", "--standalone"])
    }

    func testOpenCodesModelCannotBeSwitchedInARunningSession() throws {
        let result = try call(makeServer(), "linkc_switch_model", ["agent": "opencode", "model": "opencode/big-pickle"])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("opencode cannot switch a running session's model — delegate at another tier instead"), result.text)
    }

    func testTheModelReportSaysOpenCodeCannotSwitch() throws {
        let report = try call(makeServer(), "linkc_get_models", ["agent": "opencode"])
        XCTAssertTrue(report.text.contains("- opencode cannot switch a running session's model; delegate at another tier\n"), report.text)
    }
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `swift test --scratch-path $SP --filter MCPServerOpenCodeTests`
Expected: compile error for `openCodeModels:`; then the refusals are not given.

- [ ] **Step 3: Implement**

In `MCPServer.swift`:

```swift
    public typealias OpenCodeModelLister = @Sendable (_ folder: String) throws -> [String]
```

```swift
    /// The models OpenCode offers in a folder, read on every OpenCode delegation: a free model can
    /// go at any time, and OpenCode runs a session whose model it does not know on whatever it picks.
    public let openCodeModels: OpenCodeModelLister
```

Init: last parameter `openCodeModels: @escaping OpenCodeModelLister = { try MCPServer.listOpenCodeModels(in: $0) }`, stored as `self.openCodeModels = openCodeModels`.

```swift
    /// `opencode models`, on a private server so listing never starts OpenCode's shared background
    /// service when it is not running.
    static let openCodeModelsArguments = ["models", "--standalone"]

    /// The models `opencode models` lists in `folder` — a project's own config can add providers.
    /// Throws when OpenCode is missing or the listing fails.
    public static func listOpenCodeModels(in folder: String) throws -> [String] {
        guard let executable = AgentDescriptor.resolveExecutable(for: .opencode) else {
            throw LinkCError.process("Executable for \(AgentKind.opencode.pillText) not found")
        }
        let result = try LiveProcessRunner.runCapturingSync(
            executable: executable, args: openCodeModelsArguments, cwd: URL(fileURLWithPath: folder),
            env: AgentDescriptor.environment(for: .opencode, home: FileManager.default.homeDirectoryForCurrentUser),
            timeout: 60)
        guard result.status == 0 else {
            throw LinkCError.process("`opencode models` exited \(result.status): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return result.stdout.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
```

In `linkc_delegate_task`, right after the `if let tier { guard settings.model(...) != nil ... }` block:

```swift
                if toAgent == .opencode, let tier, let model = settings.model(for: .opencode, tier: tier) {
                    let offered: [String]
                    do {
                        offered = try openCodeModels(workspaceRoot)
                    } catch {
                        return toolResultResponse(
                            id: id,
                            text: "Error: could not check opencode tier \(tier.rawValue)'s model \(model) against the models OpenCode lists — \(error)",
                            isError: true)
                    }
                    guard offered.contains(model) else {
                        return toolResultResponse(
                            id: id,
                            text: "Error: \(model) (opencode tier \(tier.rawValue)) is not among the models OpenCode lists — free models come and go; set the tier in linkC settings.",
                            isError: true)
                    }
                }
```

In `linkc_switch_model`, right after the `.shell` guard:

```swift
                guard agent != .opencode else {
                    // OpenCode has no `/model <id>` command: typed in, it goes to the model as a prompt.
                    return toolResultResponse(id: id, text: "Error: opencode cannot switch a running session's model — delegate at another tier instead.", isError: true)
                }
```

In `linkc_get_models`, after the tier loop and before `text += "\n"`:

```swift
                    if agent == .opencode {
                        text += "- opencode cannot switch a running session's model; delegate at another tier\n"
                    }
```

`Sources/linkc-mcp` builds the server with the default lister; check it passes nothing that overrides it.

- [ ] **Step 4: Run the tests to see them pass**

Run: `swift test --scratch-path $SP --filter 'MCPServerOpenCodeTests|MCPServerModelTests|MCPServerTaskTests|MCPServerTests|MCPServerIdentityTests'`
Expected: pass.

- [ ] **Step 5: Check the listing against the real OpenCode**

From a scratch folder under the scratchpad: `OPENCODE_DISABLE_AUTOUPDATE=1 opencode models --standalone | head -3` and confirm `listOpenCodeModels`'s parsing matches (one `provider/model` id per line, no colour codes when piped). Report the lines.

- [ ] **Step 6: Revert-proof, then commit**

```bash
git add Sources/LinkCKit/MCP/MCPServer.swift Tests/LinkCKitTests/MCPServerOpenCodeTests.swift
git commit -m "feat(mcp): refuse OpenCode delegation to a model OpenCode no longer lists"
```

---

### Task 8: Whole-branch verification

**Files:** none new.

- [ ] **Step 1: Full suite and build**

Run: `swift build --scratch-path $SP && swift test --scratch-path $SP 2>&1 | tail -30`
Expected: every test passes except any that also failed on the baseline (`TerminalSessionTests.testTwoBackToBackSendInputCallsNeverInterleave` failed once on `main`). Re-run that one alone; if it passes alone, note it as timing-sensitive and pre-existing.

- [ ] **Step 2: Thread sanitizer**

Run: `./scripts/tsan.sh` (read it first; point it at the isolated build folder if it takes one).
Expected: no new reports.

- [ ] **Step 3: Account for every Grok-shaped list**

Run: `grep -rn '\.grok\b\|"grok"' Sources` and confirm each hit is Grok-only or already lists `.opencode`.

- [ ] **Step 4: Commit hygiene**

Run: `./scripts/check-commits.sh origin/main..HEAD` and `git log origin/main..HEAD --format=%B | grep -ic 'claude\|anthropic\|co-authored\|signed-off'`
Expected: the script passes; the count is 0. ("Claude" may appear only as the product name Claude Code inside code or docs, never in a commit message.)

- [ ] **Step 5: Clean up**

Remove scratch files outside the repo that the tasks made; leave the fixtures. `git status` is clean.

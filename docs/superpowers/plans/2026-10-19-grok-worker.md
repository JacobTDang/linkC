# Grok Worker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `grok` worker in linkC — Grok 4.7 on the Cursor plan, run through Cursor's CLI in its own config folder — that Claude can delegate to and control like agy.

**Architecture:** `AgentKind.grok` reuses Cursor's CLI and flags, always launches with `--model <tier model>`, and adds two variables to its terminal: `CURSOR_CONFIG_DIR=~/.cursor-grok` (its own chats and saved default model) and `LINKC_WORKER=grok`. linkC's tool server turns a caller that resolved as Cursor into Grok when that mark is present, and a launched Grok session never gets re-labelled Cursor by process detection.

**Tech Stack:** Swift 6 (strict concurrency), macOS 14, SwiftUI/AppKit app target `linkc`, library `LinkCKit` with XCTest suite `LinkCKitTests`.

**Spec:** `docs/superpowers/specs/2026-10-17-grok-worker-design.md`

## Global Constraints

- No new dependencies. Swift 6 strict concurrency stays clean; CI also runs `./scripts/tsan.sh`.
- `AgentKind.grok`: rawValue `grok`, pill `GROK`, display name `Grok (via Cursor)`, short name `Grok`, brand colour `#E5E5EA`, logo drawn in one colour (`isTemplate: true`).
- Grok's tiers, verbatim: light `grok-4.7-low`, standard `grok-4.7-medium`, deep `grok-4.7-xhigh`; default tier standard.
- Grok's folder is `~/.cursor-grok`. Its terminal adds `CURSOR_CONFIG_DIR=<home>/.cursor-grok` and `LINKC_WORKER=grok` to `LINKC_SESSION`.
- Every Grok launch names a model. With no model for the tier it refuses with exactly `no model configured for grok tier <tier> — set it in linkC settings`.
- Grok's usage row reason, verbatim: `Grok runs on the Cursor plan, which publishes no quota locally — only a cap linkC sees in its terminal`.
- Grok's tool-server usage reader reason, verbatim: `Grok runs on the Cursor plan, which writes no local session records`.
- Cursor's own behaviour does not change: it still refuses a tier (`cursor cannot be pinned to a model`).
- linkC holds no credentials. Fail loud: no swallowed errors, no silent fallbacks.
- Tests first. Mock data only in tests. Run the tests named in each task, then the whole suite before the branch is done.
- Commit messages: a plain conventional subject, no trailers of any kind, and never the word "claude" or any assistant name. Run `./scripts/check-commits.sh origin/main..HEAD` before pushing.

## Commands

- One test class: `swift test --filter LinkCKitTests.<ClassName>`
- One test: `swift test --filter LinkCKitTests.<ClassName>/<testName>`
- Everything (library and app target): `swift build && swift test`

## File Map

| File | Change |
|---|---|
| `Sources/LinkCKit/Core/AgentKind.swift` | `case grok`; its properties and descriptor; `workerEnvironmentKey`, `grokConfigDirectory(home:)`, `environment(for:home:)` (Task 1); `peers`, `peerList` (Task 5) |
| `Sources/LinkCKit/Core/AgentLogo.swift` | Grok's mark |
| `Sources/LinkCKit/Core/AgentModelCatalog.swift` | Grok's suggested models |
| `Sources/LinkCKit/Core/LimitDetector.swift` | Grok uses Cursor's cap rules |
| `Sources/LinkCKit/Usage/UsageRows.swift` | Grok's row, order and reason |
| `Sources/linkc/Theme.swift` | Grok's colour |
| `Sources/LinkCKit/Core/AgentModelSettings.swift` | Grok seeded; `fillingInAgents(from:)` |
| `Sources/LinkCKit/Config/AgentModelStore.swift` | `load` fills in agents a saved file never named |
| `Sources/linkc/Screens/SettingsScreen.swift` | Grok's tier fields |
| `Sources/LinkCKit/App/AppCoordinator.swift` | `launchModel(for:tier:)`, `grokEnvironment()` |
| `Sources/LinkCKit/Terminal/TerminalSession.swift` | a Grok session stays Grok |
| `Sources/LinkCKit/Terminal/ProcessSnooper.swift` | `environmentVariable(_:inAncestorsOf:maxDepth:)` |
| `Sources/LinkCKit/MCP/MCPServer.swift` | `AncestorWorkerCache`, `workerResolver`, Grok rule in `resolveCaller` (Task 4); agent lists, Grok usage reader (Task 5) |
| `Sources/LinkCKit/App/AppCoordinator+Relay.swift` | Grok is a reroute candidate |
| `Sources/linkc/PanelView.swift` | Grok in the new / continue / resume menus |

`Sources/LinkCKit/Board/BoardTech.swift` is deliberately unchanged: on a board, `grok` already names the xAI model provider (`("xai", "xAI", ["grok"])`), not this worker.

---

### Task 1: Grok is an agent kind

Adding the case breaks every exhaustive `switch` on `AgentKind`; this task gives each one its Grok answer, so the build compiles again with Grok fully described.

**Files:**
- Modify: `Sources/LinkCKit/Core/AgentKind.swift`
- Modify: `Sources/LinkCKit/Core/AgentLogo.swift`
- Modify: `Sources/LinkCKit/Core/AgentModelCatalog.swift`
- Modify: `Sources/LinkCKit/Core/LimitDetector.swift`
- Modify: `Sources/LinkCKit/Usage/UsageRows.swift`
- Modify: `Sources/linkc/Theme.swift`
- Test: `Tests/LinkCKitTests/AgentDescriptorTests.swift`, `AgentLogoTests.swift`, `AgentModelCatalogTests.swift`, `LimitDetectorTests.swift`, `UsageRowsTests.swift`

**Interfaces:**
- Produces: `AgentKind.grok`; `AgentKind.workerEnvironmentKey: String` (`"LINKC_WORKER"`); `AgentDescriptor.grokConfigFolderName: String` (`".cursor-grok"`); `AgentDescriptor.grokConfigDirectory(home: URL) -> URL`; `AgentDescriptor.environment(for: AgentKind, home: URL) -> [String: String]`.

- [ ] **Step 1: Write the failing tests**

Append to `AgentDescriptorTests`:

```swift
    /// Grok runs on the Cursor plan through Cursor's own CLI: same binary, same flags.
    func testGrokIsItsOwnAgentRunningCursorsCLI() {
        XCTAssertEqual(AgentKind.grok.pillText, "GROK")
        XCTAssertEqual(AgentKind.grok.displayName, "Grok (via Cursor)")
        XCTAssertEqual(AgentKind.grok.shortName, "Grok")
        XCTAssertEqual(AgentKind.grok.brandColorHex, "#E5E5EA")
        let grok = AgentDescriptor.descriptor(for: .grok)
        let cursor = AgentDescriptor.descriptor(for: .cursor)
        XCTAssertEqual(grok.kind, .grok)
        XCTAssertEqual(grok.binaryName, cursor.binaryName)
        XCTAssertEqual(grok.defaultCandidatePaths, cursor.defaultCandidatePaths)
        for mode in [LaunchMode.new, .continueLast, .resume] {
            XCTAssertEqual(AgentDescriptor.arguments(for: .grok, mode: mode, sessionId: "S-1"),
                           AgentDescriptor.arguments(for: .cursor, mode: mode, sessionId: "S-1"), "\(mode)")
        }
    }

    /// Only Grok gets its own Cursor folder and the mark that tells linkC's tool server it is Grok.
    func testOnlyGrokGetsItsOwnCursorFolderAndWorkerMark() {
        let home = URL(fileURLWithPath: "/Users/someone")
        XCTAssertEqual(AgentKind.workerEnvironmentKey, "LINKC_WORKER")
        XCTAssertEqual(AgentDescriptor.grokConfigFolderName, ".cursor-grok")
        XCTAssertEqual(AgentDescriptor.grokConfigDirectory(home: home).path, "/Users/someone/.cursor-grok")
        XCTAssertEqual(AgentDescriptor.environment(for: .grok, home: home),
                       ["CURSOR_CONFIG_DIR": "/Users/someone/.cursor-grok", "LINKC_WORKER": "grok"])
        for kind in AgentKind.allCases where kind != .grok {
            XCTAssertEqual(AgentDescriptor.environment(for: kind, home: home), [:], "\(kind)")
        }
    }
```

In `AgentLogoTests`, replace `testOnlyCursorIsTintedByTheApp` with:

```swift
    /// Cursor's and Grok's marks are one colour (the files draw in `currentColor`); the rest are
    /// drawn as they are.
    func testOnlyCursorAndGrokAreTintedByTheApp() {
        XCTAssertEqual(AgentKind.allCases.filter { $0.logo?.isTemplate == true }, [.cursor, .grok])
    }
```

Append to `AgentModelCatalogTests`:

```swift
    func testGrokSuggestsItsGrok47Tiers() {
        XCTAssertEqual(AgentModelCatalog.models(for: .grok).map(\.id), ["grok-4.7-medium", "grok-4.7-low", "grok-4.7-xhigh"])
        XCTAssertEqual(AgentModelCatalog.defaultModel(for: .grok).id, "grok-4.7-medium")
        XCTAssertTrue(AgentModelCatalog.isFreeOrSubscription(model: "grok-4.7-low", for: .grok))
    }
```

Append to `LimitDetectorTests`, after `testCursorRateLimitStillDetected`:

```swift
    /// Grok runs Cursor's CLI, so Cursor's caps are what a Grok terminal shows.
    func testGrokIsLimitedByCursorsCaps() {
        let cap = LimitDetector.detectLimit(inOutput: "Error: You've hit your " + "usage limit", agent: .grok)
        XCTAssertEqual(cap?.agent, .grok)
        XCTAssertEqual(cap?.cooldown, 6 * 3600)
        XCTAssertNotNil(LimitDetector.detectLimit(inOutput: "Rate limit " + "reached. Try again later.", agent: .grok))
    }
```

In `UsageRowsTests`, replace `testTheRowOrderIsFixed` and `testAgentsWithNoSourceAreListedWithTheirReason` with:

```swift
    func testTheRowOrderIsFixed() {
        let result = build(
            claude: reading(.claude, percent: 37, plan: nil),
            codex: reading(percent: 68),
            limits: [.cursor: cap(.cursor, clearsIn: 10_800), .grok: cap(.grok, clearsIn: 3600),
                     .agy: cap(.agy, clearsIn: 600)])
        XCTAssertEqual(result.rows.map(\.agent), [.claude, .codex, .cursor, .grok, .agy])
        XCTAssertTrue(result.unknown.isEmpty)
    }

    func testAgentsWithNoSourceAreListedWithTheirReason() {
        let result = build(codex: reading(percent: nil, weekPercent: nil, reason: "no session records found"))
        XCTAssertEqual(result.unknown.map(\.agent), [.claude, .codex, .cursor, .grok, .agy])
        XCTAssertEqual(result.unknown.first { $0.agent == .claude }?.reason,
                       "no reading yet — a Claude session reports after its first reply")
        XCTAssertEqual(result.unknown.first { $0.agent == .codex }?.reason, "no session records found")
        XCTAssertEqual(result.unknown.first { $0.agent == .cursor }?.reason.isEmpty, false)
        XCTAssertEqual(result.unknown.first { $0.agent == .grok }?.reason,
                       "Grok runs on the Cursor plan, which publishes no quota locally — only a cap linkC sees in its terminal")
        XCTAssertEqual(result.unknown.first { $0.agent == .agy }?.reason.isEmpty, false)
    }
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift build --build-tests 2>&1 | grep -m3 error:`
Expected: `error: type 'AgentKind' has no member 'grok'` (the tests do not compile yet).

- [ ] **Step 3: Implement**

`Sources/LinkCKit/Core/AgentKind.swift` — add the case after `codex`, and a Grok branch to each property:

```swift
public enum AgentKind: String, Sendable, CaseIterable, Codable {
    case claude
    case agy
    case cursor
    case codex
    case grok
    case shell
```

```swift
        case .codex: return "CODEX"
        case .grok: return "GROK"
```

```swift
        case .codex: return "#10A37F"     // openAI emerald
        case .grok: return "#E5E5EA"      // xAI's mark is monochrome; light on the dark panel
```

```swift
        case .codex: return "Codex"
        case .grok: return "Grok (via Cursor)"
```

```swift
        case .codex: return "Codex"
        case .grok: return "Grok"
```

(The second `"Codex"` line above is `shortName`'s.)

Below the enum's last property, inside `enum AgentKind`, add:

```swift
    /// The variable linkC sets on a terminal whose agent runs on another agent's CLI. Grok runs
    /// Cursor's, so this is how linkC's tool server tells a Grok worker from Cursor.
    public static let workerEnvironmentKey = "LINKC_WORKER"
```

In `AgentDescriptor.descriptor(for:)`, add before `case .shell:`:

```swift
        case .grok:
            // Grok runs on the Cursor plan through Cursor's own CLI; `environment(for:home:)` is
            // what sets a Grok terminal apart from a Cursor one.
            let cursor = descriptor(for: .cursor)
            return AgentDescriptor(
                kind: .grok,
                binaryName: cursor.binaryName,
                defaultCandidatePaths: cursor.defaultCandidatePaths,
                yoloFlags: cursor.yoloFlags,
                continueArgs: cursor.continueArgs,
                resumeArgs: cursor.resumeArgs
            )
```

After `arguments(for:mode:sessionId:)`, add:

```swift
    /// The name of Grok's own Cursor folder in the user's home.
    public static let grokConfigFolderName = ".cursor-grok"

    /// Grok's own Cursor folder: its chats and its saved default model, kept out of `~/.cursor`.
    /// Cursor's CLI saves every `--model` it is given as its default, so without this folder each
    /// Grok launch would move the user's own Cursor default to Grok.
    public static func grokConfigDirectory(home: URL) -> URL {
        home.appendingPathComponent(grokConfigFolderName, isDirectory: true)
    }

    /// What `kind`'s terminal needs beyond `LINKC_SESSION`. Only Grok needs anything: its own
    /// Cursor folder, and the mark linkC's tool server reads to tell it from Cursor.
    public static func environment(for kind: AgentKind, home: URL) -> [String: String] {
        guard kind == .grok else { return [:] }
        return [
            "CURSOR_CONFIG_DIR": grokConfigDirectory(home: home).path,
            AgentKind.workerEnvironmentKey: AgentKind.grok.rawValue
        ]
    }
```

`Sources/LinkCKit/Core/AgentLogo.swift` — in `logo`, add `case .grok: return AgentLogo(svg: Self.grokSVG, isTemplate: true)` after the Cursor line, and add below `cursorSVG` (the same package and version as the others, `icons/grok.svg`, with its packed arc flags written out and the size set to 24):

```swift
    private static let grokSVG = ##"<svg fill="currentColor" fill-rule="evenodd" height="24" style="flex:none;line-height:1" viewBox="0 0 24 24" width="24" xmlns="http://www.w3.org/2000/svg"><title>Grok</title><path d="M9.27 15.29l7.978-5.897c.391-.29.95-.177 1.137.272.98 2.369.542 5.215-1.41 7.169-1.951 1.954-4.667 2.382-7.149 1.406l-2.711 1.257c3.889 2.661 8.611 2.003 11.562-.953 2.341-2.344 3.066-5.539 2.388-8.42l.006.007c-.983-4.232.242-5.924 2.75-9.383.06-.082.12-.164.179-.248l-3.301 3.305v-.01L9.267 15.292M7.623 16.723c-2.792-2.67-2.31-6.801.071-9.184 1.761-1.763 4.647-2.483 7.166-1.425l2.705-1.25a7.808 7.808 0 0 0 -1.829 -1A8.975 8.975 0 0 0 5.984 5.83c-2.533 2.536-3.33 6.436-1.962 9.764 1.022 2.487-.653 4.246-2.34 6.022-.599.63-1.199 1.259-1.682 1.925l7.62-6.815"></path></svg>"##
```

`Sources/LinkCKit/Core/AgentModelCatalog.swift` — in `models(for:)`, before `case .shell:`:

```swift
        case .grok:
            return [
                AgentModelInfo(id: "grok-4.7-medium", displayName: "Grok 4.7 Medium", isFreeOrSubscription: true, isDefault: true),
                AgentModelInfo(id: "grok-4.7-low", displayName: "Grok 4.7 Low", isFreeOrSubscription: true, isDefault: false),
                AgentModelInfo(id: "grok-4.7-xhigh", displayName: "Grok 4.7 Extra High", isFreeOrSubscription: true, isDefault: false)
            ]
```

`Sources/LinkCKit/Core/LimitDetector.swift` — in `rules(for:)`, replace `case .cursor: return cursorRules` with:

```swift
        // Grok runs Cursor's CLI, so a Grok terminal shows Cursor's caps.
        case .cursor, .grok: return cursorRules
```

`Sources/LinkCKit/Usage/UsageRows.swift`:

```swift
    public static let order: [AgentKind] = [.claude, .codex, .cursor, .grok, .agy]
```

In `silentSourceReason`, after the `.cursor` case:

```swift
        case .grok:
            return "Grok runs on the Cursor plan, which publishes no quota locally — only a cap linkC sees in its terminal"
```

In `build`, replace `case .cursor, .agy, .shell:` with `case .cursor, .grok, .agy, .shell:`.

`Sources/linkc/Theme.swift` — in `agentColor`, after the Codex line:

```swift
        case .grok: return Color(red: 229/255, green: 229/255, blue: 234/255)  // #E5E5EA
```

- [ ] **Step 4: Run the tests**

Run: `swift build` — Expected: builds with no errors (the compiler lists any switch still missing `.grok`; these six files are all of them on `main` at `c56284d`).
Run: `swift test --filter "LinkCKitTests.(AgentDescriptorTests|AgentLogoTests|AgentModelCatalogTests|LimitDetectorTests|UsageRowsTests|HandoffComposerTests)"`
Expected: all pass. `AgentLogoTests.testEveryAgentButShellHasALogoThatLoads` now also loads Grok's mark at 24×24.

- [ ] **Step 5: Commit**

```bash
git add Sources/LinkCKit/Core/AgentKind.swift Sources/LinkCKit/Core/AgentLogo.swift Sources/LinkCKit/Core/AgentModelCatalog.swift Sources/LinkCKit/Core/LimitDetector.swift Sources/LinkCKit/Usage/UsageRows.swift Sources/linkc/Theme.swift Tests/LinkCKitTests/AgentDescriptorTests.swift Tests/LinkCKitTests/AgentLogoTests.swift Tests/LinkCKitTests/AgentModelCatalogTests.swift Tests/LinkCKitTests/LimitDetectorTests.swift Tests/LinkCKitTests/UsageRowsTests.swift
git commit -m "feat(grok): Grok is an agent kind that runs Cursor's CLI"
```

---

### Task 2: Grok's tiers

**Files:**
- Modify: `Sources/LinkCKit/Core/AgentModelSettings.swift`
- Modify: `Sources/LinkCKit/Config/AgentModelStore.swift:38-56` (`load`)
- Modify: `Sources/linkc/Screens/SettingsScreen.swift:58`
- Test: `Tests/LinkCKitTests/AgentModelStoreTests.swift`, `Tests/LinkCKitTests/MCPServerTaskTests.swift`

**Interfaces:**
- Consumes: `AgentKind.grok` (Task 1).
- Produces: `AgentModelSettings.seeded` maps Grok; `AgentModelSettings.fillingInAgents(from: AgentModelSettings) -> AgentModelSettings`.

- [ ] **Step 1: Write the failing tests**

Append to `AgentModelStoreTests`:

```swift
    func testGrokIsSeededOnGrok47WithStandardAsItsDefault() {
        let seeded = AgentModelSettings.seeded
        XCTAssertEqual(seeded.model(for: .grok, tier: .light), "grok-4.7-low")
        XCTAssertEqual(seeded.model(for: .grok, tier: .standard), "grok-4.7-medium")
        XCTAssertEqual(seeded.model(for: .grok, tier: .deep), "grok-4.7-xhigh")
        XCTAssertEqual(seeded.defaultTier(for: .grok), .standard)
    }

    /// A models.json saved before Grok existed names no Grok tiers. Loading it must still give
    /// Grok its seeded models, or every delegation to Grok would be refused.
    func testAFileSavedBeforeGrokExistedLoadsGrokFromTheSeed() throws {
        let store = AgentModelStore(directory: dir)
        let json = """
        {"models":{"codex":{"light":"gpt-5.6-luna","standard":"gpt-5.6-sol","deep":"gpt-9-testonly"}},
         "defaultTiers":{"codex":"deep"}}
        """
        try json.write(toFile: store.path, atomically: true, encoding: .utf8)

        let settings = store.load()
        XCTAssertEqual(settings.model(for: .grok, tier: .standard), "grok-4.7-medium")
        XCTAssertEqual(settings.defaultTier(for: .grok), .standard)
        XCTAssertEqual(settings.model(for: .codex, tier: .deep), "gpt-9-testonly", "an agent the file names keeps the file's models")
        XCTAssertEqual(settings.defaultTier(for: .codex), .deep)
    }

    /// An agent the file does name keeps exactly what the file says: an emptied tier stays
    /// empty instead of being refilled from the seed.
    func testASavedGrokMappingIsNotRefilledFromTheSeed() throws {
        let store = AgentModelStore(directory: dir)
        let json = """
        {"models":{"grok":{"light":"","standard":"grok-4.7-high-fast"}},"defaultTiers":{"grok":"light"}}
        """
        try json.write(toFile: store.path, atomically: true, encoding: .utf8)

        let settings = store.load()
        XCTAssertNil(settings.model(for: .grok, tier: .light))
        XCTAssertEqual(settings.model(for: .grok, tier: .standard), "grok-4.7-high-fast")
        XCTAssertNil(settings.model(for: .grok, tier: .deep))
        XCTAssertEqual(settings.defaultTier(for: .grok), .light)
    }
```

Append to `MCPServerTaskTests`, after `testDelegateToCursorWithNoTierStillWorks`:

```swift
    func testDelegateToGrokTakesItsDefaultTier() throws {
        let res = try mcpCall(server(as: .claude, models: .seeded), "linkc_delegate_task",
                              ["to": "grok", "prompt": "Rename a file"])
        XCTAssertFalse(res.isError, res.text)
        let task = try XCTUnwrap(inbox.openTasks().first)
        XCTAssertEqual(task.toAgent, .grok)
        XCTAssertEqual(task.tier, .standard)
    }

    func testDelegateToGrokRecordsAnExplicitTier() throws {
        let res = try mcpCall(server(as: .claude, models: .seeded), "linkc_delegate_task",
                              ["to": "grok", "prompt": "Design the cache", "tier": "deep"])
        XCTAssertFalse(res.isError, res.text)
        XCTAssertEqual(try XCTUnwrap(inbox.openTasks().first).tier, .deep)
    }

    func testGetModelsReportsGrokTiers() throws {
        let res = try mcpCall(server(as: .claude, models: .seeded), "linkc_get_models", ["agent": "grok"])
        XCTAssertFalse(res.isError, res.text)
        XCTAssertTrue(res.text.contains("grok-4.7-low"), res.text)
        XCTAssertTrue(res.text.contains("grok-4.7-medium — default"), res.text)
        XCTAssertTrue(res.text.contains("grok-4.7-xhigh"), res.text)
        XCTAssertFalse(res.text.contains("cannot be pinned"), res.text)
    }

    func testSwitchingGrokToAConfiguredModelIsQueued() throws {
        let res = try mcpCall(server(as: .claude, models: .seeded), "linkc_switch_model",
                              ["agent": "grok", "model": "grok-4.7-low"])
        XCTAssertFalse(res.isError, res.text)
        XCTAssertTrue(res.text.contains("/model grok-4.7-low"), res.text)
    }
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --filter "LinkCKitTests.(AgentModelStoreTests|MCPServerTaskTests)"`
Expected: the seven new tests fail. The delegations fail with `no model configured for grok tier standard — set it in linkC settings`, and the store tests get `nil` for Grok's models.

- [ ] **Step 3: Implement**

`Sources/LinkCKit/Core/AgentModelSettings.swift` — in the doc comment above `seeded`, after "`agy models` lists the agy ids verbatim.", add: "The grok ids are read verbatim from `cursor-agent models` (2026-10-17); Grok runs on the Cursor plan." In `seeded`, add a Grok entry to each table:

```swift
            AgentKind.agy.rawValue: [
                "light": "gemini-3.8-flash-low", "standard": "gemini-3.8-flash-medium", "deep": "gemini-3.1-pro-high"
            ],
            AgentKind.grok.rawValue: ["light": "grok-4.7-low", "standard": "grok-4.7-medium", "deep": "grok-4.7-xhigh"]
        ],
        defaultTiers: [
            AgentKind.claude.rawValue: ModelTier.standard.rawValue,
            AgentKind.codex.rawValue: ModelTier.standard.rawValue,
            AgentKind.agy.rawValue: ModelTier.standard.rawValue,
            AgentKind.grok.rawValue: ModelTier.standard.rawValue
        ]
```

After `configuredModels(for:)`, add:

```swift
    /// `self`, plus `seed`'s mapping for every agent `self` never mentions — how a file saved
    /// before an agent existed picks that agent up. An agent `self` does mention keeps exactly
    /// what it has, emptied tiers included.
    public func fillingInAgents(from seed: AgentModelSettings) -> AgentModelSettings {
        var result = self
        for (agent, tiers) in seed.models where result.models[agent] == nil {
            result.models[agent] = tiers
            if result.defaultTiers[agent] == nil, let tier = seed.defaultTiers[agent] {
                result.defaultTiers[agent] = tier
            }
        }
        return result
    }
```

`Sources/LinkCKit/Config/AgentModelStore.swift` — in `load()`, replace `return try parseLenient(data).settings` with:

```swift
            // A file saved before an agent existed still gives that agent its seeded tiers.
            return try parseLenient(data).settings.fillingInAgents(from: .seeded)
```

`Sources/linkc/Screens/SettingsScreen.swift:58`:

```swift
                    ForEach([AgentKind.claude, .codex, .agy, .grok], id: \.self) { agent in
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter "LinkCKitTests.(AgentModelStoreTests|MCPServerTaskTests|AppPreferencesTests|AgentModelCatalogTests)"`
Expected: all pass, including `testDelegateRefusesATieredTaskForCursor` unchanged.
Run: `swift build` — Expected: the app target builds.

- [ ] **Step 5: Commit**

```bash
git add Sources/LinkCKit/Core/AgentModelSettings.swift Sources/LinkCKit/Config/AgentModelStore.swift Sources/linkc/Screens/SettingsScreen.swift Tests/LinkCKitTests/AgentModelStoreTests.swift Tests/LinkCKitTests/MCPServerTaskTests.swift
git commit -m "feat(grok): Grok's tiers default to Grok 4.7, and a saved file from before Grok still gets them"
```

---

### Task 3: Launching a Grok worker

**Files:**
- Modify: `Sources/LinkCKit/App/AppCoordinator.swift` (`launch`, around lines 699-800)
- Modify: `Sources/LinkCKit/Terminal/TerminalSession.swift:85` (`sampleForegroundAgent`) and `:147-154` (`scrubbedEnvironment`)
- Test: `Tests/LinkCKitTests/AppCoordinatorIntegrationTests.swift`, `Tests/LinkCKitTests/TerminalSessionAgentTests.swift`, `Tests/LinkCKitTests/TerminalTests.swift`

**Interfaces:**
- Consumes: `AgentDescriptor.environment(for:home:)`, `AgentDescriptor.grokConfigDirectory(home:)`, `AgentDescriptor.grokConfigFolderName` (Task 1); Grok's seeded tiers (Task 2).
- Produces: a `.grok` session launches `<cursor> agent --yolo --trust --approve-mcps [--continue|--resume] --model <id>` with `CURSOR_CONFIG_DIR` and `LINKC_WORKER=grok`, and keeps `agentKind == .grok` while its foreground process reads as Cursor. No other session inherits a Grok terminal's mark or folder from linkC's own environment.

- [ ] **Step 1: Write the failing tests**

In `AppCoordinatorIntegrationTests.makeCoordinator`, add a `userHome: URL? = nil` parameter after `defaults`, pass `userHome: userHome,` to `AppCoordinator(...)` right after `agentPathResolver:`, and replace the mock script so it also records the two Grok variables:

```swift
            // It also records its own argv, one argument per line, in `argv-<LINKC_SESSION>` beside
            // itself, and the two variables a Grok terminal adds in `env-<LINKC_SESSION>`, so a
            // test can check exactly what linkC launched.
            let scriptContent = "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$(dirname \"$0\")/argv-$LINKC_SESSION\"\nprintf 'CURSOR_CONFIG_DIR=%s\\nLINKC_WORKER=%s\\n' \"$CURSOR_CONFIG_DIR\" \"$LINKC_WORKER\" > \"$(dirname \"$0\")/env-$LINKC_SESSION\"\nstty -echo 2>/dev/null\nprintf '\\033[?2004h'\nexec /bin/cat\n"
```

Add a helper next to `waitUntil`:

```swift
    /// The lines the mock agent wrote to `<name>-<session id>` when it started, polled for up to
    /// five seconds until there are `count` of them.
    private func launchedLines(_ name: String, of session: Session, count: Int) -> [String] {
        let file = tempDir.appendingPathComponent("\(name)-\(session.id)")
        var lines: [String] = []
        let deadline = Date().addingTimeInterval(5)
        while lines.count < count, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            lines = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }
        return lines
    }
```

Add after `testASessionSpawnedWithNoTierIsNotPinned`:

```swift
    /// A Grok worker runs Cursor's CLI pinned to its tier's Grok model, in its own Cursor folder,
    /// marked as Grok for linkC's tool server.
    @MainActor
    func testAGrokSessionLaunchesCursorsCLIOnItsTierInItsOwnFolder() throws {
        let home = tempDir.appendingPathComponent("home")
        let coordinator = makeCoordinator(userHome: home)
        defer { coordinator.shutdown() }

        let session = try coordinator.newSession(cwd: tempDir.path, agent: .grok, mode: .new, tier: .deep)

        XCTAssertEqual(session.agentKind, .grok)
        XCTAssertEqual(session.model, "grok-4.7-xhigh")
        XCTAssertEqual(session.modelTier, .deep)
        let folder = home.appendingPathComponent(".cursor-grok")
        XCTAssertEqual(launchedLines("argv", of: session, count: 6),
                       ["agent", "--yolo", "--trust", "--approve-mcps", "--model", "grok-4.7-xhigh"])
        XCTAssertEqual(launchedLines("env", of: session, count: 2),
                       ["CURSOR_CONFIG_DIR=\(folder.path)", "LINKC_WORKER=grok"])
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue, "linkC makes Grok's folder before the first launch")
    }

    /// With no tier, a Grok session still names its model — on a fresh `~/.cursor-grok`, Cursor's
    /// own default is Auto, not Grok. Continuing a Grok chat takes the default tier the same way.
    @MainActor
    func testAGrokSessionWithNoTierRunsOnItsDefaultTier() throws {
        let coordinator = makeCoordinator(userHome: tempDir.appendingPathComponent("home"))
        defer { coordinator.shutdown() }

        let fresh = try coordinator.newSession(cwd: tempDir.path, agent: .grok, mode: .new)
        XCTAssertEqual(fresh.model, "grok-4.7-medium")
        XCTAssertEqual(fresh.modelTier, .standard)
        XCTAssertEqual(launchedLines("argv", of: fresh, count: 6),
                       ["agent", "--yolo", "--trust", "--approve-mcps", "--model", "grok-4.7-medium"])

        let continued = try coordinator.newSession(cwd: tempDir.path, agent: .grok, mode: .continueLast)
        XCTAssertEqual(launchedLines("argv", of: continued, count: 7),
                       ["agent", "--yolo", "--trust", "--approve-mcps", "--continue", "--model", "grok-4.7-medium"])
    }

    @MainActor
    func testAGrokSessionWithNoModelForItsTierIsRefused() throws {
        var models = AgentModelSettings.seeded
        models.setModel("", for: .grok, tier: .standard)
        let coordinator = makeCoordinator(models: models, userHome: tempDir.appendingPathComponent("home"))
        defer { coordinator.shutdown() }

        XCTAssertThrowsError(try coordinator.newSession(cwd: tempDir.path, agent: .grok, mode: .new)) { error in
            XCTAssertTrue(String(describing: error).contains("no model configured for grok tier standard — set it in linkC settings"),
                          String(describing: error))
        }
        XCTAssertTrue(coordinator.store.sessions.isEmpty, "a refused launch leaves no session behind")
    }

    /// Without its own folder, Grok's `--model` would become the user's own Cursor default, so a
    /// folder linkC cannot make stops the launch.
    @MainActor
    func testAGrokSessionWhoseFolderCannotBeMadeIsRefused() throws {
        let notAFolder = tempDir.appendingPathComponent("home-is-a-file")
        try Data("x".utf8).write(to: notAFolder)
        let coordinator = makeCoordinator(userHome: notAFolder)
        defer { coordinator.shutdown() }

        XCTAssertThrowsError(try coordinator.newSession(cwd: tempDir.path, agent: .grok, mode: .new)) { error in
            XCTAssertTrue(String(describing: error).contains(".cursor-grok"), String(describing: error))
        }
        XCTAssertTrue(coordinator.store.sessions.isEmpty, "a failed launch leaves no session behind")
    }

    @MainActor
    func testAGrokSessionWithNoHomeFolderIsRefused() throws {
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }

        XCTAssertThrowsError(try coordinator.newSession(cwd: tempDir.path, agent: .grok, mode: .new)) { error in
            XCTAssertTrue(String(describing: error).contains("Grok needs a home folder"), String(describing: error))
        }
        XCTAssertTrue(coordinator.store.sessions.isEmpty)
    }

    @MainActor
    func testOnlyAGrokSessionGetsGrokEnvironment() throws {
        let home = tempDir.appendingPathComponent("home")
        let coordinator = makeCoordinator(userHome: home)
        defer { coordinator.shutdown() }

        let session = try coordinator.newSession(cwd: tempDir.path, agent: .codex, mode: .new)

        let env = launchedLines("env", of: session, count: 2)
        XCTAssertEqual(env.last, "LINKC_WORKER=")
        XCTAssertFalse(env.contains("CURSOR_CONFIG_DIR=\(home.appendingPathComponent(".cursor-grok").path)"), "\(env)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".cursor-grok").path))
    }
```

Append to `TerminalSessionAgentTests`:

```swift
    /// A Grok worker runs Cursor's CLI, so its foreground process reads as Cursor; it is still Grok.
    func testAGrokSessionRunningCursorsCLIStaysGrok() throws {
        let session = TerminalSession(id: "grok", cwd: "/tmp", title: "grok", agentKind: .grok)
        try session.start(executable: "/bin/cat", args: [], env: [:])
        defer { session.terminate() }
        session.agentProbe = AgentProbe(inTree: { _ in .cursor }, atOrUnder: { _ in .cursor },
                                        foregroundGroup: { _ in 42 }, now: Date.init)

        XCTAssertEqual(session.sampleForegroundAgent(fresh: true), .grok)
        XCTAssertEqual(session.agentKind, .grok)
    }

    /// Only a session launched as Grok is kept as Grok: Cursor's CLI typed into a plain terminal is Cursor.
    func testAShellRunningCursorsCLIStillBecomesCursor() throws {
        let session = TerminalSession(id: "sh", cwd: "/tmp", title: "sh", agentKind: .shell)
        try session.start(executable: "/bin/cat", args: [], env: [:])
        defer { session.terminate() }
        session.agentProbe = AgentProbe(inTree: { _ in .cursor }, atOrUnder: { _ in .cursor },
                                        foregroundGroup: { _ in 42 }, now: Date.init)

        XCTAssertEqual(session.sampleForegroundAgent(fresh: true), .cursor)
    }

    /// A Grok session that has an agent other than Cursor in front reads as that agent, as any session does.
    func testAGrokSessionRunningAnotherAgentReadsAsThatAgent() throws {
        let session = TerminalSession(id: "grok2", cwd: "/tmp", title: "grok", agentKind: .grok)
        try session.start(executable: "/bin/cat", args: [], env: [:])
        defer { session.terminate() }
        session.agentProbe = AgentProbe(inTree: { _ in .codex }, atOrUnder: { _ in .codex },
                                        foregroundGroup: { _ in 42 }, now: Date.init)

        XCTAssertEqual(session.sampleForegroundAgent(fresh: true), .codex)
    }
```

Append to `TerminalSessionTests` (in `Tests/LinkCKitTests/TerminalTests.swift`), after `testScrubbedEnvironmentDropsClaudeCodeMarkers`:

```swift
    func testScrubbedEnvironmentDropsAGrokTerminalsMarks() {
        // linkC opened from a Grok terminal (`open` forwards the caller's environment) must not
        // hand Grok's mark or Grok's Cursor folder to every session it spawns.
        let base = ["HOME": "/Users/x", "LINKC_WORKER": "grok", "CURSOR_CONFIG_DIR": "/Users/x/.cursor-grok"]
        XCTAssertEqual(TerminalSession.scrubbedEnvironment(base), ["HOME": "/Users/x"])
    }

    func testScrubbedEnvironmentKeepsTheUsersOwnCursorFolder() {
        let base = ["HOME": "/Users/x", "CURSOR_CONFIG_DIR": "/Users/x/my-cursor"]
        XCTAssertEqual(TerminalSession.scrubbedEnvironment(base), base)
    }
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --filter "LinkCKitTests.(AppCoordinatorIntegrationTests|TerminalSessionAgentTests|TerminalSessionTests)"`
Expected: the five Grok launch tests fail (no `--model` on an untiered launch, no Grok variables, no refusal), `testAGrokSessionRunningCursorsCLIStaysGrok` fails with `.cursor`, and `testScrubbedEnvironmentDropsAGrokTerminalsMarks` keeps both variables. The other new tests already pass.

- [ ] **Step 3: Implement**

`Sources/LinkCKit/App/AppCoordinator.swift` — in `launch`, replace:

```swift
        let model = tier.flatMap { resolvedModel(for: agent, tier: $0) }
        let session = store.create(cwd: cwd, title: title, id: id ?? UUID().uuidString, agentKind: agent,
                                   model: model, modelTier: model == nil ? nil : tier,
                                   claudeSessionId: resumeId, isWorker: asWorker)
```

with:

```swift
        let (model, modelTier) = try launchModel(for: agent, tier: tier)
        let session = store.create(cwd: cwd, title: title, id: id ?? UUID().uuidString, agentKind: agent,
                                   model: model, modelTier: modelTier,
                                   claudeSessionId: resumeId, isWorker: asWorker)
```

and replace:

```swift
            let env: [String: String] = ["LINKC_SESSION": session.id]
```

with:

```swift
            var env: [String: String] = ["LINKC_SESSION": session.id]
            if agent == .grok {
                env.merge(try grokEnvironment()) { _, grok in grok }
            }
```

Add these two methods right after `launch`:

```swift
    /// The model a launch pins, and the tier it came from. A tier with no model leaves a session
    /// unpinned — except Grok, which always names its model: on a fresh `~/.cursor-grok`, Cursor's
    /// own default is Auto, not Grok. With no tier, Grok takes its default one; a tier with no
    /// model refuses the launch rather than run on whatever Cursor would pick.
    private func launchModel(for agent: AgentKind, tier: ModelTier?) throws -> (model: String?, tier: ModelTier?) {
        guard agent == .grok else {
            let model = tier.flatMap { resolvedModel(for: agent, tier: $0) }
            return (model, model == nil ? nil : tier)
        }
        let settings = modelSettings()
        let grokTier = tier ?? settings.defaultTier(for: .grok)
        guard let model = settings.model(for: .grok, tier: grokTier) else {
            throw LinkCError.process("no model configured for grok tier \(grokTier.rawValue) — set it in linkC settings")
        }
        return (model, grokTier)
    }

    /// What a Grok terminal adds to `LINKC_SESSION`: its own Cursor folder, made here if missing,
    /// and the mark linkC's tool server reads to tell it from Cursor. Fails loud — without its
    /// folder, Grok's `--model` would become the default of the user's own Cursor.
    private func grokEnvironment() throws -> [String: String] {
        guard let userHome else {
            throw LinkCError.process("Grok needs a home folder for its own Cursor settings, and linkC has none")
        }
        let folder = AgentDescriptor.grokConfigDirectory(home: userHome)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw LinkCError.process("could not create \(folder.path) for Grok's Cursor settings — \(error.localizedDescription)")
        }
        return AgentDescriptor.environment(for: .grok, home: userHome)
    }
```

`grokEnvironment()` runs inside `launch`'s existing `do`, so a throw there goes through `cleanup(sessionId:)` like any launch error.

`Sources/LinkCKit/Terminal/TerminalSession.swift` — in `sampleForegroundAgent`, replace `agentKind = detected ?? initialAgentKind` with:

```swift
        let live = detected ?? initialAgentKind
        // A Grok worker runs Cursor's CLI, so its process reads as Cursor; it is still Grok.
        agentKind = (initialAgentKind == .grok && live == .cursor) ? .grok : live
```

In the same file, replace `scrubbedEnvironment` and add one sentence to its doc comment:

```swift
    /// The inherited environment minus Claude Code's own session markers. linkC may itself be
    /// running inside a claude session (launched from a terminal there, or via `open`, which
    /// forwards the caller's environment) — passing CLAUDECODE/CLAUDE_CODE_* through would make
    /// every spawned claude treat itself as a child session: transcript saving off, nested-
    /// session warnings. A Grok terminal's mark and Cursor folder go too, or every Cursor session
    /// would run as Grok; a Cursor folder the user chose is kept. Sessions get a clean slate; the
    /// explicit `env` overlay still wins.
    static func scrubbedEnvironment(_ base: [String: String]) -> [String: String] {
        base.filter { key, value in
            key != "CLAUDECODE" && !key.hasPrefix("CLAUDE_CODE_")
                && key != AgentKind.workerEnvironmentKey
                && !(key == "CURSOR_CONFIG_DIR"
                     && URL(fileURLWithPath: value).lastPathComponent == AgentDescriptor.grokConfigFolderName)
        }
    }
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter "LinkCKitTests.(AppCoordinatorIntegrationTests|TerminalSessionAgentTests|TerminalSessionTests|AppCoordinatorRelayTests)"`
Expected: all pass, including the existing Codex launch tests (`testACodexSessionIsLaunchedNamingItsSession`, `testASessionSpawnedWithNoTierIsNotPinned`).

- [ ] **Step 5: Commit**

```bash
git add Sources/LinkCKit/App/AppCoordinator.swift Sources/LinkCKit/Terminal/TerminalSession.swift Tests/LinkCKitTests/AppCoordinatorIntegrationTests.swift Tests/LinkCKitTests/TerminalSessionAgentTests.swift Tests/LinkCKitTests/TerminalTests.swift
git commit -m "feat(grok): a Grok worker launches on its tier's model in its own Cursor folder"
```

---

### Task 4: A Grok worker is Grok to linkC's tools

Cursor's CLI loads Cursor's registration (`LINKC_AGENT=cursor`) and passes its MCP servers only that registration's `env` block, so the `LINKC_WORKER` mark on the Grok terminal is read from the nearest ancestor that has it.

**Files:**
- Modify: `Sources/LinkCKit/Terminal/ProcessSnooper.swift:239-252`
- Modify: `Sources/LinkCKit/MCP/MCPServer.swift` (after `AncestorSessionCache`; stored properties; `init`; `resolveCaller`)
- Test: `Tests/LinkCKitTests/MCPServerIdentityTests.swift`, `Tests/LinkCKitTests/MCPServerTaskTests.swift`, new `Tests/LinkCKitTests/ProcessSnooperAncestorEnvironmentTests.swift`

**Interfaces:**
- Consumes: `AgentKind.grok`, `AgentKind.workerEnvironmentKey` (Task 1).
- Produces: `ProcessSnooper.environmentVariable(_ name: String, inAncestorsOf pid: pid_t, maxDepth: Int = 8) -> String?`, and an internal overload adding `parentOf: (pid_t) -> pid_t?` and `variableOf: (String, pid_t) -> String?` that tests drive; `public enum AncestorWorkerCache`; `MCPServer.WorkerResolver = @Sendable () -> String?`; `MCPServer.init(..., sessionResolver:, workerResolver: = { AncestorWorkerCache.value }, usageReaders:, ...)`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/LinkCKitTests/ProcessSnooperAncestorEnvironmentTests.swift`:

```swift
import XCTest
@testable import LinkCKit

/// The ancestor walk over a made-up process tree: the kernel hides an Apple binary's environment
/// (a test's own `/bin/sh` reads as empty), so the walk is tested through its two lookups.
final class ProcessSnooperAncestorEnvironmentTests: XCTestCase {
    /// 40 → 30 → 20 → 10 → launchd.
    private let parents: [pid_t: pid_t] = [40: 30, 30: 20, 20: 10, 10: 1]

    private func walk(_ environments: [pid_t: [String: String]], from pid: pid_t = 40, maxDepth: Int = 8) -> String? {
        ProcessSnooper.environmentVariable("MARK", inAncestorsOf: pid, maxDepth: maxDepth,
                                           parentOf: { self.parents[$0] },
                                           variableOf: { name, pid in environments[pid]?[name] })
    }

    func testTheNearestAncestorCarryingTheVariableWins() {
        XCTAssertEqual(walk([20: ["MARK": "near"], 10: ["MARK": "far"]]), "near")
    }

    func testTheProcessItselfIsNotItsOwnAncestor() {
        XCTAssertNil(walk([40: ["MARK": "mine"]]))
    }

    func testAnEmptyValueIsPassedOver() {
        XCTAssertEqual(walk([30: ["MARK": ""], 10: ["MARK": "far"]]), "far")
    }

    func testTheWalkStopsBeforeLaunchdAndAtItsDepth() {
        XCTAssertNil(walk([1: ["MARK": "launchd"]]))
        XCTAssertNil(walk([10: ["MARK": "far"]], maxDepth: 2))
        XCTAssertEqual(walk([10: ["MARK": "far"]], maxDepth: 3), "far")
    }
}
```

Append to `MCPServerIdentityTests`:

```swift
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
```

Append to `MCPServerTaskTests`:

```swift
    /// A Grok worker's tool server loads Cursor's registration; in the terminal linkC marked as
    /// Grok it is still the task's assignee.
    func testAGrokWorkerStartsItsOwnTask() throws {
        let task = try inbox.createTask(from: .claude, to: .grok, tier: .standard, prompt: "Build", files: [])
        try inbox.markTaskDelivered(taskId: task.id, sessionId: "s1")
        let grok = MCPServer(workspaceRoot: tempDir.path, environment: ["LINKC_AGENT": "cursor"],
                             ancestorResolver: { _ in nil }, sessionResolver: { nil },
                             workerResolver: { "grok" }, usageReaders: [:])

        let res = try mcpCall(grok, "linkc_start_task", ["task_id": task.id])

        XCTAssertFalse(res.isError, res.text)
        XCTAssertEqual(try inbox.task(id: task.id)?.state, .started)
    }
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift build --build-tests 2>&1 | grep -m3 error:`
Expected: `extra argument 'workerResolver' in call`, and `ProcessSnooper.environmentVariable` has no `inAncestorsOf:` overload.

- [ ] **Step 3: Implement**

`Sources/LinkCKit/Terminal/ProcessSnooper.swift` — replace `sessionId(inAncestorsOf:maxDepth:)` and its doc comment with:

```swift
    /// Walks *up* from `pid` (exclusive) through at most `maxDepth` parents and returns the first
    /// non-empty `name` found in an ancestor's real environment (via `KERN_PROCARGS2`), not ours —
    /// an MCP server spawned without the variable in its own `environment` can still recover it
    /// from an ancestor (Codex's or Cursor's CLI process) that did not pass it down.
    public static func environmentVariable(_ name: String, inAncestorsOf pid: pid_t, maxDepth: Int = 8) -> String? {
        environmentVariable(name, inAncestorsOf: pid, maxDepth: maxDepth,
                            parentOf: { parentPid(of: $0) }, variableOf: { environmentVariable($0, ofProcess: $1) })
    }

    /// The walk itself, over any process tree. The kernel hides an Apple binary's environment
    /// from other processes, so tests drive the walk through these two lookups instead.
    static func environmentVariable(
        _ name: String, inAncestorsOf pid: pid_t, maxDepth: Int,
        parentOf: (pid_t) -> pid_t?, variableOf: (String, pid_t) -> String?
    ) -> String? {
        guard pid > 0, maxDepth > 0 else { return nil }
        var current = pid
        for _ in 0..<maxDepth {
            guard let parent = parentOf(current), parent > 1 else { return nil }
            if let value = variableOf(name, parent), !value.isEmpty {
                return value
            }
            current = parent
        }
        return nil
    }

    /// `LINKC_SESSION` from the nearest ancestor that carries one.
    public static func sessionId(inAncestorsOf pid: pid_t, maxDepth: Int = 8) -> String? {
        environmentVariable("LINKC_SESSION", inAncestorsOf: pid, maxDepth: maxDepth)
    }
```

`Sources/LinkCKit/MCP/MCPServer.swift` — after `AncestorSessionCache`, add:

```swift
/// `LINKC_WORKER` from the nearest ancestor that carries it, read at most once per process like
/// `AncestorSessionCache`: Cursor's CLI passes its MCP servers only the registration's own `env`
/// block, so the mark linkC set on a Grok terminal never reaches `environment` directly.
public enum AncestorWorkerCache {
    /// Under XCTest, a test that injected no `workerResolver` reads no real process: it is simply
    /// not in a worker terminal. A test of the worker path injects its own resolver.
    nonisolated(unsafe) static var walk: @Sendable () -> String? = {
        if AncestorSessionCache.isRunningUnderXCTest { return nil }
        return ProcessSnooper.environmentVariable(AgentKind.workerEnvironmentKey, inAncestorsOf: getpid())
    }
    public static let value: String? = walk()
}
```

Next to the existing `SessionResolver` typealias, add:

```swift
    public typealias WorkerResolver = @Sendable () -> String?
```

After the `sessionResolver` stored property, add:

```swift
    /// Falls back to an ancestor's real environment when ours has no `LINKC_WORKER`; see
    /// `AncestorWorkerCache`. Only `resolveCaller` reads it.
    public let workerResolver: WorkerResolver
```

In `init`, add the parameter after `sessionResolver` and assign it:

```swift
        sessionResolver: @escaping SessionResolver = { AncestorSessionCache.value },
        workerResolver: @escaping WorkerResolver = { AncestorWorkerCache.value },
```

```swift
        self.sessionResolver = sessionResolver
        self.workerResolver = workerResolver
```

Replace `resolveCaller` and its doc comment with:

```swift
    /// Identity: explicit `agent` arg → `LINKC_AGENT` env → ancestor process → `.shell` (unidentified),
    /// then a caller that resolved as Cursor inside a terminal linkC marked as Grok is Grok.
    func resolveCaller(_ args: [String: Any]) -> MCPCaller {
        let caller = resolveCallerIgnoringWorker(args)
        guard caller.agent == .cursor, let worker = cursorWorker() else { return caller }
        return MCPCaller(agent: worker, pid: caller.pid)
    }

    private func resolveCallerIgnoringWorker(_ args: [String: Any]) -> MCPCaller {
        let explicitPid = (args["pid"] as? Int).map { pid_t($0) }
        if let s = (args["agent"] as? String) ?? (args["from"] as? String),
           let kind = AgentKind(rawValue: s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()),
           kind != .shell {
            return MCPCaller(agent: kind, pid: explicitPid ?? getppid())
        }
        if let env = environment["LINKC_AGENT"], let kind = AgentKind(rawValue: env.lowercased()), kind != .shell {
            return MCPCaller(agent: kind, pid: explicitPid ?? getppid())
        }
        if let found = ancestorResolver(getpid()) {
            return MCPCaller(agent: found.agent, pid: explicitPid ?? found.pid)
        }
        return MCPCaller(agent: .shell, pid: explicitPid ?? getppid())
    }

    /// The worker linkC launched on Cursor's CLI in this terminal, if it marked one. Grok runs
    /// Cursor's CLI: that CLI hands its MCP servers Cursor's registration, and the model inside may
    /// call itself cursor, so the mark decides. A mark other than `grok` is reported and ignored.
    private func cursorWorker() -> AgentKind? {
        guard let raw = environment[AgentKind.workerEnvironmentKey] ?? workerResolver() else { return nil }
        guard raw.lowercased() == AgentKind.grok.rawValue else {
            FileHandle.standardError.write(Data(
                "linkc-mcp: ignoring \(AgentKind.workerEnvironmentKey)=\(raw) — only grok runs on Cursor's CLI\n".utf8))
            return nil
        }
        return .grok
    }
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter "LinkCKitTests.(ProcessSnooperAncestorEnvironmentTests|MCPServerIdentityTests|MCPServerTaskTests|MCPServerTests|MCPServerModelTests)"`
Expected: all pass, including `testDefaultSessionResolverWalksTheAncestryAtMostOnce` unchanged.

- [ ] **Step 5: Commit**

```bash
git add Sources/LinkCKit/Terminal/ProcessSnooper.swift Sources/LinkCKit/MCP/MCPServer.swift Tests/LinkCKitTests/ProcessSnooperAncestorEnvironmentTests.swift Tests/LinkCKitTests/MCPServerIdentityTests.swift Tests/LinkCKitTests/MCPServerTaskTests.swift
git commit -m "feat(grok): linkC's tools know a Cursor caller in a Grok terminal is Grok"
```

---

### Task 5: Grok in every list of agents

These lists are literal, so the compiler does not flag them: tool descriptions and errors, the peers offered when a target is capped, `linkc_get_models` with no agent, the usage report, the relay's reroute candidates, and the panel's menus.

**Files:**
- Modify: `Sources/LinkCKit/Core/AgentKind.swift`
- Modify: `Sources/LinkCKit/MCP/MCPServer.swift` (lines 195, 364, 439, 443, 472, 493, 505, 768, 771, 780, 902, 982, 1021, 1028, 1073, and `defaultUsageReaders`)
- Modify: `Sources/LinkCKit/App/AppCoordinator+Relay.swift:953`
- Modify: `Sources/LinkCKit/App/WorkspaceManifest.swift:16` (doc comment)
- Modify: `Sources/linkc/AgentPill.swift:4` (doc comment)
- Modify: `Sources/linkc/PanelView.swift:277-298`
- Test: `Tests/LinkCKitTests/AgentDescriptorTests.swift`, `MCPServerTaskTests.swift`, `MCPServerModelTests.swift`, `AppCoordinatorRelayTests.swift`

**Interfaces:**
- Consumes: everything above.
- Produces: `AgentKind.peers: [AgentKind]` (every case but `.shell`, in declaration order) and `AgentKind.peerList: String` (`"claude, agy, cursor, codex, grok"`).

- [ ] **Step 1: Write the failing tests**

Append to `AgentDescriptorTests`:

```swift
    func testPeersAreEveryAgentButAShell() {
        XCTAssertEqual(AgentKind.peers, [.claude, .agy, .cursor, .codex, .grok])
        XCTAssertEqual(AgentKind.peerList, "claude, agy, cursor, codex, grok")
    }
```

Append to `MCPServerTaskTests`:

```swift
    func testAnUnknownAgentErrorNamesGrok() throws {
        let res = try mcpCall(server(as: .claude, models: .seeded), "linkc_delegate_task", ["to": "gork", "prompt": "x"])
        XCTAssertTrue(res.isError)
        XCTAssertTrue(res.text.contains("Supported agents: claude, agy, cursor, codex, grok."), res.text)
    }

    func testACappedTargetOffersGrokInstead() throws {
        try inbox.recordLimit(agent: .codex, reason: "quota", cooldown: 1800)
        let res = try mcpCall(server(as: .claude, models: .seeded), "linkc_delegate_task", ["to": "codex", "prompt": "x"])
        XCTAssertTrue(res.isError)
        XCTAssertTrue(res.text.contains("Alternative available peer agents: claude, agy, cursor, grok."), res.text)
    }

    func testGetModelsWithNoAgentListsGrok() throws {
        let res = try mcpCall(server(as: .claude, models: .seeded), "linkc_get_models")
        XCTAssertFalse(res.isError, res.text)
        XCTAssertTrue(res.text.contains("## Grok (via Cursor)"), res.text)
        XCTAssertTrue(res.text.contains("grok-4.7-medium — default"), res.text)
    }
```

Append to `MCPServerModelTests`:

```swift
    func testEveryToolThatListsAgentsNamesGrok() throws {
        let req = Data(#"{"jsonrpc": "2.0", "id": 1, "method": "tools/list"}"#.utf8)
        let resJson = try JSONSerialization.jsonObject(with: try XCTUnwrap(server.handleMessage(req))) as? [String: Any]
        let tools = try XCTUnwrap((resJson?["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        func description(_ tool: String, _ property: String) -> String {
            let schema = tools.first { $0["name"] as? String == tool }?["inputSchema"] as? [String: Any]
            let properties = schema?["properties"] as? [String: Any]
            return (properties?[property] as? [String: Any])?["description"] as? String ?? ""
        }
        for (tool, property) in [("linkc_delegate_task", "to"), ("linkc_send_message", "to"),
                                 ("linkc_switch_model", "agent"), ("linkc_get_models", "agent"),
                                 ("linkc_broadcast_intent", "agent")] {
            XCTAssertTrue(description(tool, property).contains("grok"), "\(tool).\(property): \(description(tool, property))")
        }
        let delegate = tools.first { $0["name"] as? String == "linkc_delegate_task" }?["description"] as? String ?? ""
        XCTAssertTrue(delegate.contains("grok"), delegate)
    }

    func testTheUsageReportHasAGrokSection() throws {
        let req = Data(#"{"jsonrpc": "2.0", "id": 9, "method": "tools/call", "params": {"name": "linkc_get_usage_status"}}"#.utf8)
        let resJson = try JSONSerialization.jsonObject(with: try XCTUnwrap(server.handleMessage(req))) as? [String: Any]
        let content = (resJson?["result"] as? [String: Any])?["content"] as? [[String: Any]]
        let text = content?.first?["text"] as? String ?? ""
        XCTAssertTrue(text.contains("## Grok (via Cursor)"), text)
    }

    func testGroksDefaultUsageReaderSaysWhyItHasNoFigures() throws {
        let usage = try XCTUnwrap(MCPServer.defaultUsageReaders()[.grok])()
        XCTAssertEqual(usage.agent, .grok)
        XCTAssertEqual(usage.unavailableReason, "Grok runs on the Cursor plan, which writes no local session records")
    }
```

Append to `AppCoordinatorRelayTests`, after `testCheckLimitsAndRerouteSkipsUninstalledCandidateAgents`:

```swift
    /// A capped agent's task can move to Grok when Grok is the one installed peer left.
    @MainActor
    func testACappedTaskCanRerouteToGrok() async throws {
        let ws = tempDir.path
        let scriptURL = tempDir.appendingPathComponent("mock_agent.sh")
        if !FileManager.default.fileExists(atPath: scriptURL.path) {
            try? "#!/bin/sh\nstty -echo 2>/dev/null\nprintf '\\033[?2004h'\nexec /bin/cat\n".write(to: scriptURL, atomically: true, encoding: .utf8)
            var attrs = (try? FileManager.default.attributesOfItem(atPath: scriptURL.path)) ?? [:]
            attrs[.posixPermissions] = 0o755
            try? FileManager.default.setAttributes(attrs, ofItemAtPath: scriptURL.path)
        }
        let settingsDir = tempDir.appendingPathComponent("settings_grok_reroute_test")
        try? FileManager.default.createDirectory(at: settingsDir, withIntermediateDirectories: true)
        let coordinator = AppCoordinator(
            terminals: TerminalSessionManager(),
            hookServer: HookServer.forTesting(),
            notifications: NotificationManager(sink: RecordingSink(), now: { Date() }),
            claudePath: scriptURL.path,
            settingsDir: settingsDir,
            userSettingsURL: tempDir.appendingPathComponent("user-settings.json"),
            manifestDir: tempDir.appendingPathComponent("manifest_grok_reroute_test"),
            agentPathResolver: { kind in kind == .grok ? scriptURL.path : nil },
            userHome: tempDir.appendingPathComponent("home"),
            modelSettings: { .seeded },
            isWatching: { _ in false }
        )
        defer { coordinator.shutdown() }

        let inbox = InboxStore(workspaceRoot: ws)
        let claudeSession = try coordinator.newSession(cwd: ws, agent: .claude)
        coordinator.store.updateState(id: claudeSession.id, to: Self.turnOver)
        let task = try inbox.createTask(from: .cursor, to: .claude, prompt: "Deploy service mesh", files: [])
        try inbox.markTaskDelivered(taskId: task.id, sessionId: claudeSession.id)

        coordinator.terminals.sendInput(sessionId: claudeSession.id, text: "Rate limit reached\n")
        let outputReady = try await waitUntil {
            coordinator.terminals.session(id: claudeSession.id)?.recentOutput(lines: 10).contains("Rate limit reached") ?? false
        }
        XCTAssertTrue(outputReady)

        XCTAssertTrue(coordinator.checkLimitsAndReroute(for: claudeSession.id))
        let copy = try XCTUnwrap(inbox.openTasks().first { $0.hop == 1 })
        XCTAssertEqual(copy.toAgent, .grok)
    }
```

Grok is now a peer with a model for every tier, so four existing tests that rule out every peer by name must rule out Grok too, or they stop testing what they say:

- `AppCoordinatorRelayTests.testATieredTaskWithNoCapablePeerIsLeftAloneOnReroute` and `testASessionClearsErrorOnceItsCooldownEndsWithoutAFocusClick`: after `models.setModel("", for: .agy, tier: .light)`, add `models.setModel("", for: .grok, tier: .light)`.
- `AppCoordinatorRelayTests.testACooldownIsNotReArmedOnEveryTick`: after `models.setModel("", for: .cursor, tier: .standard)`, add `models.setModel("", for: .grok, tier: .standard)`.
- `MCPServerTests.testDelegateTaskAllPeersLimitedReportsNone`: after the Cursor `recordLimit`, add `try inboxStore.recordLimit(agent: .grok, reason: "Usage cap", cooldown: 600)`.

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --filter "LinkCKitTests.(AgentDescriptorTests|MCPServerTaskTests|MCPServerModelTests|AppCoordinatorRelayTests|MCPServerTests)"`
Expected: the eight new tests fail — `peers` does not exist yet (compile error), and once it does, the lists and descriptions lack Grok and the reroute finds no candidate.

- [ ] **Step 3: Implement**

`Sources/LinkCKit/Core/AgentKind.swift` — inside `enum AgentKind`, after `workerEnvironmentKey`:

```swift
    /// Every agent that can take a task: all but a plain shell, in declaration order.
    public static var peers: [AgentKind] { allCases.filter { $0 != .shell } }

    /// `peers` as text, for tool descriptions and errors: "claude, agy, cursor, codex, grok".
    public static var peerList: String { peers.map(\.rawValue).joined(separator: ", ") }
```

`Sources/LinkCKit/MCP/MCPServer.swift`:

```swift
    public static let unidentifiedCallerMessage =
        "Cannot identify calling agent; pass agent: \"claude\" | \"agy\" | \"cursor\" | \"codex\" | \"grok\"."
```

- `linkc_broadcast_intent` `agent`: `"Agent kind (\(AgentKind.allCases.map(\.rawValue).joined(separator: ", ")))"`
- `linkc_delegate_task` description: `"Delegate a coding task, subtask, or follow-up prompt to a peer agent (e.g. \(AgentKind.peerList)), claiming files and enqueuing the prompt for delivery."`
- `linkc_delegate_task` and `linkc_send_message` `to`: `"Target agent kind (\(AgentKind.peerList))"`
- `linkc_switch_model` `agent`: `"Agent kind (\(AgentKind.peerList)), defaults to claude"`
- `linkc_get_models` `agent`: `"Agent kind (\(AgentKind.peerList)), optional"`
- Each of the four `"Error: Unknown agent '…'. Supported agents: claude, agy, cursor, codex."` texts (delegate, send_message, switch_model, get_models): `Supported agents: \(AgentKind.peerList).`
- The shell refusal: `"Error: Cannot delegate tasks to interactive terminal shell. Target an AI CLI agent (\(AgentKind.peerList))."`
- `let peerCandidates: [AgentKind] = AgentKind.peers.filter { $0 != toAgent }`
- `targetAgents = [.claude, .codex, .agy, .cursor, .grok]`
- `for agent in [AgentKind.codex, .claude, .agy, .cursor, .grok] {`
- In `defaultUsageReaders()`, after the Cursor entry:

```swift
            .cursor: { .unavailable(.cursor, reason: "cursor writes no local session records") },
            .grok: { .unavailable(.grok, reason: "Grok runs on the Cursor plan, which writes no local session records") }
```

`Sources/LinkCKit/App/AppCoordinator+Relay.swift:953`:

```swift
        let supportedPeers: [AgentKind] = [.claude, .codex, .agy, .cursor, .grok]
```

`Sources/linkc/PanelView.swift` — in `LauncherMenu`, add a Grok entry after each Cursor entry:

```swift
                Button("New Cursor Agent session…") { model.newSession(agent: .cursor, mode: .new) }
                Button("New Grok session…") { model.newSession(agent: .grok, mode: .new) }
```

```swift
                Button("Cursor Agent") { model.newSession(agent: .cursor, mode: .continueLast) }
                Button("Grok") { model.newSession(agent: .grok, mode: .continueLast) }
```

```swift
                Button("Cursor Agent") { model.newSession(agent: .cursor, mode: .resume) }
                Button("Grok") { model.newSession(agent: .grok, mode: .resume) }
```

Doc comments that list the agents:

- `Sources/LinkCKit/App/WorkspaceManifest.swift:16`: `(e.g. claude, agy, cursor, codex)` → `(e.g. claude, agy, cursor, codex, grok)`
- `Sources/linkc/AgentPill.swift:4`: `(CLAUDE, AGY, CURSOR, CODEX, SHELL)` → `(CLAUDE, AGY, CURSOR, CODEX, GROK, SHELL)`

Then confirm no agent list was missed:

Run: `grep -rn -E "claude, agy, cursor, codex[^,]|claude, codex, agy, cursor|cursor, codex, shell|\.agy, \.cursor\]|\.cursor, \.codex\]|\.cursor\]" Sources`
Expected: no output.

- [ ] **Step 4: Run the tests**

Run: `swift build && swift test`
Expected: the whole suite passes.

- [ ] **Step 5: Commit**

```bash
git add Sources/LinkCKit/Core/AgentKind.swift Sources/LinkCKit/MCP/MCPServer.swift Sources/LinkCKit/App/AppCoordinator+Relay.swift Sources/LinkCKit/App/WorkspaceManifest.swift Sources/linkc/AgentPill.swift Sources/linkc/PanelView.swift Tests/LinkCKitTests/AgentDescriptorTests.swift Tests/LinkCKitTests/MCPServerTaskTests.swift Tests/LinkCKitTests/MCPServerModelTests.swift Tests/LinkCKitTests/AppCoordinatorRelayTests.swift
git commit -m "feat(grok): Grok is offered wherever linkC lists its agents"
```

---

## After the last task

- `./scripts/tsan.sh` — clean (the one documented SwiftTerm suppression only).
- `./scripts/check-commits.sh origin/main..HEAD` — clean.
- Manual checks, once the user has updated linkC and reconnected linkC's tools in CLI sessions started outside linkC (spec §6):
  - Start a Grok session from the panel menu: the pill reads GROK and stays GROK.
  - Delegate one small task to `grok`; it completes through `linkc_complete_task`, attributed to Grok.
  - `~/.cursor/cli-config.json` still has the user's own default model, and the Grok chat sits under `~/.cursor-grok/chats`.

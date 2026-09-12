# Per-Task Model Selection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A delegated task runs on a model chosen for that task — a tier — instead of whatever model its agent session happened to launch with.

**Architecture:** Three tiers (`light`, `standard`, `deep`) map to a real model id per agent kind. The mapping lives in `<Application Support>/linkC/models.json` because two processes need it: the app, which launches sessions pinned with `--model`, and the `linkc-mcp` server, which refuses a delegation whose tier has no model. Sessions are pinned at launch and never switched; the relay routes a task only to a session whose tier matches, spawning a pinned one when none exists.

**Tech Stack:** Swift 6 (strict concurrency, `swiftLanguageMode(.v6)`), SwiftPM, XCTest, SwiftUI for the settings row. No new dependencies.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-09-11-per-task-model-selection-design.md`. Where this plan and the spec disagree, ask — do not guess.
- Tiers are exactly `light`, `standard`, `deep`. Delegation never names a raw model id.
- Seeded mapping, verbatim: claude `light: haiku`, `standard: sonnet`, `deep: opus`; codex `light: gpt-6-luna`, `standard: gpt-6-sol`, `deep: gpt-6-astra`; agy `light: flash_lite`, `standard: flash`, `deep: pro`. Default tier for every agent: `standard`. Cursor has no mapping.
- Refusal texts, verbatim: `tier must be light, standard or deep`; `no model configured for <agent> tier <tier> — set it in linkC settings`; `cursor cannot be pinned to a model`.
- `TaskRecord.tier` is `ModelTier?`, never required. `loadUnlocked` throws on a decode error, so a required field would make pre-existing task rows unreadable and take the inbox with them.
- A model id that maps to two tiers resolves to the lighter one, scanning `light`, then `standard`, then `deep`.
- No silent fallback anywhere: a task that cannot be placed on its tier stays queued and logs why. Never "use the session that exists".
- Nothing injects `/model` as part of delivering a task. Sessions are pinned at launch.
- Every task ends with `swift test` green (708 tests pass today) and a commit. Never mention Claude in a commit message and never add attribution trailers.

## File Structure

| File | Responsibility |
|---|---|
| `Sources/LinkCKit/Core/AgentModelSettings.swift` (new) | `ModelTier` and `AgentModelSettings`: the mapping, the seeded defaults, and every resolution rule. Pure value types, no I/O. |
| `Sources/LinkCKit/Config/AgentModelStore.swift` (new) | Reads and writes `models.json` in Application Support. The only I/O for the mapping, shared by the app and the MCP process. |
| `Sources/LinkCKit/Preferences/AppPreferences.swift` | Holds the live `AgentModelSettings` for the UI and persists edits through the store. |
| `Sources/LinkCKit/Blackboard/InboxModels.swift` | `TaskRecord.tier`. |
| `Sources/LinkCKit/Blackboard/InboxStore.swift` | `createTask(tier:)`. |
| `Sources/LinkCKit/MCP/MCPServer.swift` | The `tier` argument, the three refusals, and `linkc_get_models` reporting the configured mapping. |
| `Sources/LinkCKit/Core/Domain.swift`, `Core/SessionStore.swift` | `Session.model` and `Session.modelTier`. |
| `Sources/LinkCKit/App/AppCoordinator.swift` | Launch pinning (`--model`) and the tier a spawn is for. |
| `Sources/LinkCKit/App/AppCoordinator+Relay.swift` | Tier-matched routing, the legacy no-tier path, and reroute keeping the tier. |
| `Sources/linkc/Screens/SettingsScreen.swift` | The MODELS section: three model fields and a default-tier picker per agent. |

---

### Task 1: Tiers and the mapping type

**Files:**
- Create: `Sources/LinkCKit/Core/AgentModelSettings.swift`
- Test: `Tests/LinkCKitTests/AgentModelSettingsTests.swift` (new)

**Interfaces:**
- Consumes: `AgentKind` from `Sources/LinkCKit/Core/AgentKind.swift` (cases `.claude`, `.agy`, `.cursor`, `.codex`, `.shell`; `rawValue` is the lowercased name).
- Produces: `ModelTier` (`.light`, `.standard`, `.deep`); `AgentModelSettings.seeded`; `model(for:tier:) -> String?`; `defaultTier(for:) -> ModelTier`; `tier(forModel:agent:) -> ModelTier?`; `setModel(_:for:tier:)`; `setDefaultTier(_:for:)`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LinkCKit

final class AgentModelSettingsTests: XCTestCase {
    func testSeededMappingMatchesTheSpec() {
        let s = AgentModelSettings.seeded
        XCTAssertEqual(s.model(for: .claude, tier: .light), "haiku")
        XCTAssertEqual(s.model(for: .claude, tier: .standard), "sonnet")
        XCTAssertEqual(s.model(for: .claude, tier: .deep), "opus")
        XCTAssertEqual(s.model(for: .codex, tier: .light), "gpt-6-luna")
        XCTAssertEqual(s.model(for: .codex, tier: .standard), "gpt-6-sol")
        XCTAssertEqual(s.model(for: .codex, tier: .deep), "gpt-6-astra")
        XCTAssertEqual(s.model(for: .agy, tier: .light), "flash_lite")
        XCTAssertEqual(s.model(for: .agy, tier: .deep), "pro")
        XCTAssertEqual(s.defaultTier(for: .codex), .standard)
    }

    func testCursorAndShellHaveNoMapping() {
        let s = AgentModelSettings.seeded
        XCTAssertNil(s.model(for: .cursor, tier: .standard))
        XCTAssertNil(s.model(for: .shell, tier: .standard))
    }

    func testAnEditedModelIsReadBackAndSurvivesARoundTrip() throws {
        var s = AgentModelSettings.seeded
        s.setModel("gpt-7-nova", for: .codex, tier: .deep)
        s.setDefaultTier(.light, for: .codex)
        let decoded = try JSONDecoder().decode(AgentModelSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(decoded.model(for: .codex, tier: .deep), "gpt-7-nova")
        XCTAssertEqual(decoded.defaultTier(for: .codex), .light)
    }

    func testTierForModelPrefersTheLighterTierWhenTwoShareAnId() {
        var s = AgentModelSettings.seeded
        s.setModel("sonnet", for: .claude, tier: .light)
        XCTAssertEqual(s.tier(forModel: "sonnet", agent: .claude), .light)
        XCTAssertEqual(s.tier(forModel: "opus", agent: .claude), .deep)
        XCTAssertNil(s.tier(forModel: "something-nobody-configured", agent: .claude))
    }

    func testAnAgentWithNoConfiguredDefaultFallsBackToStandard() {
        var s = AgentModelSettings(models: [:], defaultTiers: [:])
        XCTAssertEqual(s.defaultTier(for: .claude), .standard)
        s.setDefaultTier(.deep, for: .claude)
        XCTAssertEqual(s.defaultTier(for: .claude), .deep)
    }
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `swift test --filter AgentModelSettingsTests`
Expected: FAIL — `cannot find 'AgentModelSettings' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// What a delegated task asks for. Delegation speaks only in tiers: providers rename models
/// constantly, and a rate-limit reroute moves a task to another agent kind, where a literal
/// model id would mean nothing.
public enum ModelTier: String, Codable, Sendable, CaseIterable, Equatable {
    case light, standard, deep

    /// Light first: `tier(forModel:agent:)` resolves an id shared by two tiers to the cheaper one.
    public static let resolutionOrder: [ModelTier] = [.light, .standard, .deep]

    public var label: String {
        switch self {
        case .light: return "Light"
        case .standard: return "Standard"
        case .deep: return "Deep"
        }
    }
}

/// The tier → model id mapping, keyed by `AgentKind.rawValue` so the JSON on disk reads plainly
/// and an unknown agent in an edited file is ignored rather than fatal.
public struct AgentModelSettings: Codable, Sendable, Equatable {
    public private(set) var models: [String: [String: String]]
    public private(set) var defaultTiers: [String: String]

    public init(models: [String: [String: String]], defaultTiers: [String: String]) {
        self.models = models
        self.defaultTiers = defaultTiers
    }

    /// Today's models. `gpt-6-astra` is verified from `~/.codex/config.toml`; `gpt-6-sol` and
    /// `gpt-6-luna` follow the same pattern and are editable in settings if a provider differs.
    public static let seeded = AgentModelSettings(
        models: [
            AgentKind.claude.rawValue: ["light": "haiku", "standard": "sonnet", "deep": "opus"],
            AgentKind.codex.rawValue: ["light": "gpt-6-luna", "standard": "gpt-6-sol", "deep": "gpt-6-astra"],
            AgentKind.agy.rawValue: ["light": "flash_lite", "standard": "flash", "deep": "pro"]
        ],
        defaultTiers: [
            AgentKind.claude.rawValue: ModelTier.standard.rawValue,
            AgentKind.codex.rawValue: ModelTier.standard.rawValue,
            AgentKind.agy.rawValue: ModelTier.standard.rawValue
        ]
    )

    /// The model id to launch, or nil when this agent has no model for this tier — the caller
    /// refuses rather than substituting one.
    public func model(for agent: AgentKind, tier: ModelTier) -> String? {
        guard let id = models[agent.rawValue]?[tier.rawValue] else { return nil }
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func defaultTier(for agent: AgentKind) -> ModelTier {
        defaultTiers[agent.rawValue].flatMap(ModelTier.init(rawValue:)) ?? .standard
    }

    /// Which tier a running model belongs to, for a session whose model was switched by hand.
    public func tier(forModel model: String, agent: AgentKind) -> ModelTier? {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return ModelTier.resolutionOrder.first {
            self.model(for: agent, tier: $0)?.caseInsensitiveCompare(trimmed) == .orderedSame
        }
    }

    public mutating func setModel(_ id: String, for agent: AgentKind, tier: ModelTier) {
        models[agent.rawValue, default: [:]][tier.rawValue] = id.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public mutating func setDefaultTier(_ tier: ModelTier, for agent: AgentKind) {
        defaultTiers[agent.rawValue] = tier.rawValue
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter AgentModelSettingsTests`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/LinkCKit/Core/AgentModelSettings.swift Tests/LinkCKitTests/AgentModelSettingsTests.swift
git commit -m "feat(models): add model tiers and the per-agent mapping type"
```

---

### Task 2: The mapping on disk, and preferences

**Files:**
- Create: `Sources/LinkCKit/Config/AgentModelStore.swift`
- Modify: `Sources/LinkCKit/Preferences/AppPreferences.swift`
- Test: `Tests/LinkCKitTests/AgentModelStoreTests.swift` (new), `Tests/LinkCKitTests/AppPreferencesTests.swift`

**Interfaces:**
- Consumes: `AgentModelSettings`, `ModelTier` from Task 1.
- Produces: `AgentModelStore(directory: URL)` with `load() -> AgentModelSettings`, `save(_:)`, `path: String`, and `static var applicationSupport: AgentModelStore`; `AppPreferences.agentModels` (settable, persists on write); `AppPreferences.init(defaults:modelStore:)`.

**Why a file and not UserDefaults:** `linkc-mcp` runs as its own process with its own defaults domain, and it needs this mapping to refuse a delegation. `endpoints.json` in the same directory is the pattern to copy.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LinkCKit

final class AgentModelStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-models-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testMissingFileLoadsTheSeededMapping() {
        XCTAssertEqual(AgentModelStore(directory: dir).load(), AgentModelSettings.seeded)
    }

    func testSavedEditsAreReadBack() throws {
        let store = AgentModelStore(directory: dir)
        var settings = AgentModelSettings.seeded
        settings.setModel("gpt-7-nova", for: .codex, tier: .deep)
        store.save(settings)
        XCTAssertEqual(AgentModelStore(directory: dir).load().model(for: .codex, tier: .deep), "gpt-7-nova")
    }

    func testAnUnreadableFileLoadsTheSeededMappingAndKeepsTheBadFile() throws {
        let store = AgentModelStore(directory: dir)
        try "{ not json".write(toFile: store.path, atomically: true, encoding: .utf8)
        XCTAssertEqual(store.load(), AgentModelSettings.seeded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.path), "A corrupt file is never deleted under the user")
    }
}
```

Add to `Tests/LinkCKitTests/AppPreferencesTests.swift`:

```swift
    func testAgentModelsDefaultToTheSeededMappingAndPersistEdits() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-prefs-models-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AgentModelStore(directory: dir)

        let prefs = AppPreferences(defaults: defaults, modelStore: store)
        XCTAssertEqual(prefs.agentModels.model(for: .codex, tier: .standard), "gpt-6-sol")

        var edited = prefs.agentModels
        edited.setModel("gpt-7-nova", for: .codex, tier: .standard)
        prefs.agentModels = edited

        let reloaded = AppPreferences(defaults: defaults, modelStore: store)
        XCTAssertEqual(reloaded.agentModels.model(for: .codex, tier: .standard), "gpt-7-nova")
    }
```

- [ ] **Step 2: Run them and watch them fail**

Run: `swift test --filter "AgentModelStoreTests|AppPreferencesTests"`
Expected: FAIL — `cannot find 'AgentModelStore' in scope`.

- [ ] **Step 3: Write the store**

```swift
import Foundation

/// `<Application Support>/linkC/models.json`: which model each tier launches, per agent.
/// ```json
/// {"models":{"codex":{"light":"gpt-6-luna","standard":"gpt-6-sol","deep":"gpt-6-astra"}},
///  "defaultTiers":{"codex":"standard"}}
/// ```
/// Two processes read this: the app, to launch a session with `--model`, and `linkc-mcp`, to
/// refuse a delegation whose tier has no model. A missing file means "nothing configured yet"
/// and loads the seeded mapping; an unreadable one is logged and left alone, never rewritten
/// under the user.
public struct AgentModelStore: Sendable {
    private let fileURL: URL

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("models.json", isDirectory: false)
    }

    /// The same directory the rest of linkC's own files live in.
    public static var applicationSupport: AgentModelStore {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("linkC", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return AgentModelStore(directory: dir)
    }

    public var path: String { fileURL.path }

    public func load() -> AgentModelSettings {
        guard let data = try? Data(contentsOf: fileURL) else { return .seeded }
        guard let decoded = try? JSONDecoder().decode(AgentModelSettings.self, from: data) else {
            NSLog("linkC: models.json at %@ is unreadable, using the seeded mapping", fileURL.path)
            return .seeded
        }
        return decoded
    }

    public func save(_ settings: AgentModelSettings) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(settings).write(to: fileURL, options: .atomic)
        } catch {
            // Loud: a silently dropped edit looks exactly like a setting that did not take.
            NSLog("linkC: could not write models.json at %@ — %@", fileURL.path, String(describing: error))
        }
    }
}
```

- [ ] **Step 4: Wire it into preferences**

In `Sources/LinkCKit/Preferences/AppPreferences.swift`, add the stored property beside `showsUsageFooter` and extend the initializer:

```swift
    /// Tier → model per agent. Backed by `models.json`, not UserDefaults: `linkc-mcp` is a
    /// separate process with its own defaults domain and needs to read the same mapping.
    public var agentModels: AgentModelSettings {
        didSet { modelStore.save(agentModels) }
    }

    private let defaults: UserDefaults
    private let modelStore: AgentModelStore

    public init(defaults: UserDefaults = .standard, modelStore: AgentModelStore = .applicationSupport) {
        self.defaults = defaults
        self.modelStore = modelStore
        self.hotKeyPreset = defaults.string(forKey: Keys.hotKey)
            .flatMap(HotKeyPreset.init(rawValue:)) ?? .none
        self.showsUsageFooter = defaults.object(forKey: Keys.usageFooter) as? Bool ?? true
        self.agentModels = modelStore.load()
    }
```

- [ ] **Step 5: Run the tests**

Run: `swift test --filter "AgentModelStoreTests|AppPreferencesTests"`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/LinkCKit/Config/AgentModelStore.swift Sources/LinkCKit/Preferences/AppPreferences.swift Tests/LinkCKitTests/AgentModelStoreTests.swift Tests/LinkCKitTests/AppPreferencesTests.swift
git commit -m "feat(models): store the tier mapping in models.json and read it from preferences"
```

---

### Task 3: A tier on the task record

**Files:**
- Modify: `Sources/LinkCKit/Blackboard/InboxModels.swift`, `Sources/LinkCKit/Blackboard/InboxStore.swift`
- Test: `Tests/LinkCKitTests/InboxTaskLifecycleTests.swift`

**Interfaces:**
- Consumes: `ModelTier` from Task 1.
- Produces: `TaskRecord.tier: ModelTier?`; `TaskRecord.init(..., tier: ModelTier? = nil, ...)`; `InboxStore.createTask(from:to:fromSessionId:tier:prompt:files:hop:force:verification:gate:timeout:)`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/LinkCKitTests/InboxTaskLifecycleTests.swift`:

```swift
    func testCreateTaskRecordsTheTier() throws {
        let task = try store.createTask(from: .claude, to: .codex, tier: .light, prompt: "Rename a file", files: [])
        XCTAssertEqual(try store.task(id: task.id)?.tier, .light)
    }

    func testATaskRowWrittenBeforeTiersStillDecodes() throws {
        // A pre-tier row: every field the old binary wrote, and no `tier`. The inbox must load it,
        // because `loadUnlocked` throws on a decode error and would take the whole file down.
        // The store keeps its file at `<workspace>/.linkc/inbox.json`.
        let linkcDir = tempDir.appendingPathComponent(".linkc", isDirectory: true)
        try FileManager.default.createDirectory(at: linkcDir, withIntermediateDirectories: true)
        let json = """
        {"version":2,"workspacePath":"\(tempDir.path)","updatedAt":0,"messages":[],"agentLimits":[],
         "tasks":[{"id":"11111111-2222-3333-4444-555555555555","fromAgent":"claude","toAgent":"codex",
         "prompt":"Legacy","files":[],"state":"queued","hop":0,"createdAt":0,"leaseExpiresAt":99999999999,
         "unreportedTurnEndNotified":false}]}
        """
        try json.write(to: linkcDir.appendingPathComponent("inbox.json"), atomically: true, encoding: .utf8)
        let loaded = try XCTUnwrap(try store.task(id: "11111111-2222-3333-4444-555555555555"))
        XCTAssertNil(loaded.tier, "A pre-tier row has no tier, and that is not an error")
        XCTAssertEqual(loaded.state, .queued)
    }
```

- [ ] **Step 2: Run them and watch them fail**

Run: `swift test --filter InboxTaskLifecycleTests`
Expected: FAIL — `extra argument 'tier' in call` and `value of type 'TaskRecord' has no member 'tier'`.

- [ ] **Step 3: Add the field**

In `Sources/LinkCKit/Blackboard/InboxModels.swift`, beside `fromSessionId`:

```swift
    /// Which model tier this task runs on. Optional for one reason: `loadUnlocked` throws on a
    /// decode error, so a required field would make every task row written before tiers existed
    /// unreadable and take the inbox with it. `nil` means "written before tiers" and keeps the
    /// pre-tier routing; every task created from here on carries one.
    public let tier: ModelTier?
```

Add `tier: ModelTier? = nil,` to `init` after `fromSessionId`, and `self.tier = tier` beside `self.fromSessionId = fromSessionId`.

In `Sources/LinkCKit/Blackboard/InboxStore.swift`, add `tier: ModelTier? = nil,` to `createTask` after `fromSessionId`, and pass it through:

```swift
            let task = TaskRecord(
                fromAgent: from, fromSessionId: fromSessionId, tier: tier, toAgent: to,
                prompt: prompt, files: normalized,
                state: verification == nil || gate != nil ? .queued : .gating, hop: hop,
                verification: verification, gate: gate
            )
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter InboxTaskLifecycleTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LinkCKit/Blackboard/InboxModels.swift Sources/LinkCKit/Blackboard/InboxStore.swift Tests/LinkCKitTests/InboxTaskLifecycleTests.swift
git commit -m "feat(models): record a tier on every task"
```

---

### Task 4: Delegation takes a tier, and refuses loudly

**Files:**
- Modify: `Sources/LinkCKit/MCP/MCPServer.swift` (tool schema near line 164; `linkc_delegate_task` handler near line 437; `linkc_get_models` handler near line 581)
- Test: `Tests/LinkCKitTests/MCPServerTaskTests.swift`

**Interfaces:**
- Consumes: `AgentModelSettings`, `AgentModelStore` (Task 2), `ModelTier` (Task 1), `InboxStore.createTask(tier:)` (Task 3).
- Produces: `MCPServer.init(..., modelSettings: AgentModelSettings = AgentModelStore.applicationSupport.load())`; a `tier` argument on `linkc_delegate_task`.

The server reads the mapping once at construction. Tests inject it directly instead of touching Application Support.

- [ ] **Step 1: Write the failing test**

Append to `Tests/LinkCKitTests/MCPServerTaskTests.swift`:

```swift
    private func server(as agent: AgentKind, models: AgentModelSettings) -> MCPServer {
        MCPServer(workspaceRoot: tempDir.path,
                  environment: ["LINKC_AGENT": agent.rawValue],
                  ancestorResolver: { _ in nil },
                  modelSettings: models)
    }

    func testDelegateAppliesTheAgentDefaultTierWhenNoneIsGiven() throws {
        let res = try call(server(as: .claude, models: .seeded), "linkc_delegate_task",
                           ["to": "codex", "prompt": "Rename a file"])
        XCTAssertFalse(res.isError, res.text)
        let task = try XCTUnwrap(inbox.openTasks().first)
        XCTAssertEqual(task.tier, .standard)
    }

    func testDelegateRecordsAnExplicitTier() throws {
        let res = try call(server(as: .claude, models: .seeded), "linkc_delegate_task",
                           ["to": "codex", "prompt": "Rename a file", "tier": "light"])
        XCTAssertFalse(res.isError, res.text)
        XCTAssertEqual(try XCTUnwrap(inbox.openTasks().first).tier, .light)
    }

    func testDelegateRefusesAnUnknownTier() throws {
        let res = try call(server(as: .claude, models: .seeded), "linkc_delegate_task",
                           ["to": "codex", "prompt": "Rename a file", "tier": "cheapest"])
        XCTAssertTrue(res.isError)
        XCTAssertTrue(res.text.contains("tier must be light, standard or deep"), res.text)
        XCTAssertTrue(inbox.openTasks().isEmpty, "A refused delegation creates no task")
    }

    func testDelegateRefusesATierWithNoModelConfigured() throws {
        var models = AgentModelSettings.seeded
        models.setModel("", for: .codex, tier: .light)
        let res = try call(server(as: .claude, models: models), "linkc_delegate_task",
                           ["to": "codex", "prompt": "Rename a file", "tier": "light"])
        XCTAssertTrue(res.isError)
        XCTAssertTrue(res.text.contains("no model configured for codex tier light — set it in linkC settings"), res.text)
        XCTAssertTrue(inbox.openTasks().isEmpty)
    }

    func testDelegateRefusesATieredTaskForCursor() throws {
        let res = try call(server(as: .claude, models: .seeded), "linkc_delegate_task",
                           ["to": "cursor", "prompt": "Rename a file", "tier": "light"])
        XCTAssertTrue(res.isError)
        XCTAssertTrue(res.text.contains("cursor cannot be pinned to a model"), res.text)
        XCTAssertTrue(inbox.openTasks().isEmpty)
    }

    func testGetModelsReportsTheConfiguredMapping() throws {
        var models = AgentModelSettings.seeded
        models.setModel("gpt-7-nova", for: .codex, tier: .deep)
        let res = try call(server(as: .claude, models: models), "linkc_get_models", ["agent": "codex"])
        XCTAssertFalse(res.isError, res.text)
        XCTAssertTrue(res.text.contains("gpt-7-nova"), res.text)
        XCTAssertTrue(res.text.contains("deep"), res.text)
    }
```

- [ ] **Step 2: Run them and watch them fail**

Run: `swift test --filter MCPServerTaskTests`
Expected: FAIL — `extra argument 'modelSettings' in call`.

- [ ] **Step 3: Take the settings in the initializer**

Add the stored property and parameter in `MCPServer`:

```swift
    public let modelSettings: AgentModelSettings
```

```swift
        ancestorResolver: @escaping AncestorResolver = { ProcessSnooper.detectAgent(inAncestorsOf: $0) },
        modelSettings: AgentModelSettings = AgentModelStore.applicationSupport.load()
    ) {
```

and `self.modelSettings = modelSettings` in the body.

- [ ] **Step 4: Advertise the argument**

In the `linkc_delegate_task` schema, beside `"force"`:

```swift
                        "tier": ["type": "string", "description": "Model tier for this task: light, standard or deep. Defaults to the agent's configured default tier."],
```

- [ ] **Step 5: Resolve and refuse in the handler**

Immediately before the `let task: TaskRecord` block in `linkc_delegate_task`:

```swift
                let tier: ModelTier
                if let raw = (args["tier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
                    guard let parsed = ModelTier(rawValue: raw.lowercased()) else {
                        return toolResultResponse(id: id, text: "Error: tier must be light, standard or deep.", isError: true)
                    }
                    tier = parsed
                } else {
                    tier = modelSettings.defaultTier(for: toAgent)
                }
                guard toAgent != .cursor else {
                    return toolResultResponse(id: id, text: "Error: cursor cannot be pinned to a model.", isError: true)
                }
                guard modelSettings.model(for: toAgent, tier: tier) != nil else {
                    return toolResultResponse(
                        id: id,
                        text: "Error: no model configured for \(toAgent.rawValue) tier \(tier.rawValue) — set it in linkC settings.",
                        isError: true)
                }
```

and pass `tier: tier` to `createTask`.

- [ ] **Step 6: Report the mapping instead of the stale whitelist**

Replace the body of `linkc_get_models` that lists `AgentModelCatalog.models(for:)` with the configured mapping:

```swift
                var text = "# Configured Models by Tier\n\n"
                for agent in targetAgents {
                    text += "## \(agent.displayName)\n"
                    if agent == .cursor {
                        text += "- cursor cannot be pinned to a model\n\n"
                        continue
                    }
                    for tier in ModelTier.resolutionOrder {
                        let id = modelSettings.model(for: agent, tier: tier) ?? "(not set)"
                        let marker = tier == modelSettings.defaultTier(for: agent) ? " — default" : ""
                        text += "- **\(tier.rawValue)**: \(id)\(marker)\n"
                    }
                    text += "\n"
                }
                text += "Edit these in linkC settings under MODELS.\n"
```

- [ ] **Step 7: Run the tests**

Run: `swift test --filter MCPServerTaskTests`
Expected: PASS. Existing tests in that file must stay green.

- [ ] **Step 8: Commit**

```bash
git add Sources/LinkCKit/MCP/MCPServer.swift Tests/LinkCKitTests/MCPServerTaskTests.swift
git commit -m "feat(models): delegate a task on a tier, refusing anything it cannot place"
```

---

### Task 5: Sessions launch pinned to a model

**Files:**
- Modify: `Sources/LinkCKit/Core/Domain.swift` (`Session`), `Sources/LinkCKit/Core/SessionStore.swift` (`create`), `Sources/LinkCKit/App/AppCoordinator.swift` (`spawnTeammate`, `newSession`, `launch`)
- Test: `Tests/LinkCKitTests/AppCoordinatorIntegrationTests.swift`

**Interfaces:**
- Consumes: `ModelTier`, `AgentModelSettings` (Tasks 1–2).
- Produces: `Session.model: String?`, `Session.modelTier: ModelTier?`; `SessionStore.create(cwd:title:id:agentKind:model:modelTier:)`; `AppCoordinator.spawnTeammate(in:agent:goal:tier:)`; `AppCoordinator.newSession(cwd:agent:mode:tier:)`; `AppCoordinator.init(..., modelSettings:)`.

A pinned session keeps its model for life. Nothing in the delivery path ever switches it.

**How the coordinator sees the mapping:** `AppCoordinator` holds no `AppPreferences` — that type
lives in the app layer (`Sources/linkc/LinkCApp.swift:124`). Add a closure parameter to
`AppCoordinator.init`, after `verifier`:

```swift
        modelSettings: @escaping @MainActor @Sendable () -> AgentModelSettings = { AgentModelStore.applicationSupport.load() },
```

stored as `private let modelSettings: @MainActor @Sendable () -> AgentModelSettings`. It is a closure,
not a value, so a settings edit is seen on the next spawn without anyone re-injecting anything. In
`Sources/linkc/LinkCApp.swift`, pass `modelSettings: { preferences.agentModels }` where the
coordinator is constructed. In tests, add a parameter to the file's existing private
`makeCoordinator` helper:

```swift
    @MainActor
    private func makeCoordinator(
        sink: NotificationSink = RecordingSink(),
        verifier: any TaskVerifier = VerificationRunner(),
        models: AgentModelSettings = .seeded
    ) -> AppCoordinator {
```

and forward `modelSettings: { models }` to `AppCoordinator(...)`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/LinkCKitTests/AppCoordinatorIntegrationTests.swift`:

```swift
    @MainActor
    func testSpawningForATierPinsTheSessionToThatModel() throws {
        let coordinator = makeCoordinator(models: .seeded)
        defer { coordinator.shutdown() }

        let session = try coordinator.newSession(cwd: tempDir.path, agent: .codex, mode: .new, tier: .light)

        XCTAssertEqual(session.modelTier, .light)
        XCTAssertEqual(session.model, "gpt-6-luna")
    }

    @MainActor
    func testASessionSpawnedWithNoTierIsNotPinned() throws {
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }

        let session = try coordinator.newSession(cwd: tempDir.path, agent: .codex, mode: .new)

        XCTAssertNil(session.modelTier)
        XCTAssertNil(session.model)
    }
```

`AppCoordinatorIntegrationTests` has its own private `makeCoordinator` helper; give it the same
`models: AgentModelSettings = .seeded` parameter described above and forward `modelSettings: { models }`.

- [ ] **Step 2: Run them and watch them fail**

Run: `swift test --filter AppCoordinatorIntegrationTests`
Expected: FAIL — `extra argument 'tier' in call`.

- [ ] **Step 3: Carry the model on the session**

In `Sources/LinkCKit/Core/Domain.swift`, add to `Session` beside `agentKind`:

```swift
    /// The model this session was launched with, and the tier it was launched for. Set once at
    /// launch: a pinned session is never switched out from under the person using it, so the
    /// relay can trust this when it picks an assignee.
    public var model: String?
    public var modelTier: ModelTier?
```

Add `model: String? = nil, modelTier: ModelTier? = nil` to the initializer and assign both.

In `Sources/LinkCKit/Core/SessionStore.swift`:

```swift
    public func create(cwd: String, title: String, id: String = UUID().uuidString, agentKind: AgentKind = .claude,
                       model: String? = nil, modelTier: ModelTier? = nil) -> Session {
        let s = Session(id: id, cwd: cwd, title: title, agentKind: agentKind, model: model, modelTier: modelTier)
        sessions.append(s)
        return s
    }
```

- [ ] **Step 4: Pass `--model` at launch**

In `AppCoordinator.launch`, add `tier: ModelTier? = nil` to the signature, resolve the model, and record it:

```swift
        let model = tier.flatMap { modelSettings().model(for: agent, tier: $0) }
        let session = store.create(cwd: cwd, title: title, id: id ?? UUID().uuidString, agentKind: agent,
                                   model: model, modelTier: model == nil ? nil : tier)
```

Then append the flag to whichever argv branch runs:

```swift
            if agent == .claude {
                try? DirectoryTrustManager.preApproveTrust(workspacePath: cwd, claudeJsonURL: claudeJsonURL)
                executable = claudePath
                let settingsPath = try writeSettings(for: session)
                args = Self.claudeLaunchArgs(mode: mode, resumeId: resumeId, settingsPath: settingsPath)
                    + (model.map { AgentModelCatalog.launchArguments(model: $0, for: agent) } ?? [])
            } else {
                guard let resolved = agentPathResolver?(agent) ?? AgentDescriptor.resolveExecutable(for: agent) else {
                    throw LinkCError.process("Executable for \(agent.pillText) not found")
                }
                executable = resolved
                args = AgentDescriptor.arguments(for: agent, mode: mode)
                    + (model.map { AgentModelCatalog.launchArguments(model: $0, for: agent) } ?? [])
            }
```

Thread `tier` through the two callers: `newSession(cwd:agent:mode:tier:)` passes it to `launch`, and `spawnTeammate(in:agent:goal:tier:)` passes it to `newSession`. Both default to `nil`, so a restore or a hand-opened session stays unpinned.

- [ ] **Step 5: Run the tests**

Run: `swift test --filter AppCoordinatorIntegrationTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/LinkCKit/Core/Domain.swift Sources/LinkCKit/Core/SessionStore.swift Sources/LinkCKit/App/AppCoordinator.swift Tests/LinkCKitTests/AppCoordinatorIntegrationTests.swift
git commit -m "feat(models): pin a spawned session to its tier's model"
```

---

### Task 6: The relay routes by tier

**Files:**
- Modify: `Sources/LinkCKit/App/AppCoordinator+Relay.swift` (`dispatchTasks` candidate filter near line 137; `checkLimitsAndReroute` copy near line 486)
- Test: `Tests/LinkCKitTests/AppCoordinatorRelayTests.swift`

**Interfaces:**
- Consumes: `TaskRecord.tier` (Task 3), `Session.modelTier` (Task 5), `spawnTeammate(in:agent:goal:tier:)` (Task 5).
- Produces: no new API. Behaviour: a tiered task reaches only a session of that tier; a task with no tier keeps pre-tier routing; a reroute keeps the tier.

- [ ] **Step 1: Write the failing test**

Append to `Tests/LinkCKitTests/AppCoordinatorRelayTests.swift`:

```swift
    /// A tiered task only ever reaches a session pinned to that tier.
    @MainActor
    func testATieredTaskOnlyReachesASessionOfThatTier() async throws {
        let ws = tempDir.path
        let inbox = InboxStore(workspaceRoot: ws)
        let coordinator = makeCoordinator(models: .seeded)
        defer { coordinator.shutdown() }

        let deep = try coordinator.newSession(cwd: ws, agent: .codex, mode: .new, tier: .deep)
        coordinator.store.updateState(id: deep.id, to: .ready)
        let task = try inbox.createTask(from: .claude, to: .codex, tier: .light, prompt: "Rename a file", files: [])

        coordinator.processPendingMessages(workspacePath: ws)
        XCTAssertEqual(try inbox.task(id: task.id)?.state, .queued, "A deep session must not take a light task")

        let light = try coordinator.newSession(cwd: ws, agent: .codex, mode: .new, tier: .light)
        coordinator.store.updateState(id: light.id, to: .ready)
        coordinator.processPendingMessages(workspacePath: ws)

        let delivered = try XCTUnwrap(inbox.task(id: task.id))
        XCTAssertEqual(delivered.state, .delivered)
        XCTAssertEqual(delivered.assigneeSessionId, light.id)
    }

    /// An unpinned session is not a candidate for tiered work — it is running a model nobody asked for.
    @MainActor
    func testAnUnpinnedSessionNeverTakesATieredTask() async throws {
        let ws = tempDir.path
        let inbox = InboxStore(workspaceRoot: ws)
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }

        let unpinned = try coordinator.newSession(cwd: ws, agent: .codex, mode: .new)
        coordinator.store.updateState(id: unpinned.id, to: .ready)
        let task = try inbox.createTask(from: .claude, to: .codex, tier: .standard, prompt: "Rename a file", files: [])

        coordinator.processPendingMessages(workspacePath: ws)
        XCTAssertEqual(try inbox.task(id: task.id)?.state, .queued)
    }

    /// A row written before tiers keeps the old routing rather than stalling forever.
    @MainActor
    func testALegacyTaskWithNoTierStillReachesAnIdleSession() async throws {
        let ws = tempDir.path
        let inbox = InboxStore(workspaceRoot: ws)
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }

        let any = try coordinator.newSession(cwd: ws, agent: .codex, mode: .new)
        coordinator.store.updateState(id: any.id, to: .ready)
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "Legacy brief", files: [])
        XCTAssertNil(task.tier, "createTask without a tier records none")

        coordinator.processPendingMessages(workspacePath: ws)
        XCTAssertEqual(try inbox.task(id: task.id)?.assigneeSessionId, any.id)
    }
```

- [ ] **Step 2: Run them and watch them fail**

Run: `swift test --filter AppCoordinatorRelayTests`
Expected: FAIL — the light task is delivered to the deep session, and the unpinned session takes the tiered task.

- [ ] **Step 3: Add the tier clause**

In `dispatchTasks`, replace the candidate filter and the spawn with:

```swift
            let candidates = store.sessions.filter {
                ($0.cwd as NSString).standardizingPath == workspacePath && $0.agentKind == task.toAgent
                    && $0.state != .ended && $0.id != task.fromSessionId
                    // A tiered task runs only on a session pinned to that tier. A row written
                    // before tiers has none, and keeps the pre-tier rule: any session of its kind.
                    && (task.tier == nil || $0.modelTier == task.tier)
            }
            if candidates.isEmpty {
                // Spawn now, deliver on a later tick. A CLI needs seconds to reach its prompt, and a
                // frame typed into a booting TUI is lost — the worker never sees the task. The session
                // stays `.starting` until its agent is really running: Claude's SessionStart hook, or
                // `sampleAgentStates` for every other kind.
                _ = try? spawnTeammate(in: workspacePath, agent: task.toAgent, goal: task.prompt, tier: task.tier)
                continue
            }
```

- [ ] **Step 4: Keep the tier across a reroute**

In `checkLimitsAndReroute`, add `tier: currentTask.tier` to the hop copy:

```swift
                _ = try inboxStore.createTask(
                    from: currentTask.fromAgent, to: target, tier: currentTask.tier, prompt: currentTask.prompt,
                    files: currentTask.files, hop: hop + 1, force: true,
                    verification: currentTask.verification, gate: currentTask.gate
                )
```

The synthesized task in the `else` branch gets no tier: nobody asked for one, and inventing a tier there would pin a session on a guess.

- [ ] **Step 5: Write the reroute test**

```swift
    @MainActor
    func testARerouteKeepsTheTaskTier() async throws {
        let ws = tempDir.path
        let inbox = InboxStore(workspaceRoot: ws)
        let coordinator = makeCoordinator(models: .seeded)
        defer { coordinator.shutdown() }

        let session = try coordinator.newSession(cwd: ws, agent: .claude, mode: .new, tier: .light)
        coordinator.store.updateState(id: session.id, to: .working)
        let task = try inbox.createTask(from: .cursor, to: .claude, tier: .light, prompt: "Build a streaming proxy", files: [])
        try inbox.markTaskDelivered(taskId: task.id, sessionId: session.id)
        try inbox.markTaskStarted(taskId: task.id)

        coordinator.terminals.sendInput(sessionId: session.id, text: "Rate limit reached. Please try again later.\n")
        let outputReady = try await waitUntil {
            coordinator.terminals.session(id: session.id)?.recentOutput(lines: 10).contains("Rate limit reached") ?? false
        }
        XCTAssertTrue(outputReady)
        XCTAssertTrue(coordinator.checkLimitsAndReroute(for: session.id))

        let copy = try XCTUnwrap(inbox.openTasks().first { $0.hop == 1 })
        XCTAssertEqual(copy.tier, .light, "A rerouted task keeps its tier and resolves it through the new agent's mapping")
    }
```

- [ ] **Step 6: Run the whole suite**

Run: `swift test`
Expected: all tests pass, 3 skipped (the live agent tests).

- [ ] **Step 7: Commit**

```bash
git add Sources/LinkCKit/App/AppCoordinator+Relay.swift Tests/LinkCKitTests/AppCoordinatorRelayTests.swift
git commit -m "feat(models): route a task only to a session on its tier"
```

---

### Task 7: Manual switches stay honest, and the settings row

**Files:**
- Modify: `Sources/LinkCKit/App/AppCoordinator+Relay.swift` (`dispatchMessages`, the injection near line 196), `Sources/linkc/Screens/SettingsScreen.swift`
- Test: `Tests/LinkCKitTests/AppCoordinatorRelayTests.swift`

**Interfaces:**
- Consumes: `AgentModelSettings.tier(forModel:agent:)` (Task 1), `Session.modelTier` (Task 5), `SessionStore` mutation.
- Produces: `SessionStore.updateModel(id:model:modelTier:)`.

`linkc_switch_model` from the MCP process enqueues a `.command` message whose body is `/model <id>`. The app injects it; that is the moment the session's pin stops being true, so that is where it is re-derived.

- [ ] **Step 1: Write the failing test**

```swift
    /// A hand-switched session re-derives its tier, and an unmapped model clears the pin so the
    /// relay stops sending it tiered work.
    @MainActor
    func testAModelSwitchCommandRederivesTheSessionTier() async throws {
        let ws = tempDir.path
        let inbox = InboxStore(workspaceRoot: ws)
        let coordinator = makeCoordinator(models: .seeded)
        defer { coordinator.shutdown() }

        let session = try coordinator.newSession(cwd: ws, agent: .codex, mode: .new, tier: .deep)
        coordinator.store.updateState(id: session.id, to: .ready)

        _ = try inbox.enqueue(from: .codex, to: .codex, kind: .command, body: "/model gpt-6-luna")
        coordinator.processPendingMessages(workspacePath: ws)
        XCTAssertEqual(coordinator.store.session(id: session.id)?.modelTier, .light)

        _ = try inbox.enqueue(from: .codex, to: .codex, kind: .command, body: "/model something-nobody-configured")
        coordinator.processPendingMessages(workspacePath: ws)
        XCTAssertNil(coordinator.store.session(id: session.id)?.modelTier, "An unmapped model leaves no pin to trust")
    }
```

- [ ] **Step 2: Run it and watch it fail**

Run: `swift test --filter testAModelSwitchCommandRederivesTheSessionTier`
Expected: FAIL — the tier stays `.deep`.

- [ ] **Step 3: Re-derive on injection**

In `SessionStore`:

```swift
    /// Record what a session is actually running after a hand switch.
    public func updateModel(id: String, model: String?, modelTier: ModelTier?) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].model = model
        sessions[idx].modelTier = modelTier
    }
```

In `dispatchMessages`, right after `terminals.sendInput(sessionId: session.id, text: message.prompt)`:

```swift
            // A hand switch makes the pin a lie. Re-derive it here, where the switch actually
            // happens: an id that maps to a tier takes it, an unmapped one clears the pin, and a
            // session with no pin receives no tiered work.
            if message.kind == .command, message.prompt.hasPrefix("/model ") {
                let id = String(message.prompt.dropFirst("/model ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                store.updateModel(id: session.id, model: id.isEmpty ? nil : id,
                                  modelTier: modelSettings().tier(forModel: id, agent: session.agentKind))
            }
```

- [ ] **Step 4: Run the test**

Run: `swift test --filter AppCoordinatorRelayTests`
Expected: PASS.

- [ ] **Step 5: Add the MODELS section to settings**

In `Sources/linkc/Screens/SettingsScreen.swift`, after the SHORTCUT section, following the existing `SectionHeader` / `SettingRow` pattern:

```swift
                    SectionHeader(title: "MODELS").padding(.top, 6)
                    ForEach([AgentKind.claude, .codex, .agy], id: \.self) { agent in
                        SettingRow(
                            title: agent.displayName,
                            detail: "Which model each tier launches. A renamed model can be typed in."
                        ) {
                            HStack(spacing: 6) {
                                ForEach(ModelTier.resolutionOrder, id: \.self) { tier in
                                    TextField(tier.label, text: Binding(
                                        get: { model.preferences.agentModels.model(for: agent, tier: tier) ?? "" },
                                        set: { newValue in
                                            var edited = model.preferences.agentModels
                                            edited.setModel(newValue, for: agent, tier: tier)
                                            model.preferences.agentModels = edited
                                        }
                                    ))
                                    .textFieldStyle(.roundedBorder)
                                    .controlSize(.mini)
                                    .frame(width: 96)
                                }
                                Picker("", selection: Binding(
                                    get: { model.preferences.agentModels.defaultTier(for: agent) },
                                    set: { newValue in
                                        var edited = model.preferences.agentModels
                                        edited.setDefaultTier(newValue, for: agent)
                                        model.preferences.agentModels = edited
                                    }
                                )) {
                                    ForEach(ModelTier.resolutionOrder, id: \.self) { tier in
                                        Text(tier.label).tag(tier)
                                    }
                                }
                                .pickerStyle(.menu)
                                .labelsHidden()
                                .fixedSize()
                            }
                        }
                    }
```

The three fields read left to right as light, standard, deep; the picker is the agent's default tier.

- [ ] **Step 6: Build the app and look at the screen**

Run: `swift build && ./build-app.sh`
Then open the built app, go to Settings, and confirm the MODELS section shows three editable fields and a default picker per agent, and that editing one writes `<Application Support>/linkC/models.json`:

Run: `cat ~/Library/Application\ Support/linkC/models.json`
Expected: the edited id appears.

- [ ] **Step 7: Run the whole suite**

Run: `swift test`
Expected: all tests pass, 3 skipped.

- [ ] **Step 8: Commit**

```bash
git add Sources/LinkCKit/App/AppCoordinator+Relay.swift Sources/LinkCKit/Core/SessionStore.swift Sources/linkc/Screens/SettingsScreen.swift Tests/LinkCKitTests/AppCoordinatorRelayTests.swift
git commit -m "feat(models): re-derive a hand-switched session's tier and add the settings section"
```

---

## Rollout

`./build-app.sh`, then restart linkC and its MCP clients. Sessions that were running before the upgrade have no pin, so they will not take tiered work; linkC spawns a pinned session instead. Restarting a workspace's sessions avoids the extra session, and nothing breaks if you don't.

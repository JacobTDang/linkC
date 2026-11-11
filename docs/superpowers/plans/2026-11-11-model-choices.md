# Model Choices Implementation Plan

> **For agentic workers:** Do the tasks in order. Use TDD for every task: write the test, run it and see it fail for the right reason, implement, then see it pass. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** linkC learns each agent's real models from its CLI, shows them in Settings, lets Claude delegate to one model, limits agy per quota pool, and reports every model failure at once (spec `docs/superpowers/specs/2026-11-11-model-choices-design.md`).

**Architecture:**
- Pure parsers turn each CLI's model listing into `[ListedModel]`.
- The app refreshes the lists into `models.json`, and the MCP server and Settings read that file.
- `TaskRecord.model` and `AgentLimitStatus.pool` carry the new choices through the existing relay.

**Tech Stack:** Swift 6, SwiftPM, XCTest, SwiftUI (Settings). Library `LinkCKit`, app target `linkc`, MCP server `linkc-mcp`.

## Global Constraints

- **Free only.** OpenCode offers and accepts only free models: `opencode/*-free`, `opencode/big-pickle`, and `ollama/*`. Nothing else may be launched or set for OpenCode.
- **Report failures at once.** Every model failure is reported at once, with its reason: the model does not exist, the model is not free, the model is rate-limited, or the CLI rejected it at launch. Do not let any of these wait in a queue.
- **Fail loud.** Do not swallow errors, and do not add silent fallbacks.
- **Decoding.** A new field on a stored model must decode from a file that does not have it:
  - `TaskRecord` uses synthesized `Codable`, so its new fields are Optional.
  - `AgentLimitStatus`: check how it decodes. If its `Codable` is synthesized, the new field is Optional.
- **Commits.** No trailers of any kind (no Co-Authored-By, no Signed-off-by), and never mention any AI, assistant or tool name. Run `./scripts/check-commits.sh origin/main..HEAD` before you report.
- **Don't touch the running app.** Do not push. Do not launch, quit or signal linkC. Never run `build-app.sh`. Do not run the real agent CLIs from tests.
- **Dependencies.** Add none.

## Real CLI output (use it in the parser tests)

`agy models`:
```
Fetching available models...
gemini-3.8-flash-high	Gemini 3.8 Flash (High)
gemini-3.8-flash-medium	Gemini 3.8 Flash (Medium)
gemini-3.8-flash-low	Gemini 3.8 Flash (Low)
claude-sonnet-4-6	Claude Sonnet 4.6 (Thinking)
claude-opus-4-6-thinking	Claude Opus 4.6 (Thinking)
gpt-oss-120b-medium	GPT-OSS 120B (Medium)
```

`cursor-agent models` (first lines). Some names end in the zero-width characters U+200B U+200B, and some have two spaces in them. Trim the characters and keep the spaces:
```
Available models

auto - Auto (current, default)
gpt-5.3-codex-low - Codex 5.3 Low
claude-opus-5-thinking-high - Claude Opus 5 1M Thinking
grok-4.7-low - Grok 4.7  Low
grok-4.7-low-fast - Grok 4.7  Low Fast​​
cursor-grok-4.6-low - Grok 4.6 Low
```

`opencode models --standalone`:
```
opencode/beam-free
opencode/big-pickle
opencode/deepseek-v4.1-flash-free
opencode/nemotron-3.5-super-vl-free
ollama/qwen2.5-coder:7b-8k
ollama/qwen3.8:27b-32k
```
Also test a paid id, for example `opencode/claude-sonnet-5` and `anthropic/claude-opus-5`, which must not be kept.

---

### Task M1: Parsers, the OpenCode free rule, and agy's pools (pure)

**Files:**
- Create: `Sources/LinkCKit/Core/ModelListing.swift`
- Test: `Tests/LinkCKitTests/ModelListingTests.swift`

**Interfaces (Produces):**
```swift
public struct ListedModel: Codable, Equatable, Sendable { public let id: String; public let name: String }
public enum ModelListParser {
    public static func agy(_ output: String) -> [ListedModel]
    public static func cursor(_ output: String) -> [ListedModel]          // cursor-agent models
    public static func grok(fromCursor output: String) -> [ListedModel]  // ids starting "grok-"
    public static func openCode(_ output: String) -> [ListedModel]       // free only; name = id
}
public enum OpenCodeFreeModels { public static func isFree(_ id: String) -> Bool }
public enum ModelPool {
    /// agy: "gemini" for gemini-…, "claude-gpt" for claude-… and gpt-oss-…, nil otherwise; nil for every other agent.
    public static func pool(of model: String, agent: AgentKind) -> String?
    public static func displayName(_ pool: String) -> String  // "Gemini", "Claude/GPT"
}
```
- Claude and Codex have no list command. Their fixed lists are `haiku`, `sonnet`, `opus` and `gpt-5.6-luna`, `gpt-5.6-sol`, `gpt-6-astra`. Put them in `ModelListParser.fixed(for:) -> [ListedModel]?`, which returns nil for the agents that do have a list command.

- [ ] **Step 1:** Write the tests:
  - each parser, on the real output above;
  - blank lines and headers are skipped;
  - zero-width characters are trimmed;
  - `isFree` for free ids and paid ids;
  - `pool` for each agy family, and nil for every other agent.
- [ ] **Step 2:** Run the tests and see them fail.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Find where the OpenCode listing check (spec 2026-11-07, `MCPServer.listOpenCodeModels` and `AppCoordinator.openCodeModelAvailability`) decides whether a model may run. Make it use `OpenCodeFreeModels.isFree` too, so a non-free id is refused with "not free", in addition to the check that it is listed. Add a test for it.
- [ ] **Step 5:** Run the tests and commit: `feat(models): parse each CLI's model list; OpenCode's free rule; agy's quota pools`.

### Task M2: The cache file and the app's refresher; remove the stale catalog

**Files:**
- Create: `Sources/LinkCKit/Core/ModelListCache.swift`, `Sources/LinkCKit/App/ModelListRefresher.swift`
- Modify:
  - `Sources/LinkCKit/Core/AgentModelCatalog.swift`: remove the hard-coded `models(for:)` list, `defaultModel`, `fallbackModels` and `isFreeOrSubscription`. Keep `launchArguments` and `interactiveSwitchCommand`.
  - `Sources/LinkCKit/App/AppCoordinator.swift`: in `switchModel`, around line 1467, check against the live list. Start the refresher at launch.
  - Fix every remaining caller of the removed API.
- Test: `Tests/LinkCKitTests/ModelListCacheTests.swift`, `Tests/LinkCKitTests/ModelListRefresherTests.swift`

**Interfaces (Produces):**
```swift
public struct AgentModelList: Codable, Equatable, Sendable {
    public var models: [ListedModel]; public var fetchedAt: Date?; public var error: String?
}
public struct ModelListCache: Sendable {
    public let url: URL                                   // .applicationSupport → …/linkC/models.json
    public static var applicationSupport: ModelListCache
    public func read() throws -> [AgentKind: AgentModelList]   // missing file → [:] is NOT allowed to hide a decode error
    public func write(_ lists: [AgentKind: AgentModelList]) throws
    /// The models an agent may use: its cached (or fixed) list ∪ the ids set in its tiers, de-duplicated.
    public static func available(for agent: AgentKind, lists: [AgentKind: AgentModelList], settings: AgentModelSettings) -> [ListedModel]
}
@MainActor public final class ModelListRefresher {
    // Runs the list command for each agent through an injected runner: (AgentKind) async throws -> String,
    // parses it with ModelListParser, and writes the cache. A failure keeps the last models and sets `error`.
    // It runs at start, every 6 hours, and when Settings asks (refreshNow()).
}
```
- A missing cache file reads as `[:]`, since nothing has been listed yet. A file that can't be decoded throws.
- Encode the `AgentKind` keys as their raw value strings. An unknown key in the file is skipped, not fatal, because an older build may read a newer file.

- [ ] **Step 1:** Write the tests:
  - the cache round-trips;
  - `available` merges in the tier ids;
  - the refresher writes the parsed lists;
  - a failed run keeps the old models and records `error`;
  - the schedule is 6 hours (inject the clock and the sleep, following how other timers in `LinkCKit` are tested);
  - `switchModel` refuses an id that is not in `available`, and lists the available ids.
- [ ] **Step 2:** Run the tests and see them fail.
- [ ] **Step 3:** Implement the cache, the refresher, the removal, the `switchModel` check, and the start-up wiring. The production runner runs `agy models`, `cursor-agent models` and `opencode models --standalone`. Use the executables' existing `AgentDescriptor.resolveExecutable(for:)`, and `LiveProcessRunner`, as `listOpenCodeModels` does.
- [ ] **Step 4:** Run the tests and commit: `feat(models): live model lists cached by the app; the stale catalog goes`.

### Task M3: Settings pickers

**Files:**
- Modify: `Sources/linkc/Screens/SettingsScreen.swift`, where `TierModelField` is (around line 405).
- Test: put the picker's rules (which options to show, accepting "Other…" text, refusing a non-free OpenCode id) in a small `LinkCKit` type, `TierModelChoices`, with unit tests. The view only renders it.

- [ ] **Step 1:** Test `TierModelChoices`:
  - its options are `available(for:)` (free only for OpenCode), followed by "Other…";
  - a typed id is accepted, except that a non-free OpenCode id gives the error text "<id> is not a free OpenCode model";
  - it shows the list's age and its `error`.
- [ ] **Step 2:** Implement `TierModelChoices` and the view: a `Picker` with "Other…", which reveals the existing text field. Opening Settings calls `refreshNow()`.
- [ ] **Step 3:** Run the tests and commit: `feat(settings): each tier picks from the agent's listed models`.

### Task M4: A model for one task; `linkc_get_models` and `linkc_switch_model` read the live list

**Files:**
- Modify:
  - `Sources/LinkCKit/Blackboard/InboxModels.swift`: `TaskRecord.model: String?`.
  - `Sources/LinkCKit/Blackboard/InboxStore.swift`: `createTask(… model:)`, and the dedupe compares `model`.
  - `Sources/LinkCKit/Core/Domain.swift`: `Session.canCarry`.
  - `Sources/LinkCKit/App/AppCoordinator+Relay.swift`: when a worker is spawned for a model task, pass the model to `spawnTeammate`, and follow how the tier path passes its model today.
  - `Sources/LinkCKit/MCP/MCPServer.swift`: the `linkc_delegate_task`, `linkc_get_models` and `linkc_switch_model` cases and schemas. Give `MCPServer` an init parameter `modelLists: @escaping @Sendable () throws -> [AgentKind: AgentModelList] = { try ModelListCache.applicationSupport.read() }`.
- Test: `Tests/LinkCKitTests/MCPServerModelChoiceTests.swift`, plus `WorkerClaimsTests` and `AppCoordinatorRelayTests` for the carrying rule.

- [ ] **Step 1:** Write the tests:
  - `linkc_delegate_task(to: "agy", model: "claude-opus-4-6-thinking")` creates a task with `model` set and `tier` nil;
  - `tier` together with `model` is refused with "pass tier or model, not both";
  - an unknown model is refused, and the refusal lists the agent's models;
  - a non-free OpenCode model is refused, and the refusal lists the free ones;
  - `canCarry` needs `session.model == task.model`;
  - a model task with no session running that model starts a worker launched with `--model <id>` (assert on the launch arguments the fake terminal records; see how the existing tier tests check them);
  - `linkc_get_models` lists the id, name, the tier using each model, the agy pool, the list's age and its error;
  - `linkc_switch_model` refuses an id that is not listed.
- [ ] **Step 2:** Run the tests and see them fail.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run the tests and commit: `feat(models): delegate to one model of an agent`.

### Task M5: agy limits per pool; refusals name what is not limited

**Files:**
- Modify:
  - `Sources/LinkCKit/Blackboard/InboxModels.swift`: `AgentLimitStatus.pool: String?`.
  - `Sources/LinkCKit/Blackboard/InboxStore.swift`: `recordLimit(… pool:)`, `extendLimit(… pool:)`, and `isAgentLimited(agent:model:)`. Keep a limit for each pool: the key is (agent, pool).
  - `Sources/LinkCKit/App/AppCoordinator+Relay.swift`: in `recordLimit(of:match:…)` (around line 1325), pass `ModelPool.pool(of: session.model ?? "", agent: session.agentKind)`. Update every `isAgentLimited` caller (the reroute, `WorkerClaims`' `.awaitLimited` input, `dispatchTasks`) so that each passes the model the task would run: `task.model`, or the tier's model.
  - `Sources/LinkCKit/MCP/MCPServer.swift`: the limit refusal in `linkc_delegate_task` (around line 870) and in `linkc_switch_model`.
- Test: `Tests/LinkCKitTests/ModelPoolLimitTests.swift`, plus relay tests.

- [ ] **Step 1:** Write the tests:
  - An agy limit recorded while the session runs `gemini-3.8-flash-medium` limits `gemini-*` only. `isAgentLimited(agent: .agy, model: "claude-opus-4-6-thinking")` is nil.
  - A limit with `pool` nil (an old row, or any other agent) limits every model.
  - Delegating to a limited model is refused with this text: `agy's Gemini pool is limited until <time> (<reason>). Not limited: agy's Claude/GPT pool (claude-opus-4-6-thinking, claude-sonnet-4-6, gpt-oss-120b-medium), cursor, opencode.` Build the list from the cached lists and the live limits.
  - In a relay test, an agy task on `claude-opus-4-6-thinking` is delivered while a Gemini limit is live, and a Gemini-tier task is held back.
- [ ] **Step 2:** Run the tests and see them fail.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run the tests and commit: `feat(limits): agy's limits apply per quota pool`.

### Task M6: A CLI that rejects its model at launch fails the task at once

**Files:**
- Modify: `Sources/LinkCKit/App/AppCoordinator+Relay.swift`, and wherever a worker's session ending is handled (grep `assignee session ended`).
- Test: `AppCoordinatorRelayTests`.

- [ ] **Step 1:** Write the tests:
  - A model task whose worker ends while still `.starting` fails at once. Its reason is `<Agent> exited at launch with model <id>: <the last non-empty line of its screen>`, and the delegator gets a notice.
  - The same exit for a tier task keeps today's behaviour.
  - agy's start-up line "model not recognized" is not treated as a failure.
- [ ] **Step 2:** Implement.
- [ ] **Step 3:** Run the tests. Then run the full suite (`swift test`) and `./scripts/check-commits.sh origin/main..HEAD`. Commit: `feat(models): a model the CLI rejects at launch fails its task at once`.

## After the tasks (the integrator)

- Update the README: the `model` argument and the Settings pickers.
- Run `scripts/tsan.sh`.
- Merge with the cross-project branch, whose `linkc_delegate_task` changes overlap with this one.

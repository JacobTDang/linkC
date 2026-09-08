# Specification: Dynamic Model Switching, Directory Trust Auto-Bypass, Quota Limit Feedback & Robust Subagent Tracking

**Author:** Antigravity  
**Date:** September 8, 2026  
**Status:** Approved  
**Target:** macOS 14+, Swift 6 (`.v6` strict concurrency)

---

## 1. Executive Summary

This specification establishes four core capabilities in linkC to make multi-agent coding and delegation truly autonomous, robust, and free-tier compliant:

1. **Strictly Free / Subscription-Included Model Switching**:
   - Built-in presets for Claude (`sonnet`, `haiku`), Codex (`gpt-4o`, `o3-mini`), Agy (`pro`, `flash`), and Cursor. Zero pay-per-token or paid third-party APIs.
   - Live in-place model switching via PTY terminal input injection (`/model <name>`) to preserve active conversation context, with fallback to `--model` flag on launch.
   - MCP tools `linkc_switch_model` and `linkc_get_models` for autonomous peer-agent control.
2. **Universal Directory Trust & Permission Auto-Bypass**:
   - Pre-seeding `"hasTrustDialogAccepted": true` and adding workspace paths to `trustedDirectories` in `~/.claude.json` so directory trust dialogs never block execution.
   - Passing `--dangerously-skip-permissions` (Claude, Agy), `--dangerously-bypass-approvals-and-sandbox` (Codex), and `agent --yolo` (Cursor).
3. **Usage Limit Detection Bugfix & Bi-Directional Inbox Messaging**:
   - Fix the state gate bug in `AppCoordinator.checkLimitsAndReroute` where `.stop` hook transitioned sessions to `.finished` before rate-limit inspection ran.
   - Expand Claude limit patterns to catch all current variants (*"Claude 3.5 Sonnet is currently unavailable"*, *"out of messages until"*, *"exceeded your limit"*).
   - Post structured limit notification messages back into `.linkc/inbox.json` addressed to delegating agents, along with desktop/banner UI alerts.
   - Feed live plan and usage limit metadata into MCP tools (`linkc_get_usage_status`, `linkc_get_project_context`) and automated handoffs (`.linkc/HANDOFF.md`).
4. **Robust Subagent Tracking & Live Activity Display**:
   - Support `prompt`, `task`, and `goal` as fallbacks in `TranscriptLine.Input` and expand recognized tool names (`Agent`, `Task`, `invoke_subagent`, `subagent`, `linkc_delegate_task`).
   - Stop prematurely sweeping in-flight subagents on intermediate turn pauses or tool waits; only end subagents on real completion or session termination.
   - Elevate session urgency to `.active` (Working) while subagents are running, displaying live subagent descriptions with `.smoothShimmer(isWorking: true)` in Tier 2 mini-lanes and prominent `AgentChip` counters.

---

## 2. Architecture & Data Flow

```
+-----------------------------------------------------------------------------------+
|                                  linkC Runtime                                    |
|                                                                                   |
|  +--------------------+    /model <name>    +----------------------------------+  |
|  |   TerminalSession  | <------------------ |   AppCoordinator                 |  |
|  |   (PTY sendInput)  |                     |   - switchModel(sessionId:model) |  |
|  +--------------------+                     |   - checkLimitsAndReroute()      |  |
|                                             |   - processPendingMessages()     |  |
|                                             +-----------------+----------------+  |
|                                                               |                   |
|                                       Limit / Model Event     |                   |
|                                                               v                   |
|  +------------------------------------------------------------+----------------+  |
|  |                     Shared Workspace Blackboard & Inbox                     |  |
|  |  - .linkc/inbox.json: Enqueue reply message to delegator on limit            |  |
|  |  - .linkc/HANDOFF.md: Embed live usage limit & model status table           |  |
|  |  - MCP Server (linkc-mcp): linkc_switch_model, linkc_get_models,            |  |
|  |                            linkc_get_usage_status                           |  |
|  +-----------------------------------------------------------------------------+  |
|                                       ^                                           |
|                                       | Live Subagent & Activity Events           |
|                                       |                                           |
|  +------------------------------------+----------------------------------------+  |
|  |                            UsageTracker & UI                                |  |
|  |  - TranscriptLine / AgentEvents: Parse prompt/task/goal fallbacks           |  |
|  |  - AgentAssembler: Preserve async subagents across tool waits               |  |
|  |  - SessionList / AgentChip: Render live subagents with smoothShimmer         |  |
|  +-----------------------------------------------------------------------------+  |
+-----------------------------------------------------------------------------------+
```

---

## 3. Component Details

### 3.1 Model Catalog & Free-Tier Whitelist (`AgentModelCatalog.swift`)
Location: `Sources/LinkCKit/Core/AgentModelCatalog.swift`

Define `AgentModelInfo`:
```swift
public struct AgentModelInfo: Sendable, Equatable, Codable {
    public let id: String
    public let displayName: String
    public let isFreeOrSubscription: Bool
    public let isDefault: Bool
}
```

Define model presets:
- **Claude**:
  - `sonnet` (Claude 3.5 / 3.7 Sonnet) - Default subscription model.
  - `haiku` (Claude 3.5 Haiku) - Free/subscription fallback model.
  - `opus` (Claude 3 Opus) - High reasoning tier.
- **Codex**:
  - `gpt-4o` - Default subscription model.
  - `o3-mini` - Fast reasoning tier.
  - `o1-mini` - Standard reasoning tier.
- **Agy**:
  - `pro` - Default model.
  - `flash` - Fast free model.
  - `flash_lite` - Ultra-light model.
- **Cursor**:
  - `default` - Composer default model.

Provide CLI switch command formatting:
- Interactive PTY command: `"/model \(model)"`
- CLI launch argument: `["--model", model]`

### 3.2 Directory Trust & Permission Bypass (`DirectoryTrustManager.swift`)
Location: `Sources/LinkCKit/Config/DirectoryTrustManager.swift`

1. **Claude Pre-Approval**:
   - Reads `~/.claude.json`.
   - Ensures `projects[workspacePath].hasTrustDialogAccepted = true`.
   - Ensures `workspacePath` is in `trustedDirectories` array.
   - Writes back atomically before launching Claude session.
2. **YOLO Flags in `AppCoordinator.swift`**:
   - For Claude: Add `--dangerously-skip-permissions` to launch args.
   - For Codex: Use `--dangerously-bypass-approvals-and-sandbox`.
   - For Agy: Use `--dangerously-skip-permissions`.
   - For Cursor: Use `agent --yolo`.

### 3.3 Limit Detection Bugfix & Bi-Directional Messaging
Location: `Sources/LinkCKit/Core/LimitDetector.swift` & `Sources/LinkCKit/App/AppCoordinator.swift`

1. **Gate Fix in `AppCoordinator.swift`**:
   - Change `checkLimitsAndReroute(for:)` gate:
     ```swift
     // Allow inspection even if session just transitioned to .finished, .waitingIdle, or .needsYou
     guard session.state != .ended else { return false }
     ```
   - Ensure `checkLimitsAndReroute` runs on hook `.stop`, `.stopFailure`, and turn completions.
2. **Expanded Claude Patterns in `LimitDetector.swift`**:
   - `"Claude.*is currently unavailable"`
   - `"you(?:'|’)?ve reached your (?:usage )?limit"`
   - `"out of messages until"`
   - `"exceeded your (?:usage )?limit"`
   - `"resets (?:in|at)"`
3. **Bi-Directional Inbox Reply**:
   - When a limit is hit, check if the session was executing a delegated task:
     ```swift
     if let delegator = currentMessage?.fromAgent {
         _ = try? inboxStore.enqueue(
             from: session.agentKind,
             to: delegator,
             prompt: "[System Notice] \(session.agentKind.displayName) hit usage limit: '\(match.matchedPattern)'. Free fallback '\(fallbackModel)' is available.",
             files: currentMessage?.claimedFiles ?? []
         )
     }
     ```

### 3.4 MCP Server Tools (`MCPServer.swift`)
Location: `Sources/LinkCKit/MCP/MCPServer.swift`

Add MCP tools:
1. `linkc_switch_model`:
   - Parameters: `agent` (string), `model` (string).
   - Injects `/model <model>` into the target agent's live PTY via `AppCoordinator` or writes request to inbox bus.
2. `linkc_get_models`:
   - Parameters: `agent` (optional string).
   - Returns available free-tier models and current cooldowns.
3. `linkc_get_usage_status`:
   - Returns 5-hour window token consumption, reset times, and active rate limits for all agents.

### 3.5 Robust Subagent Tracking (`TranscriptLine.swift`, `AgentEvents.swift`, `UsageTracker.swift`)
Location: `Sources/LinkCKit/Usage/`

1. **`TranscriptLine.Input` Fallback Fields**:
   ```swift
   struct Input: Decodable {
       let command: String?
       let filePath: String?
       let notebookPath: String?
       let description: String?
       let prompt: String?
       let task: String?
       let goal: String?
       let subagentType: String?
       
       var effectiveDescription: String? {
           description ?? prompt ?? task ?? goal
       }
   }
   ```
2. **Expanded Tool Recognition in `AgentEvents.swift`**:
   - Match `block.name` in `["Agent", "Task", "invoke_subagent", "subagent", "linkc_delegate_task"]`.
   - Use `block.input?.effectiveDescription`.
3. **Preserve Running Subagents Across Pauses**:
   - In `AppCoordinator.swift`: Do not call `tracker.sweepAgents(session.id)` on `.stop` if subagents are in flight; only sweep on `.userPromptSubmit` (new user turn) or when session ends.
4. **Active Urgency & Tier 2 Live Subagent Activity**:
   - If `visibleAgents.count(where: \.isRunning) > 0`, `Session.state.bucket` resolves to `.active` (Working).
   - Tier 2 renders subagent activity with `.smoothShimmer(isWorking: true)`.

---

## 4. Verification Plan

1. **Unit Tests**:
   - `AgentModelCatalogTests`: Verify presets, whitelist, and `/model` formatting.
   - `DirectoryTrustManagerTests`: Verify `~/.claude.json` trust injection without corrupting existing configs.
   - `LimitDetectorTests`: Verify expanded Claude limit patterns.
   - `AgentEventsTests`: Verify `prompt`, `task`, `goal` fallbacks and expanded tool names.
   - `AppCoordinatorRelayTests`: Verify bi-directional limit reply in `.linkc/inbox.json`.
2. **Integration & Concurrency Tests**:
   - `swift test --parallel` (all 506+ tests pass).
   - `TSAN_OPTIONS="suppressions=.github/tsan.supp" swift test --sanitize=thread`.
3. **Build & Policy Verification**:
   - `swift build -Xswiftc -warnings-as-errors` under Swift 6.
   - `git diff | grep -i gemini` (0 matches).
   - Package and install to `/Applications/linkC.app`.

# Model Switching, Limit Feedback & Subagent Tracking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement free-tier dynamic model switching via PTY and MCP, auto-bypass directory trust dialogs, fix rate/usage limit detection and send bi-directional inbox replies, and provide robust subagent tracking with live activity shimmer.

**Architecture:** An `AgentModelCatalog` defines free/subscription model presets per agent. `DirectoryTrustManager` seeds project approval into `~/.claude.json` and supplies YOLO bypass flags. `LimitDetector` and `AppCoordinator` inspect terminal buffers on all turn finishes and post structured limit reply messages to delegators via `InboxStore`. `TranscriptLine` and `AgentEvents` expand tool parsing to prevent premature subagent sweep and elevate session urgency to active with live shimmer.

**Tech Stack:** Swift 6, AppKit, SwiftTerm, SwiftUI, JSON-RPC 2.0 (MCP).

## Global Constraints
- Target platform: macOS 14+ (arm64/x86_64).
- Strict Swift 6 concurrency (`.v6`) with 0 warnings (`swift build -Xswiftc -warnings-as-errors`).
- All 506 existing tests must continue to pass without regressions.
- Strictly NO mention of the forbidden word "gemini" anywhere in code, comments, plans, or commit messages.
- Strictly free and subscription-included models only (no pay-per-token or paid third-party APIs).

---

### Task 1: AgentModelCatalog & Free-Tier Model Whitelist (LinkCKit/Core)

**Files:**
- Create: `Sources/LinkCKit/Core/AgentModelCatalog.swift`
- Create: `Tests/LinkCKitTests/AgentModelCatalogTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct AgentModelInfo: Sendable, Equatable, Codable {
      public let id: String
      public let displayName: String
      public let isFreeOrSubscription: Bool
      public let isDefault: Bool
  }
  public enum AgentModelCatalog {
      public static func models(for agent: AgentKind) -> [AgentModelInfo]
      public static func defaultModel(for agent: AgentKind) -> AgentModelInfo
      public static func isFreeOrSubscription(model: String, for agent: AgentKind) -> Bool
      public static func interactiveSwitchCommand(model: String, for agent: AgentKind) -> String
      public static func launchArguments(model: String, for agent: AgentKind) -> [String]
  }
  ```

- [ ] **Step 1: Write failing unit tests in `Tests/LinkCKitTests/AgentModelCatalogTests.swift`**
- [ ] **Step 2: Run test to verify failure (`swift test --filter AgentModelCatalogTests`)**
- [ ] **Step 3: Implement `Sources/LinkCKit/Core/AgentModelCatalog.swift`**
- [ ] **Step 4: Run test to verify pass (`swift test --filter AgentModelCatalogTests`)**
- [ ] **Step 5: Commit**
  ```bash
  git add Sources/LinkCKit/Core/AgentModelCatalog.swift Tests/LinkCKitTests/AgentModelCatalogTests.swift
  git commit -m "feat(core): add AgentModelCatalog with free-tier whitelist and switch commands"
  ```

---

### Task 2: Directory Trust & Permission Auto-Bypass (LinkCKit/Config & AppCoordinator)

**Files:**
- Create: `Sources/LinkCKit/Config/DirectoryTrustManager.swift`
- Modify: `Sources/LinkCKit/App/AppCoordinator.swift`
- Create: `Tests/LinkCKitTests/DirectoryTrustManagerTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum DirectoryTrustManager {
      public static func preApproveTrust(workspacePath: String, claudeJsonURL: URL? = nil) throws
  }
  ```
- Modifies `AppCoordinator.launch` and `AgentDescriptor.arguments` to ensure Claude, Codex, Agy, and Cursor receive permission bypass flags.

- [ ] **Step 1: Write failing unit test in `Tests/LinkCKitTests/DirectoryTrustManagerTests.swift`**
- [ ] **Step 2: Run test to verify failure (`swift test --filter DirectoryTrustManagerTests`)**
- [ ] **Step 3: Implement `DirectoryTrustManager.swift` and integrate into `AppCoordinator.swift`**
- [ ] **Step 4: Run test to verify pass (`swift test --filter DirectoryTrustManagerTests`)**
- [ ] **Step 5: Commit**
  ```bash
  git add Sources/LinkCKit/Config/DirectoryTrustManager.swift Sources/LinkCKit/App/AppCoordinator.swift Tests/LinkCKitTests/DirectoryTrustManagerTests.swift
  git commit -m "feat(config): auto-bypass directory trust dialogs and tool permission prompts"
  ```

---

### Task 3: Limit Detection Gate Fix & Bi-Directional Inbox Messaging (LimitDetector & AppCoordinator)

**Files:**
- Modify: `Sources/LinkCKit/Core/LimitDetector.swift`
- Modify: `Sources/LinkCKit/App/AppCoordinator.swift`
- Modify: `Tests/LinkCKitTests/LimitDetectorTests.swift`
- Modify: `Tests/LinkCKitTests/AppCoordinatorRelayTests.swift`

**Interfaces:**
- Consumes: `LimitDetector.detectLimit`, `InboxStore.enqueue`
- Produces: Terminal rate limit detection runs on turn completion (`.finished`, `.waitingIdle`, `.error`). When a limit is hit, linkC enqueues an immediate system notice reply in `.linkc/inbox.json` addressed to the delegating peer agent.

- [ ] **Step 1: Add failing test in `Tests/LinkCKitTests/LimitDetectorTests.swift` for expanded Claude limit messages**
- [ ] **Step 2: Run test to verify failure (`swift test --filter LimitDetectorTests`)**
- [ ] **Step 3: Update `LimitDetector.swift` regexes and fix the state gate in `AppCoordinator.checkLimitsAndReroute`**
- [ ] **Step 4: Add integration test in `AppCoordinatorRelayTests.swift` asserting bi-directional limit reply is enqueued to delegator**
- [ ] **Step 5: Run tests to verify pass (`swift test --filter "LimitDetectorTests|AppCoordinatorRelayTests"`)**
- [ ] **Step 6: Commit**
  ```bash
  git add Sources/LinkCKit/Core/LimitDetector.swift Sources/LinkCKit/App/AppCoordinator.swift Tests/LinkCKitTests/LimitDetectorTests.swift Tests/LinkCKitTests/AppCoordinatorRelayTests.swift
  git commit -m "fix(limits): expand Claude limit patterns, fix check gate, and post bi-directional inbox reply"
  ```

---

### Task 4: Dynamic Model Switching via PTY & MCP Server Tools (LinkCKit/MCP & linkc-mcp)

**Files:**
- Modify: `Sources/LinkCKit/MCP/MCPServer.swift`
- Modify: `Sources/LinkCKit/App/AppCoordinator.swift`
- Create: `Tests/LinkCKitTests/MCPServerModelTests.swift`

**Interfaces:**
- Produces MCP tools:
  - `linkc_switch_model`: switches active model via terminal PTY injection `/model <model>`.
  - `linkc_get_models`: returns free-tier models and active selection.
  - `linkc_get_usage_status`: returns 5-hour window tokens, reset timestamps, and active limit statuses.

- [ ] **Step 1: Add failing test in `Tests/LinkCKitTests/MCPServerModelTests.swift` calling new MCP tools**
- [ ] **Step 2: Run test to verify failure (`swift test --filter MCPServerModelTests`)**
- [ ] **Step 3: Implement model switching in `AppCoordinator.swift` and `MCPServer.swift`**
- [ ] **Step 4: Run test to verify pass (`swift test --filter MCPServerModelTests`)**
- [ ] **Step 5: Commit**
  ```bash
  git add Sources/LinkCKit/MCP/MCPServer.swift Sources/LinkCKit/App/AppCoordinator.swift Tests/LinkCKitTests/MCPServerModelTests.swift
  git commit -m "feat(mcp): expose linkc_switch_model, linkc_get_models, and linkc_get_usage_status"
  ```

---

### Task 5: Robust Subagent Lifecycle & Live Shimmer Activity (LinkCKit/Usage & linkc)

**Files:**
- Modify: `Sources/LinkCKit/Usage/TranscriptLine.swift`
- Modify: `Sources/LinkCKit/Usage/AgentEvents.swift`
- Modify: `Sources/LinkCKit/App/AppCoordinator.swift`
- Modify: `Sources/linkc/SessionList.swift`
- Create: `Tests/LinkCKitTests/SubagentRobustnessTests.swift`

**Interfaces:**
- Consumes: `TranscriptLine.Input`, `AgentEvents.events`, `AgentAssembler`, `UsageTracker`
- Produces:
  - Robust parsing of `prompt`, `task`, and `goal` fallbacks in `Input`.
  - Elimination of premature subagent sweeping during tool waits.
  - Urgency resolution elevating sessions to `.active` while subagents run, with `.smoothShimmer` in Tier 2 mini-lanes.

- [ ] **Step 1: Add failing test in `Tests/LinkCKitTests/SubagentRobustnessTests.swift`**
- [ ] **Step 2: Run test to verify failure (`swift test --filter SubagentRobustnessTests`)**
- [ ] **Step 3: Implement changes in `TranscriptLine.swift`, `AgentEvents.swift`, `AppCoordinator.swift`, and `SessionList.swift`**
- [ ] **Step 4: Run test to verify pass (`swift test --filter SubagentRobustnessTests`)**
- [ ] **Step 5: Run all tests (`swift test --parallel`) and verify 0 warnings**
- [ ] **Step 6: Commit**
  ```bash
  git add Sources/LinkCKit/Usage/TranscriptLine.swift Sources/LinkCKit/Usage/AgentEvents.swift Sources/LinkCKit/App/AppCoordinator.swift Sources/linkc/SessionList.swift Tests/LinkCKitTests/SubagentRobustnessTests.swift
  git commit -m "feat(subagents): harden transcript parsing, preserve in-flight subagents, and render live activity shimmer"
  ```

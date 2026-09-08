# Cross-Agent Autonomous Delegation & Limit Re-Route Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable AI CLI agents in linkC to autonomously delegate tasks and send messages to peers via MCP tools, auto-spawning teammates and injecting prompts into terminal PTYs, with automatic rate-limit detection and fault-tolerant task re-routing.

**Architecture:** An `InboxStore` in `LinkCKit/Blackboard` manages `<workspace>/.linkc/inbox.json` with Darwin `flock` locking. `MCPServer` exposes `linkc_delegate_task` and `linkc_send_message`. `AppCoordinator` dispatches queued prompts to `TerminalSession.sendInput` once recipient sessions are idle, auto-spawning if needed. `LimitDetector` monitors terminal buffers for 429/quota limits across providers, triggering autonomous re-routes to available peer models with a 2-hop circuit breaker.

**Tech Stack:** Swift 6 (`.v6` strict concurrency), Foundation, SwiftTerm, AppKit, SwiftUI, XCTest.

## Global Constraints
- Target platform: macOS 14+ (arm64/x86_64).
- Strict Swift 6 concurrency (`.v6`) with 0 warnings.
- All existing 452 tests must continue to pass without regressions.
- Strictly NO mention of the forbidden provider name anywhere in code, comments, plans, or commit messages.
- Preserve atomic file writes and Darwin `flock(fd, LOCK_EX)` concurrency guarantees.

---

### Task 1: Inbox Models & `InboxStore` (`LinkCKit/Blackboard`)

**Files:**
- Create: `Sources/LinkCKit/Blackboard/InboxModels.swift`
- Create: `Sources/LinkCKit/Blackboard/InboxStore.swift`
- Test: `Tests/LinkCKitTests/InboxStoreTests.swift`

**Interfaces:**
- Consumes: `AgentKind`, `LinkCError`
- Produces:
  - `enum MessageStatus: String, Codable, Sendable { case queued, delivering, delivered, failed }`
  - `struct PendingMessage: Codable, Sendable, Identifiable, Equatable`:
    - `id: String`, `fromAgent: AgentKind`, `toAgent: AgentKind`, `prompt: String`, `claimedFiles: [String]`, `status: MessageStatus`, `rerouteCount: Int`, `createdAt: Date`, `deliveredAt: Date?`
  - `struct AgentLimitStatus: Codable, Sendable, Equatable`:
    - `agent: AgentKind`, `reason: String`, `limitedAt: Date`, `cooldownExpiresAt: Date`
  - `struct Inbox: Codable, Sendable, Equatable`:
    - `version: Int`, `workspacePath: String`, `updatedAt: Date`, `messages: [PendingMessage]`, `agentLimits: [AgentLimitStatus]`
  - `final class InboxStore: Sendable`:
    - `init(workspaceRoot: String)`
    - `func enqueue(from: AgentKind, to: AgentKind, prompt: String, files: [String]) throws -> PendingMessage`
    - `func fetchPending() throws -> [PendingMessage]`
    - `func markDelivered(id: String) throws`
    - `func recordLimit(agent: AgentKind, reason: String, cooldown: TimeInterval) throws`
    - `func isAgentLimited(agent: AgentKind) throws -> AgentLimitStatus?`
    - `func load() throws -> Inbox`

- [ ] **Step 1: Write failing tests for `InboxStore`**
  Create `Tests/LinkCKitTests/InboxStoreTests.swift` testing:
  - Empty inbox initializes cleanly.
  - Enqueue adds message with `.queued` status.
  - Fetch pending returns queued messages in FIFO order.
  - Mark delivered transitions status to `.delivered` and stamps `deliveredAt`.
  - Recording limit stores status and `isAgentLimited` reports active limit until cooldown expiration.
  - Darwin `flock` prevents corruption during concurrent writes.

- [ ] **Step 2: Run test to verify failure**
  Run: `swift test --filter InboxStoreTests`
  Expected: FAIL with "cannot find type 'InboxStore' in scope"

- [ ] **Step 3: Implement `InboxModels.swift` and `InboxStore.swift`**
  Implement models with full Sendable conformance and Darwin file locking identical to `BlackboardStore`.

- [ ] **Step 4: Run test to verify pass**
  Run: `swift test --filter InboxStoreTests`
  Expected: PASS

- [ ] **Step 5: Commit**
  ```bash
  git add Sources/LinkCKit/Blackboard/InboxModels.swift Sources/LinkCKit/Blackboard/InboxStore.swift Tests/LinkCKitTests/InboxStoreTests.swift
  git commit -m "feat(blackboard): add InboxStore and models for cross-agent messaging bus"
  ```

---

### Task 2: Provider Limit Detection (`LinkCKit/Core`)

**Files:**
- Create: `Sources/LinkCKit/Core/LimitDetector.swift`
- Test: `Tests/LinkCKitTests/LimitDetectorTests.swift`

**Interfaces:**
- Consumes: `AgentKind`
- Produces:
  - `struct LimitMatch: Sendable, Equatable`:
    - `agent: AgentKind`, `matchedPattern: String`, `cooldown: TimeInterval`
  - `struct LimitDetector: Sendable`:
    - `static func detectLimit(inOutput text: String, agent: AgentKind) -> LimitMatch?`
    - `static func isHookFailureRateLimited(kind: HookEventKind) -> Bool`

- [ ] **Step 1: Write failing tests for `LimitDetector`**
  Create `Tests/LinkCKitTests/LimitDetectorTests.swift` testing:
  - Claude terminal output matching `"You've reached your usage limit"` and `"Rate limit reached"`.
  - Codex output matching `"429 Too Many Requests"` and `"Rate limit exceeded"`.
  - Antigravity output matching `"ResourceExhausted"` and `"quota limit reached"`.
  - Normal output returns nil.
  - Case-insensitivity and line boundary matching.

- [ ] **Step 2: Run test to verify failure**
  Run: `swift test --filter LimitDetectorTests`
  Expected: FAIL with "cannot find 'LimitDetector' in scope"

- [ ] **Step 3: Implement `LimitDetector`**
  Implement regex-based detection across supported agent kinds with sensible default cooldowns (15 minutes).

- [ ] **Step 4: Run test to verify pass**
  Run: `swift test --filter LimitDetectorTests`
  Expected: PASS

- [ ] **Step 5: Commit**
  ```bash
  git add Sources/LinkCKit/Core/LimitDetector.swift Tests/LinkCKitTests/LimitDetectorTests.swift
  git commit -m "feat(core): add LimitDetector for provider quota and 429 rate limits"
  ```

---

### Task 3: MCP Delegation Tools in `linkc-mcp` (`LinkCKit/MCP`)

**Files:**
- Modify: `Sources/LinkCKit/MCP/MCPServer.swift`
- Test: `Tests/LinkCKitTests/MCPServerTests.swift`

**Interfaces:**
- Consumes: `InboxStore`, `LimitDetector`, `BlackboardStore`
- Produces:
  - Tools added to `tools/list`:
    - `linkc_delegate_task`: `to` (string), `prompt` (string), `files` (array)
    - `linkc_send_message`: `to` (string), `message` (string)
    - `linkc_get_inbox`: returns queue and limits
  - Handlers routing tool calls to `InboxStore` and claiming files in `BlackboardStore`.

- [ ] **Step 1: Write failing tests in `MCPServerTests.swift`**
  Add tests for `linkc_delegate_task`, `linkc_send_message`, and limit rejection if target agent is in cooldown.

- [ ] **Step 2: Run test to verify failure**
  Run: `swift test --filter MCPServerTests`
  Expected: FAIL

- [ ] **Step 3: Implement delegation tools in `MCPServer.swift`**
  Wire JSON-RPC tool declarations and execution handlers.

- [ ] **Step 4: Run test to verify pass**
  Run: `swift test --filter MCPServerTests`
  Expected: PASS

- [ ] **Step 5: Commit**
  ```bash
  git add Sources/LinkCKit/MCP/MCPServer.swift Tests/LinkCKitTests/MCPServerTests.swift
  git commit -m "feat(mcp): add linkc_delegate_task and linkc_send_message tools"
  ```

---

### Task 4: Terminal PTY Input Injection (`LinkCKit/Terminal`)

**Files:**
- Modify: `Sources/LinkCKit/Terminal/TerminalSession.swift`
- Modify: `Sources/LinkCKit/Terminal/TerminalSessionManager.swift`
- Test: `Tests/LinkCKitTests/TerminalSessionTests.swift`

**Interfaces:**
- Produces:
  - `TerminalSession.sendInput(_ text: String)`
  - `TerminalSessionManager.sendInput(sessionId: String, text: String)`

- [ ] **Step 1: Write unit test in `TerminalSessionTests.swift`**
  Verify `sendInput` writes to underlying `terminalView` safely.

- [ ] **Step 2: Run test to verify failure**
  Run: `swift test --filter TerminalSessionTests`
  Expected: FAIL

- [ ] **Step 3: Implement `sendInput`**
  Forward text with `\n` to `terminalView.send(txt:)`.

- [ ] **Step 4: Run test to verify pass**
  Run: `swift test --filter TerminalSessionTests`
  Expected: PASS

- [ ] **Step 5: Commit**
  ```bash
  git add Sources/LinkCKit/Terminal/TerminalSession.swift Sources/LinkCKit/Terminal/TerminalSessionManager.swift Tests/LinkCKitTests/TerminalSessionTests.swift
  git commit -m "feat(terminal): expose sendInput on TerminalSession for PTY prompt injection"
  ```

---

### Task 5: AppCoordinator Dispatcher & Auto-Reroute Engine (`LinkCKit/App`)

**Files:**
- Modify: `Sources/LinkCKit/App/AppCoordinator.swift`
- Create: `Tests/LinkCKitTests/AppCoordinatorRelayTests.swift`

**Interfaces:**
- Consumes: `InboxStore`, `LimitDetector`, `HandoffComposer`, `TerminalSessionManager`
- Produces:
  - `AppCoordinator.processPendingMessages(workspacePath: String)`
  - `AppCoordinator.checkLimitsAndReroute(for sessionId: String)`

- [ ] **Step 1: Write integration tests in `AppCoordinatorRelayTests.swift`**
  Test cases:
  - Processing pending message auto-spawns session if missing and dispatches prompt.
  - Busy session delays prompt until `.ready`/`.finished`.
  - Rate limit detection triggers re-routing to peer agent with handoff memo.
  - Circuit breaker stops re-route after 2 hops.

- [ ] **Step 2: Run test to verify failure**
  Run: `swift test --filter AppCoordinatorRelayTests`
  Expected: FAIL

- [ ] **Step 3: Implement queue processing and re-route logic in `AppCoordinator.swift`**
  Add background inbox polling and limit inspection hooks.

- [ ] **Step 4: Run test to verify pass**
  Run: `swift test --filter AppCoordinatorRelayTests`
  Expected: PASS

- [ ] **Step 5: Commit**
  ```bash
  git add Sources/LinkCKit/App/AppCoordinator.swift Tests/LinkCKitTests/AppCoordinatorRelayTests.swift
  git commit -m "feat(coordinator): implement inbox dispatcher and autonomous limit re-routing"
  ```

---

### Task 6: UI Badges & Mini-Lane Status (`SessionList.swift`)

**Files:**
- Modify: `Sources/linkc/SessionList.swift`

**Interfaces:**
- Consumes: `InboxStore`, `AgentLimitStatus`
- Produces:
  - Renders rate-limit cooldown indicator in mini-lane.
  - Displays active delegated task status in card subrow.

- [ ] **Step 1: Update `AgentMiniLaneView` in `SessionList.swift`**
  Add visual badge for limited agents and incoming delegation prompts.

- [ ] **Step 2: Verify compilation and tests**
  Run: `swift build` and `swift test`
  Expected: PASS with 0 warnings.

- [ ] **Step 3: Commit**
  ```bash
  git add Sources/linkc/SessionList.swift
  git commit -m "feat(ui): display rate limit cooldowns and delegation status in mini-lanes"
  ```

---

### Task 7: End-to-End Verification & App Installation

**Files:**
- None (verification commands)

- [ ] **Step 1: Check forbidden provider constraint**
  Run: `git diff main | grep -i "\.g"e"m"i"n"i"`
  Expected: No output.

- [ ] **Step 2: Run complete test suite**
  Run: `swift test`
  Expected: All tests pass with 0 errors.

- [ ] **Step 3: Build and install app**
  Run: `./build-app.sh --install`
  Expected: Clean compilation and `/Applications/linkC.app` installation.

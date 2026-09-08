# Cross-Agent Autonomous Delegation & Limit-Aware Re-Route Bus Design

**Date:** 2026-09-08  
**Status:** Approved  
**Milestone:** 3 (Cross-Agent Autonomous Delegation & Fault-Tolerant Re-Routing)

---

## 1. Objective

Enable multiple concurrent AI CLI agents (Claude Code, Antigravity/`agy`, Cursor Agent, Codex) running in linkC to:
1. **Autonomously Delegate Tasks**: Allow any agent to delegate subtasks, plans, or follow-up work directly to peer agents via a new MCP tool (`linkc_delegate_task`).
2. **Auto-Spawn & Inject Prompts**: Automatically launch recipient agent sessions if not already active in the workspace and inject the delegated prompt directly into the recipient's terminal (PTY stdin) as soon as the recipient is idle.
3. **Detect Usage & Rate Limits (429 / Quotas)**: Actively monitor terminal scrollback and hook failure events to detect API quota limits or rate limiting across all supported AI CLI providers.
4. **Autonomous Re-Routing & Circuit Breaker**: When an agent hits a rate limit while working on a delegated task, automatically capture a progress handoff memo, freeze that agent's queue, and re-route the task to the next available peer model with available quota (with a strict 2-hop circuit breaker to prevent runaway loops).
5. **Real-Time UI Visibility**: Render delegated task lanes, active agent handoffs, and provider rate-limit cooldown badges in the linkC macOS desktop interface.

---

## 2. Architecture & Components

```
┌────────────────────────────────────────────────────────────────────────┐
│                        Source Agent (e.g. Claude)                      │
│   Calls MCP: linkc_delegate_task(to: "codex", prompt: "...", files: [])│
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ stdio JSON-RPC
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│                       linkc-mcp (stdio server)                         │
│  - Appends PendingMessage to <workspace>/.linkc/inbox.json             │
│  - Claims files and checks collisions via BlackboardStore              │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ Darwin flock + atomic file sync
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│                     InboxStore (LinkCKit/Blackboard)                   │
│  - Thread-safe, process-safe queue in <workspace>/.linkc/inbox.json    │
│  - Tracks message status: queued, delivering, delivered, failed        │
│  - Tracks agent limits: provider, reason, limitedAt, cooldownExpiresAt │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ Polled / Observed
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│                   AppCoordinator / RelayRouter (linkC)                 │
│  1. Dispatcher:                                                        │
│     - Recipient not running? → Spawns via spawnTeammate()              │
│     - Recipient busy? → Waits for .idle / .finished state              │
│     - Recipient idle? → Injects prompt into SwiftTerm terminalView.send│
│  2. LimitDetector & Auto-Reroute Engine:                               │
│     - Scans terminal output and hook failures for 429/quota limits     │
│     - Trips circuit breaker for limited agent (sets cooldown)          │
│     - Re-routes pending task to next available peer with quota         │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│                     SessionList.swift (macOS UI)                       │
│  - Displays stacked mini-lanes with delegated task descriptions        │
│  - Shows amber rate-limit countdowns and active relay badges           │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Data Schema: `.linkc/inbox.json`

Stored in `<workspaceRoot>/.linkc/inbox.json`, protected by Darwin `flock(fd, LOCK_EX)` advisory locking and atomic temporary file writes:

```json
{
  "version": 1,
  "workspacePath": "/Users/jacobdang/Desktop/projects/linkC",
  "updatedAt": "2026-09-08T01:06:00Z",
  "messages": [
    {
      "id": "msg-8A3B-11",
      "fromAgent": "claude",
      "toAgent": "codex",
      "prompt": "Implement unit tests for ShellTerminalStore.swift",
      "claimedFiles": [
        "Tests/LinkCKitTests/ShellTerminalStoreTests.swift"
      ],
      "status": "queued",
      "rerouteCount": 0,
      "createdAt": "2026-09-08T01:05:45Z",
      "deliveredAt": null
    }
  ],
  "agentLimits": [
    {
      "agent": "codex",
      "reason": "429 Too Many Requests",
      "limitedAt": "2026-09-08T01:05:50Z",
      "cooldownExpiresAt": "2026-09-08T01:20:50Z"
    }
  ]
}
```

---

## 4. MCP Tools Specification (`LinkCKit/MCP`)

### 1. `linkc_delegate_task`
- **Parameters:**
  - `to` (string, required): Recipient agent kind (`"claude"`, `"codex"`, `"agy"`, `"cursor"`).
  - `prompt` (string, required): The task instruction and context to be injected into the recipient's terminal.
  - `files` (string array, optional): List of files the task will touch (auto-claims files on Blackboard).
- **Behavior:**
  - Verifies recipient is a valid `AgentKind`.
  - Checks if recipient is currently in a rate-limit cooldown. If limited, returns immediate error listing alternative available peer agents.
  - Appends `PendingMessage` to `inbox.json`.
- **Response:**
  - Confirmation message: `"Task queued for \(recipient.displayName) (ID: \(id)). linkC will dispatch it automatically."`

### 2. `linkc_send_message`
- **Parameters:**
  - `to` (string, required): Recipient agent kind.
  - `message` (string, required): Informational note or query.
- **Behavior:**
  - Appends `PendingMessage` with prompt prefix `[Peer Note from \(sender.displayName)]: \(message)`.

### 3. `linkc_get_inbox`
- **Parameters:** None.
- **Behavior:**
  - Returns current queue of messages, delivery status, and active provider limits.

---

## 5. Dispatcher & PTY Terminal Injection (`LinkCKit/Terminal`)

### Safe Prompt Injection
1. `TerminalSession.sendInput(text: String)`:
   - Exposes pure SwiftTerm input sending:
     ```swift
     public func sendInput(_ text: String) {
         terminalView.send(txt: text.hasSuffix("\n") ? text : text + "\n")
     }
     ```
   - Only executed when session child PID is active and session is in `.ready`, `.finished`, or `.waitingIdle` state.
2. `AppCoordinator` Queue Processor:
   - Evaluates pending messages every 0.5s or upon `HookEvent` (`stop`, `sessionStart`).
   - If recipient session does not exist in workspace, invokes `spawnTeammate(in: workspacePath, agent: chosenAgent)`.
   - Injects formatted prompt:
     ```text
     [Delegated Task from Claude Code]:
     Implement unit tests for ShellTerminalStore.swift
     ```
   - Updates message status to `.delivered`.

---

## 6. Rate Limit Detection & Auto-Reroute Engine

### 1. `LimitDetector` (`LinkCKit/Core`)
- Scans terminal output buffers and hook failure events for provider signatures:
  - **Claude Code**: Hook `stopFailure` OR terminal text matching `"You've reached your usage limit"`, `"Rate limit reached"`, `"credit balance too low"`.
  - **Codex**: Terminal text matching `"(429|Too Many Requests|quota exceeded|Rate limit exceeded)"`.
  - **Antigravity**: Terminal text matching `"(ResourceExhausted|quota limit reached)"`.
- When a match occurs, creates an `AgentLimitStatus` with default 15-minute cooldown.

### 2. Autonomous Re-Route State Machine
- When an agent running a delegated task trips a limit:
  1. Sets agent's status to `.limitReached(cooldown: ...)`.
  2. Freezes that agent's queue.
  3. Inspects candidate peer agents installed on the system:
     - Priority: Agents already running in the workspace > Installed agents that can be spawned.
     - Filters out any agent currently in a limit cooldown.
  4. Generates `.linkc/HANDOFF.md` with `git status -s`, last 50 lines of terminal output, and the uncompleted task prompt.
  5. If candidate is not running, auto-spawns it.
  6. Re-queues the message to the candidate agent with updated `rerouteCount += 1`.
  7. **Circuit Breaker**: If `rerouteCount >= 2` (or no alternative agents have quota), stops re-routing, transitions workspace to `.needsYou`, and posts an alert to the user.

---

## 7. UI Integration (`SessionList.swift`)

- In the workspace row and Option 2 stacked mini-lanes:
  - Displays rate-limit status with cooldown:
    `CODEX: ⚠️ Rate limited (resets in 12m)`
  - Displays active re-route handoff:
    `AGY: ✨ Resuming task from Codex: implementing tests...`
  - Menu bar icon flashes coral when the circuit breaker trips (all providers exhausted).

---

## 8. Testing & Validation Strategy

1. **`InboxStoreTests.swift`**:
   - Tests file locking, atomic writes, concurrent access, FIFO ordering, and message state transitions.
2. **`LimitDetectorTests.swift`**:
   - Tests regex pattern matching across mock terminal outputs for all supported agent kinds.
   - Tests cooldown expiration calculations.
3. **`AppCoordinatorRelayTests.swift`**:
   - End-to-end delegation test: Agent A sends message → auto-spawns Agent B → injects prompt into mock terminal.
   - Limit auto-reroute test: Mock limit on Agent B → auto-generates handoff → re-routes to Agent C.
   - Circuit breaker test: Verifies loop terminates safely after 2 hops.
4. **Platform & Safety Rules**:
   - Strict Swift 6 (`.v6`) concurrency compliance with 0 warnings.
   - Strictly NO mention of the forbidden word in any source, comments, or documentation.
   - All existing 452 tests must pass without regressions.

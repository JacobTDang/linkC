# Task Protocol v2: Explicit Completion, Exclusive Leases, and Loop Guard

**Date:** 2026-09-09
**Status:** Approved
**Supersedes (in part):** `2026-09-08-cross-agent-delegation-and-limit-reroute-design.md` (relay and completion sections)

---

## 1. Problem

Field feedback from an orchestrating agent that drove three vendors' CLIs through linkC:

| # | Observed failure | Root cause in current code |
|---|------------------|----------------------------|
| 1 | Completion echoes nested five deep, re-forwarding the orchestrator's own replies and two-day-old transcripts. | `AppCoordinator.notifyDelegatorOnTaskCompletion` fires on every turn end, picks "the last delivered message to this agent kind", and enqueues `[Task Completed by X] Original Task: <full prompt> Result: <30 lines of scrollback>` as an ordinary `PendingMessage`. Completion notices are themselves messages, so they become the next "last delivered task". Nothing dedupes, nothing terminates. |
| 2 | One brief delivered to two agents; both worked the same branch. | `linkc_delegate_task` only *warns* on file collisions. Re-routing enqueues a second copy of the same prompt without cancelling the first. |
| 3 | Work attributed to the wrong agent; Cursor shows PID 0; registry shows zero active agents while three are mid-task. | `MCPServer` defaults `agent` to `"claude"` and `pid` to its own `getpid()`. The blackboard prunes agents 15 min after their last heartbeat, and nothing heartbeats. |
| 4 | "Delivered" did not mean started; STOP arrived after the work was done; a task for a deleted directory was still delivered. | `MessageStatus` is `queued/delivering/delivered/failed`. `.delivered` is set the instant text is written to the PTY. No cancel, no expiry. |
| 5 | A usage-limit notice was injected as a task and then relayed as if it were the task. | `checkLimitsAndReroute` enqueues `[System Notice] …` as a normal prompt. |
| 6 | Handoff memo's Goal became "Task Completed by Cursor Agent". | `spawnTeammate` falls back to the last inbox prompt as the goal. |
| 7 | Every echo carried the full original brief. | Completion prompt embeds `currentMessage.prompt` verbatim. |
| 8 | Tool list changed mid-session; cached client calls broke. | Three tools were added in commit `a586694` while the user's session was live. No additive-only policy. |

## 2. Goals

1. A task is completed by an **explicit tool call**, never by scraping a terminal.
2. A task has **exactly one assignee** and an **exclusive lease** on its files while open.
3. Task state is truthful: `queued → delivered → started → done | failed`, plus `cancelled` and `expired`.
4. The relay **cannot loop**: completions and notices are distinct message kinds that are never treated as tasks; duplicate and framed payloads are rejected at the store boundary.
5. Identity comes from the **posting process**, and every tool call **heartbeats** presence.
6. System notices never enter a terminal.
7. Echoes are **one line plus a task id**; the full record lives in the store and is fetched by reference.
8. The MCP tool list is **additive only** within a major version.

## 3. Non-goals

- New UI. Existing dashboard surfaces gain task state fields only where they already display messages.
- Cross-workspace tasks. A task belongs to one workspace root.
- Interpreting free-text messages ("STOP") as cancels. Only `linkc_cancel_task` cancels.

## 4. Architecture

```
Delegating agent                      linkc-mcp (stdio, one per client)
  linkc_delegate_task ───────────────▶ resolves identity (arg → LINKC_AGENT → ancestor pid)
                                      heartbeats caller on blackboard
                                      InboxStore.createTask  ── refuses if lease conflict
                                            │
                                            ▼  <workspace>/.linkc/inbox.json  (v2, one flock)
                                      ┌──────────────────────────────────────────┐
                                      │ tasks:    [TaskRecord]   ← lifecycle     │
                                      │ messages: [PendingMessage] ← kind-tagged │
                                      │ agentLimits: [AgentLimitStatus]          │
                                      └──────────────────────────────────────────┘
                                            │ polled by linkC app
                                            ▼
linkC app (AppCoordinator relay)
  dispatchTasks     : queued task → framed prompt into ONE assignee session → delivered
  dispatchMessages  : .completion / .peerNote → one-line inject; .notice → never injected
  expireTasks       : missing workspace / stale queue / dead assignee → expired | failed
  relayTurnEnd      : assignee turn ends while delivered|started → ONE "ended without report" line
  reroute on limit  : cancel original task, enqueue hop+1 copy, .notice to delegator

Assignee agent
  linkc_start_task    → started
  linkc_complete_task → done | failed, one-line echo to delegator
```

All task and message writes go through `InboxStore` under a single `flock`, so a state transition and the message that announces it are atomic.

## 5. Data model (`Sources/LinkCKit/Blackboard/InboxModels.swift`)

### 5.1 `TaskState`

```swift
public enum TaskState: String, Codable, Sendable {
    case queued, delivered, started, done, failed, cancelled, expired
}
```

Open states: `queued`, `delivered`, `started`. Terminal states: `done`, `failed`, `cancelled`, `expired`.

Allowed transitions (enforced by `InboxStore`; any other transition throws `LinkCError.server`):

| From | To |
|------|----|
| `queued` | `delivered`, `cancelled`, `expired` |
| `delivered` | `started`, `done`, `failed`, `cancelled`, `expired` |
| `started` | `done`, `failed`, `cancelled`, `expired` |
| any terminal | (none) |

`delivered → done/failed` is allowed so an agent that skipped `start_task` can still report.

### 5.2 `TaskRecord`

```swift
public struct TaskRecord: Codable, Sendable, Identifiable, Equatable {
    public let id: String                 // UUID
    public let fromAgent: AgentKind
    public let toAgent: AgentKind
    public var assigneeSessionId: String? // linkC session id; set on delivery
    public let prompt: String             // full brief, stored once
    public let files: [String]            // normalized relative paths; the lease
    public var state: TaskState
    public let hop: Int                   // reroute count, 0 for original
    public let createdAt: Date
    public var deliveredAt: Date?
    public var startedAt: Date?
    public var finishedAt: Date?
    public var leaseExpiresAt: Date       // createdAt + 4h; refreshed to now + 4h on start
    public var report: TaskReport?
    public var cancelReason: String?
    public var unreportedTurnEndNotified: Bool // set once relayTurnEnd has fired
}

public struct TaskReport: Codable, Sendable, Equatable {
    public let status: String   // "done" | "failed"
    public let summary: String  // required, single paragraph
    public let commits: [String]
    public let tests: [String]
}
```

### 5.3 `MessageKind` and `PendingMessage`

```swift
public enum MessageKind: String, Codable, Sendable {
    case task        // legacy v1 rows only; v2 never creates these — tasks live in `tasks`
    case completion  // one-line "[linkC task <id8> …]" to the delegator
    case peerNote    // linkc_send_message
    case notice      // system notice; never injected into a terminal
    case command     // raw text injected verbatim (e.g. "/model sonnet" from linkc_switch_model); no frame
}
```

`PendingMessage` gains `kind: MessageKind`, `taskId: String?`, `contentHash: String` (SHA-256 of `from|to|kind|prompt`, hex). `MessageStatus` is unchanged.

### 5.4 `Inbox`

`version` becomes `2`; adds `tasks: [TaskRecord]`. Decoding a v1 file: `tasks = []`, each message gets `kind` inferred from its prefix (`[Task Completed by` → `.completion`, `[Peer Note from` → `.peerNote`, `[System Notice]` → `.notice`, else `.task`), `taskId = nil`, `contentHash` computed. v1 `.task` rows are dispatched as before so an in-flight upgrade does not lose work; they are never created again.

Pruning on save: terminal tasks older than 24 h are removed; open tasks are never pruned by age (they expire via §8.3 instead). Messages keep the current 24 h / 100-row rule.

## 6. `InboxStore` API (`Sources/LinkCKit/Blackboard/InboxStore.swift`)

New methods, all under the existing lock:

- `createTask(from:to:prompt:files:hop:force:) throws -> TaskRecord`
  - Normalizes files. If `!force` and any file overlaps an **open** task (`queued`, `delivered`, or `started`) whose `toAgent != to`, throws `LinkCError.server("lease conflict …")` naming the holder's agent kind and task id. Delegating further work on the same files to the *same* assignee is allowed; it queues behind the open task.
  - If an open task exists with identical `to` and `prompt`, returns it unchanged (idempotent).
  - Rejects `hop > 2` and prompts beginning with a frame marker (§7.4).
- `markDelivered(taskId:sessionId:)`, `markStarted(taskId:)`, `complete(taskId:report:)`, `cancel(taskId:reason:)`, `expire(taskId:reason:)` — each validates the transition table and stamps the matching date; `complete` sets `state` from `report.status`.
- `openTasks(for: AgentKind?) -> [TaskRecord]`, `task(id:) -> TaskRecord?`, `leaseHolders(for files: [String]) -> [TaskRecord]`.
- `enqueue(from:to:kind:taskId:body:)` replaces the existing `enqueue`. It:
  - Rejects `kind == .task` (v2 never creates task messages; callers use `createTask`).
  - Rejects any `body` whose first line begins with a frame marker (§7.4), for every kind. Callers pass the bare body; the store composes `prompt = frame + body` where the frame is `[linkC task <id8>] ` for `.completion`, `[Peer Note from <Agent>]: ` for `.peerNote`, and `[linkC notice] ` for `.notice`. This is the loop guard: a forwarded message can never become the body of another message.
  - Rejects a duplicate `contentHash` for the same `from → to` created within the last 24 h; returns the existing row.
- `markMessageDelivered(id:)` — renamed from `markDelivered` to disambiguate from the task method.

The existing `recordLimit` / `isAgentLimited` are unchanged.

## 7. MCP tools (`Sources/LinkCKit/MCP/MCPServer.swift`)

### 7.1 Stability policy

- Tool names, required parameters, and parameter types are never removed or changed within major version `0.x → 1.x`. New tools and optional parameters may be added.
- `serverInfo.version` becomes `0.2.0`. `capabilities.tools` becomes `{"listChanged": false}`.
- `linkc_get_inbox` is retained and extended (§7.3). Every tool currently advertised remains.

### 7.2 Identity resolution (applies to every tool)

`resolveCaller(args) -> (AgentKind, pid_t)`:

1. Explicit `agent` argument, if it parses to a non-`shell` `AgentKind`.
2. `LINKC_AGENT` environment variable (set by `MCPRegistrar`, §9).
3. `ProcessSnooper.detectAgent(inAncestorsOf: getpid())` — walk parent pids via `proc_pidinfo(PROC_PIDTBSDINFO)` up to 8 levels, return the first executable matching a known CLI, together with that pid.
4. Otherwise `AgentKind.shell` with `pid = getppid()`. Read-only tools (`linkc_get_project_context`, `linkc_check_conflicts`, `linkc_get_inbox`, `linkc_get_task`, `linkc_get_models`, `linkc_get_usage_status`) still answer; every other tool returns an `isError` result: `Cannot identify calling agent; pass agent: "claude" | "agy" | "cursor" | "codex".` Nothing defaults to `claude`, and no heartbeat is recorded for an unidentified caller.

The resolved pid is the CLI's pid from step 3 when available, else `getppid()`. Never the server's own pid.

On every successful tool call the server calls `BlackboardStore.heartbeat(agentKind:pid:)` (new method: refresh `lastHeartbeat` if a record for that pid exists; otherwise insert with `goal: "(idle)"`, `status: "active"`, no files). Heartbeat never overwrites an existing goal or claimed files.

### 7.3 Tools

Unchanged: `linkc_broadcast_intent`, `linkc_get_project_context`, `linkc_check_conflicts`, `linkc_post_note`, `linkc_switch_model`, `linkc_get_models`, `linkc_get_usage_status`, `linkc_send_message` (now `kind: .peerNote`).

For `linkc_switch_model`: when no in-process switcher exists, the command is enqueued as `kind: .command` and injected verbatim.

**`linkc_delegate_task`** — same schema plus optional `force: boolean`. Behaviour:
- Limit check as today.
- `InboxStore.createTask(...)`. On lease conflict, returns `isError` text: `Refused: <files> are leased by <Agent> under task <id8> (state). Retry with force: true to override.`
- Also records the delegator's intent on the blackboard as today.
- Success text: `Task <id> queued for Codex. It will be delivered when Codex is idle. Track with linkc_get_task("<id>").`

**`linkc_start_task`** `{ task_id }` → `delivered → started`, refreshes lease. Returns the task summary line.

**`linkc_complete_task`** `{ task_id, status: "done"|"failed", summary, commits?: [string], tests?: [string] }`
- Validates `summary` non-empty.
- `InboxStore.complete(...)`, then `enqueue(kind: .completion, taskId:, to: task.fromAgent, body: "<status> by <Agent> — <summary first line, max 200 chars>. linkc_get_task(\"<id>\") for details.")`. The stored prompt therefore reads `[linkC task <id8>] done by Codex — …`.
- Posts a `SharedNote` titled `Task <id8> <status>` containing summary, commits, tests, so the blackboard remains the durable record.

**`linkc_cancel_task`** `{ task_id, reason?, force? }` — caller must be `fromAgent` or `toAgent` (or `force: true`). Cancels; if the task was `delivered`/`started`, enqueues `kind: .completion` to `toAgent` with body `cancelled: <reason>. Stop work on it.` so the dispatcher injects one line into the assignee's terminal. A `queued` task is cancelled silently.

**`linkc_get_task`** `{ task_id }` — full record as markdown, including the full prompt and report.

**`linkc_my_tasks`** `{}` — open tasks where the caller is `toAgent`, then open tasks where the caller is `fromAgent`, each as one line: `<id8> [state] from X: <prompt first 80 chars>`.

**`linkc_get_inbox`** — adds an `## Open Tasks` section (id8, state, from → to, age, files count) before the message sections. Message rows show `kind` and `taskId`. Content bodies are truncated to the first 200 characters.

### 7.4 Frame markers

Constants in `InboxModels.swift`, used by the store's rejection rule and by the dispatcher's framing:

```
[linkC task        (v2 task delivery and all completion/cancel/turn-end lines)
[linkC notice]     (v2 notice)
[Peer Note from    (v1/v2 peer note prefix)
[Task Completed by (v1 completion)
[System Notice]    (v1 notice)
```

Task delivery framing (§8.1) is composed by the dispatcher at injection time and is not stored as a message; `createTask` rejects prompts beginning with any marker so a framed delivery pasted back by an agent can never become a new task.

## 8. Dispatcher (`Sources/LinkCKit/App/AppCoordinator.swift`, relay section)

`processPendingMessages(workspacePath:)` is split into three steps run in order each tick: `expireTasks`, `dispatchTasks`, `dispatchMessages`.

### 8.1 `dispatchTasks`

For each task in `queued` for this workspace, oldest first:
1. Pick the assignee session: a non-ended session in this workspace with `agentKind == task.toAgent`. If several, choose the one whose state is idle (`ready`, `finished`, `waitingIdle`); if none idle, wait. If none exists at all, `spawnTeammate(in:agent:goal: task.prompt)` and wait for it to become `ready`.
2. When the assignee is idle, inject the framed prompt and call `markDelivered(taskId:sessionId:)`:

```
[linkC task <id8> from Claude Code]
<prompt>

When you begin, call linkc_start_task("<id>"). When finished, call linkc_complete_task("<id>", status, summary, commits, tests). Do not paste this brief into any reply.
```

3. A task is delivered to exactly one session, once. `assigneeSessionId` is recorded; if that session later ends, the task fails (§8.3) rather than being redelivered.

### 8.2 `dispatchMessages`

For each message in `queued` for this workspace:
- `.notice` → mark delivered immediately, never injected. (It is surfaced by `linkc_get_inbox` and the dashboard.)
- `.completion`, `.peerNote` → inject into an idle session of `toAgent` (spawning as today if none), then mark delivered.
- v1 `.task` rows → dispatched as today for one upgrade cycle.

### 8.3 `expireTasks`

- Workspace directory does not exist → the relay tick returns without spawning, injecting, or writing. `inbox.json` lives inside the workspace, so there is nothing left to mark and a store write would recreate the deleted directory.
- `queued` for more than 60 min → `expired("undelivered for 60m")`.
- `delivered`/`started` whose `assigneeSessionId` no longer exists in `store.sessions` (session ended or was stopped) → `failed` with `report.summary = "assignee session ended before reporting"`, one `.completion` line to the delegator.
- `leaseExpiresAt` passed while `delivered`/`started` → `expired("lease expired")`, one `.completion` line to the delegator.

Each expiry/failure enqueues at most one `.completion` line (the store's dedupe makes this idempotent).

### 8.4 `relayTurnEnd(sessionId:)` (replaces `notifyDelegatorOnTaskCompletion`)

Called where `notifyDelegatorOnTaskCompletion` is called today (hook `.stop`, and non-Claude working → finished). For each task in `delivered`/`started` whose `assigneeSessionId == sessionId` and `unreportedTurnEndNotified == false`:
- Set `unreportedTurnEndNotified = true`.
- Enqueue `.completion` to `fromAgent` with body `<Agent> turn ended without a report. Task remains <state>; linkc_get_task("<id>") or linkc_cancel_task("<id>").`

No terminal output is read. The task stays open; the delegator decides.

### 8.5 Limit reroute (`checkLimitsAndReroute`)

- The "current task" is the newest task in `delivered`/`started` whose `assigneeSessionId == sessionId` (never derived from messages).
- Before enqueueing the hop+1 copy: `cancel(taskId: original, reason: "rerouted to <Agent> after limit")`, which releases its lease. Then `createTask(from: original.fromAgent, to: candidate, prompt: original.prompt, files: original.files, hop: original.hop + 1, force: true)` — `force` so a reroute is never blocked by an unrelated lease; the delegator learns of the reroute through the `.notice` and can cancel.
- The alert to the delegator becomes `enqueue(kind: .notice, …)`; it is no longer injected.
- Circuit breaker (`hop < 2`) unchanged.

### 8.6 Handoff memo

`spawnTeammate` and the reroute path derive `lastGoal` as: explicit `goal` argument → newest open `TaskRecord.prompt` for the workspace → blackboard `activeAgents.last.goal` → placeholder. The inbox `messages` array is never consulted for the goal.

## 9. Registrar (`Sources/LinkCKit/MCP/MCPRegistrar.swift`)

`registerServer` and `registerTomlServer` take `env: [String: String]`. `registerAll` passes `["LINKC_AGENT": "claude"]` for the two Claude files, `"cursor"` for Cursor, `"agy"` for Antigravity, `"codex"` for both Codex files. JSON form: `"env": {"LINKC_AGENT": "cursor"}`. TOML form: a `[mcp_servers.linkc-multiplier.env]` table with `LINKC_AGENT = "codex"`. Existing entries are rewritten in place.

## 10. Blackboard (`BlackboardStore`, `ProcessSnooper`)

- `BlackboardStore.heartbeat(agentKind:pid:)` as described in §7.2.
- `AppCoordinator.sampleAgentStates` additionally heartbeats every live non-shell session it owns (`agentKind`, PTY child pid), so agents that never call a tool still appear as present. Prune window stays 15 min.
- `ProcessSnooper.detectAgent(inAncestorsOf: pid_t) -> (AgentKind, pid_t)?` walks parents with a depth cap of 8.

## 11. Dashboard compatibility (`AgentDashboardAggregator`)

Replace the `msg.prompt.hasPrefix("[Task Completed by")` check with `msg.kind == .completion`. Include open `TaskRecord`s as timeline items (`state`, `from → to`, `id8`). No other UI changes.

## 12. Error handling

- All state-transition errors surface to the calling agent as `isError` tool results with the current state named, e.g. `Task 3f2a… is already done; cannot start.`
- Store lock timeouts propagate as today (JSON-RPC `-32000`).
- A corrupt `inbox.json` falls back to an empty v2 inbox (existing behaviour, now with `tasks: []`).
- Dispatcher failures (spawn error, missing session) leave the task `queued`; expiry rules bound how long.

## 13. Testing

- `InboxStoreTests`: transition table (every allowed and one disallowed edge), lease refusal and `force`, idempotent `createTask`, frame-marker rejection, `contentHash` dedupe, `hop > 2` rejection, v1 → v2 decode with kind inference, terminal-task pruning.
- `MCPServerTests` / new `MCPServerTaskTests`: each new tool's happy path and error path; identity resolution order (arg, `LINKC_AGENT`, unknown → error, never `claude`); every previously advertised tool name still present; `listChanged: false`.
- `AppCoordinatorRelayTests`: a completion is never re-echoed (two turn-ends produce one line); `.notice` is never injected; a task is delivered to one session even with two sessions of that kind; `relayTurnEnd` fires once per task; cancel injects one line to the assignee; reroute cancels the original before creating the copy; missing workspace expires tasks.
- `HandoffComposerTests` / `AppCoordinatorIntegrationTests`: goal comes from the task, not the messages.
- `MCPRegistrarTests`: `env` written in JSON and TOML forms; rewriting preserves unrelated keys.
- `ProcessSnooperTests`: `detectAgent(inAncestorsOf:)` finds a known CLI in a synthetic parent chain (or returns nil past depth 8).

## 14. Migration and rollout

- No manual migration. First save after upgrade writes `version: 2`.
- v1 `.task` rows already queued are still delivered once; new task creation always goes through `createTask`.
- Agents on cached tool lists keep working: every v1 tool name and schema is unchanged; they simply cannot report completion until they reconnect, and `relayTurnEnd` gives the delegator a one-line signal in the meantime.

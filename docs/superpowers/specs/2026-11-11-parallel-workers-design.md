# Parallel Workers: More Than One Worker of an Agent at Once

**Date:** 2026-11-11
**Status:** Approved design (branch `feat/parallel-workers`)

## 1. Problem

Jacob wants to run several workers of one agent at once: three Codex tasks should run in three Codex workers, not one after another.

Opening sessions by hand is not capped. Delegation is. `dispatchTasks` (`AppCoordinator+Relay.swift`) gathers the folder's live sessions that can carry a task. It starts a worker only when there are none. While that one worker is busy, every other task for the agent waits behind it.

## 2. Goals

- A queued task that finds no free worker of its agent and tier starts another one. There is no cap.
- Two tasks that arrive together start two workers, and the next relay passes start no more while those two boot.
- An idle worker is reused, as today.
- Claude can send a message or a model switch to the worker that holds a given task, rather than to the first session of that agent.

## 3. Non-goals

- A cap or a setting for the number of workers. Jacob chose no cap.
- A separate checkout per worker. Workers of one agent share the folder's checkout, as workers of different agents already do. The collision banner and `linkc_check_conflicts` cover it.
- Bringing every worker back after a quit. Codex, Cursor and agy can only continue a folder's newest conversation, so `RelaunchPlan` brings back one entry per folder and agent. A worker that loses is dropped, its task fails with "assignee session ended before reporting", and its delegator is told. That stays.
- The panel's New, Continue and Resume menus. They were never capped.

## 4. How a queued task finds its worker

A new pure type, `WorkerClaims`, plans each pass of `dispatchTasks`. Its inputs:

- the folder's queued tasks, in queue order;
- the folder's live sessions (not ended);
- the ids of sessions that are the assignee of a `delivered` or `started` task, which are tasks given to them and not yet reported.

It walks the tasks in order. Each task gets one decision:

- **Pinned task** (`targetSessionId` set): unchanged. If its session can carry it, the task claims that session, so no other task in the pass counts on it. The task is delivered when the session is idle and ready, and waits otherwise. It never starts a session. A pinned task whose session has ended expires, as today.
- **Unpinned task:** it claims the first session that meets all of these:
  - `canCarry(task)` is true: same agent, tier matches if the task has one, not the delegator;
  - no earlier task claimed it in this pass;
  - it is not the assignee of a `delivered` or `started` task;
  - it is idle (`ready`, `finished`, `waitingIdle`) or `starting`.

  An idle session is preferred to a starting one.
  - **Idle session claimed:** the existing readiness checks decide what happens: the injection gap, a negotiated bracketed paste, and the settle margin. If they pass, the task is delivered. If not, the task waits for that session. The paste-negotiation timeout still expires the task.
  - **Starting session claimed:** the task waits for it. A booting worker counts as taken, so no extra worker starts.
  - **No session claimed:** a worker is started, after the existing checks: the tier has a model, and OpenCode lists the model. Sessions that are `working`, `waitingPermission` or `error` are never claimed.

`WorkerClaims` decides only. It does not deliver, start, or write to the inbox. `dispatchTasks` carries out each decision with the code it has today.

Effects:

- A worker that went idle without reporting its task gets no new unpinned task. The next task gets a fresh worker instead of having its brief pasted on top of an unanswered question.
- The existing reaper closes idle extra workers: 60 s after their task ends, or after 10 minutes idle. It needs no change.

## 5. Messages and model switches by task

`linkc_send_message(to, message, from?, task_id?)` and `linkc_switch_model(agent?, model, task_id?)` take an optional `task_id`:

- `linkc_send_message` with a `task_id`: the message goes to the worker that holds that task. Without one it goes to the first live session of `to`, as today.
- `linkc_switch_model` with a `task_id`: it switches that task's worker. `agent` defaults to the task's agent.

`PendingMessage` gets an optional `toSessionId`. It is separate from `taskId`, which already means "a notice about a task, routed to its delegator". The MCP server sets `toSessionId` when the message is sent: it looks up the task (`task(matching:)`, so a short id works) and takes the task's `assigneeSessionId`.

`deliveryTarget` checks `toSessionId` first:

- If that session is live in this folder, the message goes to it.
- If that session has ended, or left the folder, the message fails with the reason "its worker ended". The message is never sent to another session of that agent.

The tools return an error, with the reason, when:

- the task does not exist;
- the task has no worker yet ("send it once the task starts");
- the task's agent differs from `to` or `agent`;
- the task's worker has ended.

A task that is finished but whose worker is still live can still be messaged, for a follow-up in the same context.

The in-app `ModelSwitcher` closure and `AppCoordinator.switchModel` take an optional session id, so they switch that one session. The tool descriptions tell Claude to pass `task_id` when more than one worker of an agent may be running.

## 6. Errors

- A launch that fails is logged and recorded in `lastSpawnFailure`, as today. The task stays queued and is retried on a later pass.
- A message whose worker has ended fails with the reason.
- The `task_id` refusals in §5 are tool errors.

## 7. Testing

TDD through the existing seams. Nothing real is launched.

- `WorkerClaims` unit tests, one for each rule:
  - an idle worker is reused;
  - a busy worker means a new spawn;
  - a starting worker is claimed, not spawned past;
  - two tasks give two spawns, and the next pass, with both starting, gives none;
  - a worker holding an unreported task is skipped;
  - a pinned task keeps its own session;
  - a tier mismatch is not claimed.
- `dispatchTasks` integration tests with the fake terminal and agent resolver:
  - three Codex tasks with one busy worker start two workers;
  - the next pass, with those two starting, starts none;
  - once idle, each task goes to a different worker.
- Message routing:
  - `toSessionId` reaches the right one of two workers;
  - an ended worker fails the message;
  - with no `toSessionId`, routing is as today.
- MCP: `task_id` on both tools, and each refusal.
- The full suite and `scripts/tsan.sh`.

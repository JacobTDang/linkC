# Parallel Workers: More Than One Worker of an Agent at Once

**Date:** 2026-11-11
**Status:** Approved design (branch `feat/parallel-workers`)

## 1. Problem

Jacob wants to run several workers of one agent at once: three Codex tasks should run in three Codex workers, not one after another.

Opening sessions by hand is not capped. Delegation is. `dispatchTasks` (`AppCoordinator+Relay.swift`) gathers the folder's live sessions that can carry a task. It starts a worker only when there are none. While that one worker is busy, every other task for the agent waits behind it.

## 2. Goals

- A queued task that finds no free worker of its agent and tier starts another one. There is no cap.
- Two tasks that arrive together start two workers, one per relay pass, and later passes start no more while those two boot.
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

Pinned tasks claim first, then the unpinned tasks in queue order, so an earlier unpinned task cannot take a pinned task's session. Each task gets one decision:

- **Pinned task** (`targetSessionId` set): unchanged. If its session can carry it, the task claims that session, so no other task in the pass counts on it. The task is delivered when the session is idle and ready, and waits otherwise. It never starts a session. A pinned task whose session has ended expires, as today.
- **Unpinned task:** it claims the first session that meets all of these:
  - `canCarry(task)` is true: same agent, tier matches if the task has one, not the delegator;
  - no earlier task claimed it in this pass;
  - it is not the assignee of a `delivered` or `started` task;
  - it is idle (`ready`, `finished`, `waitingIdle`) or `starting`.

  An idle session is preferred to a starting one.
  - **Idle session claimed:** the existing readiness checks decide what happens: the injection gap, a negotiated bracketed paste, and the settle margin. If they pass, the task is delivered. If not, the task waits for that session. The paste-negotiation timeout still expires the task.
  - **Starting session claimed:** the task waits for it. A booting worker counts as taken, so no extra worker starts.
  - **No free session, but a worker holding no task is `working` or `waitingPermission`:** the task claims that worker and waits for it. This is a worker held at a prompt before it got a task, such as a trust dialog at boot, or one busy as it boots. A worker started past it could stop at the same prompt, pass after pass. A session the user opened, or a worker busy with its own task, is never waited for this way.
  - **A session that could carry the task is `error`:** its agent is rate-limited, so the task waits, as it did before this change. No fresh worker is started into the cooldown.
  - **Otherwise:** a worker is started, after the existing checks: the tier has a model, and OpenCode lists the model. Every such task runs those checks, so a refusal is reported for each. `dispatchTasks`, not `WorkerClaims`, then launches at most one worker per agent and tier in a pass; another task that needs one waits for the next pass. So a CLI that exits at launch is retried once a pass, as before, not once per queued task.

`WorkerClaims` decides only. It does not deliver, start, or write to the inbox. `dispatchTasks` carries out each decision with the code it has today.

Effects:

- The paste-negotiation timeout counts from when the claimed session went idle, not from when the task was created, so time spent queued behind workers still booting is not held against the session.
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
- the task's agent differs from `to` or `agent`.

The MCP server runs outside the app and cannot see which sessions are live. So a worker that has ended is caught at delivery: the message fails, and the user is told (§6).

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
  - two tasks with no workers each need one, and with one worker starting the second still needs one;
  - a worker with no task held at a dialog, or busy, is waited for;
  - a rate-limited session that could carry the task holds it back;
  - a worker holding an unreported task is skipped;
  - a pinned task keeps its own session;
  - a tier mismatch is not claimed.
- `dispatchTasks` integration tests with the fake terminal and agent resolver:
  - with one busy and one idle Codex session, three Codex tasks: the idle session takes one, and the other two each start a worker, one per pass;
  - the next pass, with those two starting, starts none;
  - once idle, each task goes to a different worker;
  - a worker idle with an unreported task gets no new task, and a new worker starts.
- Message routing:
  - `toSessionId` reaches the right one of two workers;
  - an ended worker fails the message;
  - with no `toSessionId`, routing is as today.
- MCP: `task_id` on both tools, and each refusal.
- The full suite and `scripts/tsan.sh`.

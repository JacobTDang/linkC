# Stuck-task watchdog — design

**Date:** 2026-09-16
**Status:** approved (design), not yet planned or implemented

## Goal

Notice when a task that is out with a worker stops making progress, tell the delegating agent once,
and tell the user once. Nothing is cancelled, reassigned, or retried automatically.

## Non-goals

- No automatic reroute or reassignment. The synthesized reroute was removed on 2026-09-12 after a
  false positive; a notice is the whole action.
- No change to the per-second `blackboard.json` heartbeat churn. That stays deferred.
- No new agent cooperation: nothing here depends on a worker calling a tool to report progress.

## What exists today

- `AppCoordinator+Relay.processPendingMessages` runs once a second per workspace, in phases:
  `expireTasks` → `launchVerifications` → `dispatchTasks` → `dispatchMessages`. Every phase returns
  `true` when the inbox lock was still contended after `Self.relayLockTimeout`, which ends the tick.
- `expireTasks` fails a `delivered`/`started` task whose assignee session has ended, and expires one
  whose `leaseExpiresAt` has passed. `TaskRecord.leaseDuration` is 4 hours, renewed when a worker
  starts. Between those two, a live-but-hung worker holds a task for up to 4 hours unnoticed.
- `relayTurnEnd` sends the delegator one line per task when a worker's turn ends with no report
  (`TaskRecord.unreportedTurnEndNotified` makes it once-only) and posts one user notification.
- `echo(_:for:inboxStore:)` enqueues that line as a `.completion` message addressed **by agent kind**
  (`to: task.fromAgent`), not to the session that delegated.
- `dispatchMessages` delivers a queued message to the first live session in the workspace whose
  `agentKind` matches, and only while `isIdle(state)` (`ready`, `finished`, `waitingIdle`). If no
  session of that kind is alive it **spawns one** to receive the message.
- Queued messages never expire. Delivered ones are pruned after 24h; total history caps at 100 with
  every queued row kept.
- `AppCoordinator.sampleAgentStates` already reads each terminal's visible rows once a second for
  state detection (`TerminalSession.liveActivityLine()`, `showsTrustPrompt()`).

## Signals

A task in `delivered` or `started` is watched. It is stuck when any of these holds. Each threshold is
measured with `AppCoordinator`'s injectable `now`.

1. **Never started — 10 minutes.** `state == .delivered` and `now - deliveredAt > 10m`. The brief was
   typed in but the worker never called `linkc_start_task`.
2. **Waiting on the user — 5 minutes.** The assignee session's state is `.waitingPermission` and has
   been for more than 5 minutes (`Session.stateChangedAt`). Covers a question, a plan approval, and a
   folder-trust dialog.
3. **Gone quiet — 15 minutes.** The assignee session's state is `.working` and its screen signature
   (below) has not changed for more than 15 minutes.
4. **Notice cannot land — 5 minutes.** A `.completion` message about a task has been `queued` for
   more than 5 minutes (`PendingMessage.createdAt`). This one is about the orchestrator, not the
   worker, and is reported only to the user.

A long quiet build or test run is indistinguishable from a hang from outside. Because the only action
is a notice, a false alarm costs one line and one notification.

### Screen signature

`TerminalSession` gains `screenSignature() -> String`: the visible non-blank rows, excluding any row
that carries a live marker or is a spinner row, joined and hashed. `TerminalPreview.isWorkingFooter`
and `spinnerPhrase` already decide exactly that and are currently `private`; this change exposes one
helper over them (`isLiveMarkerRow(_:)`) rather than restating their rules. A spinner's own ticking timer therefore
never counts as progress, while tool output, new lines, and status changes do.

`AppCoordinator` keeps `[sessionId: (signature: String, since: Date)]` in memory, updated inside the
existing once-a-second row read in `sampleAgentStates`. Nothing is written to disk; a restart starts
the clock over.

## Actions

For each stuck spell, exactly once:

- **The delegating agent gets one line**, enqueued like `relayTurnEnd`'s, naming the task's short id,
  the reason in plain words ("delivered 10m ago, never started"), and the two calls that act on it:
  `linkc_get_task("<id>")` and `linkc_cancel_task("<id>")`.
- **The user gets one notification**, matching the existing turn-end alert's shape: what is stuck and
  that the delegator was told.
- **Signal 4 notifies the user only** — the orchestrator is by definition not receiving anything.

Once-only is recorded by a new optional field on `TaskRecord`, `stuckNotifiedAt: Date?`, alongside
`unreportedTurnEndNotified`, with an `InboxStore.markStuckNotified(taskId:timeout:)` mirroring
`markUnreportedTurnEndNotified`. The field is optional because `TaskRecord` uses synthesized
`Codable`: a required field would make every task row written before this change unreadable and take
the inbox with it.

**Recovery:** when the task moves (reaches `started`, or its assignee leaves the stuck condition —
screen changed, prompt answered), `stuckNotifiedAt` is cleared, so a later stall reports again. No
"recovered" message is sent.

Signal 4's once-only mark is in-memory (`[messageId: Date]`), so a restart may warn once more about a
notice that is still queued. That is deliberate: a notice nobody can receive should not go silent
forever because linkC restarted.

## Routing changes

- A `.completion` message carrying a `taskId` is delivered to **the session that delegated that task**
  (`TaskRecord.fromSessionId`) when that session is alive and idle.
- If that session is gone, it falls back to another live session of the same agent kind, as today.
- If no session of that kind is alive, the message **waits**. `dispatchMessages` no longer spawns a
  session to deliver a non-`.task` message; spawning stays for task briefs only.

## Where it runs

A new phase, `watchStuckTasks(workspacePath:inboxStore:)`, runs after `expireTasks` and before
`launchVerifications`, so a notice it enqueues is dispatched in the same tick. It follows the phase
convention exactly: returns `true` on a lock timeout to end the tick, logs other failures with
`NSLog` rather than throwing, and never blocks the main actor.

Order matters: `expireTasks` first, so a task already dead (assignee ended, lease lapsed) is failed or
expired rather than reported stuck.

## Testing

- Thresholds: the relay tests' `ControllableClock` with `AppCoordinator`'s injectable `now`; no test
  waits out a real threshold.
- Signals 2 and 3: the relay tests' scripted fake agent in a real terminal (the seam the trust-dialog
  test uses) draws a prompt or a frozen screen, and a spinner-only redraw proves a ticking timer is
  not progress.
- Signal 1: task rows with a back-dated `deliveredAt`.
- Signal 4: a queued `.completion` with no idle session of its agent kind.
- Once-only and recovery: a second tick must not repeat a notice; movement must clear the mark and a
  later stall must report again.
- Routing: a workspace with two sessions of the delegator's kind must deliver to the one that
  delegated; with none alive, nothing is spawned and the message stays queued.
- Every new test is revert-proofed: break the behaviour, watch that test fail, restore.

## Known gaps

- A worker that is genuinely slow and quiet (a long test run) is reported stuck. Accepted: the action
  is a notice.
- Screen signatures and the signal-4 marks do not survive a restart.
- A session's `.waitingPermission` for a non-Claude agent comes only from trust-dialog detection, so
  signal 2 covers a Codex or agy question prompt only if it is a trust dialog.

# Session lifecycle — design

**Date:** 2026-09-20
**Status:** approved (design), not yet planned or implemented

## Goal

Relaunching linkC brings back exactly the sessions it should, each on the conversation it was on,
never two on one; and agents linkC started for tasks stop costing memory once they are done.

## Non-goals

- No change to how a session is launched fresh, stopped by hand, or restored from Earlier.
- No closing of any session the user opened, ever.
- No new way to get a conversation id from Cursor, agy, or Codex; they still report none.

## What happens today (verified 2026-09-20)

This morning's relaunch brought back 11 agents, with three duplicated pairs: two Claude sessions in
`linkC` on one conversation, two Claude sessions in `circuit_mcp` continuing one conversation, and
two agy sessions in `linkC` continuing one agy conversation. Causes, all in `AppCoordinator` and
`WorkspaceManifest`:

1. **Ids get lost.** `launch(...)` passes `resumeId` to the CLI but never puts it on the new
   in-memory `Session`, which learns its `claudeSessionId` only when a hook arrives.
   `prepareForShutdown` — called on every panel hide via `flushStateToDisk` — upserts each live
   session's in-memory id, so a restored session that has not reported yet has its saved id wiped.
2. **Relaunch continues blindly.** `restoreActiveSessions` relaunches every entry marked active; an
   entry with no id gets `--continue`, which joins the folder's newest conversation. Every id-less
   entry of one agent in one folder therefore lands on the same conversation. The manual `restore(_:)`
   path already refuses a second `--continue` in an occupied folder; the relaunch path does not.
3. **Workers never end.** A session the relay spawns to carry a task (`dispatchTasks` →
   `spawnTeammate`) stays alive after its task ends and is revived on every relaunch. On 2026-09-18,
   10 agents held about 3.5 GB.

## Design

### 1. Keep conversation ids

- `launch(...)` records `resumeId` on the `Session` it creates, so the id is known from the first
  moment and survives the next save.
- `prepareForShutdown` never replaces a saved id with nil: when a live session has no id yet, the
  manifest keeps the one it has.

### 2. Relaunch without duplicates

A pure relaunch plan decides, for the manifest entries marked active at quit:

- **Claude with an id:** resume that conversation (`--resume <id>`). When several entries carry the
  same id, one comes back — the last in manifest order — and the others go to Earlier.
- **No id** (Cursor, agy and Codex always; Claude when never bound): at most one entry per
  folder and agent continues the folder's latest conversation — the last of them in manifest order,
  the most recently launched. The others go to Earlier, where restoring by hand refuses to reopen a
  conversation that is already live — a second continue in an occupied folder for any agent, or a
  Claude id a live session already carries.
- **The user's session beats a worker.** When entries competing for one conversation include the
  user's own, the last *user* entry wins, whatever a worker's position in manifest order; a worker
  only wins a contest with no user entry in it. A worker that loses is dropped, never sent to
  Earlier (see §3).
- **Workers:** see §3 — a worker comes back only while it holds an open task.

"Go to Earlier" means the entry is kept, stamped as ended, and shown under Earlier like any
session that ended.

A workspace deleted since quit is left alone: checking a worker's open tasks must not itself
recreate the folder, so any entry pointed at it — worker or the user's own — never launches into
a folder the check silently brought back.

### 3. Workers

- **What a worker is.** A session linkC starts to carry a delegated task — the relay's spawn in
  `dispatchTasks`. Every other session is the user's: one they open, restore, or add with the
  project row's ＋. `Session` and `RestorableSession` carry `isWorker: Bool`; the manifest field is
  optional on decode (an old manifest's entries read as the user's).
- **Opening one makes it the user's.** `focusSession` clears `isWorker`: once the user opens a
  worker's terminal, they are using it, and it is never closed automatically. A relaunch only ever
  puts the user's own entries on screen (a worker relaunches unselected), so a worker never
  appears there without `focusSession` having run.
- **The worker on screen is never closed.** `isWorker` can end up true for the terminal on screen
  through a path other than `focusSession` — the selection falling back to the newest terminal
  when the one in view closes, for instance. Whatever the path, the idle close skips whichever
  session is currently selected, so it never closes out from under the user.
- **Idle close.** A worker is closed when all hold:
  - it holds no open task (`TaskRecord.assigneeSessionId` is this session and `state.isOpen`);
  - its state is `ready`, `finished`, or `waitingIdle` — never `starting`, `working`,
    `waitingPermission`, or `error`;
  - it has been in that idle state for at least **10 minutes** (`stateChangedAt`).

  On top of `WorkerReaper`'s own criteria above, the coordinator's closing loop skips whichever
  session is currently on screen — see "The worker on screen is never closed" above.

  Closing is the same as ✕: the process is terminated and the session cleaned up. A worker's
  manifest entry is removed rather than stamped ended, so it does not appear under Earlier; its
  report is already in the task record. This also applies when a worker exits on its own.
- **Relaunch.** A worker whose entry is active at quit comes back only while it still holds an
  open task (checked against that workspace's inbox at launch); otherwise its entry is removed.

### Where it runs

- The idle check is a new phase in the relay's per-workspace tick (`processPendingMessages`), after
  `watchStuckTasks`, reading the open tasks the tick already loads. It follows the phase convention:
  returns `true` on an inbox lock timeout to end the tick, logs other failures with `NSLog`.
- The relaunch plan runs once in `restoreActiveSessions`, reading each workspace's open tasks.

## Architecture

- **`RelaunchPlan`** (LinkCKit, pure): from the active manifest entries and each workspace's open
  task assignees, returns which entries to resume by id, which single entry per folder and agent to
  continue, which go to Earlier, and which worker entries to drop.
- **`WorkerReaper`** (LinkCKit, pure): from the live sessions, the open task assignees, `now`, and
  the grace, returns the session ids to close.
- `AppCoordinator` gains the id fixes, `isWorker` plumbing (`spawnTeammate(..., asWorker:)` from the
  relay only), adoption in `focusSession`, worker-aware cleanup, the plan in
  `restoreActiveSessions`, and the reaper phase.

## Error handling

- An inbox that cannot be read at relaunch is logged; that workspace's workers are treated as
  holding no task and are not brought back. The user's own sessions are unaffected.
- A reaper phase that cannot read the inbox closes nothing that tick.

## Testing

- `RelaunchPlanTests`: resume by id; one of several same-id entries; one `--continue` per folder
  and agent, the newest winning, the rest to Earlier; two agents in one folder each get their own
  continue; a worker with an open task comes back, one without is dropped; an old manifest's entries
  count as the user's.
- `WorkerReaperTests`: closes an idle worker past 10 minutes; keeps one at 9 minutes, one working,
  one waiting on a prompt, one holding an open task, and every user session.
- Coordinator tests through the existing seams: a restored session keeps its id through a save
  before any hook arrives; `focusSession` adopts a worker; a closed worker leaves no Earlier entry.
- Each new test is revert-proofed.

## Known gaps

- Cursor, agy and Codex report no conversation id, so a second session of one of them in one folder
  can come back only through Earlier, by hand — and that restore continues the same latest
  conversation, not the one it was on.

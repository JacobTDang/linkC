# Verified Task Completion: Tests in the Brief, linkC Adjudicates

**Date:** 2026-09-10
**Status:** Approved design, not yet implemented
**Depends on:** Task protocol v2 (PR #28) merged to `main`
**Followed by:** Spec two — job queue promotion (push delivery, job kinds, retry, removal of terminal scraping)

## 1. Problem

In task protocol v2, completion is a worker's self-report. `linkc_complete_task` moves a task to `done` or `failed` based on the worker's own `status` argument. It sends the first 200 characters of the worker's summary to the delegator and copies the full summary onto the blackboard as a shared note.

This causes two problems:

1. **A self-report cannot be trusted.** A worker can run a narrower command than the full suite, run it on another branch, weaken a failing test, or not run it at all. Two agents have already given contradictory accounts of the same repository state. Nothing in linkC could decide between them, so the disagreement was pasted into a terminal for a person to settle.
2. **The delegator reads the detail anyway.** Because the one-line result cannot be trusted, the delegator checks the detail, and the detail is what fills its context. A shorter self-report saves nothing.

## 2. Goals

- A verified task is `done` only when linkC itself has run the task's command and the command has passed.
- The delegator writes the tests before it delegates. The worker cannot change them.
- linkC refuses a brief whose tests already pass, before any worker sees it.
- The delegator receives exactly one line per task outcome. All detail stays in the store.
- Tasks without tests still work. They are labelled `unverified` everywhere they appear.

## 3. Non-goals

- Retry, backoff, and dead-letter handling. A failed verdict is final, and the delegator decides what to do next. (Spec two.)
- Push delivery. Verification uses the existing relay poll. (Spec two.)
- Removing terminal scraping (`liveActivityLine`, `sampleForegroundAgent`, `checkLimitsAndReroute`). (Spec two.)
- Verifying in an isolated worktree. Verification runs in the task's workspace. We will reconsider this only if the two interfere.
- Parsing test-framework output. The verdict uses only the exit status.
- Running verification anywhere other than the local machine.

## 4. Architecture

```
delegator                linkc-mcp (stdio)              linkC app (relay tick)                worker
─────────                ─────────────────              ──────────────────────                ──────
commit tests at base
delegate_task(verify) ─► validate refs with git
                         task → gating
                                                        gate: run command at base
                                                          exit 1–125 → queued
                                                          otherwise  → cancelled ─► 1 line ─► delegator
                                                        dispatch (unchanged) ───────────────► implement, commit
                         complete_task(sha) ◄───────────────────────────────────────────────
                         validate sha, task → reported
                                                        verify at sha → done | failed ─► 1 line ─► delegator
```

These rules always apply:

- **The worker never sets `done` or `failed`.** The worker can only move its task to `reported`. Only the app can move a task out of `reported`.
- **Commands run in the app, never in `linkc-mcp`.** The MCP process is a short-lived stdio server, and its tool calls must return quickly. It does only fast git lookups (`rev-parse`, `cat-file`).
- **A verdict is data, not an exception.** Every failure becomes a verdict with a stated reason. This includes a failed test, a timeout, a missing binary, and a TCC denial. linkC does not hide a failure, and it does not silently try again.

## 5. Data model (`Sources/LinkCKit/Blackboard/InboxModels.swift`)

### 5.1 `TaskState`

There are two new states. Both are open, so the task keeps its file lease while in either state:

```swift
case gating      // has a verification; linkC has not yet confirmed that the tests fail at base
case reported    // the worker has reported; linkC has not yet given its verdict
```

`isOpen` is `true` for `gating`, `queued`, `delivered`, `started`, and `reported`.

This is the complete transition table. Any transition not in the table is rejected:

| From | To |
|---|---|
| `gating` | `queued`, `cancelled`, `expired` |
| `queued` | `delivered`, `cancelled`, `expired` |
| `delivered` | `started`, `reported`, `failed`, `cancelled`, `expired` |
| `started` | `reported`, `failed`, `cancelled`, `expired` |
| `reported` | `done`, `failed`, `cancelled`, `expired` |

Two v2 transitions are removed: `delivered → done` and `started → done`. The `delivered → failed` and `started → failed` transitions stay. The expiry sweep uses them when an assignee's session ends before it reports (§8.5). No worker-facing API can reach them.

### 5.2 `Verification` and `Verdict`

```swift
public struct Verification: Codable, Sendable, Equatable {
    public let branch: String
    public let baseSha: String       // full 40-character SHA, resolved at delegation
    public let command: String       // run as: <login shell> -l -c <command>
    public let testPaths: [String]   // relative to the repository root; checked for changes
    public let timeoutSeconds: Int   // 1...3600, default 600
}

public struct Verdict: Codable, Sendable, Equatable {
    public let passed: Bool          // true if the check succeeded (see below)
    public let sha: String?          // the commit the command ran at; nil if it never ran
    public let exitStatus: Int32?    // nil if the command never ran
    public let reason: String?       // set whenever passed == false
    public let stdoutTail: String    // last 2,000 characters
    public let stderrTail: String    // last 2,000 characters
    public let ranAt: Date
}
```

`passed` is `true` when the check succeeds:

- **Verification** passes only when the exit status is exactly 0.
- **The gate** passes only when the exit status is from 1 to 125. That range means the tests ran and failed, which is what a correct brief needs.
- For the gate, any other exit status refuses the brief:
  - 0 means that the tests already pass.
  - 126 and 127 mean that the shell could not run the command.
  - 128 or higher means that a signal stopped the command.

These ranges come from POSIX shell conventions, not from one test framework. They are correct for `swift test`, `pytest`, `go test`, and `cargo test`.

### 5.3 `TaskRecord`

There are three new optional fields:

```swift
public var verification: Verification?  // nil → unverified task
public var gate: Verdict?               // set when the gate runs
public var verdict: Verdict?            // set when a verified task gets its verdict
```

A task is **unverified** only when `verification == nil`. There is no separate flag.

### 5.4 `TaskReport`

```swift
public struct TaskReport: Codable, Sendable, Equatable {
    public let status: String      // "done" | "failed" — what the worker claims
    public let summary: String     // 1...1,000 characters
    public let sha: String?        // required when the task has a verification and status == "done"
    public let commits: [String]
}
```

The `tests` field is removed. It held the worker's own list of passing tests, which has no value when linkC runs the command itself. `JSONDecoder` ignores the key in existing files.

## 6. `InboxStore` API (`Sources/LinkCKit/Blackboard/InboxStore.swift`)

- **`createTask(from:to:prompt:files:hop:force:verification:)`**: `verification` is optional. A task with a verification starts in `gating`. A task without one starts in `queued`. Validation throws `InboxError.invalidVerification(reason)` for any of these conditions:
  - The command is empty.
  - `testPaths` is empty.
  - `baseSha` is not 40 lowercase hex characters.
  - `timeoutSeconds` is outside `1...3600`.

  The dedupe key (an open task with the same assignee and prompt) also includes `baseSha`. If you delegate the same prompt again against a new base, you get a new task.
- **`reportTask(taskId:report:)`**: This replaces `completeTask`. It moves a task from `delivered` or `started` to `reported`. It throws in these conditions:
  - `summaryEmpty` if the summary is empty.
  - `summaryTooLong(count)` if the summary is longer than 1,000 characters.
  - `shaRequired` if the task has a verification, `status == "done"`, and `sha` is nil.

  It sets `leaseExpiresAt` to the current time plus `TaskRecord.leaseDuration`. This prevents a late report from expiring while it waits for its verdict. It adds no message to the queue.
- **`resolveGate(taskId:verdict:)`**: If `verdict.passed` is true, it moves the task from `gating` to `queued`. If not, it moves the task to `cancelled` and sets `cancelReason = verdict.reason`. In both cases it stores `gate`.
- **`adjudicate(taskId:verdict:)`**: This is for a task that has a verification. If `verdict.passed` is true, it moves the task from `reported` to `done`. If not, it moves the task to `failed`. It stores `verdict` and sets `finishedAt`.
- **`acceptUnverified(taskId:)`**: This is for a task that has no verification. It moves the task from `reported` to `done` or `failed`, as `report.status` specifies. It stores no verdict. It throws if the task has a verification.

`markTaskDelivered`, `markTaskStarted`, `cancelTask`, and `expireTask` do not change. `completeTask` is removed.

## 7. MCP tools (`Sources/LinkCKit/MCP/MCPServer.swift`)

The v2 stability policy (v2 spec §7.1) applies. Tool names, required parameters, and parameter types do not change. Only optional parameters are added. `serverInfo.version` changes to `0.3.0`.

### 7.1 `linkc_delegate_task`

This tool gets an optional `verify` object:

```json
"verify": {
  "branch": "task/upload-retry",
  "base_sha": "3f9e2c1",
  "command": "swift test --filter UploadRetryTests",
  "test_paths": ["Tests/LinkCKitTests/UploadRetryTests.swift"],
  "timeout_seconds": 600
}
```

`timeout_seconds` is optional. Before the tool creates the task, it does fast git lookups in the workspace. It returns `isError` at the first check that fails:

1. `base_sha` must resolve to a commit (`git rev-parse --verify <base>^{commit}`). The tool stores the full SHA.
2. `branch` must resolve, and its tip must equal `base_sha`. The tests must be committed on the branch that the worker will use.
3. Each entry in `test_paths` must exist at `base_sha` (`git cat-file -e <base>:<path>`).

If all the checks pass, the tool returns one line: `Task a1b2c3d4 created. linkC will confirm the tests fail at 3f9e2c1 before delivery.`

### 7.2 `linkc_complete_task`

- **`sha`**: This is a new parameter. The schema shows it as optional, as the stability policy requires. At runtime it is required when the task has a verification and `status` is `done`. When it is present, it must resolve to a commit in the workspace.
- **`tests`**: This parameter stays in the schema. Its description says that it is deprecated and ignored. Removing it would break the stability policy.
- **`summary`**: This parameter has a limit of 1,000 characters. The tool rejects a longer summary and gives the limit. This change makes a required parameter stricter on purpose. The parameter is still a string, so the policy is kept. But an old caller that sends a long summary now gets an error and must send a shorter one.

The tool calls `reportTask` and returns one line: `Reported. linkC is verifying at 7d8e9f0.` or `Reported. Unverified task.` It no longer adds a completion message to the queue, and it no longer writes a blackboard note.

### 7.3 `linkc_get_task`

This tool also returns `verification`, `gate`, and `verdict`. It is the only place where the output tails are available.

## 8. Verification

### 8.1 `ProcessRunner` (`Sources/LinkCKit/Config/ProcessRunner.swift`)

The protocol gets a single requirement: a capturing call that returns the exit status as data.

```swift
public struct ProcessResult: Sendable, Equatable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
}

public enum ProcessRunnerError: Error, Equatable {
    case timedOut(seconds: Int)
}

public protocol ProcessRunner: Sendable {
    func runCapturing(_ executable: String, args: [String], cwd: URL?, timeout: TimeInterval) async throws -> ProcessResult
}
```

`runCapturing` throws only if the process cannot start or if it times out (`ProcessRunnerError.timedOut`). It returns a non-zero exit status. It does not throw it.

`run` becomes a protocol extension built on `runCapturing`. Its behavior stays exactly as it is now:

- On a non-zero status, it throws `LinkCError.process` with the `meaningfulStderr` text.
- On `timedOut`, it throws the same `LinkCError.process("… timed out after Ns")` message as now.

The five services that call `run` do not change. The existing `ProcessRunnerTests` are the regression guard, and they must pass without changes.

`LiveProcessRunner` continues to read both pipes at the same time, because of the 64KB pipe limit. Verification output is larger than the output of any CLI that linkC runs now.

The two test doubles (`FakeRunner`, `ScriptedRunner`) implement `run` now. They will implement `runCapturing` instead.

### 8.2 `GitClient` (new, `Sources/LinkCKit/Git/GitClient.swift`)

```swift
public struct GitClient: Sendable {
    public init(runner: any ProcessRunner = LiveProcessRunner(), gitPath: String = GitClient.resolveGit())
    public func headSha(in workspace: URL) async throws -> String
    public func resolveCommit(_ rev: String, in workspace: URL) async throws -> String
    public func isClean(in workspace: URL) async throws -> Bool
    public func isAncestor(_ ancestor: String, of descendant: String, in workspace: URL) async throws -> Bool
    public func changedFiles(_ paths: [String], from: String, to: String, in workspace: URL) async throws -> [String]
    public func fileExists(_ path: String, at rev: String, in workspace: URL) async throws -> Bool
    public func modifiedFiles(in workspace: URL) async throws -> [String]
}
```

`GitClient` uses `runCapturing`, not `run`, because git gives some answers through its exit status. For example, `merge-base --is-ancestor` and `cat-file -e` exit with 1 to mean *no*. Exit statuses 0 and 1 are answers. Any other status throws an error that contains git's stderr.

`isClean` is true when `git status --porcelain` gives no output. Untracked files count as changes, because an untracked source file changes the build even though it is not in the commit. Ignored files, for example `.build`, do not count.

`resolveGit()` tries `/usr/bin/git`, `/opt/homebrew/bin/git`, and `/usr/local/bin/git`, in that order. These are the same paths that the two current git helpers use. If it finds none, it throws an error.

### 8.3 `VerificationRunner` (new, `Sources/LinkCKit/Verification/VerificationRunner.swift`)

```swift
public struct VerificationRunner: Sendable {
    public init(git: GitClient, runner: any ProcessRunner, shell: String = ShellResolver.loginShell())
    public func gate(_ v: Verification, in workspace: URL) async -> Verdict
    public func verify(_ v: Verification, sha: String, in workspace: URL) async -> Verdict
}
```

Neither method throws. If `git` or the runner gives an error, the method returns `passed: false` with the error text as the reason. Neither method reads from or writes to the store.

The command always runs as `runCapturing(shell, args: ["-l", "-c", v.command], cwd: workspace, timeout: v.timeoutSeconds)`. The login shell loads PATH and the dotfiles, as `ShellCoordinator` does for dev commands. The PATH that a GUI app inherits does not find `swift`.

**`gate`** does these steps. It stops at the first step that fails:

1. Make sure that HEAD equals `baseSha`. If it does not, the reason is *HEAD is `<head8>`, expected base `<base8>`*.
2. Make sure that the tree is clean. If it is not, the reason is *working tree is not clean*.
3. Run the command.
4. Make sure that HEAD still equals `baseSha` and that the tree is still clean. If not, the reason is *workspace changed during the gate*.
5. Check the exit status against §5.2:
   - 1–125: the gate passes.
   - 0: the reason is *tests already pass at `<base8>`*.
   - 126 or 127: the reason is *command could not run (exit `<n>`)*.
   - 128 or higher: the reason is *command was killed (exit `<n>`)*.

**`verify`** does these steps. It stops at the first step that fails:

1. Make sure that HEAD equals `sha`.
2. Make sure that the tree is clean.
3. Make sure that `sha` descends from `baseSha`. If it does not, the reason is *`<sha8>` does not descend from base `<base8>`*.
4. Make sure that `changedFiles(testPaths, from: baseSha, to: sha)` is empty. If it is not, the reason is *test files modified: `<paths>`*. This step comes before the command, so changed tests never run.
5. Run the command.
6. Make sure that HEAD still equals `sha` and that the tree is still clean. If not, the reason is *workspace changed during verification*.
7. Pass only if the exit status is 0. If it is not, the reason is *tests failed at `<sha8>` (exit `<n>`)*.

If the command times out (gate step 3 or verify step 5), the reason is *timed out after `<n>`s*.

### 8.4 Relay integration (`Sources/LinkCKit/App/AppCoordinator+Relay.swift`)

`processPendingMessages(workspacePath:)` gets a fourth step after `dispatchMessages`: `launchVerifications(workspacePath:inboxStore:)`. This step is synchronous and never blocks the main actor. It does these steps:

1. **Settle the reports that do not need a run, immediately.**
   - A `reported` task with no verification goes through `acceptUnverified`.
   - A `reported` task with a verification whose report says `failed` gets a verdict without a run: `passed: false`, the reason *worker reported failure*, and nil `sha` and `exitStatus`.
2. **Start a maximum of one run for each workspace, and a maximum of `maxConcurrentVerifications` (2) runs in total.**
   1. If the workspace is already in `verificationsInFlight`, return. That set is a `Set<String>` isolated to the main actor. Also return if the set already holds two entries.
   2. Take the oldest task (by `createdAt`) that is in `gating`, or that is in `reported` and has a verification.
   3. Add the workspace to the set.
   4. Start a `Task` that awaits `VerificationRunner.gate` or `.verify`. This work runs off the main actor, because `LiveProcessRunner` detaches.
   5. Back on the main actor, call `resolveGate` or `adjudicate`, send the message (§9), and remove the workspace from the set.

   The next tick takes the next task.

There is one run for each workspace at a time because SwiftPM locks `.build`. Two runs in the same workspace would wait for each other, and they would also compete with the worker's builds. The limit of two in total stops several full builds from slowing the machine while agents are also building.

Verification runs only when the relay ticks the workspace. If there is no live session in the workspace, nothing ticks it and the task waits. The task runs as soon as a session opens in that workspace, and the expiry rules in §8.5 limit the wait. While the task waits, there is nobody to deliver the line to anyway.

If a task was cancelled or expired while its run was in progress, the store rejects the transition. linkC logs the rejection with the task id and discards the verdict. The task has already sent its own outcome line.

### 8.5 Expiry (`expireTasks`)

`switch task.state` gets two new cases:

- **`gating`:** If the task is older than 60 minutes, it goes to `expired` with the reason *gate did not run within 60m*. This happens when the app is not running.
- **`reported`:** Only the lease rule applies. If `leaseExpiresAt` has passed, the task goes to `expired`. The assignee-liveness rule does **not** apply, because a worker's session is allowed to end after it reports.

## 9. Messages

The relay sends each outcome line as a `.completion` message, with the v2 frame `[linkC task <id8>]`. This is the full list of message bodies:

| Outcome | Body |
|---|---|
| Gate: the tests already pass | `cancelled — tests already pass at 3f9e2c1; brief refused` |
| Gate: the command could not run | `cancelled — gate failed: <reason>` |
| Verified, passed | `done — verified at 7d8e9f0` |
| Verified, failed | `failed — <reason>` |
| Unverified, reported done | `done (unverified)` |
| The worker reported failure | `failed — worker reported failure` |

If the gate confirms that the tests fail, linkC sends no message. The delegator sees only refusals and final outcomes. The v2 suffix `linkc_get_task("<id>") for details.` is removed, because every agent already has the tool in its tool list.

## 10. Dashboard (`Sources/LinkCKit/Blackboard/AgentDashboardAggregator.swift`)

- The body of the task item is one of these:

  | Task | Body |
  |---|---|
  | Open | The prompt |
  | Verified, `done` | *verified at `<sha8>`* |
  | Unverified, `done` | *unverified* |
  | `failed`, `cancelled`, or `expired` | The stored reason: `verdict.reason`, else `cancelReason`, else `report.summary` |

  The title keeps its `[state]` suffix, so `[gating]` and `[reported]` show as soon as a task enters those states.
- This body is how every failure reason gets to the UI. If a verdict is only in the store, nobody sees it.
- `modifiedFiles` moves to `GitClient`, so `aggregateProject` and `aggregateGlobal` become `async`. The app already runs aggregation as a background task. The aggregator and dashboard tests also become `async` and use `await`.

## 11. Error handling

| Case | Outcome |
|---|---|
| `verify` refers to a commit, branch, or test path that does not exist | `linkc_delegate_task` returns `isError`, and no task is created |
| The branch tip is not `base_sha` | `isError`, and no task is created |
| Gate: HEAD is not base, the tree is not clean, or the workspace changed | `cancelled`, with the reason |
| Gate: exit 0, 126, 127, or 128 and higher | `cancelled`, with the reason |
| A verified `done` report has no `sha` | `linkc_complete_task` returns `isError`, and the state does not change |
| `sha` is not a commit | `isError`, and the state does not change |
| The summary is empty or longer than 1,000 characters | `isError`, with the limit given |
| Verify: HEAD is not `sha`, the tree is not clean, or `sha` does not descend from base | `failed`, with the reason |
| Test files were changed | `failed — test files modified: <paths>` |
| Timeout | `failed — timed out after <n>s` |
| Command not found, TCC denial, or the process cannot start | `failed`, with the stderr tail as the reason |
| The app is not running when the gate or the report arrives | The task waits, and the expiry rules in §8.5 apply |
| The app quits during a run | The task stays in `gating` or `reported`, and it runs again after the app starts. The orphaned child process continues until it is done, so the next run can wait for its `.build` lock. |
| A verdict arrives for a task that has already ended | linkC logs it with the task id and discards the verdict |

## 12. Testing

Write each test before its implementation. The test doubles stay in the test target only.

- **`TaskState`:** Each transition in §5.1 succeeds, and `delivered → done` and `started → done` are rejected.
- **`InboxStore`:**
  - A task created with a verification starts in `gating`, and each validation error occurs.
  - `reportTask` accepts a 1,000-character summary and rejects a 1,001-character summary. `shaRequired` occurs, and the lease is extended.
  - `resolveGate`, `adjudicate`, and `acceptUnverified` each move tasks to both of their outcomes.
  - An `inbox.json` written before this spec, with `tests` in its reports and no verification fields, still decodes.
- **`ProcessRunner`:**
  - `runCapturing` returns a non-zero status without throwing.
  - A timeout throws `ProcessRunnerError.timedOut`.
  - The existing `ProcessRunnerTests` pass without changes. This proves that `run` still gives the same error text for a non-zero exit and for a timeout.
- **`GitClient`:** Test against a real temporary repository:
  - `headSha` and `resolveCommit`
  - `isClean`: a changed tracked file is a change, an untracked file is a change, and an ignored file is not
  - `isAncestor`: it returns true, returns false, and throws for a bad revision
  - `changedFiles`, `fileExists`, and `modifiedFiles`
- **`VerificationRunner`:** Use a fake `GitClient` and a scripted `ProcessRunner`.
  - Write one test for each step in §8.3 that can fail.
  - Write one test for each gate exit class: 0, 1, 127, and 130.
  - Write one test each for a pass, a timeout, and a workspace that changes during the run.
  - Command output comes from a temporary script file. Each assertion checks for a marker that cannot appear in the command string, so a test cannot pass because of an echoed command. This follows the CLI verification rule.
- **Relay:**
  - Runs for the same workspace happen one at a time, so a second task waits for the first.
  - The total limit of two holds.
  - Unverified reports and reports of worker failure are settled without a run.
  - Each body in §9 matches exactly.
  - The two new expiry cases work.
  - A `reported` task does not fail when its assignee's session ends.
- **MCP:**
  - For `linkc_delegate_task` with `verify`: the SHA resolves to 40 characters, a missing test path is rejected, a branch mismatch is rejected, and the response text matches exactly.
  - For `linkc_complete_task`: `sha` is required only in the correct cases and must be a commit, the summary limit holds, `tests` is accepted and ignored, and no message or blackboard note is written.
- **End to end:** Use real git, a real login shell, and `LiveProcessRunner`.
  - The test command is `./check.sh`. It is a script that fails until a marker file exists. This keeps the test fast and needs no toolchain.
  - Commit a check that fails, delegate the task, tick, and confirm the change from `gating` to `queued`.
  - Commit the fix, report, tick, and confirm `done` with the exact message.
  - In a second version of the test, change `check.sh` in the worker's commit, and confirm `failed — test files modified: check.sh`.
- **Mutation check:** Disable the check for changed test files (§8.3 verify step 4) and make sure that the tamper test fails. Then restore the check.
- **Concurrency:** `./scripts/tsan.sh` must stay clean.

## 13. Dead code removed

- `InboxStore.completeTask`, which is replaced by `reportTask`, `adjudicate`, and `acceptUnverified`
- `TaskReport.tests` and every place that reads it
- The `delivered → done` and `started → done` transitions
- The completion-message and blackboard-note writes in `linkc_complete_task`
- `AgentDashboardAggregator.inspectGitModifiedFiles`, whose caller moves to `GitClient.modifiedFiles`

**Moved to spec two:** `AppCoordinator.inspectGitStatus`. Its only callers are in the handoff memo for limit reroutes, which spec two rewrites together with `checkLimitsAndReroute`. If we moved those callers now, spec two would remove that work.

## 14. Migration and rollout

- PR #28 must be merged to `main` first.
- An existing `inbox.json` file decodes without changes. The old `tests` key is ignored, and the new fields decode as `nil`.
- A task that is still open when this change ships has no verification. When its worker reports, the task goes from `reported` to `done` (unverified).
- MCP `serverInfo.version` changes to `0.3.0`. Every change to an existing tool is a new optional parameter, except for the summary limit in §7.2. Clients must reconnect to see the new parameters.
- Ship this change with `./build-app.sh`. Do not copy `linkc-mcp` over `~/.local/bin/linkc-mcp`. That path is a symlink into the signed bundle, and copying over it breaks the signature.

## 15. Amendments from planning (2026-09-10)

Two sources changed the design while the implementation plan was written: the code itself, and the real git commands run against it. Where this section and an earlier section do not agree, this section applies.

1. **`GitClient` is synchronous (§8.2, §7.1, §10).** `MCPServer.handleMessage` is synchronous, and the MCP tools must run git. So `GitClient` has synchronous methods, built on a new `LiveProcessRunner.runCapturingSync`.
   - Consumers depend on a `GitInspecting` protocol. Its methods are `headSha`, `resolveCommit`, `statusPorcelain`, `isAncestor`, `changedFiles`, and `fileExists`. `isClean` and `modifiedFiles` are derived from `statusPorcelain`.
   - `GitClient` has no runner parameter. Its tests use a real repository.
   - Because git is synchronous, `aggregateProject` and `aggregateGlobal` stay synchronous.
2. **Status checks exclude `.linkc` (§8.2).** `InboxStore` writes `.linkc/inbox.json` inside the workspace, and most repositories do not ignore that directory. `git status --porcelain` always reported it, so every gate would have failed. `statusPorcelain` runs `git status --porcelain -- . ':(exclude).linkc'` instead.
3. **`fileExists` uses `git ls-tree --name-only <rev> -- <path>` (§8.2, §7.1).** For a missing path, `git cat-file -e` exits with 128, not 1. That is the same status as a real error, so it cannot tell the two apart. `ls-tree` exits with 0 and prints nothing.
4. **`failTask(taskId:reason:)` (§6).** When `completeTask` was removed, the expiry sweep lost its way to fail a task whose assignee's session ended. `failTask` moves a task from `delivered` or `started` to `failed`, and stores the reason in `cancelReason`.
5. **Error names (§6).** The existing `emptySummary` stays. The new errors are `invalidVerification(String)`, `summaryTooLong(count:)`, `shaRequired`, `invalidReportStatus(String)`, `notVerified(String)`, and `verificationPresent(String)`.
6. **`TaskVerifier` protocol (§8.3, §8.4).** The relay depends on `TaskVerifier`, which has `gate` and `verify`. `VerificationRunner` conforms to it. `AppCoordinator` takes `verifier: any TaskVerifier = VerificationRunner()`.
7. **Gate reasons include the refusal wording (§8.3, §9).** Every gate reason starts with `gate failed: `, except "tests already pass at `<b7>`; brief refused". The relay sends `cancelled — <reason>`, and that gives both gate rows in §9 exactly.
8. **Seven-character SHAs.** In §8–§10, `<sha8>`, `<base8>`, and `<head8>` all mean seven characters, as in the examples.
9. **Reports without a sha (§8.4).** A verified task in `reported` whose report says `done` but has no `sha` fails without a run: `failed — report is missing its sha`. This can only happen when someone edits `inbox.json` by hand.
10. **Expiry lines (§8.5, §9).** Expiry sends `expired — gate did not run within 60m` for a `gating` task, and `expired — lease lapsed before verification` for a `reported` task. The v2 expiry lines no longer end with `linkc_get_task(...) for details.`
11. **A third `linkc_complete_task` response (§7.2).** When a verified task is reported `failed`, the tool returns `Reported. linkC will mark the task failed.`
12. **The delivery frame.** The brief for a verified task gives the branch, the command, and the test paths that the worker must not change. It asks for `linkc_complete_task(id, status, summary, sha)`.
13. **A finished run does not start a relay tick (§8.4).** The next state sweep, about one second later, delivers a task that is newly queued and starts the next run. If a run's workspace was deleted, the run discards its verdict. It does not create the directory again.
14. **This spec removes `inspectGitStatus` (§13).** Its callers are `spawnTeammate` and the handoff memo for reroutes, so reroute code is not its only caller. The reason for moving it to spec two was wrong. Both callers move to `AppCoordinator.gitStatusSummary(in:)`, which is built on `GitClient`. The "Moved to spec two" paragraph in §13 no longer applies.

## 16. Amendments from the final review (2026-09-11)

The whole-branch review found problems in paths that cross the whole feature, which the per-task reviews could not see. Where this section and an earlier section do not agree, this section applies.

1. **An undecodable inbox is an error (§6, §14).** `InboxStore` no longer treats an `inbox.json` it cannot decode as empty. It throws and leaves the file untouched. Before this change, a linkC binary that could not decode a newer file read it as empty, and its next write replaced the file.
2. **Rollout (§14).** An older linkC binary cannot decode an inbox that contains a verified task, and binaries built before item 1 would discard that inbox. After you upgrade, quit linkC and restart every MCP client that has `linkc-mcp` loaded before you delegate a verified task.
3. **A timeout stops the whole command (§8.1, §8.3).** Commands run in their own process group. On timeout, linkC sends SIGTERM to the group, then SIGKILL after 2 seconds.
4. **Task ids accept a unique prefix (§7).** The task tools accept the full id, or a unique prefix of at least 8 characters, matched case-insensitively. An ambiguous prefix is an error.
5. **A rerouted verified task keeps its verification (§8.4).** After a rate limit, the copy made for a new agent keeps its verification and the gate it already passed, and it starts in `queued` without a new gate. Its report is verified at the new worker's sha.
6. **A malformed `verify` is an error (§7.1).** A `verify` that is not an object, or a `timeout_seconds` that is not an integer, returns `isError` and creates no task. A JSON `null` for either one counts as absent.
7. **A gating task with no verification is cancelled (§8.4).** Such a task can only come from a hand-edited inbox. It is cancelled with `cancelled — gate failed: task has no verification`, so it cannot block other runs.

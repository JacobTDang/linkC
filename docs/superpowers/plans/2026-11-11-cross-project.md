# Cross-Project Implementation Plan

> **For agentic workers:** Do the tasks of your track in order. TDD for every task: write the test, run it and see it fail for the right reason, then implement, then see it pass. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A session in one project can reach another project. It can ask a question, hand off work, chat, or read that project's board and notes, and the context of both sessions stays small (spec `docs/superpowers/specs/2026-11-11-cross-project-design.md`).

**Architecture:**
- Cross-project traffic is written straight into the target project's own `.linkc/inbox.json`. It is stamped with a return address: the sending project's path and the sending session.
- In the target project it is an ordinary task or message.
- The target project's relay forwards the notices about a task back to the sending project's inbox.
- The app publishes the known projects to `projects.json`, so that the out-of-process MCP server can resolve the project names.

**Tech Stack:** Swift 6, SwiftPM, XCTest. Library `LinkCKit`, app target `linkc`, MCP server `linkc-mcp`.

## Global Constraints

- Answers and reports are at most 1,000 characters (`TaskReport.summaryLimit`). Cross-project messages are at most 2,000 characters.
- Fail loud. Do not swallow errors, and do not use silent fallbacks. Refusals are tool errors that give the reason.
- Use mock data only in tests. Add no new dependencies.
- A new field on a stored model (`TaskRecord`, `PendingMessage`, `Inbox`) must decode from a file that does not have it. `TaskRecord` uses synthesized `Codable`, so its new fields are Optional. `PendingMessage` and `Inbox` have hand-written `init(from:)`, so use `decodeIfPresent`.
- Commits: no trailers of any kind (no Co-Authored-By, no Signed-off-by), and never mention any AI, assistant or tool name. Before you report, run `./scripts/check-commits.sh origin/main..HEAD`.
- Do not push. Do not launch, quit or signal linkC. Never run `build-app.sh`.
- Tests: `swift test --filter <Class>` while working. Run the full suite (`swift test`) once before you report.

## Already done (base commits on `feat/cross-project`)

- `Sources/LinkCKit/Core/KnownProjects.swift`:
  - `KnownProject(path:sessions:)`, with `.name` (the folder name) and `OpenSession(id:agent:activity:)`. `agent` is the `AgentKind.rawValue` string; `.agentKind` converts it. `activity` is `.idle`, `.busy` or `.starting`.
  - `KnownProjectsFile(url:)`, with `.applicationSupport`, `read() throws -> [KnownProject]`, `write(_:)` and `remove()`.
  - `KnownProjectsError.linkCNotRunning` and `.unreadable`.
  - `ProjectRef.resolve(_ ref:, among:, caller:) throws -> KnownProject`, with the errors `ProjectRefError.unknown`, `.ambiguous` and `.own`.
- `MCPServer` gets an init parameter `knownProjects: KnownProjectsFile = .applicationSupport` and an internal `targetProject(_ args:) throws -> KnownProject?`. It returns nil when there is no `project` argument, and throws the refusals otherwise. Every cross-project tool calls it, and passes a thrown error to `errorResult(id:_:)`.
- Tests: `KnownProjectsTests` and `MCPServerProjectArgumentTests`. `MCPServerTaskRoutingTests` shows how MCP tests build a server and call a tool.

## Tracks

- **Track A (Codex)**, worktree `.worktrees/cross-project-codex`, branch `feat/cross-project-codex`: tasks A1 to A4.
- **Track B (Cursor)**, worktree `.worktrees/cross-project-cursor`, branch `feat/cross-project-cursor`: tasks B1 and B2.

Both tracks branch from the base. Both edit `MCPServer.swift`, so keep each change inside the tool's own `case` block or a new helper. Do not reformat code that is already there. The integrator merges the tracks.

---

## Track A (Codex)

### Task A1: The app publishes known projects and serves them; `linkc_list_projects`

**Files:**
- Create: `Sources/LinkCKit/App/KnownProjectsPublisher.swift`
- Modify:
  - `Sources/LinkCKit/App/AppCoordinator.swift`: the init parameters (around lines 300-345), the production convenience init (around line 400), `sweepTick()` (around line 555) and `shutdown()`.
  - `Sources/linkc/LinkCApp.swift`, around line 228, where `AppCoordinator(` is constructed.
  - `Sources/LinkCKit/MCP/MCPServer.swift`: the tool list, the dispatch, and `readOnlyTools`.
- Test:
  - Create `Tests/LinkCKitTests/KnownProjectsPublisherTests.swift`.
  - Add the coordinator tests to `Tests/LinkCKitTests/AppCoordinatorRelayTests.swift`.
  - Create `Tests/LinkCKitTests/MCPServerListProjectsTests.swift`.

**Interfaces:**
- Produces:
  ```swift
  public enum KnownProjectsPublisher {
      /// Sidebar projects ∪ MCP folders ∪ live sessions' folders, canonical, sorted by path. Each project's
      /// live sessions (state != .ended), sorted by id: .starting → .starting; ready/finished/waitingIdle → .idle;
      /// anything else → .busy.
      public static func projects(sidebar: [String], mcpFolders: Set<String>, sessions: [Session]) -> [KnownProject]
  }
  ```
  - `AppCoordinator.init` gets `knownProjectsFile: KnownProjectsFile? = nil` (nil: publish nothing; tests pass a temporary file) and `sidebarProjects: @escaping @MainActor @Sendable () -> [String] = { [] }`.
  - The convenience init passes `.applicationSupport`.
  - `LinkCApp` passes `{ sidebarState.projectOrder }`.
- `InboxStore.hasOpenWork(timeout:) throws -> Bool`: true when any message is `.queued`, or any task `state.isOpen`.

- [ ] **Step 1: Publisher tests.**
  - Two sidebar paths, one MCP folder, and sessions in two of them. The result is the union, canonical and sorted, with each session mapped to its activity.
  - An ended session is left out.
  - A sidebar path that is also an MCP folder appears once.
  - Run them and see them fail. Then implement `KnownProjectsPublisher`.
- [ ] **Step 2: Coordinator tests** (use `makeCoordinator` with a temporary `knownProjectsFile`):
  - After one sweep, the file lists the session's project, with the session `idle` or `busy`.
  - The file is rewritten only when its contents change. Test this with the file's modification date, or by having a test hook count the writes.
  - After `shutdown()`, the file is gone.
  - A known project (from `sidebarProjects`) with no session, and with a queued task for `codex` in its inbox, gets a codex worker started by the sweep. Today it would not, because only session folders and MCP folders are relayed.
  - Find the entry point that tests use to run a sweep. If `sweepTick` is private, follow how the existing tests drive `processPendingMessages(workspacePath:)` and the sweep, and add an `internal` test seam only if none exists.
- [ ] **Step 3: Implement.**
  - In `sweepTick()`, compute the known projects and write the file when they differ from the last write. Log a write error with `NSLog("[linkC] projects.json — %@", …)`.
  - Watch the inboxes of the known projects too (`inboxWatcher?.watch(workspaces:)`).
  - Run `processPendingMessages(workspacePath:)` for each known project that is not already relayed and whose `hasOpenWork()` is true.
  - Remove the file in `shutdown()`.
- [ ] **Step 4: `linkc_list_projects` tests**, using `KnownProjectsFile` in a temporary directory:
  - One line for each project other than the caller's: `nemo_ib  ~/Projects/nemo_ib  claude idle, codex busy`. Write the path with `~` in place of the home folder.
  - A project with no sessions shows `no sessions`.
  - No other project: `No other project is known to linkC.`
  - With the file missing, the error text is `KnownProjectsError.linkCNotRunning`'s.
  - The tool is in `readOnlyTools`, so an unidentified caller may use it.
- [ ] **Step 5: Implement the tool.** Description: "List the other projects linkC knows, one line each: name, path, and each open session's agent and whether it is idle or busy. Pass a name or path as `project` to linkc_ask, linkc_delegate_task, linkc_send_message, linkc_get_board or linkc_get_project_context."
- [ ] **Step 6:** Run the tests in the three test classes, then commit: `feat(projects): linkC publishes and serves known projects; linkc_list_projects`.

### Task A2: Tasks to another project: `linkc_delegate_task(project:)`, `linkc_ask`, the return address and the pointer

**Files:**
- Modify:
  - `Sources/LinkCKit/Blackboard/InboxModels.swift`: `TaskRecord`, `Inbox`, and a new `SentTask`.
  - `Sources/LinkCKit/Blackboard/InboxStore.swift`: `createTask` and the new pointer methods.
  - `Sources/LinkCKit/App/AppCoordinator+Relay.swift`: `deliveryFrame(for:)`, around line 144.
  - `Sources/LinkCKit/MCP/MCPServer.swift`: `linkc_delegate_task`, and a new `linkc_ask`.
- Test: `Tests/LinkCKitTests/CrossProjectTasksTests.swift` (new). Add the frame tests wherever `deliveryFrame` is tested today (grep for it).

**Interfaces:**
- `TaskRecord` gets:
  - `public let fromProject: String?`: the canonical path of the sending project, or nil when the task is local.
  - `public let question: Bool?`: true for an ask. Add `public var isQuestion: Bool { question == true }`.
  - Both are added to the init with the defaults nil and false (store nil when false).
- `InboxStore.createTask(… fromProject: String? = nil, isQuestion: Bool = false …)`. Dedupe also compares `fromProject`.
- `public struct SentTask: Codable, Equatable, Sendable { taskId: String; project: String; fromSessionId: String?; createdAt: Date }`.
- `Inbox.sentTasks: [SentTask]`. Decode it with `decodeIfPresent … ?? []`, and add it to `CodingKeys` and the init.
- `InboxStore`:
  - `recordSent(_: SentTask, timeout:) throws`;
  - `sentTask(matching prefix: String, timeout:) throws -> SentTask?`. This uses the same prefix rules as `task(matching:)`: at least 8 characters, and `InboxError.ambiguousTaskId` when the prefix matches more than one task;
  - `sentTasks(timeout:) throws -> [SentTask]`;
  - `dropSent(taskId:timeout:) throws`.

- [ ] **Step 1: Model and store tests.**
  - An inbox file written without `sentTasks`, `fromProject` or `question` still loads.
  - `createTask(fromProject:isQuestion:)` stores both fields.
  - `recordSent`, `sentTask(matching:)` (a short id, an ambiguous prefix) and `dropSent` round-trip.
  - See them fail, implement, and see them pass.
- [ ] **Step 2: `deliveryFrame` tests.**
  - A task with `fromProject` `/p/money-printer` starts with `[linkC task <short> from money-printer · Claude]`. A local task keeps today's first line.
  - A question's frame contains: `This is a question from money-printer. Answer it with linkc_complete_task("<id>", status: "done", summary: <your answer, at most 1,000 characters>). Do not change any files.`
  - A question's frame does not contain "commit your work". The frame still starts with `LinkCFrame.taskPrefix`.
  - Implement.
- [ ] **Step 3: `linkc_delegate_task` with `project`: MCP tests across two temporary folders.**
  - Write `projects.json` listing both folders, and give the server `knownProjects:`.
  - The task lands in the target folder's inbox with `fromProject` set to the caller's canonical folder and `fromSessionId` set to the caller's `LINKC_SESSION`.
  - The caller's inbox gains a `SentTask` with that task id and the target path.
  - The result text names the project and the short id.
  - Each check `linkc_delegate_task` makes today runs against the target project: the rate limits (`isAgentLimited`), the OpenCode model listing for that folder, the tier model, the leases and the hop. A file lease held in the target project refuses the task.
  - An unknown project is refused, and nothing is written in either inbox.
- [ ] **Step 4: Implement.**
  - In the `linkc_delegate_task` case, call `targetProject(args)`.
  - When it returns a project, use `InboxStore(workspaceRoot: project.path)` in place of `inboxStore`, and `project.path` in place of `workspaceRoot`, for every check and for the write. Factor the body into a helper that takes the store and the root, rather than copying it.
  - Create the task first, then `recordSent` in the caller's own inbox. If `recordSent` throws, return an error that gives the created task id and says that this project won't track it.
- [ ] **Step 5: `linkc_ask` tests.**
  - `linkc_ask(project:, question:, to:, tier:)` creates a task in the target inbox with `isQuestion`, no files, and the default `to` claude. It also records the pointer.
  - A missing `project` or `question` is refused.
  - `verify` is not in the tool's schema. If it is passed, it is refused: "an ask cannot be verified".
  - Implement, reusing the Step 4 helper.
  - Description: "Ask an agent in another project a question. It answers from its own context, and the answer (at most 1,000 characters) comes back to this session as a [linkC task …] line. Use linkc_list_projects to see the projects."
- [ ] **Step 6:** Run the tests, then commit: `feat(tasks): delegate or ask across projects with a return address`.

### Task A3: Notices about a sent task go home; a cancel notice reaches the worker

**Files:**
- Modify:
  - `Sources/LinkCKit/Blackboard/InboxStore.swift`: a new `receiveForwarded`.
  - `Sources/LinkCKit/App/AppCoordinator+Relay.swift`: a new phase in `processPendingMessages`, plus `deliveryTarget(for:in:inboxStore:caller:)` (around line 798) and `dispatchMessages`.
  - `Sources/LinkCKit/MCP/MCPServer.swift`: the `linkc_cancel_task` stop notice, around line 1326.
- Test: add to `Tests/LinkCKitTests/AppCoordinatorRelayTests.swift` (the relay tests across two folders), and to the MCP tests for the cancel change.

**Interfaces:**
- `InboxStore.receiveForwarded(_ message: PendingMessage, timeout:) throws -> Bool`:
  - It inserts a copy of an already framed message, with a new id, the same kind, taskId, prompt, fromAgent, toAgent and contentHash, and status `.queued`.
  - It returns false when the same contentHash was received or enqueued in the last 24 hours. That is the same dedupe `enqueue` uses.
  - It does not reject a framed prompt. Forwarded prompts are framed on purpose.
- `func forwardNoticesHome(workspacePath: String, inboxStore: InboxStore) -> Bool`. It returns true when the lock was contended, the same contract as the other phases. It runs in `processPendingMessages` before `dispatchMessages`.

- [ ] **Step 1: Relay tests across two temporary folders, `home` and `away`.** Use `makeCoordinator`, a live `claude` session in `home`, and an assignee session in `away`. Create in `away`'s inbox a task with `fromProject: home`, `fromSessionId: <home session>`, delivered to the away session, and report it with `inboxStore.reportTask`.
  - After a relay pass for `away` and then for `home`, the completion line (`[linkC task <short>] …`) is pasted into the home session, and no line is pasted into the away session.
  - If the home session that asked has ended, the line goes to another live claude session in `home`.
  - A crash between the two steps loses nothing and sends nothing twice. Test this by calling `receiveForwarded` with the message in `home` before the pass. After the pass, `home`'s inbox holds exactly one copy, and `away`'s copy is marked delivered.
  - If the home folder was deleted, the away copy is marked failed and an NSLog line names it, so it does not wait forever.
  - A notice about a local task (no `fromProject`) is delivered locally, as today.
- [ ] **Step 2: Implement.**
  - `forwardNoticesHome`: for each queued message with a `taskId`, a nil `toSessionId`, and a local task whose `fromProject` is non-nil and differs from this folder:
    1. call `InboxStore(workspaceRoot: fromProject).receiveForwarded(message)`;
    2. then call `markMessageDelivered` here.
  - Never hold both locks: do step 1 completely, then step 2.
  - In `dispatchMessages`, skip a message that `forwardNoticesHome` owns, so it is never pasted into a session in the target project when forwarding was delayed by a contended lock.
  - In `deliveryTarget`, when the `taskId` names no local task, look up `inboxStore.sentTask(matching: taskId)`. If its `fromSessionId` is live in this folder, return that session. Otherwise fall through to the existing last line.
- [ ] **Step 3: Cancel test.** A task that was delivered to session W and then cancelled through `linkc_cancel_task` enqueues the stop notice with `toSessionId: W`. Today it has no `toSessionId`, so `deliveryTarget` routes it to the delegator, not the worker. Because of the `toSessionId`, `forwardNoticesHome` does not forward it.
  - Implement: pass `toSessionId: task.assigneeSessionId`.
- [ ] **Step 4:** Run the tests, then commit: `feat(relay): notices about a task sent from another project go home`.

### Task A4: The delegator's tools follow the pointer

**Files:**
- Modify: `Sources/LinkCKit/MCP/MCPServer.swift`: `requireTask` and its callers, `linkc_my_tasks`, `linkc_get_task`, `linkc_cancel_task`, `linkc_close_worker`, and `taskWorker` (from spec 2026-11-11 parallel workers, used by `linkc_send_message` and `linkc_switch_model`).
- Test: add to `Tests/LinkCKitTests/CrossProjectTasksTests.swift`.

**Interfaces:**
- `requireTask(_ args:) throws -> (task: TaskRecord, store: InboxStore, root: String)`. It looks in this inbox first. If the task is not there, it checks `sentTask(matching:)` and loads the task from `InboxStore(workspaceRoot: pointer.project)`. When the pointer's task is gone from that inbox, it calls `dropSent` and throws `InboxError.taskNotFound`.
- Every tool that calls `requireTask` uses the returned `store` and `root` in place of `inboxStore` and `workspaceRoot`.

- [ ] **Step 1: Tests** (two folders; the task is created through `linkc_delegate_task(project:)` as in A2):
  - `linkc_get_task` with the short id from `home` returns the record held in `away`.
  - `linkc_cancel_task` from `home` cancels the task in `away`. A delivered task gets its stop notice in `away`, with `toSessionId` set to the assignee.
  - `linkc_close_worker` from `home` writes the close request in `away`.
  - `linkc_my_tasks` lists the task under "delegated" with ` → away` after its line.
  - `linkc_send_message(to:, message:, task_id:)` with that task id enqueues in `away` with `toSessionId` set to the assignee.
  - `linkc_switch_model(task_id:)` enqueues its `/model` command in `away`, or, when a `modelSwitcher` is set, calls it with the away path and the assignee's session id.
  - A pointer whose task was removed from `away` gives "task not found", and the pointer is dropped.
- [ ] **Step 2: Implement.** In `linkc_my_tasks`, list the open tasks from each pointer's inbox. A project folder that can't be read gives one line, `<project>: could not be read (<error>)`, not a silent skip.
- [ ] **Step 3:** Run this track's test classes and the full suite, then commit: `feat(tasks): a sent task is tracked, cancelled and messaged from the project that sent it`.

---

## Track B (Cursor)

### Task B1: Reading another project's board and notes

**Files:**
- Modify: `Sources/LinkCKit/MCP/MCPServer.swift`: the `linkc_get_board` case (around line 790) and the `linkc_get_project_context` case (around line 745), plus both schemas.
- Test: `Tests/LinkCKitTests/MCPServerCrossProjectReadTests.swift` (new). Look at the existing `linkc_get_board` and `linkc_get_project_context` tests (grep the Tests folder) for how boards and notes are seeded.

**Interfaces:**
- Both tools take `project`, which is resolved by `targetProject(args)`.
- `linkc_get_project_context` also takes `note` (a title, matched ignoring case).

- [ ] **Step 1: Tests** (two temporary folders; `projects.json` lists both):
  - `linkc_get_board(project: "away")` returns away's overview. `board: "<slug>"` returns away's detail board. The text matches what a server rooted in `away` returns.
  - `linkc_get_project_context(project: "away")` returns away's system map and peers, and one line for each note, `- <title>`, with no note bodies. It ends with `Read one with linkc_get_project_context(project: "away", note: "<title>").`
  - `note: "<title>"` returns that note in full. An unknown title is refused, and the refusal lists the titles.
  - Without `project`, both tools behave exactly as today. Keep the existing tests green.
  - An unknown project, and a missing `projects.json`, are refused with the `ProjectRefError` or `KnownProjectsError` text.
- [ ] **Step 2: Implement.** Move each case's body into a helper that takes the root folder (and a `BlackboardStore` for that folder), then call it with `workspaceRoot` or `project.path`. Do not copy the body.
- [ ] **Step 3:** Run the tests, then commit: `feat(mcp): read another project's board and notes`.

### Task B2: Chat across projects: `linkc_send_message(project:)` and `reply_to`

**Files:**
- Modify:
  - `Sources/LinkCKit/Blackboard/InboxModels.swift`: `PendingMessage`.
  - `Sources/LinkCKit/Blackboard/InboxStore.swift`: `enqueue`, and a new `message(matching:)`.
  - `Sources/LinkCKit/MCP/MCPServer.swift`: the `linkc_send_message` case and its schema.
- Test: `Tests/LinkCKitTests/MCPServerCrossProjectChatTests.swift` (new), plus the inbox model tests.

**Interfaces:**
- `PendingMessage` gets:
  - `public let fromProject: String?`;
  - `public let fromSessionId: String?`;
  - `public let chainDepth: Int`.
  - All three use `decodeIfPresent`; `chainDepth` defaults to 0. Add them to the init and to `CodingKeys`.
- `InboxStore.enqueue(… fromProject: String? = nil, fromSessionId: String? = nil, chainDepth: Int = 0 …)`.
- For `.peerNote` with a non-nil `fromProject`, the prompt is:
  `[Peer Note from <Agent> · <project name>]: <body>\nReply with linkc_send_message(project: "<project name>", reply_to: "<id prefix 8>")`
  - Compute `contentHash` from the prompt without the reply line, so the 24-hour dedupe still works.
- `InboxStore.message(matching prefix: String, timeout:) throws -> PendingMessage?`: the same prefix rules as `task(matching:)`.
- `public static let crossProjectMessageLimit = 2_000` and `public static let replyChainLimit = 10`, both on `PendingMessage`.

- [ ] **Step 1: Model and store tests.**
  - An old message row without the new keys decodes, with `chainDepth` 0.
  - `enqueue(fromProject:fromSessionId:chainDepth:)` stores them and composes the prompt above.
  - Two identical cross-project messages are deduped.
  - `message(matching:)` handles a short id and an ambiguous prefix.
- [ ] **Step 2: MCP tests** (two folders; `projects.json` lists `away` with an idle `codex` session):
  - `linkc_send_message(project: "away", to: "codex", message:)` enqueues into away's inbox, with `fromProject` set to the caller's canonical folder, `fromSessionId` set to the caller's `LINKC_SESSION`, and `chainDepth` 0.
  - A message longer than 2,000 characters is refused before anything is written: `Messages to another project are at most 2,000 characters. Point to a file path instead; both projects are on this Mac.`
  - When `projects.json` shows no live `codex` session in `away`, the message is refused: `No Codex session is open in away. Use linkc_ask or linkc_delegate_task, which start one.`
  - With `reply_to`:
    - In `away`, a server replies to that message's id (the short id works). The reply lands in the caller's (`home`) inbox, with `toSessionId` set to the original `fromSessionId`, `toAgent` set to the original `fromAgent`, and `chainDepth` 1. `project` and `to` may be left out.
    - A `project` or `to` that differs from the message's origin is refused.
    - A message with no `fromSessionId` gets a reply with no `toSessionId`, and the open-session check applies.
    - `reply_to` naming a message at `chainDepth` 9 is refused: `This conversation has gone back and forth 10 times. Ask the user before continuing.`
    - An unknown id: `Message <id> not found; send without reply_to.`
    - A message that has no `fromProject`: `Message <id> did not come from another project; reply without reply_to.`
  - Without `project` and `reply_to`, the behaviour is as today. Keep `MCPServerTaskRoutingTests` green.
- [ ] **Step 3: Implement.**
  - The checks, in order: the size, then `reply_to`, then the project resolution (`targetProject`), then the open-session check from the `KnownProject.sessions` that `targetProject` returned.
  - Write into `InboxStore(workspaceRoot: <target path>)`.
  - Schema: add `project` and `reply_to`, each with a one-line description. Make `to` optional when `reply_to` is given: keep `required: ["message"]`, and check `to` in code.
- [ ] **Step 4:** Run the tests and the full suite, then commit: `feat(mcp): chat with a session in another project`.

---

## Integration (the integrator, after both tracks)

1. Merge `feat/cross-project-codex` and then `feat/cross-project-cursor` into `feat/cross-project`, and resolve the conflicts in `MCPServer.swift`.
2. Update `README.md`: the tool table (`linkc_list_projects`, `linkc_ask`, the `project` and `reply_to` arguments), and one paragraph on cross-project use.
3. Run the full suite and `scripts/tsan.sh`, then `./scripts/check-commits.sh origin/main..HEAD`.

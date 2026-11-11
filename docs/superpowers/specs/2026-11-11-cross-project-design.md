# Cross-Project: Sessions in One Project Reach Another

**Date:** 2026-11-11
**Status:** Approved design (branch `feat/cross-project`)

## 1. Problem

Jacob wants a session in one project, for example Claude in money-printer, to reach any agent in another project, for example nemo_ib. He wants to do this without filling either session's context.

Today every linkC channel stays in one folder:

- The inbox is `<folder>/.linkc/inbox.json`.
- The MCP server (`linkc-mcp`) knows only the folder it started in.
- The relay delivers a folder's tasks and messages only to sessions in that same folder.
- The relay serves only folders that have a live session or a running MCP server.

## 2. Goals

Jacob chose all four of these:

- **Ask:** money-printer asks nemo_ib a question. An agent there answers from its own context. The asker gets back a short answer, not the files that were read.
- **Hand off work:** money-printer gives nemo_ib a task. The work is done in nemo_ib, and a short report comes back.
- **Chat:** two sessions in different projects send messages to each other.
- **Read:** money-printer reads nemo_ib's board and notes, with no agent involved.

Context stays small on both sides:

- An answer or a report is 1,000 characters at most.
- A cross-project message is 2,000 characters at most.
- Reads return summaries first, and the details only on request.

## 3. Non-goals

- **Access control.** Any known project can reach any other (Jacob's choice). Every delivery says which project and session it came from.
- **Other machines.** All projects are on this Mac.
- **Edits to another project's board or notes.** Reads only.
- **Messages that start workers.** A message waits for an open session, the same as today. Only an ask or a task starts a worker.

## 4. Known projects

A known project is either:

- a project in linkC's sidebar (`SidebarState.projectOrder`), or
- a folder with a running MCP server (`MCPWorkspaceRegistry`).

The MCP server runs outside the app, so it cannot see the sidebar or the sessions. Because of this, the app writes `~/Library/Application Support/linkC/projects.json` and rewrites it whenever its contents change. It holds one entry for each known project:

- `name`: the folder's last path component;
- `path`: the canonical path;
- `sessions`: one entry for each live session, with its id, agent, and state (`idle`, `busy` or `starting`).

The app writes the file atomically. A reader that finds the file missing or unreadable reports this as an error and does not continue with an empty list.

### 4.1 `linkc_list_projects`

This new read-only tool returns one line for each known project, other than the caller's own project. For example:

`nemo_ib  ~/Projects/nemo_ib  claude idle, codex busy`

A project with no open session shows `no sessions`.

### 4.2 The `project` argument

The tools that cross projects take a `project` argument. It accepts either a folder name or a full path. `ProjectRef.resolve(_:among:caller:)` resolves it:

- **A full path:** must be a known project.
- **A name:** matched case-insensitively against each known project's `name`.
- **No match:** an error that lists the known names.
- **Two or more matches:** an error that lists their paths and asks for the path instead.
- **The caller's own project:** an error that says to use the tool without `project`.

### 4.3 Serving

The sweep serves every known project with open inbox work, in addition to the folders it serves today. The inbox watcher watches the inbox of each known project. A task sent to nemo_ib when nothing is open there still starts a worker in nemo_ib, by the usual worker rules (spec 2026-11-11 parallel workers).

## 5. Asks and handoffs

### 5.1 Handing off work

`linkc_delegate_task` takes `project`. The MCP server writes the task into that project's inbox. In that inbox it is an ordinary task:

- it uses the usual `WorkerClaims` pick: an idle open session of the agent, otherwise a new worker;
- its file leases and tier apply in that project;
- its verification, if any, runs in that project's checkout.

### 5.2 Asking

`linkc_ask(project, question, to?, tier?)` is a new tool. `to` defaults to `claude`. It creates a task with `isQuestion = true`. A question:

- claims no files;
- needs no sha when it is reported done;
- cannot be verified, so `verify` is refused.

The brief tells the receiver that this is a question: it answers with `linkc_complete_task`, the summary is the answer (1,000 characters at most), and it changes no files.

### 5.3 The return address

`TaskRecord` gets `fromProject`, the canonical path of the sending project. Its value is nil for a local task. `fromSessionId` already records the asking session, through `LINKC_SESSION`.

The hop limit (at most 2) counts across projects. A worker in nemo_ib that delegates on to a third project adds one hop.

A brief that comes from another project starts with its origin. For example:

`[linkC task from money-printer · claude …]`

### 5.4 The sender's pointer

The sending inbox gets `sentTasks`: one entry for each task sent elsewhere, with:

- the task id;
- the target project path;
- `fromSessionId`;
- `createdAt`.

With this pointer, the delegator's tools work on the task by id from the sending project:

- `linkc_get_task` reads the record from the target project's inbox.
- `linkc_my_tasks` lists the open tasks sent elsewhere, with their project.
- `linkc_cancel_task` and `linkc_close_worker` act on the target project's inbox.

A pointer is dropped when a tool or the relay finds that its task is no longer in the target project's inbox.

### 5.5 Replies go home

A notice about a task with a `fromProject` belongs to the sending project. Such notices are:

- the report;
- a failure;
- an expiry;
- a stuck warning;
- a refused tier or model.

The target project's relay forwards each one in two steps:

1. It enqueues the notice into the sending project's inbox, with the same kind, `taskId`, and body. The usual content-hash dedupe applies.
2. It marks the local copy delivered.

The relay never holds both inbox locks at the same time. If it crashes between the two steps, the next pass enqueues the notice again, and the dedupe drops the copy.

In the sending project, `deliveryTarget` routes a notice whose `taskId` is in `sentTasks` like a local delegator's notice:

- to the asking session, if it is live there;
- otherwise to the first live session of that agent there.

### 5.6 Context

The asker gets one line and a summary of at most 1,000 characters. All the reading happens in the receiver's context. The full record is available through `linkc_get_task`, on request.

## 6. Chat

### 6.1 Sending

`linkc_send_message` takes `project`. The checks, in order:

1. **Size:** a message longer than 2,000 characters is refused. The refusal says to point to a file path instead, because both projects are on this Mac.
2. **An open session:** if `projects.json` shows no live session of `to` in the target project, the send is refused: "no codex session is open in nemo_ib; use linkc_ask or linkc_delegate_task, which start one".
3. **Delivery:** the message is enqueued in the target project's inbox. It is delivered like a local message, to a live session of `to` in that project.

A session can close between the check and delivery. In that case the message waits, and the user is told, as with any undelivered message today.

`PendingMessage` gets three fields:

- `fromProject`;
- `fromSessionId`;
- `chainDepth` (default 0).

A message from another project is pasted with its origin and a way to reply. For example:

`[linkC message from money-printer · claude] … Reply with linkc_send_message(project: "money-printer", reply_to: "<id>")`

### 6.2 Replying

`reply_to` is the id of a message in the caller's own inbox:

- The reply goes to that message's `fromProject`, with `toSessionId` set to its `fromSessionId`. So it reaches the exact session that wrote the message, or fails as an ended worker does today, and the user is told.
- If the message has no `fromSessionId`, because its sender started outside linkC, the reply goes to the first live session of that agent in that project.
- If the message id is not found, the reply is refused: "message not found; send without reply_to".
- The reply's `chainDepth` is the message's `chainDepth + 1`. At depth 10 the reply is refused: "ask the user before continuing".

### 6.3 `task_id` across projects

`task_id` on `linkc_send_message` and `linkc_switch_model` also accepts a task in `sentTasks`. The project comes from the pointer, and the rest works as in spec 2026-11-11 parallel workers §5.

## 7. Reads

`linkc_get_board` and `linkc_get_project_context` take `project` and read that project's files directly. No agent and no inbox are involved.

- **`linkc_get_board(project:)`** returns the overview by default and a detail board on request, as it does locally.
- **`linkc_get_project_context(project:, note:)`** returns the system map, the peers, and one line for each note title. With `note`, it returns that one note in full.

`linkc_edit_board`, `linkc_post_note` and `linkc_broadcast_intent` do not take `project`.

## 8. Errors

Every refusal is a tool error that gives the reason. Nothing falls back silently. The refusals are:

- an unknown, ambiguous, or own project (§4.2);
- `projects.json` missing or unreadable: "linkC isn't running, so other projects can't be reached";
- `verify` on an ask;
- a message over 2,000 characters, or to an agent with no open session there;
- a `reply_to` that is not found, or that is past the chain limit.

The relay reports failures on the target side, for example a refused tier, as notices that it forwards home (§5.5).

## 9. Rollout

A CLI session started outside linkC runs its MCP server from before the update. In each such session, type `/mcp` to load the new tools and arguments.

## 10. Testing

TDD through the existing seams. Nothing real is launched.

- **Unit tests:**
  - `ProjectRef.resolve`: case, a name shared by two folders, the caller's own project, an unknown name, a path;
  - the `projects.json` round trip;
  - a missing file is an error.
- **MCP tests:**
  - each tool with `project`;
  - `linkc_ask`;
  - `reply_to`: the routing and the depth limit;
  - `task_id` through `sentTasks`;
  - each refusal in §8.
- **Relay tests**, with the fake terminal, across two temporary folders:
  - a task sent to a project with no session starts a worker there;
  - the report is forwarded home and reaches the asking session;
  - if the asking session ended, the report goes to another session of that agent;
  - a crash between the two forwarding steps does not lose or duplicate the notice;
  - a known project with queued work and no session is served.
- **Full runs:** the full suite and `scripts/tsan.sh`.

# The `linkc` command: open an agent in a linkC window from any terminal

**Date:** 2026-10-27
**Status:** Approved design, not yet implemented

## 1. Problem

You can only start an agent session in linkC from linkC's own UI. From a terminal, there is no way to open an agent in linkC, in the folder you are working in, with a prompt already typed in. An agent working in a terminal, such as Claude run in a shell, has no way to do it either.

## 2. Goals

- `linkc <agent> "prompt"` run in any terminal opens that agent in linkC. It works in the folder the command ran in, appears in its own window, and has the prompt typed in.
- The command returns at once and says where the session opened.
- The session shows in linkC's sidebar like any other. Exiting the agent closes its window and ends the session.
- An agent can run the command with `--task` to hand work to the new session. The new session is a worker the agent can follow and close.
- If linkC is not running, the command starts it.

## 3. Non-goals

- Running the agent inside the calling terminal.
- Waiting for the agent to finish (a `--wait` flag).
- Agents other than linkC's own agent kinds.

## 4. Usage

```
linkc <agent> [--tier light|standard|deep] [--task] [prompt ...]
linkc --help
```

- `<agent>` is one of `claude`, `codex`, `agy`, `cursor` or `grok`.
- `prompt` is the remaining words, joined with spaces, so quoting is optional. Without a prompt, the agent opens empty. `--task` needs a prompt.
- `--tier` picks the model tier. The default is that agent's default tier in **Settings > Models**.
- On success the command prints `Opened Codex in a linkC window (money-printer).` and exits 0.
- A usage error (an unknown agent or option, or `--task` without a prompt) prints the reason and the usage to stderr and exits 2.
- On any other failure it prints a reason to stderr and exits 1. Failures include:
  - `--task` not run by an agent;
  - linkC not answering within 20 seconds;
  - linkC's own refusal, such as no model set for that tier, or a folder that is gone.

## 5. How the command reaches linkC

linkC already talks to its MCP servers through files, and the command does the same. It needs no network port and no token.

1. The command writes a request file into `~/Library/Application Support/linkC/open-requests/<id>.json`, atomically. The folder is created with mode 0700. The request holds:
   - `id`;
   - `agent`;
   - `folder`, the command's working folder in canonical form;
   - `prompt` (optional);
   - `tier` (optional);
   - `task` (optional), holding `fromAgent` and an optional `fromSessionId`;
   - `createdAt`.
2. If no linkC process (bundle id `com.linkc.app`) is running, the command starts linkC with `open -b com.linkc.app`.
3. linkC watches that folder, and a new request wakes its sweep. linkC then:
   - handles each request once and deletes it;
   - writes `<id>.result.json`, which holds `ok`, the `sessionId` when `ok` is true, and a `message`.
4. The command waits up to 20 seconds for its result file. It prints the result's message, deletes the file, and exits.

A request that is more than 60 seconds old when linkC reads it is dropped, with a result saying so. A request left behind while linkC was not running therefore never opens a window long after it was made.

## 6. What linkC does with a request

1. **Validate.** The agent must be known, the folder must exist, and the tier must resolve to a model, as delegation already requires. A refusal is written as `ok: false` with the reason.
2. **Start the session.** linkC starts a session for the agent in the folder. It is a worker when the request carries `task`, and it is not selected.
3. **Show it in its own window.** The window is the existing torn-off window, placed beside the panel, and linkC comes forward.
4. **Type the prompt.**
   - **Without `task`:** the prompt is typed into the session once, followed by Enter. This happens when the agent is ready: bracketed paste has been negotiated and the session is idle. It is the same path linkC uses to type in a task brief.
   - **With `task`:** linkC records a task in the folder's inbox. The task runs from the calling agent to the new session's agent, and it is **pinned** to the new session (§8). The relay delivers it there as a normal task brief. The worker reports back. The calling agent follows it with `linkc_get_task` and can close it with `linkc_close_worker`.
5. **Answer.** linkC writes `ok: true` with the session id and the message.

## 7. Ownership and lifecycle

- **Without `--task`**, the session is yours. linkC never closes it, and it ends when you exit the agent.
- **With `--task`**, the session is a worker carrying the pinned task. It closes like any worker: about a minute after its task ends, or when its delegator closes it. Typing into it makes it yours (#76).
- **On exit**, the session ends and its window closes. The ended session is pruned. linkC already does all of this.

## 8. Pinned tasks

- `TaskRecord` gains an optional `targetSessionId`. Inbox files written before this change decode it as nil.
- `dispatchTasks` delivers a task that has a `targetSessionId` only to that session, once it is idle and accepts paste. It never delivers the task anywhere else, and it never launches a session for it.
- If the target session has ended before delivery, the task expires with the reason "its session ended before the task was delivered". A queued task may only become delivered, cancelled or expired.

## 9. Who is asking (`--task`)

- The command finds the agent it runs under by walking its parent processes, as linkC's MCP tools do (`ProcessSnooper.detectAgent(inAncestorsOf:)`). It also reads `LINKC_SESSION` when that is set, which gives the task its `fromSessionId`.
- If no agent is found, the command fails with: "--task is for an agent handing off work; run without --task to open your own session."

## 10. Install

- A new executable target, `linkc-cli`, depends on LinkCKit.
- `build-app.sh` copies the binary into the bundle at `Contents/MacOS/linkc-cli` and links `~/.local/bin/linkc` to it, the same way it installs `linkc-mcp`. `~/.local/bin` is already on the user's PATH.

## 11. Errors

linkC fails loudly. Every refusal reaches the command, which prints it to stderr. A request or result file that can't be read is logged and removed. The command reports a result it can't read as an error.

## 12. Testing

Unit tests in LinkCKit, written first:
- **Arguments:** each agent, `--tier`, `--task`, joining the prompt words, and every usage error.
- **Request and result files:**
  - encoding and decoding;
  - writing a request and listing the pending ones;
  - dropping a stale request with a result;
  - removing a request once it has been handled.
- **The command's wait:** a result appearing, a timeout, and an unreadable result. These use an injected clock and folder.
- **The coordinator handling a request,** with the mock agent script the tests already use:
  - a session of that agent opens in that folder and the result is `ok`;
  - refusals for a missing folder and for a tier with no model;
  - the prompt is typed once the agent is ready, and only once;
  - with a task, the session is a worker and a task pinned to it is recorded.
- **Dispatch:**
  - a pinned task is delivered only to its target, even when another idle session of that kind exists;
  - it never spawns a session;
  - a target that ended expires the task.

App target (checked by build and by reading): the coordinator's "opened" callback tears the session off into a window and brings linkC forward.

Manual checks after the update:
1. Run `linkc codex "say hi"` in Terminal. A linkC window opens with the prompt typed in.
2. Type `/exit` in it. The window closes.
3. Have Claude, running in a linkC shell terminal, run `linkc codex --task "…"`. Claude can then follow the task with `linkc_get_task` and close the worker.

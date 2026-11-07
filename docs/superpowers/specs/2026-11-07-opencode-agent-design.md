# OpenCode Agent: OpenCode's Free Models as a linkC Agent

**Date:** 2026-11-07
**Status:** Approved design (branch `feat/opencode-agent`)

## 1. Problem

OpenCode reaches a set of free models (DeepSeek V4.1 Flash, Big Pickle, Crouton Alpha and others) with no account and no key. linkC cannot run OpenCode: Claude cannot delegate to it, and Jacob cannot open it from linkC's menu. He wants it as an agent like the others: its own pill, tiers, tools, limits and usage row.

## 2. Goals

- `linkc_delegate_task(to: "opencode", tier: …)` starts or reaches an OpenCode worker on a free model, and Claude controls it like any peer: message it, cancel its task, read its completion.
- Jacob opens OpenCode sessions from linkC's menu and with `linkc opencode`, on a free model.
- linkC's tools reach OpenCode wherever it runs: in linkC, and in a terminal outside linkC.
- A task never runs on a model other than the one its tier names. A removed free model is refused, not silently replaced.
- linkC holds no credentials for OpenCode. The free models need none.

## 3. Non-goals

- Paid OpenCode providers or OpenCode Go. Jacob can put any `provider/model` id in a tier by hand; linkC seeds only free ones.
- Reasoning-effort variants. OpenCode's TUI has no `--variant` flag (§4).
- Switching a running OpenCode session's model (§5.9).
- OpenCode usage figures. The free models publish no quota.
- A Resume… picker for OpenCode. OpenCode has no picker flag; its own `/sessions` picker is one command away inside it.

## 4. What OpenCode does (verified 2026-11-07, OpenCode 1.18.19 at `/opt/homebrew/bin/opencode`)

- `opencode models` lists 11 `opencode/*` free models. Each answered `opencode run -m opencode/<id> "Reply with exactly the word OK."` with `OK`. `opencode models` takes about 0.7 s.
- `opencode --auto --model <provider/model>` starts the TUI with every permission approved (`--auto`: "auto-approve permissions that are not explicitly denied"). Jacob's config denies nothing. There is no folder-trust dialog.
- The TUI rejects `--variant`: it prints the help and exits. `opencode run` accepts it; the TUI does not.
- An unknown model id does not fail. The TUI shows a toast, `Model <id> is not valid`, for about two seconds, then runs on the config's default model — for Jacob, `ollama/qwen3.8:27b-32k`, a local model.
- On startup, with a newer release out, the TUI opens on an "Update Available" dialog with an Ask/Skip/Confirm choice. `OPENCODE_DISABLE_AUTOUPDATE=1` removes it.
- The TUI turns on bracketed paste (`ESC[?2004h`). A bracketed-paste multi-line brief followed by Return submits it as one prompt.
- While a turn runs, the row under the input box is a progress bar of `⬝` and `■` glyphs, then `esc interrupt`, then the context size. When the turn ends, that row shows the folder path. A Braille spinner row (`⠋ Thinking`) sits above the box while the model thinks.
- `/model <id>` is not a command. Typed into the TUI, it went to the model as a prompt.
- `OPENCODE_CONFIG_CONTENT` (inline JSON config) is merged over `~/.config/opencode/opencode.json`: with an inline `mcp` entry, `opencode mcp list` showed the six servers from the file plus the inline one. Inline config has the higher precedence.
- A local MCP server inherits OpenCode's environment plus its `environment` block: a stand-in server saw `LINKC_SESSION` from the terminal and `LINKC_AGENT` from the block.
- OpenCode names MCP tools `<server>_<tool>`. Given linkC's real task brief, with a stand-in `linkc-multiplier` server, `deepseek-v4.1-flash-free`, `big-pickle` and `crouton-alpha-free` each called `linkc_start_task` with the task id, did the work, committed it, and called `linkc_complete_task` with `status: done`.
- `-c` continues the newest session of the OpenCode project, and moves to that session's folder. A project is the repo's root commit, so all worktrees of one repo are one project; folders with no commits share one global project. Launched in one folder, `-c` reopened a session from another folder of the same root commit.
- `opencode session list --format json` lists the project's sessions with `id`, `directory`, `updated` (ms) and `projectId`, newest first (about 0.9 s). `opencode --session <id>` opens that session in its folder.
- The foreground process is OpenCode's own binary (`/opt/homebrew/Cellar/opencode/1.18.19/bin/opencode`, through the `/opt/homebrew/bin/opencode` link); its MCP servers are its children.
- OpenCode's retry code reports a free-tier cap as `Free usage exceeded, subscribe to Go`, with a `Free limit reached` action title. This was read from the 1.18.19 binary; no live cap was seen.
- OpenCode's installer puts the binary in `~/.opencode/bin`.

## 5. Design

### 5.1 A new agent kind

`AgentKind` gains `case opencode`:

| Property | Value |
|---|---|
| `rawValue` | `opencode` |
| `pillText` | `OPENCODE` |
| `displayName` | `OpenCode` |
| `shortName` | `OpenCode` |
| `brandColorHex` | `#FAB283` (the accent of OpenCode's default theme) |
| Logo | OpenCode's mark from @lobehub/icons-static-svg 1.95.1, as a template image |

### 5.2 Launch

`AgentDescriptor` for `.opencode`: binary `opencode`, candidates `/opt/homebrew/bin/opencode`, `/usr/local/bin/opencode`, `~/.opencode/bin/opencode`; flags `--auto`; no continue or resume arguments (§5.3).

The terminal environment adds to `LINKC_SESSION`:

- `OPENCODE_DISABLE_AUTOUPDATE=1`, so the update dialog never takes the first text linkC types.
- `OPENCODE_CONFIG_CONTENT` carrying linkC's MCP server (§5.4).

Every OpenCode launch names a model, as Grok's does. A session from the menu or `linkc opencode` without `--tier` runs on the default tier's model and records no tier, so it is never handed a delegated task. A delegated task, or `--tier`, uses its tier's model and records the tier. A continued session uses the default tier's model. With no model for the tier, the launch refuses: `no model configured for opencode tier <tier> — set it in linkC settings`. It never falls back to OpenCode's own default.

Menus: OpenCode is under New and Continue last, not under Resume….

### 5.3 Continuing a session

linkC continues an OpenCode session in its own folder only. For `.continueLast` — the menu item, and every restore after a quit — linkC runs `opencode session list --format json` in the session's folder, takes the newest entry whose `directory` is that folder (both canonicalized with `ProjectPath.canonical`), and launches with `--session <id>`. With no such entry, the session starts new. If the listing fails, or its output does not parse, the launch fails with that error; it does not start a new session in its place.

The listing runs off the main thread, through `ProcessRunner`; the session is launched when it returns. `RelaunchPlan` already lets at most one entry per folder and agent continue, so two restored OpenCode sessions never land on one conversation.

### 5.4 linkC's tools

**Registration.** `MCPRegistrar.registerAll` also registers with `~/.config/opencode/opencode.json`, in OpenCode's format:

```json
"mcp": {
  "linkc-multiplier": {
    "type": "local",
    "command": ["<home>/.local/bin/linkc-mcp"],
    "environment": { "LINKC_AGENT": "opencode" },
    "enabled": true
  }
}
```

Every other key in the file is kept. The file is written atomically, with sorted keys and unescaped slashes, and only when the entry differs from the one already there. A missing file or folder is created.

**Fail loud on a file that cannot be read.** An existing file that is not a JSON object — comments, trailing commas, a half-written file — is not touched; registration throws, naming the path. `registerAll` already collects each client's failure and reports them together. The shared JSON writer (`registerServer`, used for Claude, Cursor, agy and Codex's `mcp.json`) gets the same guard: today it reads an unparseable file as empty and overwrites it. An empty or whitespace-only file is read as `{}`, since there is nothing in it to lose.

**Injection at launch.** Each OpenCode terminal linkC starts also gets `OPENCODE_CONFIG_CONTENT` with the same `linkc-multiplier` entry, so linkC's own sessions have the tools even when registration failed. The entry carries no session id: the MCP server inherits `LINKC_SESSION` from OpenCode (§4), so the same text is right in every terminal. If linkC's own environment already holds an `OPENCODE_CONFIG_CONTENT`, linkC merges its entry into that JSON; if that JSON does not parse as an object, the launch fails naming the variable.

### 5.5 Identity

OpenCode runs its own binary with its own registration, so no worker mark is needed. `MCPServer.resolveCaller` finds it by its order: explicit `agent`/`from` → `LINKC_AGENT=opencode` → the `opencode` ancestor process → `.shell`. `LinkCCommand.caller` finds `linkc` run from an OpenCode terminal the same way.

OpenCode sets `OPENCODE=1`, `OPENCODE_PID` and `AGENT=1` on every start, overwriting what it inherits, so linkC does not strip them.

### 5.6 Process detection

`ProcessSnooper.detectAgent(inPath:)` maps an `opencode` executable to `.opencode`. An OpenCode started by hand in a linkC shell pane is picked up like any other agent.

### 5.7 Screen state

OpenCode is screen-read, like every agent but Claude.

- **Working:** the row under the input box shows OpenCode's progress bar followed by `esc interrupt`. Only that shape counts — a run of `⬝`/`■` glyphs, then the hint — so prose that mentions the phrase does not. The phrase is the Braille spinner row's text above the box when there is one, else `Working`.
- **Done:** the hint is gone; `TurnEndDebounce` ends the turn as for the other agents.
- **Watchdog:** the working row counts as a live row, so its animated bar and the ticking context size are not read as progress.
- **Rejected model:** OpenCode's `Model <id> is not valid` toast, on any OpenCode session, posts one notification per session — `OpenCode rejected <id> and is running on its own default model` — and logs the screen rows.

The rules are tested against screens captured from the real TUI: idle, three working stages, done, and the toast.

### 5.8 Tiers

`AgentModelSettings.seeded` gains OpenCode, default tier standard:

| Tier | Model |
|---|---|
| light | `opencode/deepseek-v4.1-flash-free` |
| standard | `opencode/big-pickle` |
| deep | `opencode/crouton-alpha-free` |

Ids are stored whole, provider included, so any id `opencode models` lists can go in a tier (`ollama/qwen3.8:27b-32k` among them). `AgentModelStore.load` fills OpenCode into a saved `models.json` that does not mention it, as it did for Grok. Settings > Models shows OpenCode's tiers and default tier after Grok. `AgentModelCatalog.models(for: .opencode)` lists the three seeds. `linkc_get_models` reports OpenCode's tiers.

**A removed model is refused at delegation.** Free models are offered for a limited time (Pulse Alpha Free was withdrawn on 2026-11-06), and OpenCode replaces an unknown id with its default (§4). So `linkc_delegate_task(to: "opencode")` resolves the task's tier — the one asked for, else the default — and runs `opencode models` inside `linkc-mcp`. When the id is not listed, it refuses: `opencode/<id> (opencode tier <tier>) is not among the models OpenCode lists — free models come and go; set the tier in linkC settings`. When `opencode models` fails, delegation refuses with its error. The check runs in `linkc-mcp`, never on linkC's main thread. Two other paths start an OpenCode worker without passing through `linkc_delegate_task` — a task linkC reroutes to OpenCode off a capped agent, and a message to OpenCode with no session to take it — and are not checked; the on-screen toast (§5.7) still reports a rejected model on them.

### 5.9 Model switching

`linkc_switch_model` refuses for OpenCode: `opencode cannot switch a running session's model — delegate at another tier instead`. `linkc_get_models` says the same under OpenCode's tiers, as it does for Cursor.

### 5.10 Limits and reroute

`LimitDetector` gets OpenCode rules for its free-tier cap: `free usage exceeded` and `free limit reached`, matched as whole phrases, with the default cooldown. The generic 429 and "too many requests" patterns are left out: OpenCode retries those by itself, and one retry would bench OpenCode for the whole cooldown. Limits are tracked per agent kind, so a capped OpenCode leaves the others available. OpenCode is a reroute candidate like every peer.

### 5.11 Usage row

OpenCode gets a row after Grok: `OpenCode's free models publish no quota locally — only a cap linkC sees in its terminal`. A cap linkC saw outranks it. `linkc_get_usage_status` reports OpenCode as unavailable for the same reason.

### 5.12 Every list of agents

The compiler flags the exhaustive switches on `AgentKind`. These lists and strings it does not flag, and each gains `opencode`:

- `AppCoordinator+Relay.swift` `supportedPeers`
- `MCPServer.swift`: `peerCandidates`, `targetAgents`, the usage-status loop, `defaultUsageReaders`, every tool description that lists agents
- `UsageRows.order`
- `SettingsScreen` tier list
- `LinkCCommand.agents` and its usage text
- `PanelView` New and Continue last menus
- `Theme` agent colour, `AgentLogo`, `BoardTech`'s agent-named components

Switches with a `default:` branch are checked by hand. The plan greps for `.grok` and `"grok"` and accounts for every hit.

`SettingsScreen.swift`, `AppPreferences.swift`, `NotificationManager.swift` and the `AppCoordinator` files are also being changed on `feat/discord-notifications`, so edits there stay as small as they can be.

## 6. Rollout

`AgentKind` is persisted in `inbox.json`, the blackboard and session manifests, and those stores fail loud on a value they cannot decode. A build without `.opencode` — the running linkC, or a `linkc-mcp` an MCP client spawned before the update — breaks on the first OpenCode task. So:

1. Update linkC (the update strip restarts it). Its first launch registers linkC in `~/.config/opencode/opencode.json`.
2. Reconnect linkC's tools in every CLI session started outside linkC (Claude Code: `/mcp`).
3. Only then delegate to OpenCode.

## 7. Errors

- OpenCode not installed: `Executable for OPENCODE not found`.
- No model for the tier: refused, as in §5.2.
- A tier's model not listed by OpenCode: delegation refused, as in §5.8.
- `opencode models` or `opencode session list` failing: the delegation or the continue fails with its error.
- `opencode.json` that is not a JSON object: registration reports it and leaves the file untouched.
- An `OPENCODE_CONFIG_CONTENT` in linkC's environment that does not parse: the launch fails naming it.
- A model rejected on screen: a notification, as in §5.7.

## 8. Testing

Unit tests in LinkCKit, each written first and shown to fail with its change reverted:

- `AgentKind.opencode` properties; launch arguments and environment for new and continued sessions: `--auto`, `--model`, `--session`, `OPENCODE_DISABLE_AUTOUPDATE`, `OPENCODE_CONFIG_CONTENT`, the merge into an inherited value, and its refusal of one that does not parse.
- An OpenCode launch with no resolvable model refuses.
- Continue: the newest session in exactly this folder is chosen; a session in another folder of the same project is not; none starts a new session; a failing or unparseable listing fails the launch.
- Registration: a new file; an existing file keeps every other key; an unchanged entry is not rewritten; a file that is not a JSON object is refused and left byte-for-byte; the shared writer refuses the same way; an empty file is read as `{}`.
- `detectAgent(inPath:)` for OpenCode's link and its Cellar path; `resolveCaller` with `LINKC_AGENT=opencode`.
- Screen state from the captured screens: idle reads idle, each working stage reads working, done reads done, prose mentioning the hint reads idle, the toast is found and names the id.
- Tiers: the seeded mapping; `load` fills OpenCode into a saved file without it and leaves a saved OpenCode mapping alone.
- Delegation: refused when the tier's id is not listed, refused when listing fails, accepted when listed — through a fake model lister.
- `linkc_switch_model` refuses for OpenCode; `linkc_get_models` reports its tiers and the note.
- `LimitDetector` flags OpenCode's cap text for `.opencode`, leaves other agents alone, and does not flag a 429.
- The usage row and its order.

Manual, after the update in §6:

- Open an OpenCode session from the menu: the pill reads OPENCODE and stays OPENCODE; the footer shows the default tier's model.
- From Claude, delegate one small task to `opencode`. It completes through `linkc_complete_task`, attributed to OpenCode.
- `~/.config/opencode/opencode.json` keeps its providers, model and other servers, and gains `linkc-multiplier`.
- Set a tier to a made-up id and delegate on it: refused.
- Quit and restore with an OpenCode session open in a worktree: it comes back on its own conversation, in its own folder.

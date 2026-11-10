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
- Catching, on screen, a model OpenCode refused: 2.2.5 shows nothing (§4.1). Delegation checks the model first (§5.8); a session opened from the menu on a withdrawn default-tier model runs on whatever OpenCode picks, which its footer shows.

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
- OpenCode names MCP tools `<server>_<tool>`. Given linkC's real task brief, with a stand-in `linkc-multiplier` server, the then-current free models each called `linkc_start_task` with the task id, did the work, committed it, and called `linkc_complete_task` with `status: done`.
- `-c` continues the newest session of the OpenCode project, and moves to that session's folder. A project is the repo's root commit, so all worktrees of one repo are one project; folders with no commits share one global project. Launched in one folder, `-c` reopened a session from another folder of the same root commit.
- `opencode session list --format json` lists the project's sessions with `id`, `directory`, `updated` (ms) and `projectId`, newest first (about 0.9 s). `opencode --session <id>` opens that session in its folder.
- The foreground process is OpenCode's own binary (`/opt/homebrew/Cellar/opencode/1.18.19/bin/opencode`, through the `/opt/homebrew/bin/opencode` link); its MCP servers are its children.
- OpenCode's retry code reports a free-tier cap as `Free usage exceeded, subscribe to Go`, with a `Free limit reached` action title. This was read from the 1.18.19 binary; no live cap was seen.
- OpenCode's installer puts the binary in `~/.opencode/bin`.

### 4.1 OpenCode 2.2.5 (verified 2026-11-07)

OpenCode updated itself to 2.2.5 through Homebrew the same day (its own auto-update, run from a session in the home folder). linkC targets 2.2.5. What changed from the above:

- The TUI's flags are `--standalone`, `--server`, `--auto`, `--continue`/`-c`, `--session`/`-s` ("Session ID to continue, or to create if it does not exist") and `--prompt`. There is no `--model`: given one, OpenCode prints its help and exits. `opencode run` and `opencode mini` still take `--model`.
- Sessions run in a shared background service (`opencode serve --service`) unless `--standalone` is given, which starts a private `opencode serve --stdio` as the TUI's child. With `--standalone`, `OPENCODE_CONFIG_CONTENT` applies to that session: `{"model": "opencode/big-pickle", "mcp": {…}}` put Big Pickle in the footer and loaded the inline server beside the user's own. The MCP servers are children of the private server, and the stand-in server saw the terminal's `LINKC_SESSION`. A free model given a real task brief called `linkc_start_task` and `linkc_complete_task` as before. Quitting the TUI leaves no private server behind.
- The config's `model` applies to a new session only. `--session <id>` reopens the session on the model it last ran on, whatever the config says.
- An unknown model id in the config shows no notice within 8 s: the session silently runs on another model.
- `OPENCODE_DISABLE_AUTOUPDATE` and `OPENCODE_CONFIG_CONTENT` are still read.
- The working footer is unchanged: an 8-glyph bar of `⬝`/`■`, then the interrupt hint and context size; the folder path once the turn ends. At 46 columns the first seconds of a turn show the bar with no hint (`⬝⬝⬝⬝⬝⬝⬝⬝shift+tab agents  ctrl+p commands`). A Braille spinner row (`⠋ Thinking`) sits right above the input box, and the session title row at the top of the screen carries a Braille spinner while a turn runs. 1.18.19 has no title row and draws `▣  Build · <model>` between the spinner row and the box.
- `opencode models` and `opencode session list --format json` print what 1.18.19 printed (same ids; same `id`, `directory`, `updated` fields, newest first). Both take `--standalone`, which keeps them from starting the shared background service when it is not running; `opencode models --standalone` takes about 1.4 s, `opencode session list --format json --standalone` about 0.6 s.
- The binary is still a native `opencode` executable (`/opt/homebrew/Cellar/opencode/2.2.5/bin/opencode`), and the TUI is the terminal's foreground process.

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

`AgentDescriptor` for `.opencode`: binary `opencode`, candidates `/opt/homebrew/bin/opencode`, `/usr/local/bin/opencode`, `~/.opencode/bin/opencode`; flags `--standalone --auto`; no continue or resume arguments (§5.3). `--standalone` gives each linkC session its own OpenCode server, so the session's environment — its model, linkC's tools, `LINKC_SESSION` — reaches it; the shared background service has the environment of whatever started it.

The terminal environment adds to `LINKC_SESSION`:

- `OPENCODE_DISABLE_AUTOUPDATE=1`, so the update dialog never takes the first text linkC types.
- `OPENCODE_CONFIG_CONTENT` carrying the session's model and linkC's MCP server (§5.4). OpenCode 2.2.5's TUI has no `--model` flag (§4.1), so the model goes here, never in the arguments.

Every OpenCode launch names a model, as Grok's does. A session from the menu or `linkc opencode` without `--tier` runs on the default tier's model and records no tier, so it is never handed a delegated task. A delegated task, or `--tier`, uses its tier's model and records the tier. With no model for the tier, the launch refuses: `no model configured for opencode tier <tier> — set it in linkC settings`. It never leaves the model to OpenCode's own default.

A continued session keeps the model it last ran on (§4.1), so linkC records no model for it. The default tier's model still goes in its config, for when no session ran in the folder and a new one starts.

Menus: OpenCode is under New and Continue last, not under Resume….

### 5.3 Continuing a session

linkC continues an OpenCode session in its own folder only. For `.continueLast` — the menu item, and every restore after a quit — linkC runs `opencode session list --format json --standalone --max-count 10000` in the session's folder (OpenCode lists 100 sessions by default, across every worktree of the project; a listing that reaches the 10,000 asked for fails rather than risk missing this folder's session), takes the newest entry whose `directory` is that folder (both canonicalized with `ProjectPath.canonical`), and launches with `--session <id>`. With no such entry, the session starts new. If the listing fails, or its output does not parse, the launch fails with that error; it does not start a new session in its place.

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

**Injection at launch.** Each OpenCode terminal linkC starts also gets `OPENCODE_CONFIG_CONTENT` with the same `linkc-multiplier` entry and the session's `model`, so linkC's own sessions have the tools even when registration failed. The entry carries no session id: the MCP server inherits `LINKC_SESSION` from OpenCode (§4), so the same text is right in every terminal. If linkC's own environment already holds an `OPENCODE_CONFIG_CONTENT`, linkC merges its entry into that JSON; if that JSON does not parse as an object, the launch fails naming the variable.

### 5.5 Identity

OpenCode runs its own binary with its own registration, so no worker mark is needed. `MCPServer.resolveCaller` finds it by its order: explicit `agent`/`from` → `LINKC_AGENT=opencode` → the `opencode` ancestor process → `.shell`. `LinkCCommand.caller` finds `linkc` run from an OpenCode terminal the same way.

OpenCode sets `OPENCODE=1`, `OPENCODE_PID` and `AGENT=1` on every start, overwriting what it inherits, so linkC does not strip them.

### 5.6 Process detection

`ProcessSnooper.detectAgent(inPath:)` maps an `opencode` executable to `.opencode`. An OpenCode started by hand in a linkC shell pane is picked up like any other agent.

### 5.7 Screen state

OpenCode is screen-read, like every agent but Claude.

- **Working:** the row under the input box opens with OpenCode's 8-glyph progress bar of `⬝`/`■`. The bar alone decides, since a narrow screen can show it with no hint after it (§4.1); prose that mentions the hint does not count. The phrase is the text of the Braille spinner row right above the box, skipping the box's own `┃` rows, the `┃` transcript block above it and 1.18.19's `▣  Build · <model>` header, and never the 2.2.5 session-title row (the screen's first row, which carries a spinner all turn); with no such row it is `Working`.
- **Done:** the bar is gone; `TurnEndDebounce` ends the turn as for the other agents.
- **Not the generic scan:** OpenCode's input box carries none of the prompt markers the generic scan stops at, so an OpenCode screen is read only by these rules, and a finished turn's output above the box is never taken for a running one.
- **Watchdog:** the bar row counts as a live row, so its animation and the ticking context size are not read as progress.

The rules are tested against screens captured from the real TUI, 2.2.5 and 1.18.19, at 92 and 46 columns: idle, working stages, done.

### 5.8 Tiers

`AgentModelSettings.seeded` gains OpenCode, default tier standard:

| Tier | Model |
|---|---|
| light | `opencode/deepseek-v4.1-flash-free` |
| standard | `opencode/big-pickle` |
| deep | `opencode/nemotron-3.5-super-vl-free` |

Ids are stored whole, provider included, so any id `opencode models` lists can go in a tier (`ollama/qwen3.8:27b-32k` among them). `AgentModelStore.load` fills OpenCode into a saved `models.json` that does not mention it, as it did for Grok. Settings > Models shows OpenCode's tiers and default tier after Grok. `AgentModelCatalog.models(for: .opencode)` lists the three seeds. `linkc_get_models` reports OpenCode's tiers.

**A removed model is refused at delegation.** Free models are offered for a limited time (Pulse Alpha Free was withdrawn on 2026-11-06), and OpenCode replaces an unknown id with its default (§4). So `linkc_delegate_task(to: "opencode")` resolves the task's tier — the one asked for, else the default — and runs `opencode models --standalone` in the workspace, inside `linkc-mcp`. When the id is not listed, it refuses: `opencode/<id> (opencode tier <tier>) is not among the models OpenCode lists — free models come and go; set the tier in linkC settings`. When `opencode models` fails, does not answer within 60 seconds, or lists no models, delegation refuses with its error. The check runs in `linkc-mcp`, never on linkC's main thread. Three other paths start an OpenCode worker without passing through `linkc_delegate_task` — a task linkC reroutes to OpenCode off a capped agent, a message to OpenCode with no session to take it, and `linkc opencode --tier X --task`, handled in `AppCoordinator+Open.swift` — and are not checked.

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

## 8. Testing

Unit tests in LinkCKit, each written first and shown to fail with its change reverted:

- `AgentKind.opencode` properties; launch arguments and environment for new and continued sessions: `--standalone --auto`, no `--model`, `--session`, `OPENCODE_DISABLE_AUTOUPDATE`, `OPENCODE_CONFIG_CONTENT` with the model and linkC's server, the merge into an inherited value, and its refusal of one that does not parse.
- An OpenCode launch with no resolvable model refuses.
- Continue: the newest session in exactly this folder is chosen; a session in another folder of the same project is not; none starts a new session; a failing or unparseable listing fails the launch.
- Registration: a new file; an existing file keeps every other key; an unchanged entry is not rewritten; a file that is not a JSON object is refused and left byte-for-byte; the shared writer refuses the same way; an empty file is read as `{}`.
- `detectAgent(inPath:)` for OpenCode's link and its Cellar path; `resolveCaller` with `LINKC_AGENT=opencode`.
- Screen state from the captured screens: idle reads idle, each working stage reads working (the narrow bar with no hint included), done reads done, output and prose above a finished turn's box read idle.
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

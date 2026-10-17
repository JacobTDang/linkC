# Grok Worker: Grok on the Cursor Plan, as Its Own Agent

**Date:** 2026-10-17
**Status:** Approved design, not yet implemented

## 1. Problem

Claude delegates work to agy, Codex and Cursor through linkC. Grok is not among them, though Jacob's Cursor plan includes it: `cursor-agent models` lists `grok-4.7-low` through `grok-4.7-xhigh`, each with a `-fast` variant. He wants Grok as a worker of its own — its own pill, tiers, limits and environment — not as a setting on the Cursor worker.

## 2. Goals

- `linkc_delegate_task(to: "grok", tier: …)` starts or reaches a Grok worker, and Claude controls it like any peer: message it, switch its model, cancel its task, read its completion.
- A Grok worker is told apart from Cursor everywhere: its pill, its identity when it calls linkC's tools, its limit status, its usage row, its tier settings.
- Running Grok never changes Jacob's own Cursor: not its default model, not its chat history.
- Grok holds no credentials of its own. It runs on the Cursor login already in the keychain.

## 3. Non-goals

- The native xAI CLI (`grok`, Grok Build). It needs an xAI account Jacob does not have.
- Tiers for the Cursor worker. Cursor keeps refusing a tier (`cursor cannot be pinned to a model`), unchanged.
- Grok usage figures. Cursor publishes no quota locally; Grok gets the same "cap seen in its terminal" row Cursor has.
- Telling a Grok session apart from a Cursor one when Jacob types `cursor-agent` by hand in a plain terminal. That stays Cursor.

## 4. What the Cursor CLI does (verified 2026-10-17, cursor-agent 2026.10.16-e3cb207)

- `--model <id>` works: `cursor-agent -p --model grok-4.7-low-fast "Reply with exactly the word OK."` answered `OK` in 3.4 s.
- `--model` is persisted as the CLI's default model in `<config dir>/cli-config.json`. A Grok launch against `~/.cursor` would silently move Jacob's own Cursor default to Grok — the probe above did exactly that, and it was reverted by hand.
- `CURSOR_CONFIG_DIR=<dir>` moves `cli-config.json` and `chats/` into `<dir>`, through both `cursor-agent` and the `cursor agent` launcher. The login stays in the keychain: `CURSOR_CONFIG_DIR=<empty dir> cursor-agent status` reports logged in.
- `CURSOR_CONFIG_DIR` does not move the MCP config. User MCP servers are read from `os.homedir()/.cursor/mcp.json` regardless, so a Grok worker loads the same `linkc-multiplier` registration as Cursor, with its `LINKC_AGENT=cursor` env block. Skills and `projects/` transcripts also stay under `~/.cursor`.

## 5. Design

### 5.1 A new agent kind

`AgentKind` gains `case grok`:

| Property | Value |
|---|---|
| `rawValue` | `grok` |
| `pillText` | `GROK` |
| `displayName` | `Grok (via Cursor)` |
| `shortName` | `Grok` |
| `brandColorHex` | `#E5E5EA` (xAI's mark is monochrome; light so it reads on the dark panel) |
| Logo | Grok's mark as a template image, tinted like the other monochrome logos |

### 5.2 Launch

A Grok worker runs Cursor's CLI, resolved exactly as the Cursor worker resolves it, with Cursor's flags (`agent --yolo --trust --approve-mcps`), continue/resume arguments, and always `--model <id>`.

The terminal environment adds two variables to `LINKC_SESSION`:

- `CURSOR_CONFIG_DIR=~/.cursor-grok` — Grok's own CLI settings and chat history. "Continue last" resumes Grok's last chat, never a Cursor one, and Grok's `--model` never touches `~/.cursor/cli-config.json`.
- `LINKC_WORKER=grok` — the worker identity (§5.3).

linkC creates `~/.cursor-grok` before the first launch. If it cannot, the launch fails with an error naming the path.

Every Grok launch names a model. A new Grok session from the menu uses the default tier's model; a delegated task uses its tier's model; a continued or resumed session uses the default tier's model. If no model resolves, the launch refuses with the same message delegation uses (`no model configured for grok tier <tier> — set it in linkC settings`). It never falls back to whatever the CLI's own default is — on a fresh `~/.cursor-grok` that would be Cursor's Auto, not Grok.

### 5.3 Identity

Because the MCP registration is shared (§4), `LINKC_AGENT=cursor` reaches a Grok worker's tool server. `MCPServer.resolveCaller` therefore gains a first step: `LINKC_WORKER`, read from the server's own environment, else from the nearest ancestor's real environment — the same two-step lookup `LINKC_SESSION` already uses (`ProcessSnooper.environmentVariable(_:ofProcess:)`).

New order: `LINKC_WORKER` → explicit `agent`/`from` argument → `LINKC_AGENT` → ancestor process → `.shell`.

`LINKC_WORKER` comes before the explicit argument because linkC set it on the terminal it launched, while a Grok model running inside Cursor's CLI may well call itself `cursor`. `targetAgentTools` (`linkc_switch_model`, `linkc_get_models`) keep reading `agent` as a target, not an identity. A `LINKC_WORKER` value that is not an agent kind is logged to stderr and skipped.

### 5.4 Process detection

`TerminalSession.sampleForegroundAgent` re-labels a session from its foreground process, and a Grok worker's process is `cursor-agent`. Rule: a session launched as `.grok` whose foreground process detects as `.cursor` stays `.grok`. Every other detection is unchanged. A restored Grok session restores as `.grok`.

### 5.5 Tiers and control

`AgentModelSettings.seeded` gains Grok, default tier standard:

| Tier | Model |
|---|---|
| light | `grok-4.7-low` |
| standard | `grok-4.7-medium` |
| deep | `grok-4.7-xhigh` |

A saved `models.json` predates Grok, so `AgentModelStore.load` fills in the seeded mapping for an agent kind the saved file does not mention at all. An agent the file does mention keeps exactly what the file says, empty tiers included. Settings shows Grok's tier fields and default tier next to Claude, Codex and agy.

`AgentModelCatalog.models(for: .grok)` lists the three seeded ids as suggestions. `linkc_switch_model` already validates against the configured tiers and types `/model <id>` into the terminal, which Cursor's CLI accepts (`modelSlashCommands: true`). `linkc_get_models` reports Grok's tiers.

### 5.6 Limits and reroute

Cursor's CLI prints the caps, so `LimitDetector` uses Cursor's rules for `.grok`. Limits are tracked per agent kind, so a capped Grok model leaves Cursor available, and the reverse. Grok is a reroute candidate like every other peer.

### 5.7 Usage row

Grok gets a row after Cursor: `Grok runs on the Cursor plan, which publishes no quota locally — only a cap linkC sees in its terminal`. A cap linkC saw outranks it, as for every agent.

### 5.8 Every list of agents

The compiler flags the exhaustive switches on `AgentKind`. These literal lists and strings it does not flag, and each gains `grok`:

- `AppCoordinator+Relay.swift` `supportedPeers`
- `MCPServer.swift`: `peerCandidates`, `targetAgents`, the usage-status loop, every tool description that lists agents, and every `Supported agents:` error
- `UsageRows.order`
- `SettingsScreen` tier list

Switches with a `default:` branch (`UsageRows.silentSourceReason`, the launch trust switch, `BoardTech`'s agent-named components) are checked by hand. The plan greps for `.cursor` and `"cursor"` and accounts for every hit.

## 6. Rollout

`AgentKind` is persisted in `inbox.json`, the blackboard, and session manifests, and those stores fail loud on a value they cannot decode. A build without `.grok` — the running linkC, or a `linkc-mcp` an MCP client spawned before the update — breaks on the first Grok task. So:

1. Update linkC (the update strip restarts it).
2. Reconnect linkC's tools in every CLI session started outside linkC (Claude Code: `/mcp`).
3. Only then delegate to Grok.

## 7. Errors

- Cursor's CLI not installed: the existing `Executable for GROK not found`.
- No model for the tier: refused, as in §5.2.
- `~/.cursor-grok` cannot be created: the launch fails naming the path.
- A Grok model id Cursor no longer offers: Cursor's CLI fails in the terminal, where it is visible. The ids above were read from `cursor-agent models` on 2026-10-17 and stay editable in Settings.

## 8. Testing

Unit tests in LinkCKit, written first:

- `AgentKind.grok` properties, and the launch arguments and environment: Cursor's flags, `--model`, `CURSOR_CONFIG_DIR`, `LINKC_WORKER`, for new, continue and resume.
- A Grok launch with no resolvable model refuses.
- `resolveCaller`: `LINKC_WORKER=grok` wins over `LINKC_AGENT=cursor` and over an explicit `agent: "cursor"`; found in an ancestor's environment; an unknown value is skipped.
- A `.grok` session whose foreground detects as `.cursor` stays `.grok`; a `.shell` session running `cursor-agent` still becomes `.cursor`.
- Tiers: the seeded Grok mapping; `load` fills Grok into a saved file without it and leaves a saved Grok mapping alone.
- Delegation to `grok` on each tier, and the default tier.
- `LimitDetector` flags Cursor's cap text for `.grok`, and Grok's cap leaves Cursor's status alone.
- The usage row and its order.

Manual, after the update in §6:

- Start a Grok session from the menu: the pill reads GROK and stays GROK.
- From Claude, delegate one small task to `grok`. It completes through `linkc_complete_task`, attributed to Grok.
- `~/.cursor/cli-config.json` still has Jacob's own default model, and the Grok chat sits under `~/.cursor-grok/chats`.

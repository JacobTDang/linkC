# Three New Agents: Freebuff, Kilo and Crush, on Free Models Only

**Date:** 2026-11-12
**Status:** Approved design (branches `feat/freebuff-agent`, `feat/kilo-agent`, `feat/crush-agent`)

## 1. Problem

Jacob wants three more terminal coding agents in linkC, used only on their free tiers:

| Agent | CLI (installed) | Free tier |
|---|---|---|
| **Freebuff** | `freebuff` 0.2.36 (`/opt/homebrew/bin/freebuff`, npm `freebuff`) | Free daily hours (5 a day at limited access), ad-supported. Default model DeepSeek V4.1 Flash. |
| **Kilo** | `kilo` 7.8.27 (`/opt/homebrew/bin/kilo`, npm `@kilocode/cli`). A fork of OpenCode. | A free Kilo account. Only the models whose id marks them free. |
| **Crush** | `crush` 0.101.0 (`/opt/homebrew/bin/crush`, brew `charmbracelet/tap/crush`) | None of its own: Charm's Hyper is paid. Uses OpenRouter's `:free` models with Jacob's free OpenRouter key. |

## 2. Goals

- Each agent is a full linkC agent, as OpenCode is (spec 2026-11-07-opencode-agent):
  - **Panel:** a session opens from the panel's New menu, has its own pill and colour, and Continue and restore work.
  - **State:** linkC reads its screen for working, idle, waiting on a question, and limited.
  - **linkC's tools:** it can use linkC's MCP tools, so it can accept a delegated task and report it.
  - **Delegation:** Claude can delegate to it, and workers start in the panel.
  - **Limits:** a limit is detected and reported at once (spec 2026-11-11-model-choices §7).
- **Free only.** A non-free model is never offered, set, launched or switched to for Kilo or Crush. This uses the same enforcement points as OpenCode's free rule (model-choices spec, §4.3 and §7).
- **Freebuff runs only long tasks.** Jacob: a short session costs the same as a long one. So Freebuff is used only for work that runs a long time: deep research, large implementations, reverse engineering something thoroughly.

## 3. Non-goals

- Paid models, or Charm Hyper.
- Tiers for Freebuff. It has no model flag, so it runs on its own default, as Cursor does.
- Holding credentials. Kilo's account login and Crush's OpenRouter key stay in each CLI's own config, as linkC's architecture requires.

## 4. Shared shape

Each agent follows the OpenCode integration point by point. Read `docs/superpowers/specs/2026-11-07-opencode-agent-design.md` and its plan for every place a new `AgentKind` touches: `AgentKind` and its descriptor, `AgentLogo`, `Theme`, the panel's New menu, `RelaunchPlan`, `ProcessSnooper`, `TerminalPreview`, `LimitDetector`, `UsageRows`, `MCPRegistrar`, `MCPServer`, `LinkCCommand`, `BoardTech`, Settings, and the model lists of spec 2026-11-11-model-choices.

### 4.1 State and limits from real screens

- **Capture:** the screen patterns come from real captures. Run the CLI in tmux and capture with `tmux capture-pane -p`, as the OpenCode plan did. Commit the captures as fixtures under `Tests/LinkCKitTests/Fixtures/`.
- **States:** the screen reader tells apart idle (ready for a prompt), working, waiting on a question or permission prompt, and a limit message.
- **Not states:** ad lines (Freebuff), tips, and banners never count as a state.
- **Limits:**
  - recorded with the reset time when the screen states one, as for the other agents;
  - reported to the delegator at once.
- **Spending:** capturing uses a little of each free tier. Keep each capture session short.

### 4.2 MCP registration

`MCPRegistrar.registerAll` adds linkC's server to each agent's user-level config:

- **Merging:** it merges into the file and never overwrites or drops other servers.
- **Unreadable file:** a file it cannot parse is left untouched, and the failure is reported, as for OpenCode.
- **Per agent:**
  - Freebuff: `~/.agents/mcp.json`, in `mcpServers` format. Freebuff reads `{cwd}/.agents`, `{cwd}/../.agents` and `~/.agents` (see `sdk/src/agents/load-mcp-config.ts` in CodebuffAI/freebuff).
  - Kilo: `~/.config/kilo/kilo.jsonc` (or `kilo.json`), under the `mcp` key, in OpenCode's format. Kilo does not read `~/.config/opencode`.
  - Crush: `~/.config/crush/crush.json`, under the `mcp` key, as `{"type": "stdio", "command": …, "args": …}`.

### 4.3 The free rule and model lists (Kilo and Crush)

- **Listing:** `ModelListParser` and `ModelListRefresher` get a source for each agent. The parsed list keeps free models only.
  - Kilo: `kilo models`, one `provider/model` id per line.
  - Crush: `crush models`, one `provider/model` id per line.
- **Free rule, one function for each agent, used on every path OpenCode's rule guards:**
  - Kilo: an id is free when it starts with `kilo/` and either ends in `:free`, ends in `-free`, or its last path component is `free`. Examples: `kilo/nvidia/nemotron-3.5-super-vl:free`, `kilo/reflection/beam-free`, `kilo/kilo-auto/free`, `kilo/openrouter/free`.
  - Crush: an id is free when it starts with `openrouter/` and ends in `:free`.
- **Starting tiers:**

  | Agent | light | standard (default) | deep |
  |---|---|---|---|
  | Kilo | `kilo/nvidia/nemotron-3.5-lightning:free` | `kilo/kilo-auto/free` | `kilo/nvidia/nemotron-3-ultra-550b-a55b:free` |
  | Crush | `openrouter/nvidia/nemotron-3.5-lightning:free` | `openrouter/nvidia/nemotron-3.5-super-vl:free` | `openrouter/nvidia/nemotron-3-ultra-550b-a55b:free` |

  Each is checked against today's `kilo models` and `crush models` output.
- **Pinning a session's model:** neither CLI takes a TUI model flag, so linkC sets the model through each CLI's per-session config, and never by editing the user's global config.
  - **Kilo:** `KILO_CONFIG_CONTENT` (or `KILO_CONFIG`), the way linkC's OpenCode launch sets its model. Verify on the real CLI that the model shown in Kilo's footer is the pinned one.
  - **Crush:** `CRUSH_GLOBAL_CONFIG` pointing at a per-session file that is the user's global `crush.json` with the `large` and `small` models set to the tier's free model. Merging keeps the user's providers and OpenRouter key. Verify that the session runs the pinned model and that Crush's `small` model is free too.
  - **If neither mechanism pins the model on the real CLI:** stop and report. Never launch an unpinned session, since it could run a paid default.
- **Continue and restore** start a new conversation on the free default model, as for OpenCode (model-choices spec §9). A resumed conversation could be on a paid model.
- **Not set up yet:** if the account or key is missing (Kilo not logged in, no OpenRouter key in Crush), the CLI's own listing or launch fails. That failure is reported at once with what Jacob must do: "run `kilo` and `/connect`", "add an OpenRouter key to Crush". It is never left to wait in the queue.

### 4.4 Freebuff: long tasks only

- **Never chosen by linkC on its own:**
  - Freebuff is never a reroute target when another agent hits a limit.
  - It is never named under "Not limited:" in limit refusals.
  - It is never picked as a fallback.
  - One property on `AgentKind`, `isLongTaskOnly`, says so, and every automatic route checks it.
- **Claude decides:** the descriptions of `linkc_delegate_task` and `linkc_get_models` say that Freebuff is only for long-running work (deep research, large implementations, reverse engineering), because a Freebuff session costs the same however short it is. Claude must not send it short tasks.
- **No tiers:** a Freebuff task with `tier` or `model` is refused with the reason. Every session starts on Freebuff's default.
- **Launch:** `freebuff`, plus `--continue` for Continue and restore. Never `--trust-agents`, because trusting a repository's `.agents` files is the user's call.
- **Hours run out:** reported at once, like any limit, with the time they come back when Freebuff shows it.

## 5. Rollout

- `freebuff`, `kilo` and `crush` are new persisted `AgentKind` values. A `linkc-mcp` from before the update fails loudly on them, so type `/mcp` in CLI sessions started outside linkC after updating.
- Kilo needs one login (`kilo`, then `/connect`, using a free Kilo account).
- Crush needs Jacob's free OpenRouter key, set in Crush.

## 6. Testing

TDD through the existing seams. Tests never run the real CLIs and never read the real config files.

- **Screens:** screen-state and limit tests on the captured fixtures, for each agent.
- **MCP registration:** a new file, a merge into a file with other servers, and an unreadable file left untouched, for each config format.
- **Free rules and parsers:** free and paid ids, and real `kilo models` and `crush models` output.
- **Launches:**
  - the per-session model config for Kilo and Crush, and the user's global config is untouched;
  - Continue and restore start fresh;
  - Freebuff is launched without `--trust-agents`.
- **Freebuff routing:**
  - never a reroute target;
  - never in "Not limited:";
  - `tier` and `model` refused.
- **Full runs:** the full suite, `scripts/tsan.sh`, and `swift build -c release`.

# Freebuff, Kilo and Crush Implementation Plan

> **For agentic workers:** Do your track's tasks in order. Use TDD for every task: write the test, run it and see it fail for the right reason, then implement, then see it pass. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Three new linkC agents on free models only, as `docs/superpowers/specs/2026-11-12-freebuff-kilo-crush-design.md` describes. Read the whole spec first.

**Architecture:** Each agent is added the way OpenCode was. `docs/superpowers/specs/2026-11-07-opencode-agent-design.md` and `docs/superpowers/plans/2026-11-07-opencode-agent.md` are the map of every place a new `AgentKind` touches. Find each place with `grep -rn "opencode" Sources Tests`, and add your agent's case wherever OpenCode has one.

**Tech Stack:** Swift 6, SwiftPM, XCTest, SwiftUI. Library `LinkCKit`, app target `linkc`, MCP server `linkc-mcp`.

## Global Constraints

- **Free models only, on every path.** That covers Settings, delegation, `switch_model`, the New menu, spawn, reroute, the `linkc` command, Continue and restore. A session whose model cannot be pinned to a free one is not launched.
- **Report failures at once.** Every failure is reported at once with its reason (spec 2026-11-11-model-choices §7). A missing login or key says what to do.
- **Fail loud.** No swallowed errors (`try?` that hides a failure, an empty catch, a silent fallback).
- **Test isolation.** Tests never run the real CLIs and never read or write the real `~/.agents`, `~/.config/kilo`, `~/.config/crush` or `~/Library/Application Support/linkC` files. Inject paths and runners. Every `MCPServer(` and `AppCoordinator(` in Tests passes `modelLists: TestModelLists.none`, or the headless init.
- **Real captures.** Run the real CLI in tmux (`tmux new -d -s cap -x 120 -y 40 '<cli>'`, `tmux send-keys`, `tmux capture-pane -p -t cap`, `tmux kill-session -t cap`), as the OpenCode plan did. Keep every session short, because each one uses the free tier. Never type secrets.
- **Commits.** No trailers of any kind (no Co-Authored-By, no Signed-off-by). Never mention any AI, assistant or tool name. If your git adds a trailer, commit with `git commit-tree`. Run `./scripts/check-commits.sh origin/main..HEAD` before you report.
- **Leave linkC alone.** Do not push. Do not launch, quit or signal linkC. Never run `build-app.sh`.
- **Before you report:** run the full `swift test`, then `swift build -c release`. A debug run misses compiler crashes in the release optimizer.

## Track F: Freebuff (branch `feat/freebuff-agent`, worktree `.worktrees/freebuff-agent`)

- [ ] **F1. The agent.**
  - `AgentKind.freebuff`, with every case OpenCode has: display name "Freebuff", pill text, a colour taken from Freebuff's own UI, a logo, and its descriptor.
  - Launch: binary `freebuff`, found in `~/.local/bin`, `/opt/homebrew/bin` and `/usr/local/bin`; `--continue` for Continue and restore; never `--trust-agents`.
  - No tiers: every place OpenCode has tiers, Freebuff is untiered, as Cursor is.
  - Tests: the launch arguments, Continue, and no `--trust-agents`.
- [ ] **F2. MCP registration** into `~/.agents/mcp.json` (`mcpServers`): merge into the file, keep other servers, and leave an unreadable file untouched and report it. Tests use temporary files.
- [ ] **F3. Screens.**
  - Capture these screens to fixtures: idle, working, a question or permission prompt, and an ad line. If it can be seen without spending real hours, also capture the out-of-hours message; otherwise use the wording from Freebuff's source (CodebuffAI/freebuff, `cli/`) and say so in your report.
  - Screen-state and limit tests on the fixtures. An ad line is never a state.
- [ ] **F4. Long tasks only.**
  - Add `AgentKind.isLongTaskOnly`, true only for Freebuff.
  - Every automatic route skips it: the reroute candidate filter in `AppCoordinator+Relay.swift` (`checkLimitsAndReroute`), the "Not limited:" lists in `MCPServer.limitRefusal`, and any fallback.
  - `linkc_delegate_task` to Freebuff with a `tier` or `model` is refused: "Freebuff has no tiers; it runs its own default model."
  - The descriptions of `linkc_delegate_task` and `linkc_get_models` carry the spec §4.4 sentence.
  - Tests for each.
- [ ] **F5.** Full suite and release build, then report.

## Track K: Kilo (branch `feat/kilo-agent`, worktree `.worktrees/kilo-agent`)

- [ ] **K1. The agent.**
  - `AgentKind.kilo` with every case OpenCode has, its colour and logo taken from Kilo's own UI.
  - Launch: binary `kilo`; Continue and restore start a new conversation on the free default model.
  - The model is pinned per session through `KILO_CONFIG_CONTENT` or `KILO_CONFIG`. Check how linkC pins OpenCode's model and mirror it.
  - Verify on the real CLI, in tmux, that Kilo's footer shows the pinned free model. If it does not, stop and report.
  - Tests: launch arguments and env, and that the global config is untouched.
- [ ] **K2. MCP registration** into `~/.config/kilo/kilo.jsonc` (or `kilo.json` if that is the file present) under `mcp`, in OpenCode's format. Reuse OpenCode's registrar writer, which already merges and handles JSONC.
- [ ] **K3. Free rule, list source and tiers.**
  - `KiloFreeModels.isFree` (spec §4.3), with tests on free ids and paid ids.
  - A `kilo models` source in `ModelListParser` and `ModelListRefresher`, keeping free ids only.
  - Seeded tiers from spec §4.3.
  - Enforce free-only on every path where OpenCode's rule runs: grep `OpenCodeFreeModels.isFree` and add Kilo beside it.
- [ ] **K4. Screens.**
  - Capture these to fixtures: idle, working, a permission prompt, the "not logged in" or connect screen, and a free-model rate-limit message. Kilo's UI is OpenCode's, so start from OpenCode's screen reader and change only what differs.
  - Tests on the fixtures.
- [ ] **K5.** A missing login is reported at once with "run `kilo`, then `/connect`". Then the full suite and release build, then report.

## Track C: Crush (branch `feat/crush-agent`, worktree `.worktrees/crush-agent`)

- [ ] **C1. The agent.**
  - `AgentKind.crush` with every case OpenCode has, its colour and logo taken from Crush's UI.
  - Launch: binary `crush`; Continue and restore start a new conversation on the free default model.
  - The model is pinned per session: `CRUSH_GLOBAL_CONFIG` points at a per-session copy of the user's `~/.config/crush/crush.json` (find it with `crush dirs`), with `models.large` and `models.small` set to the tier's free OpenRouter model. The copy keeps the user's providers and key.
  - Verify on the real CLI, in tmux, that the session shows the pinned free model. If it does not, stop and report.
  - Tests: launch env, the per-session config contents, and the user's file untouched. Delete the per-session file when the session ends.
- [ ] **C2. MCP registration** into `~/.config/crush/crush.json` under `mcp` (`{"type": "stdio", "command": …, "args": […]}`): merge into the file, keep other servers, and leave an unreadable file untouched and report it.
- [ ] **C3. Free rule, list source and tiers.**
  - `CrushFreeModels.isFree`: `openrouter/…:free` only (spec §4.3).
  - A `crush models` source, keeping free OpenRouter ids only.
  - Seeded tiers from spec §4.3.
  - Enforce free-only on every path, as in K3.
- [ ] **C4. Screens.**
  - Capture these to fixtures: idle, working, a permission prompt, the "no OpenRouter key" state, and an OpenRouter free-tier rate-limit message (OpenRouter's free models have a daily request cap).
  - Tests on the fixtures.
- [ ] **C5.** A missing OpenRouter key is reported at once with "add an OpenRouter key to Crush". Then the full suite and release build, then report.

## Integration (the integrator)

- Merge the three branches. Each one adds its own case to the same `AgentKind` switches, so the conflicts are mechanical: keep all the cases.
- Update the README: the agents table, plus a paragraph on Freebuff's long-task-only rule.
- Run the full suite, TSan and the release build, then open the PR.

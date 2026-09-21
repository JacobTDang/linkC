# Usage rows: one shape for every agent — design

**Date:** 2026-09-21
**Status:** approved (design, including the footer-hint trade-off below)
**Supersedes** the rows table of `2026-09-19-agent-usage-section-design.md`; that spec's section placement, collapse state, Codex refresh cadence, and Cursor/agy sources stand.

## Why

Jacob, on the shipped section: "its inconsistent … it should just show the current 5 window, and if we hit usage for session or week it will show session or weekly usage hit." The Claude row showed a token count (`367.9M · resets 2h`) and the Codex row a percentage (`22%`), because linkC believed Claude published no percentage.

It does. Claude Code passes its status line a `rate_limits` object (docs: code.claude.com/docs/en/statusline):

```json
"rate_limits": {
  "five_hour": { "used_percentage": 23.5, "resets_at": 1738425600 },
  "seven_day": { "used_percentage": 41.2, "resets_at": 1738857600 }
}
```

`used_percentage` runs 0–100; `resets_at` is Unix seconds. The object is present only for Pro and Max subscribers and only after a session's first API response; each window may be absent, and Claude Code drops a window once its `resets_at` passes. The status line runs on events, debounced at 300 ms.

Verified on Claude Code 2.1.278 with linkC's launch flags: a status line command received `"rate_limits": {"five_hour": {"used_percentage": 66, "resets_at": 1789980000}, "seven_day": {"used_percentage": 92, "resets_at": 1790017200}}` on a Max plan.

## Reading Claude's numbers

- **The hook.** `SettingsComposer` adds a `statusLine` to the per-session settings linkC already passes each Claude session it launches (`--settings session-<id>.json`):
  `{"type": "command", "command": "curl -s -m 2 -X POST -H 'X-LinkC-Token: <token>' -H 'X-LinkC-Event: status_line' --data-binary @- http://127.0.0.1:<port>/hook >/dev/null"}` — the same endpoint, token header, and event header linkC's existing hooks use (the server routes by `X-LinkC-Event`, not by path). It prints nothing, so no status row appears.
- **What it costs.** Any configured status line makes Claude drop the `esc to interrupt` hint from its footer (docs, and verified: the footer reads `⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents` mid-turn). Esc still interrupts. Jacob accepted this trade.
- **Never over the user's own.** When the user's settings, the project's `.claude/settings.json`, or its `.claude/settings.local.json` already define `statusLine`, linkC adds none, and Claude's row reports the reason ("your own status line is configured — linkC can't read Claude's usage").
- **The server.** `HookServer` gives a request whose `X-LinkC-Event` is `status_line` its own path: after the same token check, it decodes only `rate_limits` (tolerant of every other field, and of `rate_limits` being absent) and hands the reading to a new `onStatusLine` callback instead of the session-event decoder. It still always answers 200 at once. A body without `rate_limits`, or with neither window, delivers nothing.
- **The reading.** The coordinator keeps the newest reading (the windows present, plus the time it arrived). Limits are per account, so a reading from any linkC-hosted Claude session serves the whole row. In memory only; after a relaunch the row waits for the next report.

## The rows

The same shape for Claude and Codex (Codex from its rollout snapshot, as today):

| Case | Text | Tone |
|---|---|---|
| Normal | `37% · resets 2h` — the 5-hour window | coral at ≥ 80, else quiet |
| 5-hour window at 100% | `session limit hit · resets 2h` | coral |
| Weekly window at 100% | `weekly limit hit · resets 3d` | coral |
| Both at 100% | the weekly one | coral |
| A cap linkC's detector saw (any agent) | `limit hit · retry 15m` — linkC's own retry wait | coral |
| Stale (older than `AgentUsage.staleAfter`, or the shown window's reset has passed) | same text, dimmed | never coral |
| Nothing known | on the "no usage data" line, with the reason | quiet |

- No token counts anywhere; the `22% · 7d 100%` form is gone.
- "At 100%" compares the rounded percentage, like the coral threshold.
- A "limit hit" row only uses a window that is live (reading fresh and its reset not yet passed).
- Remaining times use `AgeFormat.compact` ("2h", "3d").
- **Headline** (the collapsed section's trailing text): `limit hit` when any row shows a hit; otherwise the highest live 5-hour percentage; nothing when none is known.
- **Help** on a row: the other window's figure and reset, the reading's age, and the plan when known.
- **Unknown reasons** for Claude: "no reading yet — a Claude session reports after its first reply"; "your own status line is configured — linkC can't read Claude's usage".

## Keeping the activity line

`TerminalPreview.liveActivity` (the terminal header's activity line, the sidebar row's subtitle, and the dashboards) knows a Claude turn is running only from that footer hint. Without it, the scan stops at the input box and reports nothing.

It learns Claude's spinner row instead: a row above the input box, led by a spinner glyph, whose phrase ends in `…` followed by a running timer in parentheses — `✳ Bunning… (2s · thinking with xhigh effort)`, `✳ Bunning… (13s · ↓ 417 tokens)`. The activity is the phrase before the parenthesis (`Bunning…`), the same phrase the footer path gives today. A finished turn's summary (`✻ Worked for 13s`) has no ellipsis-and-timer, so it never reads as live. Banner rows between the spinner and the box (`You've used 92% of your weekly limit · resets 2pm`, `◉ xhigh · /effort`) are skipped, as are Claude's todo rows under the spinner. The footer rule stays for sessions launched before this change.

Claude's session state is unaffected: it comes from hooks, never from the screen.

## Architecture

- `ClaudeRateLimits` (LinkCKit, `Usage/`): decodes the status-line body's `rate_limits` into an `AgentUsage` (windows labelled `5h` and `7d`, `observedAt` = arrival time), so both agents feed one row builder.
- `UsageRows.build` takes `claude: AgentUsage?` instead of `WindowUsage?` and applies the table above to both agents through one shared path.
- `SettingsComposer` gains the `statusLine` entry (skipped when one exists); `HookServer` gains the `status_line` event and `onStatusLine`; `AppCoordinator` keeps the reading and exposes it; the sidebar passes it to `UsageRows`.

## Testing

- `ClaudeRateLimitsTests`: the docs' example decodes to two windows; one window; none; absent `rate_limits`; unknown extra fields ignored.
- `SettingsComposer` tests: the status line is added with the port and token; a user or project `statusLine` is left untouched and none is added.
- `HookServer` test: a tokened `status_line` POST delivers a reading to `onStatusLine` and nothing to `onEvent`; a wrong token delivers nothing; a body without `rate_limits` delivers nothing.
- `TerminalTests`: the frames captured with the status line on — a thinking spinner, a token-counter spinner, each with a banner row between it and the box — read as live with the right phrase; a finished turn's `✻ Worked for 13s` above the box reads as idle; the existing footer captures still pass.
- `UsageRowsTests`: every table row for both agents, the weekly-over-session precedence, a stale reading, the headline, the two Claude unknown reasons.
- Each new test revert-proofed.

## Known gaps

- Only Pro and Max plans report `rate_limits`; an API-key session never will, and its row stays on the unknown line.
- The reading refreshes only while some Claude session is active (the status line runs on events).
- linkC-hosted Claude sessions no longer show the `esc to interrupt` hint.

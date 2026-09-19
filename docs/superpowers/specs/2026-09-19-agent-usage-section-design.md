# Agent usage section — design

**Date:** 2026-09-19
**Status:** approved (design), not yet planned or implemented

## Goal

One place in the sidebar that answers "how much have I got left?" for every agent linkC drives,
saying plainly what it knows and what it does not.

## Non-goals

- No new network calls and no new credentials. Every figure comes from a file the agent's own CLI
  already writes, or from what linkC watched happen in its terminals.
- No usage history, charts, or per-session breakdown. The panel footer keeps its own plan line.
- No change to the delegation warning the MCP server already gives (`linkc_get_usage_status`).

## What each agent publishes

| Agent | Source | What it gives |
|---|---|---|
| Claude | `UsageTracker.window` — already maintained for the footer from `~/.claude/projects` transcripts | tokens in the current 5-hour block, its reset, tokens over 7 days. No percentage: no published limit |
| Codex | `CodexUsageReader` over `~/.codex/sessions` rollouts (already used by the MCP server) | percent used and reset for a 5-hour and a weekly window, plus when the snapshot was written |
| Cursor | nothing local — its CLI publishes no quota and its transcripts carry none | only what linkC's own limit detector recorded: `AgentLimitStatus` (reason, `cooldownExpiresAt`) |
| agy | nothing local — it refreshes a quota summary from the server and never writes it to disk | same as Cursor |

Checked on this machine: `cursor-agent --help` and `agy --help` have no usage command; agy's logs show
a `quota_manager` refreshing a `QuotaSummary` that is never written to disk; no file under `~/.cursor`
or `~/.gemini` carries a quota figure.

## The rows

A row is built for every agent, in a fixed order: Claude, Codex, Cursor, agy.

| Case | Row text | Tone |
|---|---|---|
| A percentage window (Codex) | `68% · resets 1h` | coral at ≥ 80, else quiet |
| A token window (Claude) | `1.2M · resets 2h` | quiet |
| A window with no reset time | `68%` / `1.2M` | as above |
| Capped — a limit record whose `cooldownExpiresAt` is in the future | `capped · clears 3h` | coral |
| A reading older than `AgentUsage.staleAfter` (1 h) | the same text, dimmed, help says "read <age> ago" | quiet, never coral |
| Nothing known | the agent joins the "no usage data" line | quiet |

- The figure is the **5-hour window** — the one that bites. Tokens are formatted with
  `UsageFormat.tokens`; a reset is `resets <age>` using `AgeFormat.compact` of the time remaining.
- A stale reading is never coral: a number that might no longer be true must not raise an alarm.
  This mirrors `AgentUsage.windowNeedingWarning`, which already refuses to warn on a stale reading.
- **Help (hover)** on a row: the weekly window when the source has one, the plan when known, and how
  long ago the reading was taken. On the "no usage data" line: why each listed agent has none
  ("Cursor publishes no quota locally", "agy keeps its quota on the server").

## The section

- A collapsible **Usage** section in the sidebar, between Cloud and Earlier, using the existing
  `CollapsibleSection` and a new `SidebarState.Section.usage`. Collapsed by default; the state is
  remembered like the others.
- Its label's trailing text is the highest 5-hour percentage any agent reports (`68%`), so a squeeze
  shows while collapsed; nothing when no agent reports a percentage.
- The section is always present — this is the answer to "what have I got left?", and an empty
  answer is still an answer.
- Rows are not clickable; nothing here launches or focuses anything.

## Where the numbers come from at runtime

- **Claude:** `AppModel.usage.window` — already recomputed continuously; the row reads it.
- **Codex:** a new `AppModel.codexUsage: AgentUsage?`, filled by `CodexUsageReader.read()` on a
  background task at launch and every 5 minutes while the panel is visible. The reader reads only
  the tail of the few newest rollouts. It never runs on the main actor and never blocks a view.
- **Cursor and agy:** `AgentLimitStatus` rows from the inboxes of the workspaces that currently have
  a session, through the existing 1-second-cached `AppModel.inbox(for:)`. When one agent is capped in
  several workspaces, the furthest-out `cooldownExpiresAt` wins.

## Architecture

- **`UsageRows`** (new, `Sources/LinkCKit/Usage/UsageRows.swift`) — the whole decision, pure:

  ```swift
  public struct UsageRow: Equatable, Sendable {
      public let agent: AgentKind
      public let text: String          // "68% · resets 1h", "capped · clears 3h"
      public let isCoral: Bool
      public let isStale: Bool
      public let help: String
  }

  public enum UsageRows {
      public static func rows(
          claude: WindowUsage?,        // AppModel.usage.window
          codex: AgentUsage?,          // nil until the first read completes
          limits: [AgentKind: AgentLimitStatus],
          now: Date
      ) -> (rows: [UsageRow], unknown: [AgentKind], headline: String?)
  }
  ```

  `unknown` is the agents with nothing to report, in the same fixed order; `headline` is the section
  label's trailing text.
- **View:** `UsageSection` in `Sources/linkc/Sidebar.swift`, drawing `UsageRows.rows(...)` with the
  sidebar's own row look (agent mark, name, trailing figure), plus the dim unknown line.
- **`AppModel`** gains `codexUsage` and the refresh task; the existing sweep and `inbox(for:)` supply
  the rest. No view body writes state.

## Error handling

- A failing or absent Codex reader yields `AgentUsage.unavailable(reason:)`; Codex then appears on
  the "no usage data" line and its reason is the help text. Nothing is silently empty.
- An unreadable inbox is already logged once by `AppModel.inbox(for:)`; a missing inbox simply means
  no limit is known.

## Testing

`UsageRowsTests` in `LinkCKitTests`, test-first, covering: a percentage row and its reset; the coral
threshold at exactly 80; a token row; a missing reset; a capped row from a limit record and the
furthest-out cooldown winning; an expired cooldown falling to unknown; a stale reading rendering
dimmed and never coral; the fixed agent order; the unknown list; and the headline picking the highest
percentage (and being nil with no percentages). Each is revert-proofed. The view is checked on screen
after an install.

## Known gaps

- Claude has no percentage, so its row cannot say how close to a limit it is — only how much it has
  spent in the window.
- Cursor and agy only ever show a cap linkC itself saw; a cap hit outside linkC is invisible.
- The Codex reading can be up to 5 minutes old (its age is in the row's help).

# Live usage tracking

## Problem

linkC shows nothing about consumption. Three layers matter, each with its own home:

1. **Context fill (per session)** — how close a session's conversation is to auto-compact.
2. **Session totals (per session)** — tokens and approximate dollars a session has consumed.
3. **Plan window (global)** — tokens consumed across *all* claude activity in the current
   5-hour block and trailing 7 days, with the block's reset time.

## Data source

Every hook event claude sends linkC includes `transcript_path` (currently ignored by the
decoder). Transcript JSONL lines for assistant messages carry `message.usage`
(`input_tokens`, `cache_read_input_tokens`, `cache_creation_input_tokens`,
`output_tokens`), `message.model`, `timestamp`, and `isSidechain` (subagent traffic).

- **Context fill** = the last main-chain (non-sidechain) assistant message's
  `input + cache_read + cache_creation`, against the model's context window (200k default).
- **Session totals** = sum of usage over all the session's assistant messages (sidechains
  included — they consume real tokens), priced by a built-in per-model table (marked `~`).
- **Plan window** = the same sums across every transcript under `~/.claude/projects` with
  recent activity, bucketed into the current 5h block (ccusage-style approximation: block
  starts at the first activity after a ≥5h gap, floored to its hour; resets 5h later) and a
  rolling 7-day total. Absolute numbers only — no invented percentages of unpublished limits.

Reads are incremental: a tail reader remembers a byte offset per file and parses only
appended lines (offset reset on truncation). Updates are hook-driven, with a timer backstop:
per-session reads piggyback the home view's existing 1s preview tick (cheap incremental
tail); the global scan refreshes every 60s while the panel is visible and on every hook event.

## UI

- **Home card**: a 2pt hairline bar along the card's bottom edge showing context fill —
  tertiary white, warming to amber past 75%. Absent entirely until data exists.
- **Terminal chrome** (session open): a quiet center label — `142k · ~$1.87`.
- **Home footer**: one tertiary line pinned under the list — `5h · 3.1M tok · resets ~2am · 7d · 41M`.
  The only place plan usage appears.

## Components (LinkCKit `Usage/`)

- `MessageUsage` — parsed per-line record: timestamp, model, four token counts, isSidechain.
  `TranscriptUsage.parseLine(String) -> MessageUsage?` pure; non-assistant/usage-less lines → nil.
- `TranscriptTailReader` — per-path byte-offset incremental line reader.
- `ModelPricing` — model-id prefix → $/MTok (input, output, cache read, cache write);
  `cost(of: MessageUsage) -> Double`. Unknown models cost 0 and are excluded from `~$` (never guessed).
- `UsageWindows` — pure block/window math over `[MessageUsage]`: current 5h block total +
  reset date, trailing 7d total.
- `UsageTracker` (@MainActor, observable) — owns reader offsets and aggregates; fed
  transcript paths from hook events; exposes per-session `SessionUsage` (context tokens,
  total tokens, approx cost) and global `WindowUsage`.
- Hook decoder gains `transcriptPath`; `AppCoordinator` forwards it to the tracker.

## Testing

TDD for everything pure: line parsing (assistant/sidechain/malformed/non-usage), tail reader
(append, truncate, fresh file), window math (block boundaries, gap resets, 7d pruning),
pricing (known model, unknown model → excluded). UI layers are SwiftUI — verified by
rebuild and screenshot.

## Out of scope

True plan-limit percentages (limits unpublished), weekly reset schedules (account-specific),
OTEL, cost budgets/alerts.

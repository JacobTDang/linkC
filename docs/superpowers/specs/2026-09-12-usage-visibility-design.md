# Usage Visibility: What Each Agent Has Left, Read From Its Own Files

**Date:** 2026-09-12
**Status:** Approved design, not yet implemented
**Depends on:** per-task model selection (`bc4ec2b`), the limit-detector fixes (`3887c31`, `7ce2e57`)

## 1. Problem

An orchestrator decides which agent gets a task with no idea what any of them has left. It can pick the agent that is one call from its ceiling while another sits idle at 20%, and it only finds out when work fails mid-flight.

`linkc_get_usage_status` looks like the answer and is not. Its description promises "current token usage, 5-hour rolling window stats, reset timestamps, and active rate limits". What it returns is a list of active limits and a per-agent default model — and those model names come from `AgentModelCatalog`, the stale hardcoded table, so it reports `gpt-4o` for Codex when the configured model is `gpt-5.6-sol`. Today it is worse than nothing: an agent that trusts it is misinformed twice.

Meanwhile linkC already computes real numbers for Claude — `UsageWindows` derives a 5-hour block, its reset, and a 7-day total from the transcripts — and draws them in the panel footer. The MCP server is a separate process and cannot see any of it.

There is also a harder lesson behind this. linkC inferred exhaustion by scraping terminal text, and on 2026-09-12 that read ordinary prose as a limit ten times, spending Codex quota on invented work. Codex writes its exact quota state to a file on every turn. Reading the file is not merely more convenient than scraping; it is the difference between knowing and guessing.

## 2. Goals

- An orchestrator can ask what each agent has left, and get numbers that come from that agent's own records.
- Every figure says how old it is. A stale number is labelled, never presented as current.
- An agent with no readable usage source says so. It never reports zero, which would read as "completely fresh".
- Delegating to an agent that is nearly out says so in the result, without blocking the delegation.
- `linkc_get_usage_status` describes exactly what it returns.

## 3. Non-goals

- Refusing a delegation on usage grounds. The orchestrator decides; linkC informs. (Revisit only if warnings prove insufficient.)
- Inventing a percentage where the provider publishes no limit. Claude's remaining share is not knowable from the transcripts, so it is not claimed.
- Cost or dollar figures. `ModelPricing` exists for the footer and is untouched here.
- Live subscription or push. Usage is read when asked.
- Replacing the terminal-scraped limit detector. That is spec two's job; this spec gives the structured source that makes its removal possible.

## 4. What each agent actually exposes

| Agent | Source | What it yields |
|---|---|---|
| codex | `~/.codex/sessions/**/rollout-*.jsonl`, newest file holding a `rate_limits` payload | `primary` and `secondary` windows with `used_percent`, `window_minutes`, `resets_at` (epoch seconds); `plan_type`; credit balance; cumulative `total_token_usage` |
| claude | `~/.claude/projects/**/*.jsonl` via the existing `UsageWindows` | 5-hour block tokens, block reset time, 7-day tokens. No percentage — Anthropic publishes no per-plan limit |
| agy | none found | unavailable |
| cursor | none found | unavailable |

Codex's limits are account-wide (`limit_id: "codex"`), so the newest session's file is authoritative regardless of which session wrote it.

## 5. The data model

```swift
/// One provider window — 5-hour, weekly — as that provider reports it.
public struct UsageWindow: Sendable, Equatable {
    public let label: String          // "5h", "7d"
    public let usedPercent: Double?   // nil when the provider publishes no limit
    public let tokens: Int?           // nil when the provider reports only a percentage
    public let resetsAt: Date?
}

/// What one agent has left, and how fresh that knowledge is.
public struct AgentUsage: Sendable, Equatable {
    public let agent: AgentKind
    public let windows: [UsageWindow]
    public let planType: String?
    /// When the underlying record was written. nil means no source was readable.
    public let observedAt: Date?
    /// Why nothing is known, when `windows` is empty — always a reason, never silence.
    public let unavailableReason: String?

    /// Past this, a delegation warns. Chosen so a warning still leaves room to finish the task.
    public static let warnThreshold: Double = 80
}
```

A reading whose `observedAt` is older than one hour is rendered as stale. The threshold is one constant, not a scatter of literals.

## 6. Reading, and refusing to guess

Two readers, each pure and testable against a fixture directory:

- `CodexUsageReader(sessionsDirectory:)` — lists `rollout-*.jsonl` newest first, reads at most the 5 newest and only the trailing 64 KB of each, and takes the last `rate_limits` payload it finds. It stops at the first file that yields one. A missing directory, no files, no `rate_limits` line, or malformed JSON each produce an `AgentUsage` with an `unavailableReason` naming which of those it was.
- `ClaudeUsageReader(projectsDirectory:)` — reuses `UsageWindows` over the transcripts to produce the 5-hour and 7-day figures with `usedPercent: nil`.

Both are constructed with their directory injected so tests never touch the real home directory, matching how `AgentModelStore` and `WatchedEndpointsStore` are already testable.

Neither reader is allowed to substitute a value. A file it cannot parse is reported as unavailable with the reason, in line with this project's rule against silent fallbacks.

## 7. What `linkc_get_usage_status` returns

```
# Agent Usage

## Codex — plan plus
- **5h**: 23% used, resets 14:04 (in 2h 11m)
- **7d**: 39% used, resets Sep 18 09:21
- observed 4m ago

## Claude Code
- **5h**: 1.24M tokens, resets 11:00 (in 38m)
- **7d**: 8.41M tokens
- no percentage available — Anthropic publishes no per-plan limit
- observed 1m ago

## Antigravity (agy)
- no usage data available: agy writes no local session records

## Active Rate Limits
_No active rate limits recorded across workspace agents._
```

The active-limits section stays, since a recorded cooldown is real and useful. The per-agent default model line is removed: it was the stale-catalog lie, and `linkc_get_models` already reports the configured mapping correctly. The tool's description is rewritten to promise exactly this.

## 8. The delegation warning

When `linkc_delegate_task` succeeds and the target's usage is readable and past `AgentUsage.warnThreshold` in any window, one line is appended to the result:

```
Task 4F21A0C3 created. Codex is at 86% of its 5h window, resets 14:04.
```

Rules: the delegation still happens; the warning never replaces a refusal; an unreadable or stale-beyond-an-hour reading produces no warning rather than a misleading one; and reading usage must never fail a delegation — a reader that throws is logged and the delegation proceeds unannotated.

## 9. Failure modes, stated plainly

| Situation | Behaviour |
|---|---|
| No source directory | `unavailableReason: "no ~/.codex/sessions directory"` |
| Directory present, no rollout files | `unavailableReason: "no session records found"` |
| Files present, none carry rate limits | `unavailableReason: "no rate-limit record in the 5 newest sessions"` |
| Malformed JSON on the line that matters | `unavailableReason: "rate-limit record could not be read"`, logged with the path |
| Reading older than one hour | Rendered with the age and marked stale; no warning issued from it |
| Reader throws during a delegation | Logged; the delegation result carries no usage line |

## 10. Testing

- `CodexUsageReaderTests`: a fixture directory with two rollout files where the newer one carries the limits; percentages, window labels and resets parsed exactly; each of the five failure modes above; a 64 KB tail boundary case where the record sits near the cut.
- `ClaudeUsageReaderTests`: fixture transcripts producing known block and week totals, with `usedPercent` nil.
- `AgentUsageTests`: staleness rendering at 59 and 61 minutes; the warn threshold at 79.9, 80 and 80.1.
- `MCPServerUsageTests`: the rendered output for a mixed workspace (Codex readable, Claude readable, agy unavailable); no default-model line; the description matches the fields returned; a reader that throws still returns a result rather than an error.
- `MCPServerTaskTests`: a delegation past the threshold carries the warning line; one under it does not; an unavailable reading produces no line; a throwing reader does not fail the delegation.

## 11. Rollout

`./build-app.sh`, then restart linkC and its MCP clients so every agent's server picks up the new tool. No state migration: nothing new is persisted, and the readers only read files their CLIs already write.

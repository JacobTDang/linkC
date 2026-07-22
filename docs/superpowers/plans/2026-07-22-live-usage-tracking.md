# Live Usage Tracking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Track context fill per session (hairline bar on cards), session token/dollar totals (terminal chrome), and 5h/7d plan-window usage (home footer) — live, from the transcript JSONL files claude already writes.

**Architecture:** A new `Sources/LinkCKit/Usage/` group holds pure, unit-tested pieces — line parsing, pricing, window math, incremental tail reading, display formatting — composed by a `@MainActor @Observable UsageTracker`. Hook events (which carry `transcript_path`, currently ignored) bind sessions to transcripts and trigger refreshes; a 5s timer while the panel is visible keeps it live. UI is three small additions to `PanelView.swift`.

**Tech Stack:** Swift 6 / SwiftUI, XCTest, no new dependencies.

## Global Constraints

- No new packages. Fail loud. Unknown models are excluded from `~$` estimates, never guessed.
- Pricing $/MTok (from current Anthropic docs, cache read = 0.1× input, write 1.25×/2× for 5m/1h TTL):
  fable-5 & mythos 10/50 (read 1.00, w5m 12.50, w1h 20.00); opus-4-5…4-8 5/25 (0.50/6.25/10.00);
  sonnet-5 intro 2/10 (0.20/2.50/4.00); sonnet-4-x 3/15 (0.30/3.75/6.00); haiku-4-x 1/5 (0.10/1.25/2.00).
- Context window denominator: 200k (Claude Code default), 1M when the model id contains "[1m]".
- All dollar figures rendered with a `~` prefix (approximate). Copy: `5h · 3.1M tok · resets ~2am · 7d · 41M`.
- Approximations (documented in code): global scan caps first-read at a 4MB tail per file and only scans files modified in the last 7d; missing `cache_creation` breakdown bills the total at the cheaper 5m write rate.

---

### Task 1: `TranscriptUsage.parseLine` → `MessageUsage`

**Files:** Create `Sources/LinkCKit/Usage/TranscriptUsage.swift`; Test `Tests/LinkCKitTests/UsageTests.swift` (new).

**Produces:** `public struct MessageUsage: Equatable, Sendable` — `timestamp: Date`, `model: String`, `inputTokens/cacheReadTokens/cacheWrite5mTokens/cacheWrite1hTokens/outputTokens: Int`, `isSidechain: Bool`; computed `cacheWriteTokens`, `contextTokens` (input+cacheRead+cacheWrite), `totalTokens` (context+output). `public enum TranscriptUsage { static func parseLine(_ line: String) -> MessageUsage? }` — nil for non-assistant lines, missing usage, or malformed JSON. ISO8601 timestamps with and without fractional seconds. `cache_creation.ephemeral_{5m,1h}_input_tokens` split preferred; falls back to `cache_creation_input_tokens` billed as 5m.

- [ ] Failing tests: real-shaped assistant line parses (all fields); sidechain flag honored; user/malformed/usage-less lines → nil; fractional + whole-second timestamps.
- [ ] Verify RED (`swift test --filter UsageTests` → compile failure), implement, verify GREEN, commit.

### Task 2: `ModelPricing`

**Files:** Create `Sources/LinkCKit/Usage/ModelPricing.swift`; Test in `UsageTests.swift`.

**Produces:** `public enum ModelPricing { static func cost(of: MessageUsage) -> Double? }` — prefix-matched table from Global Constraints; nil for unknown model ids.

- [ ] Failing tests: known-model cost arithmetic exact (hand-computed expected value); unknown model → nil; each family prefix resolves.
- [ ] RED → implement → GREEN → commit (with Task 3).

### Task 3: `UsageWindows`

**Files:** Create `Sources/LinkCKit/Usage/UsageWindows.swift`; Test in `UsageTests.swift`.

**Produces:** `public struct WindowUsage: Equatable` (`blockTokens: Int`, `blockResetAt: Date?`, `weekTokens: Int`); `public enum UsageWindows { static func compute(_ usages: [MessageUsage], now: Date) -> WindowUsage }`. Block = ccusage-style: iterate ascending, block starts at the hour-floor of the first entry ≥5h after the previous block start; active only if `now < start+5h`, else zero/nil. Week = totalTokens sum in trailing 7d.

- [ ] Failing tests: single recent burst → active block with hour-floored reset; ≥5h gap starts a new block; stale activity → no active block; 7d pruning.
- [ ] RED → implement → GREEN → commit Tasks 2+3 together.

### Task 4: `TranscriptTailReader`

**Files:** Create `Sources/LinkCKit/Usage/TranscriptTailReader.swift`; Test in `UsageTests.swift`.

**Produces:** `public final class TranscriptTailReader { func readNewLines(at path: String, firstReadTailCap: Int? = nil) -> [String] }` — per-path byte offsets; only complete (newline-terminated) lines consumed; offset resets on truncation; optional first-read cap seeks to `size - cap` and drops the first partial line; missing file → [].

- [ ] Failing tests: full read then appended-only read; partial trailing line withheld until completed; truncation reset; tail cap drops the leading partial line.
- [ ] RED → implement → GREEN → commit.

### Task 5: `UsageFormat`

**Files:** Create `Sources/LinkCKit/Usage/UsageFormat.swift`; Test in `UsageTests.swift`.

**Produces:** `public enum UsageFormat { static func tokens(Int) -> String; static func dollars(Double) -> String; static func resetTime(Date, timeZone: TimeZone = .current) -> String }` — `950`→"950", `12_400`→"12.4k", `3_100_000`→"3.1M"; dollars → "~$1.87" (floor at "~$0.01" for positive sub-cent); resetTime → "~2am" / "~2:30pm" (en_US_POSIX, minutes only when non-zero).

- [ ] RED → implement → GREEN → commit.

### Task 6: `UsageTracker` + hook plumbing

**Files:** Create `Sources/LinkCKit/Usage/UsageTracker.swift`; Modify `Sources/LinkCKit/Hooks/HookEventDecoder.swift` (+`transcript_path`), the `HookEvent` struct (add `transcriptPath: String? = nil`), `Sources/LinkCKit/App/AppCoordinator.swift` (`public weak var usageTracker` hookup in `handle`); Test `UsageTests.swift` + `HooksTests.swift`.

**Produces:** `@MainActor @Observable public final class UsageTracker`:
- `init(projectsDir: URL = ~/.claude/projects)`
- `bind(sessionId:transcriptPath:)`, `refreshSession(_:)`, `sessionUsage(_:) -> SessionUsage?` where `SessionUsage` = `contextTokens/totalTokens: Int`, `cost: Double`, `hasUnpricedTokens: Bool`, `contextFill: Double` (denominator per Global Constraints, capped at 1)
- `refreshWindow(now: Date = Date())` scanning `projectsDir` for 7d-fresh `.jsonl` (4MB first-read cap), exposing `window: WindowUsage?`
- Context = last non-sidechain message's `contextTokens`; totals include sidechains.

In `AppCoordinator.handle`, after `store.apply`: bind + refreshSession when the event carries a transcript path.

- [ ] Failing tests: decoder surfaces `transcript_path`; tracker binds/reads a temp transcript and reports session usage; incremental append updates; window scan over a temp projects dir.
- [ ] RED → implement → GREEN → commit.

### Task 7: UI + liveness

**Files:** Modify `Sources/linkc/LinkCApp.swift` (AppModel: `usage` tracker, wiring into coordinator, 5s timer gated on `panelVisible`, `windowUsageLabel`, `contextFill(_:)`, `selectedUsageLabel`), `Sources/linkc/PanelView.swift` (HomeCard hairline bar, home footer line, terminal-chrome label), `Sources/linkc/Theme.swift` (`contextWarn` gold).

- Hairline: 2pt bar flush to the card's bottom edge, white 0.25 fill on white 0.08 track, `contextWarn` past 75%; hidden when no data.
- Footer: one tertiary 10pt line under the home list: `5h · 3.1M tok · resets ~2am · 7d · 41M`; hidden until a window exists.
- Terminal chrome: quiet centered `142k · ~$1.87` while a session is open (tokens only when the model is unpriced).

- [ ] Implement; `swift build && swift test` green; TSan; `./build-app.sh`; swap (live-session check); user screenshot check.

# Agent Usage Section Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A collapsible "Usage" section in linkC's sidebar showing, for every agent, how much of its 5-hour window is gone and when it resets — or plainly saying why nothing is known.

**Architecture:** One pure type in LinkCKit (`UsageRows`) turns three inputs — Claude's running token window, Codex's own rate-limit snapshot, and the limit records linkC's detector wrote — into rows, an unknown list, and a headline. The app target adds a background re-read of the Codex snapshot and a thin SwiftUI section that draws the result.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, SwiftPM, XCTest. macOS 14.

**Spec:** `docs/superpowers/specs/2026-09-19-agent-usage-section-design.md`

## Global Constraints

- No new dependencies, no network calls, no credentials. Every figure comes from a file an agent's own CLI already writes, or from linkC's own limit records.
- Commit messages must never contain the word "claude" in any case, and carry no `Co-Authored-By`, `Claude-Session`, or "Generated with" trailers. Check with `git log -1 --format=%B | grep -ci claude` → `0`.
- Mock data only in tests. No test-only branches in production code.
- No side effects in SwiftUI view bodies; no blocking work on the main actor.
- Never run `./build-app.sh`, install or launch the app, or touch `~/.local/bin/linkc-mcp` — the user's live agent sessions run inside the installed app.
- Row order is fixed: Claude, Codex, Cursor, agy. Nothing reshuffles as numbers change.
- Exact row texts: `68% · resets 1h`, `1.2M · resets 2h`, `capped · clears 3h`, and the figure alone when there is no reset time.
- A stale reading (older than `AgentUsage.staleAfter`, or whose window's reset has already passed) is dimmed, never coral, and never contributes to the headline.
- Coral at or above `AgentUsage.warnThreshold` (80), and whenever an agent is capped.
- Tokens format with `UsageFormat.tokens`; every age or remaining time with `AgeFormat.compact`.
- Run one test class with `swift test --filter LinkCKitTests.<ClassName>`; the full suite with `swift test`. Both take minutes — use a Bash timeout of 600000 ms.

---

### Task 1: The rows

**Files:**
- Create: `Sources/LinkCKit/Usage/UsageRows.swift`
- Test: `Tests/LinkCKitTests/UsageRowsTests.swift`

**Interfaces:**
- Consumes (all existing):
  - `WindowUsage` (`Sources/LinkCKit/Usage/UsageWindows.swift`): `blockTokens: Int`, `blockResetAt: Date?`, `weekTokens: Int`
  - `AgentUsage` (`Sources/LinkCKit/Usage/AgentUsage.swift`): `agent`, `windows: [UsageWindow]`, `planType: String?`, `observedAt: Date?`, `unavailableReason: String?`, and the constants `AgentUsage.warnThreshold` (80) and `AgentUsage.staleAfter` (3600); `UsageWindow`: `label: String` ("5h", "7d"), `usedPercent: Double?`, `tokens: Int?`, `resetsAt: Date?`
  - `AgentLimitStatus` (`Sources/LinkCKit/Blackboard/InboxModels.swift`): `agent`, `reason: String`, `limitedAt: Date`, `cooldownExpiresAt: Date`
  - `UsageFormat.tokens(_:)`, `AgeFormat.compact(from:to:)`, `AgentKind.shortName`
- Produces:
  - `UsageRow` (`agent`, `text`, `isCoral`, `isStale`, `help`; `id == agent`)
  - `UnknownUsage` (`agent`, `reason`; `id == agent`)
  - `UsageRows.Result` (`rows: [UsageRow]`, `unknown: [UnknownUsage]`, `headline: String?`)
  - `UsageRows.order: [AgentKind]`
  - `UsageRows.build(claude:codex:limits:now:) -> Result`

- [ ] **Step 1: Write the failing tests**

Create `Tests/LinkCKitTests/UsageRowsTests.swift`:

```swift
import XCTest
@testable import LinkCKit

final class UsageRowsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func codex(
        percent: Double?, resetsIn: TimeInterval? = 3600, weekPercent: Double? = 31,
        observedAgo: TimeInterval = 120, plan: String? = "pro", reason: String? = nil
    ) -> AgentUsage {
        var windows: [UsageWindow] = []
        if let percent {
            windows.append(UsageWindow(
                label: "5h", usedPercent: percent, tokens: nil,
                resetsAt: resetsIn.map { now.addingTimeInterval($0) }))
        }
        if let weekPercent {
            windows.append(UsageWindow(
                label: "7d", usedPercent: weekPercent, tokens: nil,
                resetsAt: now.addingTimeInterval(86_400)))
        }
        return AgentUsage(
            agent: .codex, windows: windows, planType: plan,
            observedAt: reason == nil ? now.addingTimeInterval(-observedAgo) : nil,
            unavailableReason: reason)
    }

    private func cap(_ agent: AgentKind, clearsIn: TimeInterval, reason: String = "usage cap") -> AgentLimitStatus {
        AgentLimitStatus(
            agent: agent, reason: reason, limitedAt: now.addingTimeInterval(-60),
            cooldownExpiresAt: now.addingTimeInterval(clearsIn))
    }

    private func build(
        claude: WindowUsage? = nil, codex: AgentUsage? = nil, limits: [AgentKind: AgentLimitStatus] = [:]
    ) -> UsageRows.Result {
        UsageRows.build(claude: claude, codex: codex, limits: limits, now: now)
    }

    private func row(_ result: UsageRows.Result, _ agent: AgentKind) -> UsageRow? {
        result.rows.first { $0.agent == agent }
    }

    func testTheRowOrderIsFixed() {
        let result = build(
            claude: WindowUsage(blockTokens: 1_200_000, blockResetAt: now.addingTimeInterval(7200), weekTokens: 9_800_000),
            codex: codex(percent: 68),
            limits: [.cursor: cap(.cursor, clearsIn: 10_800), .agy: cap(.agy, clearsIn: 600)])
        XCTAssertEqual(result.rows.map(\.agent), [.claude, .codex, .cursor, .agy])
        XCTAssertTrue(result.unknown.isEmpty)
    }

    func testACodexRowShowsItsPercentageAndReset() {
        let result = build(codex: codex(percent: 68))
        XCTAssertEqual(row(result, .codex)?.text, "68% · resets 1h")
        XCTAssertEqual(row(result, .codex)?.isCoral, false)
        XCTAssertEqual(row(result, .codex)?.isStale, false)
        XCTAssertEqual(row(result, .codex)?.help.contains("7d 31%"), true)
        XCTAssertEqual(row(result, .codex)?.help.contains("pro"), true)
        XCTAssertEqual(row(result, .codex)?.help.contains("read 2m ago"), true)
    }

    func testTheCoralThresholdStartsAtEighty() {
        XCTAssertEqual(build(codex: codex(percent: 79.4)).rows.first?.isCoral, false)
        XCTAssertEqual(build(codex: codex(percent: 80)).rows.first?.isCoral, true)
    }

    func testAClaudeRowCountsTheBlocksTokensAndNamesTheWeek() {
        let window = WindowUsage(
            blockTokens: 1_200_000, blockResetAt: now.addingTimeInterval(7200), weekTokens: 9_800_000)
        let claude = row(build(claude: window), .claude)
        XCTAssertEqual(claude?.text, "1.2M · resets 2h")
        XCTAssertEqual(claude?.isCoral, false, "no published limit: a token count can never be an alarm")
        XCTAssertEqual(claude?.help.contains("9.8M"), true)
    }

    func testAFigureWithNoResetTimeStandsAlone() {
        XCTAssertEqual(build(codex: codex(percent: 68, resetsIn: nil)).rows.first?.text, "68%")
        let window = WindowUsage(blockTokens: 1_200_000, blockResetAt: nil, weekTokens: 0)
        XCTAssertEqual(build(claude: window).rows.first?.text, "1.2M")
    }

    func testAPassedResetMakesTheReadingStaleAndNeverCoral() {
        let result = build(codex: codex(percent: 92, resetsIn: -60))
        XCTAssertEqual(result.rows.first?.text, "92%", "the window moved on: no reset is claimed")
        XCTAssertEqual(result.rows.first?.isStale, true)
        XCTAssertEqual(result.rows.first?.isCoral, false)
        XCTAssertNil(result.headline)
    }

    func testAnOldReadingIsStaleAndNeverCoral() {
        let result = build(codex: codex(percent: 92, observedAgo: AgentUsage.staleAfter + 60))
        XCTAssertEqual(result.rows.first?.isStale, true)
        XCTAssertEqual(result.rows.first?.isCoral, false)
        XCTAssertNil(result.headline)
    }

    func testACapWinsOverEveryOtherSource() {
        let result = build(codex: codex(percent: 12), limits: [.codex: cap(.codex, clearsIn: 10_800)])
        XCTAssertEqual(row(result, .codex)?.text, "capped · clears 3h")
        XCTAssertEqual(row(result, .codex)?.isCoral, true)
        XCTAssertEqual(row(result, .codex)?.help.contains("usage cap"), true)
        XCTAssertNil(result.headline, "a capped agent reports no percentage")
    }

    func testAnExpiredCapFallsThroughToNoUsageData() {
        let expired = AgentLimitStatus(
            agent: .cursor, reason: "usage cap", limitedAt: now.addingTimeInterval(-7200),
            cooldownExpiresAt: now.addingTimeInterval(-60))
        let result = build(limits: [.cursor: expired])
        XCTAssertTrue(result.rows.isEmpty)
        XCTAssertEqual(result.unknown.map(\.agent), UsageRows.order)
    }

    func testAgentsWithNoSourceAreListedWithTheirReason() {
        let result = build(codex: codex(percent: nil, weekPercent: nil, reason: "no session records found"))
        XCTAssertEqual(result.unknown.map(\.agent), [.claude, .codex, .cursor, .agy])
        XCTAssertEqual(result.unknown.first { $0.agent == .codex }?.reason, "no session records found")
        XCTAssertEqual(result.unknown.first { $0.agent == .cursor }?.reason.isEmpty, false)
        XCTAssertEqual(result.unknown.first { $0.agent == .agy }?.reason.isEmpty, false)
    }

    func testTheHeadlineIsTheHighestLivePercentage() {
        XCTAssertEqual(build(codex: codex(percent: 68)).headline, "68%")
        XCTAssertNil(build(claude: WindowUsage(blockTokens: 5, blockResetAt: nil, weekTokens: 5)).headline,
                     "a token count is not a percentage")
        XCTAssertNil(build().headline)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter LinkCKitTests.UsageRowsTests`
Expected: build FAILS with "cannot find 'UsageRows' in scope".

- [ ] **Step 3: Write `UsageRows`**

Create `Sources/LinkCKit/Usage/UsageRows.swift`:

```swift
import Foundation

/// One agent's line in the sidebar's Usage section.
public struct UsageRow: Equatable, Sendable, Identifiable {
    public var id: AgentKind { agent }
    public let agent: AgentKind
    /// What the row says on the right: "68% · resets 1h", "1.2M · resets 2h", "capped · clears 3h".
    public let text: String
    public let isCoral: Bool
    /// The reading may no longer be true: the row dims and can never be coral.
    public let isStale: Bool
    /// The hover text: the other window, the plan, and how old the reading is.
    public let help: String

    public init(agent: AgentKind, text: String, isCoral: Bool, isStale: Bool, help: String) {
        self.agent = agent
        self.text = text
        self.isCoral = isCoral
        self.isStale = isStale
        self.help = help
    }
}

/// An agent with nothing to report, and why — an empty answer is still an answer.
public struct UnknownUsage: Equatable, Sendable, Identifiable {
    public var id: AgentKind { agent }
    public let agent: AgentKind
    public let reason: String

    public init(agent: AgentKind, reason: String) {
        self.agent = agent
        self.reason = reason
    }
}

/// Turns what linkC knows about each agent's quota into the sidebar's Usage section. Pure: every
/// input is a value, and `now` is injected, so every rule below is tested without a clock.
public enum UsageRows {
    public struct Result: Equatable, Sendable {
        public let rows: [UsageRow]
        public let unknown: [UnknownUsage]
        /// The section label's trailing text: the highest live percentage anyone reports.
        public let headline: String?

        public init(rows: [UsageRow], unknown: [UnknownUsage], headline: String?) {
            self.rows = rows
            self.unknown = unknown
            self.headline = headline
        }
    }

    /// Fixed, so the section never reshuffles as numbers change.
    public static let order: [AgentKind] = [.claude, .codex, .cursor, .agy]

    /// Why an agent that publishes nothing locally has no row of its own.
    static func silentSourceReason(_ agent: AgentKind) -> String {
        switch agent {
        case .cursor:
            return "Cursor publishes no quota locally — only a cap linkC sees in its terminal"
        case .agy:
            return "agy keeps its quota on the server — only a cap linkC sees in its terminal"
        default:
            return "no usage source for this agent"
        }
    }

    public static func build(
        claude: WindowUsage?,
        codex: AgentUsage?,
        limits: [AgentKind: AgentLimitStatus],
        now: Date = Date()
    ) -> Result {
        var rows: [UsageRow] = []
        var unknown: [UnknownUsage] = []
        var livePercentages: [Double] = []

        for agent in order {
            // A cap linkC watched happen outranks every other source: it is the hardest fact
            // available, and while it holds the published figures cannot be acted on anyway.
            if let limit = limits[agent], limit.cooldownExpiresAt > now {
                rows.append(UsageRow(
                    agent: agent,
                    text: "capped · clears \(AgeFormat.compact(from: now, to: limit.cooldownExpiresAt))",
                    isCoral: true,
                    isStale: false,
                    help: "\(limit.reason) · seen \(AgeFormat.compact(from: limit.limitedAt, to: now)) ago"))
                continue
            }

            switch agent {
            case .claude:
                guard let claude else {
                    unknown.append(UnknownUsage(agent: agent, reason: "no transcript activity read yet"))
                    continue
                }
                rows.append(UsageRow(
                    agent: agent,
                    text: figure(UsageFormat.tokens(claude.blockTokens), resetsAt: claude.blockResetAt, now: now),
                    // No published limit, so a token count can never be an alarm.
                    isCoral: false,
                    isStale: false,
                    help: "5h \(UsageFormat.tokens(claude.blockTokens)) · 7d \(UsageFormat.tokens(claude.weekTokens))"))
            case .codex:
                guard let codex else {
                    unknown.append(UnknownUsage(agent: agent, reason: "not read yet"))
                    continue
                }
                guard let window = codex.windows.first(where: { $0.label == "5h" }),
                      let percent = window.usedPercent
                else {
                    unknown.append(UnknownUsage(
                        agent: agent, reason: codex.unavailableReason ?? "no 5-hour window reported"))
                    continue
                }
                // Stale two ways: the reading itself is old, or the window it describes has
                // already rolled over. Either way the number might no longer be true.
                let readingAge = codex.observedAt.map { now.timeIntervalSince($0) }
                let windowRolled = window.resetsAt.map { $0 <= now } ?? false
                let isStale = (readingAge.map { $0 > AgentUsage.staleAfter } ?? true) || windowRolled
                if !isStale { livePercentages.append(percent) }
                rows.append(UsageRow(
                    agent: agent,
                    text: figure(percentText(percent), resetsAt: windowRolled ? nil : window.resetsAt, now: now),
                    isCoral: !isStale && percent >= AgentUsage.warnThreshold,
                    isStale: isStale,
                    help: codexHelp(codex, readingAge: readingAge)))
            case .cursor, .agy, .shell:
                unknown.append(UnknownUsage(agent: agent, reason: silentSourceReason(agent)))
            }
        }

        return Result(
            rows: rows,
            unknown: unknown,
            headline: livePercentages.max().map(percentText))
    }

    /// "68% · resets 1h", or the figure alone when no reset time is known.
    private static func figure(_ value: String, resetsAt: Date?, now: Date) -> String {
        guard let resetsAt, resetsAt > now else { return value }
        return "\(value) · resets \(AgeFormat.compact(from: now, to: resetsAt))"
    }

    private static func percentText(_ percent: Double) -> String {
        "\(Int(percent.rounded()))%"
    }

    private static func codexHelp(_ usage: AgentUsage, readingAge: TimeInterval?) -> String {
        var parts: [String] = []
        if let week = usage.windows.first(where: { $0.label == "7d" }), let percent = week.usedPercent {
            parts.append("7d \(percentText(percent))")
        }
        if let plan = usage.planType, !plan.isEmpty { parts.append(plan) }
        if let readingAge { parts.append("read \(AgeFormat.compact(readingAge)) ago") }
        return parts.joined(separator: " · ")
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter LinkCKitTests.UsageRowsTests`
Expected: PASS (11 tests).

- [ ] **Step 5: Revert-proof two rules**

1. Change `isCoral: !isStale && percent >= AgentUsage.warnThreshold` to `isCoral: percent >= AgentUsage.warnThreshold`. Confirm `testAPassedResetMakesTheReadingStaleAndNeverCoral` and `testAnOldReadingIsStaleAndNeverCoral` FAIL. Restore; confirm they pass.
2. Move the cap check below the `switch` (so a published figure wins). Confirm `testACapWinsOverEveryOtherSource` FAILS. Restore; confirm it passes.

- [ ] **Step 6: Run the full suite**

Run: `swift test 2>&1 | tail -5`
Expected: 0 failures.

- [ ] **Step 7: Commit**

```bash
git add Sources/LinkCKit/Usage/UsageRows.swift Tests/LinkCKitTests/UsageRowsTests.swift
git commit -m "feat(usage): decide what each agent's usage row says"
```

---

### Task 2: The sidebar section

**Files:**
- Modify: `Sources/LinkCKit/Preferences/SidebarState.swift` (the `Section` enum)
- Modify: `Sources/linkc/LinkCApp.swift` (`AppModel`: a stored `codexUsage`, a refresh, and its place in the existing usage timer)
- Modify: `Sources/linkc/AppModel+Sidebar.swift` (gather limits, expose the rows)
- Modify: `Sources/linkc/Sidebar.swift` (the section, between Cloud and Earlier)

**Interfaces:**
- Consumes: Task 1's `UsageRows.build(claude:codex:limits:now:)`, `UsageRow`, `UnknownUsage`; existing `AppModel.usage.window`, `AppModel.inbox(for:)`, `AppModel.sessions`, `CodexUsageReader(sessionsDirectory:).read() -> AgentUsage`, `SidebarState.isOpen(_:)/toggle(_:)`, `CollapsibleSection`, `Theme`, `AgentKind.shortName`
- Produces: `AppModel.codexUsage`, `AppModel.agentLimits`, `AppModel.usageRows(now:)`, the `Usage` section in the sidebar

The `linkc` target has no test harness: this task adds no unit tests (every rule it draws is covered by Task 1) and is verified by a clean build, the full suite, and a look at the real panel afterwards.

- [ ] **Step 1: Add the section case**

In `Sources/LinkCKit/Preferences/SidebarState.swift`, extend the enum so the new section's open/closed state is remembered like the others:

```swift
    public enum Section: String, Codable, CaseIterable, Sendable {
        case more, servers, cloud, usage, earlier
    }
```

Run `swift test --filter LinkCKitTests.SidebarStateTests` (its "every section starts closed" test covers the new case automatically) → PASS.

- [ ] **Step 2: Read Codex's snapshot in the background**

In `Sources/linkc/LinkCApp.swift`, next to the other `AppModel` state (near `let attention = SessionAttention()`), add:

```swift
    /// Codex's own rate-limit snapshot, re-read off the main thread. nil until the first read lands.
    private(set) var codexUsage: AgentUsage?
```

Add the refresh next to `refreshCloud()`:

```swift
    /// Re-read Codex's own rate-limit snapshot. File IO only, and off the main actor: the reader
    /// reads the tail of the few newest rollouts, and the result lands back here.
    private func refreshCodexUsage() {
        let reader = CodexUsageReader(
            sessionsDirectory: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex/sessions"))
        Task.detached(priority: .utility) { [weak self] in
            let usage = reader.read()
            await MainActor.run { self?.codexUsage = usage }
        }
    }
```

Wire it into the existing `updateUsageTimer()`: call `refreshCodexUsage()` in the immediate first-tick block (beside `refreshServers()`), and inside the timer body add, next to the other cadences:

```swift
                    // Codex writes its snapshot every turn; five minutes is live enough to read it.
                    if self.usageTicks % 60 == 0 { self.refreshCodexUsage() }
```

- [ ] **Step 3: Gather the limits and build the rows**

In `Sources/linkc/AppModel+Sidebar.swift`, add to the existing `extension AppModel`:

```swift
    /// Every agent's most recent live cap across the workspaces that have a session. When an agent
    /// is capped in more than one, the furthest-out cooldown wins: that is when it can work again.
    var agentLimits: [AgentKind: AgentLimitStatus] {
        var latest: [AgentKind: AgentLimitStatus] = [:]
        for path in Set(sessions.map { ($0.cwd as NSString).standardizingPath }) {
            for limit in inbox(for: path)?.agentLimits ?? [] {
                if let existing = latest[limit.agent], existing.cooldownExpiresAt >= limit.cooldownExpiresAt {
                    continue
                }
                latest[limit.agent] = limit
            }
        }
        return latest
    }

    /// The sidebar's Usage section: a row per agent that reports something, the rest listed with
    /// the reason they do not.
    func usageRows(now: Date = Date()) -> UsageRows.Result {
        UsageRows.build(claude: usage.window, codex: codexUsage, limits: agentLimits, now: now)
    }
```

- [ ] **Step 4: Draw the section**

In `Sources/linkc/Sidebar.swift`, inside `Sidebar.body`'s `VStack`, between the Cloud section and the Earlier section, add:

```swift
                    UsageSection(model: model)
```

And add these views to the file, after `EarlierShellRow` (before the `// MARK: - Footer` section):

```swift
// MARK: - Usage

/// What every agent has left. Re-reads its inputs every 30 s so the reset times count down;
/// the figures themselves are refreshed by the app's own timers.
private struct UsageSection: View {
    let model: AppModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let result = model.usageRows(now: context.date)
            CollapsibleSection(
                title: "Usage", trailing: result.headline, section: .usage, state: model.sidebarState
            ) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(result.rows) { row in
                        UsageRowView(row: row)
                    }
                    if !result.unknown.isEmpty {
                        Text(result.unknown.map { $0.agent.shortName }.joined(separator: ", ") + " — no usage data")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .help(result.unknown.map { "\($0.agent.shortName): \($0.reason)" }
                                .joined(separator: "\n"))
                    }
                }
            }
        }
    }
}

/// One agent's usage line: its mark, its name, and the figure. A stale reading dims rather than
/// disappears — knowing the last reading, and that it is old, beats knowing nothing.
private struct UsageRowView: View {
    let row: UsageRow

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Theme.agentColor(row.agent).opacity(row.isStale ? 0.5 : 1))
                .frame(width: 7, height: 7)
            Text(row.agent.shortName)
                .font(.system(size: 12))
                .foregroundStyle(row.isStale ? Theme.textTertiary : Theme.textSecondary)
            Spacer(minLength: 6)
            Text(row.text)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(figureColor)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .help(row.help.isEmpty ? row.agent.displayName : row.help)
    }

    private var figureColor: Color {
        if row.isStale { return Theme.textTertiary.opacity(0.7) }
        return row.isCoral ? Theme.accent : Theme.textTertiary
    }
}
```

- [ ] **Step 5: Build and run the full suite**

Run: `swift build 2>&1 | grep -E "error:|warning:" | head; swift test 2>&1 | tail -5`
Expected: no errors, no warnings, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add Sources/LinkCKit/Preferences/SidebarState.swift Sources/linkc/LinkCApp.swift Sources/linkc/AppModel+Sidebar.swift Sources/linkc/Sidebar.swift
git commit -m "feat(sidebar): show every agent's remaining usage"
```

- [ ] **Step 7: Hand over for a look**

Report that the build is ready. The controller builds the app bundle and asks the user to install it, open the Usage section, and check it against what their agents actually have left.

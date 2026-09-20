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
        let roundsUp = build(codex: codex(percent: 79.6)).rows.first
        XCTAssertEqual(roundsUp?.isCoral, true, "79.6 rounds to 80, the same figure the text prints")
        XCTAssertEqual(roundsUp?.text, "80% · resets 1h")
    }

    func testAClaudeRowCountsTheBlocksTokensAndNamesTheWeek() {
        let window = WindowUsage(
            blockTokens: 1_200_000, blockResetAt: now.addingTimeInterval(7200), weekTokens: 9_800_000)
        let claude = row(build(claude: window), .claude)
        XCTAssertEqual(claude?.text, "1.2M · resets 2h")
        XCTAssertEqual(claude?.isCoral, false, "no published limit: a token count can never be an alarm")
        XCTAssertEqual(claude?.help.contains("9.8M"), true)
        XCTAssertEqual(claude?.help.contains("no percentage: no per-plan limit is published"), true)
    }

    func testAnIdleClaudeBlockSaysSoInHelp() {
        let window = WindowUsage(blockTokens: 0, blockResetAt: nil, weekTokens: 500)
        let claude = row(build(claude: window), .claude)
        XCTAssertEqual(claude?.text, "0", "an idle block still reads a bare count")
        XCTAssertEqual(claude?.help.hasPrefix("no active 5-hour block"), true)
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
        XCTAssertEqual(result.headline, "31%", "the weekly window is still live even though the 5-hour window rolled over")
        XCTAssertEqual(result.rows.first?.help.contains("window has since reset; this was the reading before it"), true)
    }

    func testAnOldReadingIsStaleAndNeverCoral() {
        let result = build(codex: codex(percent: 92, observedAgo: AgentUsage.staleAfter + 60))
        XCTAssertEqual(result.rows.first?.isStale, true)
        XCTAssertEqual(result.rows.first?.isCoral, false)
        XCTAssertNil(result.headline)
    }

    func testACapWinsOverEveryOtherSource() {
        let result = build(codex: codex(percent: 12), limits: [.codex: cap(.codex, clearsIn: 10_800)])
        XCTAssertEqual(row(result, .codex)?.text, "capped · retry 3h")
        XCTAssertEqual(row(result, .codex)?.isCoral, true)
        XCTAssertEqual(row(result, .codex)?.help.contains("usage cap"), true)
        XCTAssertEqual(row(result, .codex)?.help.contains("retry is linkC's own wait, not the provider's reset"), true)
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

    func testTheWorstWindowDrivesTheRowAndTheHeadline() {
        let result = build(codex: codex(percent: 22, weekPercent: 100))
        XCTAssertEqual(row(result, .codex)?.text, "22% · 7d 100%")
        XCTAssertEqual(row(result, .codex)?.isCoral, true)
        XCTAssertEqual(result.headline, "100%")
        XCTAssertEqual(row(result, .codex)?.help.contains("5h resets 1h"), true)
    }

    func testAQuietWeeklyWindowLeavesTheRowAsItIs() {
        let result = build(codex: codex(percent: 68, weekPercent: 31))
        XCTAssertEqual(row(result, .codex)?.text, "68% · resets 1h")
        XCTAssertEqual(row(result, .codex)?.isCoral, false)
        XCTAssertEqual(result.headline, "68%")
    }

    func testAStaleWeeklyWindowCannotColourTheRow() {
        let result = build(codex: codex(percent: 22, weekPercent: 100, observedAgo: AgentUsage.staleAfter + 60))
        XCTAssertEqual(row(result, .codex)?.isStale, true)
        XCTAssertEqual(row(result, .codex)?.isCoral, false)
        XCTAssertNil(result.headline)
    }

    func testAReadingWithNoFiveHourWindowUsesTheWindowItHas() {
        let result = build(codex: codex(percent: nil, weekPercent: 55))
        XCTAssertEqual(row(result, .codex)?.text, "55% · resets 24h", "whatever AgeFormat gives for a day out")
    }
}

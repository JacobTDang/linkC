import XCTest
@testable import LinkCKit

final class UsageRowsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    /// A reading as either provider reports it: a 5-hour window and a weekly one.
    private func reading(
        _ agent: AgentKind = .codex, percent: Double?, resetsIn: TimeInterval? = 3600,
        weekPercent: Double? = 31, weekResetsIn: TimeInterval = 86_400,
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
                resetsAt: now.addingTimeInterval(weekResetsIn)))
        }
        return AgentUsage(
            agent: agent, windows: windows, planType: plan,
            observedAt: reason == nil ? now.addingTimeInterval(-observedAgo) : nil,
            unavailableReason: reason)
    }

    private func cap(_ agent: AgentKind, clearsIn: TimeInterval, reason: String = "usage cap") -> AgentLimitStatus {
        AgentLimitStatus(
            agent: agent, reason: reason, limitedAt: now.addingTimeInterval(-60),
            cooldownExpiresAt: now.addingTimeInterval(clearsIn))
    }

    private func build(
        claude: AgentUsage? = nil, codex: AgentUsage? = nil, limits: [AgentKind: AgentLimitStatus] = [:]
    ) -> UsageRows.Result {
        UsageRows.build(claude: claude, codex: codex, limits: limits, now: now)
    }

    private func row(_ result: UsageRows.Result, _ agent: AgentKind) -> UsageRow? {
        result.rows.first { $0.agent == agent }
    }

    func testTheRowOrderIsFixed() {
        let result = build(
            claude: reading(.claude, percent: 37, plan: nil),
            codex: reading(percent: 68),
            limits: [.cursor: cap(.cursor, clearsIn: 10_800), .agy: cap(.agy, clearsIn: 600)])
        XCTAssertEqual(result.rows.map(\.agent), [.claude, .codex, .cursor, .agy])
        XCTAssertTrue(result.unknown.isEmpty)
    }

    func testARowShowsTheFiveHourPercentageAndReset() {
        let result = build(codex: reading(percent: 68))
        XCTAssertEqual(row(result, .codex)?.text, "68% · resets 1h")
        XCTAssertEqual(row(result, .codex)?.isCoral, false)
        XCTAssertEqual(row(result, .codex)?.isStale, false)
        XCTAssertEqual(row(result, .codex)?.help, "7d 31% · resets 1d · pro · read 2m ago")
    }

    func testClaudesRowTakesTheSameShape() {
        let result = build(claude: reading(.claude, percent: 37, resetsIn: 7200, weekPercent: 41, plan: nil))
        XCTAssertEqual(row(result, .claude)?.text, "37% · resets 2h")
        XCTAssertEqual(row(result, .claude)?.help, "7d 41% · resets 1d · read 2m ago")
        XCTAssertEqual(result.headline, "37%")
    }

    func testTheCoralThresholdStartsAtEighty() {
        XCTAssertEqual(build(codex: reading(percent: 79.4)).rows.first?.isCoral, false)
        XCTAssertEqual(build(codex: reading(percent: 80)).rows.first?.isCoral, true)
        let roundsUp = build(codex: reading(percent: 79.6)).rows.first
        XCTAssertEqual(roundsUp?.isCoral, true, "79.6 rounds to 80, the same figure the text prints")
        XCTAssertEqual(roundsUp?.text, "80% · resets 1h")
    }

    func testAHighWeeklyWindowShowsInHelpButLeavesTheFigureQuiet() {
        let result = build(codex: reading(percent: 22, weekPercent: 92))
        XCTAssertEqual(row(result, .codex)?.text, "22% · resets 1h")
        XCTAssertEqual(row(result, .codex)?.isCoral, false)
        XCTAssertEqual(row(result, .codex)?.help.hasPrefix("7d 92% · resets 1d"), true)
        XCTAssertEqual(result.headline, "22%")
    }

    func testAFullFiveHourWindowSaysTheSessionLimitIsHit() {
        let result = build(claude: reading(.claude, percent: 100, resetsIn: 7200, plan: nil))
        XCTAssertEqual(row(result, .claude)?.text, "session limit hit · resets 2h")
        XCTAssertEqual(row(result, .claude)?.isCoral, true)
        XCTAssertEqual(row(result, .claude)?.isStale, false)
        XCTAssertEqual(row(result, .claude)?.help, "7d 31% · resets 1d · read 2m ago")
        XCTAssertEqual(result.headline, "limit hit")
    }

    func testAFullWeeklyWindowSaysTheWeeklyLimitIsHit() {
        let result = build(codex: reading(percent: 22, weekPercent: 100, weekResetsIn: 3 * 86_400))
        XCTAssertEqual(row(result, .codex)?.text, "weekly limit hit · resets 3d")
        XCTAssertEqual(row(result, .codex)?.isCoral, true)
        XCTAssertEqual(row(result, .codex)?.help, "5h 22% · resets 1h · pro · read 2m ago")
        XCTAssertEqual(result.headline, "limit hit")
    }

    func testTheWeeklyHitOutranksTheSessionHit() {
        let result = build(codex: reading(percent: 100, weekPercent: 100))
        XCTAssertEqual(row(result, .codex)?.text, "weekly limit hit · resets 1d")
    }

    func testAHitComparesTheRoundedPercentage() {
        XCTAssertEqual(build(codex: reading(percent: 99.6)).rows.first?.text, "session limit hit · resets 1h")
        XCTAssertEqual(build(codex: reading(percent: 99.4)).rows.first?.text, "99% · resets 1h")
    }

    func testAStaleFullWindowIsNotAHit() {
        let result = build(codex: reading(percent: 100, weekPercent: 100, observedAgo: AgentUsage.staleAfter + 60))
        XCTAssertEqual(row(result, .codex)?.text, "100% · resets 1h")
        XCTAssertEqual(row(result, .codex)?.isStale, true)
        XCTAssertEqual(row(result, .codex)?.isCoral, false)
        XCTAssertNil(result.headline)
    }

    func testAFullWindowThatHasResetIsStaleNotAHit() {
        let result = build(codex: reading(percent: 100, resetsIn: -60))
        XCTAssertEqual(row(result, .codex)?.text, "100%", "the window moved on: no reset is claimed")
        XCTAssertEqual(row(result, .codex)?.isStale, true)
        XCTAssertEqual(row(result, .codex)?.isCoral, false)
        XCTAssertNil(result.headline, "the 5-hour window rolled over, so there is no live 5-hour figure")
        XCTAssertEqual(row(result, .codex)?.help.hasPrefix("window has since reset; this was the reading before it"), true)
    }

    func testAFigureWithNoResetTimeStandsAlone() {
        XCTAssertEqual(build(codex: reading(percent: 68, resetsIn: nil)).rows.first?.text, "68%")
    }

    func testAnOldReadingIsStaleAndNeverCoral() {
        let result = build(codex: reading(percent: 92, observedAgo: AgentUsage.staleAfter + 60))
        XCTAssertEqual(result.rows.first?.isStale, true)
        XCTAssertEqual(result.rows.first?.isCoral, false)
        XCTAssertNil(result.headline)
    }

    func testACapWinsOverEveryOtherSource() {
        let result = build(codex: reading(percent: 12), limits: [.codex: cap(.codex, clearsIn: 900)])
        XCTAssertEqual(row(result, .codex)?.text, "limit hit · retry 15m")
        XCTAssertEqual(row(result, .codex)?.isCoral, true)
        XCTAssertEqual(row(result, .codex)?.help.contains("usage cap"), true)
        XCTAssertEqual(row(result, .codex)?.help.contains("retry is linkC's own wait, not the provider's reset"), true)
        XCTAssertEqual(result.headline, "limit hit")
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
        let result = build(codex: reading(percent: nil, weekPercent: nil, reason: "no session records found"))
        XCTAssertEqual(result.unknown.map(\.agent), [.claude, .codex, .cursor, .agy])
        XCTAssertEqual(result.unknown.first { $0.agent == .claude }?.reason,
                       "no reading yet — a Claude session reports after its first reply")
        XCTAssertEqual(result.unknown.first { $0.agent == .codex }?.reason, "no session records found")
        XCTAssertEqual(result.unknown.first { $0.agent == .cursor }?.reason.isEmpty, false)
        XCTAssertEqual(result.unknown.first { $0.agent == .agy }?.reason.isEmpty, false)
    }

    func testClaudeWithItsOwnStatusLineSaysWhy() {
        let result = build(claude: .unavailable(.claude, reason: ClaudeRateLimits.ownStatusLineReason))
        XCTAssertNil(row(result, .claude))
        XCTAssertEqual(result.unknown.first { $0.agent == .claude }?.reason, ClaudeRateLimits.ownStatusLineReason)
    }

    func testTheHeadlineIsTheHighestLiveFiveHourPercentage() {
        XCTAssertEqual(build(claude: reading(.claude, percent: 37), codex: reading(percent: 68)).headline, "68%")
        XCTAssertNil(build().headline)
    }

    func testAReadingWithNoFiveHourWindowUsesTheWindowItHas() {
        let result = build(codex: reading(percent: nil, weekPercent: 55))
        XCTAssertEqual(row(result, .codex)?.text, "55% · resets 1d")
        XCTAssertEqual(row(result, .codex)?.help, "pro · read 2m ago")
    }
}

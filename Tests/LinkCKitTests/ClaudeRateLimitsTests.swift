import XCTest
@testable import LinkCKit

final class ClaudeRateLimitsTests: XCTestCase {
    private let arrived = Date(timeIntervalSince1970: 1_789_970_000)

    /// The example from Claude Code's status-line docs.
    func testTheDocsExampleDecodesToBothWindows() throws {
        let body = Data(#"""
        {"session_id": "abc", "rate_limits": {
          "five_hour": {"used_percentage": 23.5, "resets_at": 1738425600},
          "seven_day": {"used_percentage": 41.2, "resets_at": 1738857600}}}
        """#.utf8)
        let usage = try XCTUnwrap(ClaudeRateLimits.decode(body, receivedAt: arrived))

        XCTAssertEqual(usage.agent, .claude)
        XCTAssertEqual(usage.windows.map(\.label), ["5h", "7d"])
        XCTAssertEqual(usage.windows[0].usedPercent, 23.5)
        XCTAssertEqual(usage.windows[0].resetsAt, Date(timeIntervalSince1970: 1_738_425_600))
        XCTAssertEqual(usage.windows[1].usedPercent, 41.2)
        XCTAssertEqual(usage.windows[1].resetsAt, Date(timeIntervalSince1970: 1_738_857_600))
        XCTAssertNil(usage.windows[0].tokens)
        XCTAssertEqual(usage.observedAt, arrived)
        XCTAssertNil(usage.planType)
        XCTAssertNil(usage.unavailableReason)
    }

    /// A body captured from Claude Code 2.1.278: whole-number percentages, many other fields.
    func testACapturedBodyWithOtherFieldsDecodes() throws {
        let body = Data(#"""
        {"session_id": "7a21", "cwd": "/tmp/work", "model": {"id": "x", "display_name": "Opus"},
         "context_window": {"used_percentage": 3}, "cost": {"total_cost_usd": 0.1},
         "rate_limits": {"five_hour": {"used_percentage": 66, "resets_at": 1789980000},
                         "seven_day": {"used_percentage": 92, "resets_at": 1790017200}}}
        """#.utf8)
        let usage = try XCTUnwrap(ClaudeRateLimits.decode(body, receivedAt: arrived))
        XCTAssertEqual(usage.windows.map(\.usedPercent), [66, 92])
    }

    func testOneWindowAloneDecodes() throws {
        let body = Data(#"{"rate_limits": {"seven_day": {"used_percentage": 12, "resets_at": 1790017200}}}"#.utf8)
        let usage = try XCTUnwrap(ClaudeRateLimits.decode(body, receivedAt: arrived))
        XCTAssertEqual(usage.windows.map(\.label), ["7d"])
    }

    /// API-key sessions, and every session before its first reply, report no limits at all.
    func testABodyWithNoWindowsIsNoReading() throws {
        for json in [#"{"session_id": "abc"}"#, #"{"rate_limits": null}"#, #"{"rate_limits": {}}"#] {
            XCTAssertNil(try ClaudeRateLimits.decode(Data(json.utf8), receivedAt: arrived), json)
        }
    }

    func testABodyThatIsNotJSONThrows() {
        XCTAssertThrowsError(try ClaudeRateLimits.decode(Data("not json".utf8), receivedAt: arrived))
    }

    func testTheLaterReadingWinsWhateverOrderTheyArriveIn() {
        let early = AgentUsage(agent: .claude, windows: [], planType: nil, observedAt: arrived, unavailableReason: nil)
        let late = AgentUsage(agent: .claude, windows: [], planType: nil,
                              observedAt: arrived.addingTimeInterval(5), unavailableReason: nil)
        XCTAssertEqual(ClaudeRateLimits.newer(nil, early), early)
        XCTAssertEqual(ClaudeRateLimits.newer(early, late), late)
        XCTAssertEqual(ClaudeRateLimits.newer(late, early), late, "an older reading landing last must not win")
    }

    func testUsagePrefersTheReadingThenTheReasonNoneCanCome() {
        let reading = AgentUsage(agent: .claude, windows: [], planType: nil, observedAt: arrived, unavailableReason: nil)
        XCTAssertEqual(ClaudeRateLimits.usage(reading: reading, userOwnsStatusLine: true), reading)
        XCTAssertEqual(
            ClaudeRateLimits.usage(reading: nil, userOwnsStatusLine: true)?.unavailableReason,
            "your own status line is configured — linkC can't read Claude's usage")
        XCTAssertNil(ClaudeRateLimits.usage(reading: nil, userOwnsStatusLine: false))
    }
}

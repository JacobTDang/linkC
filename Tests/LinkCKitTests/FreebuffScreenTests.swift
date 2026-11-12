import XCTest
@testable import LinkCKit

final class FreebuffScreenTests: XCTestCase {
    private func rows(_ name: String) throws -> [String] {
        try CodexScreenFixture.rows("freebuff-\(name)")
    }

    func testCapturedIdleAndAdAreIdle() throws {
        let screen = try rows("0.2.36-idle-ad")
        XCTAssertNil(TerminalPreview.liveActivity(from: screen, agent: .freebuff))
        XCTAssertFalse(FreebuffScreen.isWaitingForUser(in: screen))
    }

    func testCapturedWorkingScreenIsWorking() throws {
        XCTAssertEqual(TerminalPreview.liveActivity(from: try rows("0.2.36-working"), agent: .freebuff), "Thinking")
    }

    func testCapturedQuestionNeedsTheUser() throws {
        XCTAssertTrue(FreebuffScreen.isWaitingForUser(in: try rows("0.2.36-question")))
    }

    func testAdLineNeverBecomesAState() {
        XCTAssertNil(FreebuffScreen.activity(in: ["✦ Refer friends → earn hours:"]))
        XCTAssertFalse(FreebuffScreen.isWaitingForUser(in: ["✦ Refer friends → earn hours:"]))
    }

    func testSourceLimitWordingIsDetected() throws {
        for fixture in ["source-session-limit", "source-low-hours-limit", "source-session-ended"] {
            let screen = try rows(fixture)
            let match = LimitDetector.detectLimit(inOutput: screen.joined(separator: "\n"), agent: .freebuff)
            XCTAssertEqual(match?.agent, .freebuff, fixture)
        }
    }

    func testFreebuffResetLineSeveralRowsBelowTheLimitSetsTheRealExpiry() throws {
        let text = try rows("source-session-limit").joined(separator: "\n")
        let match = try XCTUnwrap(LimitDetector.detectLimit(inOutput: text, agent: .freebuff))
        XCTAssertTrue(match.bannerText.contains("resets in 6d 4h"), match.bannerText)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(
            LimitCooldown.expiry(bannerText: match.bannerText, usage: nil, now: now, calendar: calendar, fallback: match.cooldown),
            now.addingTimeInterval(148 * 3600)
        )
    }

    func testOutOfCreditsInAnAdOrTranscriptIsNotALimit() {
        XCTAssertNil(LimitDetector.detectLimit(
            inOutput: "Upgrade today — never run out of credits again.", agent: .freebuff
        ))
        XCTAssertNil(LimitDetector.detectLimit(
            inOutput: "Agent: I will handle the out of credits state next.", agent: .freebuff
        ))
    }

    func testRetryQueueConnectingAndPausedAreWorking() throws {
        for fixture in ["source-retrying", "source-capacity-wait", "source-connecting", "source-paused"] {
            XCTAssertNotNil(
                TerminalPreview.liveActivity(from: try rows(fixture), agent: .freebuff),
                fixture
            )
        }
    }

    func testRepositoryAgentsTrustPromptNeedsTheUser() throws {
        XCTAssertTrue(FreebuffScreen.isWaitingForUser(in: try rows("source-agents-trust")))
    }

    func testScreenFixturesDoNotCrossClassifyBetweenFreebuffAndOtherAgents() throws {
        let urls = try XCTUnwrap(Bundle.module.urls(forResourcesWithExtension: "txt", subdirectory: nil))
        let statePrefixes = ["claude-", "codex-", "agy-", "opencode-"]
        for url in urls where statePrefixes.contains(where: { url.lastPathComponent.hasPrefix($0) }) {
            let rows = try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)
            XCTAssertNil(FreebuffScreen.activity(in: rows), url.lastPathComponent)
            XCTAssertFalse(FreebuffScreen.isWaitingForUser(in: rows), url.lastPathComponent)
            XCTAssertNil(LimitDetector.detectLimit(inOutput: rows.joined(separator: "\n"), agent: .freebuff), url.lastPathComponent)
        }

        for url in urls where url.lastPathComponent.hasPrefix("freebuff-") {
            let rows = try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)
            for agent in AgentKind.allCases where agent != .freebuff && agent != .shell {
                XCTAssertNil(TerminalPreview.liveActivity(from: rows, agent: agent), "\(url.lastPathComponent) as \(agent)")
                XCTAssertNil(LimitDetector.detectLimit(inOutput: rows.joined(separator: "\n"), agent: agent), "\(url.lastPathComponent) as \(agent)")
            }
        }
    }
}

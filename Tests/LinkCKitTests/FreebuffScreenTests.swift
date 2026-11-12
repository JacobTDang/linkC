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
        let screen = try rows("source-weekly-limit")
        let match = LimitDetector.detectLimit(inOutput: screen.joined(separator: "\n"), agent: .freebuff)
        XCTAssertEqual(match?.agent, .freebuff)
        XCTAssertEqual(match?.matchedPattern, "Freebuff weekly limit reached")
    }
}

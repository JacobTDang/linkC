import XCTest
@testable import LinkCKit

final class OpenCodeScreenGatingTests: XCTestCase {
    func testEveryNonOpenCodeFixtureStillUsesTheGenericReader() throws {
        let others = CodexScreenFixture.allNames().filter { !$0.hasPrefix("opencode-") }
        XCTAssertFalse(others.isEmpty)
        for name in others {
            let rows = try CodexScreenFixture.rows(name)
            XCTAssertEqual(
                TerminalPreview.liveActivity(from: rows, agent: .codex),
                TerminalPreview.genericLiveActivity(from: rows),
                name)
        }
    }

    func testAnOpenCodeLookingScreenInANonOpenCodeSessionIsNotReadAsOpenCode() throws {
        let rows = try CodexScreenFixture.rows("opencode-2.2.5-working-narrow")

        XCTAssertNil(TerminalPreview.liveActivity(from: rows, agent: .codex))
        XCTAssertEqual(TerminalPreview.liveActivity(from: rows, agent: .opencode), "Working")
    }
}

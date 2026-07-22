import XCTest
@testable import LinkCKit

/// Quit-alert copy. The sessions-only strings are pinned byte-identical to what
/// `applicationShouldTerminate` shipped before this feature — that dialog must not change
/// for claude-only users. Exited terminals never count (nothing left to kill).
final class QuitWarningBuilderTests: XCTestCase {

    func testNothingRunningMeansNoWarning() {
        XCTAssertNil(QuitWarningBuilder.build(sessionCount: 0, runningTerminalCount: 0))
    }

    func testSessionsOnlyCopyIsUnchanged() throws {
        let one = try XCTUnwrap(QuitWarningBuilder.build(sessionCount: 1, runningTerminalCount: 0))
        XCTAssertEqual(one.title, "Quit linkC and end 1 session?")
        XCTAssertEqual(one.message, "Quitting ends the Claude Code session running in linkC, but it'll be offered for restore next launch.")

        let two = try XCTUnwrap(QuitWarningBuilder.build(sessionCount: 2, runningTerminalCount: 0))
        XCTAssertEqual(two.title, "Quit linkC and end 2 sessions?")
        XCTAssertEqual(two.message, "Quitting ends the Claude Code sessions running in linkC, but they'll be offered for restore next launch.")
    }

    func testTerminalsOnlyCopyIsHonestAboutNoRestore() throws {
        let one = try XCTUnwrap(QuitWarningBuilder.build(sessionCount: 0, runningTerminalCount: 1))
        XCTAssertEqual(one.title, "Quit linkC and end 1 terminal?")
        XCTAssertEqual(one.message, "Quitting ends the terminal running in linkC. Unlike Claude Code sessions, it isn't restored next launch.")

        let two = try XCTUnwrap(QuitWarningBuilder.build(sessionCount: 0, runningTerminalCount: 3))
        XCTAssertEqual(two.title, "Quit linkC and end 3 terminals?")
        XCTAssertEqual(two.message, "Quitting ends the terminals running in linkC. Unlike Claude Code sessions, they aren't restored next launch.")
    }

    func testMixedCopySplitsRestorability() throws {
        let mixed = try XCTUnwrap(QuitWarningBuilder.build(sessionCount: 1, runningTerminalCount: 1))
        XCTAssertEqual(mixed.title, "Quit linkC and end 1 session and 1 terminal?")
        XCTAssertEqual(mixed.message, "Quitting ends the Claude Code session and terminal running in linkC. The session will be offered for restore next launch — the terminal won't.")

        let plural = try XCTUnwrap(QuitWarningBuilder.build(sessionCount: 2, runningTerminalCount: 2))
        XCTAssertEqual(plural.title, "Quit linkC and end 2 sessions and 2 terminals?")
        XCTAssertEqual(plural.message, "Quitting ends the Claude Code sessions and terminals running in linkC. Sessions will be offered for restore next launch — terminals won't.")
    }
}

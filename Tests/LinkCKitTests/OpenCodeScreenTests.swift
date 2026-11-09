import XCTest
@testable import LinkCKit

/// OpenCode's screens, captured from the real TUI (2.2.5, and 1.18.19 before it) at 92 and 46
/// columns, read the way the once-a-second sweep reads them.
final class OpenCodeScreenTests: XCTestCase {
    private func screen(_ name: String) throws -> [String] { try CodexScreenFixture.rows("opencode-\(name)") }

    func testAnIdleScreenReadsIdle() throws {
        for name in ["2.2.5-idle", "2.2.5-idle-narrow", "1.18.19-idle", "1.18.19-idle-narrow"] {
            XCTAssertNil(TerminalPreview.liveActivity(from: try screen(name)), name)
        }
    }

    func testEveryWorkingStageReadsWorking() throws {
        for name in ["2.2.5-working", "2.2.5-working-narrow", "1.18.19-working", "1.18.19-working-context", "1.18.19-working-narrow"] {
            XCTAssertEqual(TerminalPreview.liveActivity(from: try screen(name)), "Working", name)
        }
    }

    /// At 46 columns, the first seconds of a 2.2.5 turn show the bar with no interrupt hint after it.
    func testTheBarAloneSaysATurnRuns() throws {
        XCTAssertEqual(TerminalPreview.liveActivity(from: try screen("2.2.5-working-narrow-no-hint")), "Working")
    }

    func testTheThinkingSpinnerNamesThePhrase() throws {
        XCTAssertEqual(TerminalPreview.liveActivity(from: try screen("2.2.5-working-thinking")), "Thinking")
        XCTAssertEqual(TerminalPreview.liveActivity(from: try screen("1.18.19-working-thinking-narrow")), "Thinking")
    }

    func testAFinishedTurnReadsIdle() throws {
        for name in ["2.2.5-done", "2.2.5-done-narrow", "1.18.19-done", "1.18.19-done-narrow"] {
            XCTAssertNil(TerminalPreview.liveActivity(from: try screen(name)), name)
        }
    }

    /// OpenCode's input box carries none of the prompt markers the generic scan stops at, so a
    /// finished turn's output above it must not be read as a turn in progress.
    func testOutputAboveAFinishedTurnsInputBoxIsNotATurn() throws {
        var rows = try screen("2.2.5-done")
        let edge = try XCTUnwrap(rows.lastIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("╹") })
        rows.insert(contentsOf: ["     ~ Reading file...", "     Writing tests…", "     ⠋ Thinking", "     press esc " + "interrupt to stop"],
                    at: edge - 3)
        XCTAssertNil(TerminalPreview.liveActivity(from: rows))
    }

    /// The bar animates and the context size ticks while a turn runs; neither is progress.
    func testTheProgressRowIsNotProgress() throws {
        let rows = try screen("2.2.5-working")
        let edge = try XCTUnwrap(rows.lastIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("╹") })
        let footer = edge + 1
        XCTAssertTrue(TerminalPreview.isLiveMarkerRow(rows[footer]), rows[footer])
        var redrawn = rows
        redrawn[footer] = "   ■■⬝⬝⬝⬝⬝⬝  esc " + "interrupt                                     24.9K (13%)  ctrl+p commands"
        XCTAssertEqual(TerminalPreview.progressSignature(rows: rows), TerminalPreview.progressSignature(rows: redrawn))
    }

    func testOtherAgentsScreensAreNotOpenCodes() throws {
        for name in ["codex-0.159-turn-finished", "codex-0.159-working-before-tip", "codex-0.159-working-narrow",
                     "codex-0.159-waiting-for-startup", "codex-0.159-working-tip-under-status"] {
            XCTAssertNil(OpenCodeScreen.turn(in: try CodexScreenFixture.rows(name)), name)
        }
    }
}

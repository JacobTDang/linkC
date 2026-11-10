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

    /// A tool call still pending is drawn inside the "┃" block with a spinner of its own. It is part
    /// of the transcript, so it never names the phrase, wherever in the block it sits.
    func testAPendingToolCallInTheBoxNeverNamesThePhrase() throws {
        let screen = try screen("2.2.5-working-thinking")
        let thinking = try XCTUnwrap(screen.firstIndex { $0.trimmingCharacters(in: .whitespaces) == "⠋ Thinking" })
        let edge = try XCTUnwrap(screen.lastIndex(where: OpenCodeScreen.isInputBoxEdge))
        for position in [thinking + 1, edge] {
            var rows = screen
            rows.insert("  ┃  ⠋ Writing command…", at: position)
            XCTAssertEqual(TerminalPreview.liveActivity(from: rows), "Thinking", "tool call inserted at row \(position)")
        }
    }

    /// The box grows tall when the model row wraps or a prompt is queued in it; the thinking row
    /// stays right above the whole box, however many rows it has.
    func testATallBoxDoesNotHideTheThinkingRow() throws {
        var rows = try screen("2.2.5-working-thinking")
        let edge = try XCTUnwrap(rows.lastIndex(where: OpenCodeScreen.isInputBoxEdge))
        rows.insert(contentsOf: Array(repeating: "  ┃  and then run the tests", count: 12), at: edge - 1)
        XCTAssertEqual(TerminalPreview.liveActivity(from: rows), "Thinking")
    }

    /// While a turn runs, the session title row at the top of the screen carries a Braille spinner.
    /// It is the screen's first row, never the thinking row, however few rows sit between it and the box.
    func testTheSessionTitleIsNeverThePhrase() throws {
        var rows = try screen("2.2.5-working-narrow-no-hint")
        XCTAssertTrue(try XCTUnwrap(rows.first).trimmingCharacters(in: .whitespaces).hasPrefix("⠋"), "no spinner on the title row")
        // A wider screen echoes the prompt in two rows, not four, which brings the title near the box.
        rows.removeAll { ["┃  Then run wc -w story.txt and report the", "┃  count."].contains($0.trimmingCharacters(in: .whitespaces)) }
        XCTAssertEqual(try XCTUnwrap(rows.lastIndex(where: OpenCodeScreen.isInputBoxEdge)), 9, "rows between the title and the box")
        XCTAssertEqual(TerminalPreview.liveActivity(from: rows), "Working")
        XCTAssertEqual(TerminalPreview.liveActivity(from: Array(rows.dropFirst())), "Working", "the same frame without the title row")
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

    /// Every screen fixture that is not OpenCode's, whatever agent it was captured from.
    func testOtherAgentsScreensAreNotOpenCodes() throws {
        let others = CodexScreenFixture.allNames().filter { !$0.hasPrefix("opencode-") }
        XCTAssertFalse(others.isEmpty, "no other agent's screens to check")
        for name in others {
            XCTAssertNil(OpenCodeScreen.turn(in: try CodexScreenFixture.rows(name)), name)
        }
    }
}

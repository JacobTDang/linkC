import XCTest
@testable import LinkCKit

/// Codex's screens, read the way the once-a-second sweep reads them. The frames are in
/// `CodexScreenFixture`.
final class CodexScreenTests: XCTestCase {
    private func screen(_ name: String) throws -> [String] { try CodexScreenFixture.rows(name) }

    /// Thirty seconds into a turn, while the model thought between tool calls, Codex drew a tip on
    /// a row under its status row. That put the tip, not the status row, next to the input box,
    /// and linkC read the turn as ended.
    func testAStatusRowWithATipUnderItStillReadsAsWorking() throws {
        XCTAssertEqual(TerminalPreview.liveActivity(from: try screen("codex-0.159-working-tip-under-status")), "Working")
    }

    /// The tip fixture with its tip row wrapped onto `continuations` further rows, indented under
    /// the tip's text the way Codex indents a wrapped detail. At the panel's narrow widths a tip
    /// does not fit one row.
    private func tipFrame(wrappedOnto continuations: [String]) throws -> [String] {
        var rows = try screen("codex-0.159-working-tip-under-status")
        let tip = try XCTUnwrap(rows.firstIndex { $0.contains("└ Tip:") })
        rows.replaceSubrange(tip...tip, with: ["  └ Tip: Use /vim to toggle"] + continuations.map { "    " + $0 })
        return rows
    }

    func testAStatusRowWithAWrappedTipUnderItStillReadsAsWorking() throws {
        XCTAssertEqual(TerminalPreview.liveActivity(from: try tipFrame(wrappedOnto: ["Vim editing in the composer."])), "Working")
        XCTAssertEqual(
            TerminalPreview.liveActivity(from: try tipFrame(wrappedOnto: ["Vim editing in", "the composer."])), "Working"
        )
    }

    /// Indented rows above the input box belong to a finished turn's output unless a status row
    /// sits above them.
    func testIndentedRowsUnderAFinishedTurnsOutputStillReadAsNotWorking() throws {
        var rows = try screen("codex-0.159-turn-finished")
        let box = try XCTUnwrap(rows.firstIndex { $0.contains("Ask Codex to do anything") })
        rows.insert(contentsOf: ["  └ done", "    Vim editing in the composer."], at: box)
        XCTAssertNil(TerminalPreview.liveActivity(from: rows))
    }

    /// Only rows under a `└` detail row are skipped as its wrapped continuation. Indented rows
    /// straight under the status row are something else, so the status row is no longer the one
    /// the input box sits under.
    func testIndentedRowsWithNoDetailRowAboveThemAreNotSkipped() throws {
        var rows = try screen("codex-0.159-working-before-tip")
        XCTAssertNotNil(TerminalPreview.liveActivity(from: rows), "the frame reads as working as captured")
        let box = try XCTUnwrap(rows.firstIndex { $0.contains("Ask Codex to do anything") })
        rows.insert(contentsOf: ["    stray indented output", "    more of it"], at: box)
        XCTAssertNil(TerminalPreview.liveActivity(from: rows))
    }

    /// A brief pasted while Codex is still starting its tool servers sits in the input box under
    /// "Waiting for startup"; there is no status row yet. The turn has not begun, but the worker
    /// is not idle either.
    func testAnInputWaitingForStartupReadsAsWorking() throws {
        XCTAssertEqual(TerminalPreview.liveActivity(from: try screen("codex-0.159-waiting-for-startup")), "Working")
    }

    func testTheFramesAroundThoseTwoStillReadAsWorking() throws {
        for name in [
            "codex-0.159-starting-mcp-servers",
            "codex-0.159-working-before-tip",
            "codex-0.159-working-background-terminal",
            "codex-0.159-working-narrow",
        ] {
            XCTAssertNotNil(TerminalPreview.liveActivity(from: try screen(name)), name)
        }
    }

    func testAFinishedTurnReadsAsNotWorking() throws {
        XCTAssertNil(TerminalPreview.liveActivity(from: try screen("codex-0.159-turn-finished")))
    }

    /// A turn can end with a terminal Codex started still running: the reply is out, the status
    /// row is gone, and a footer above the input box says one is left. The worker is not idle.
    func testAFinishedTurnWithABackgroundTerminalLeftRunningShowsIt() throws {
        let rows = try screen("codex-0.159-turn-finished-background-terminal")
        XCTAssertNil(TerminalPreview.liveActivity(from: rows), "the turn itself is over")
        XCTAssertTrue(TerminalPreview.hasBackgroundTerminals(in: rows))
    }

    /// The footer is cut at the panel's width.
    func testTheFooterCutShortByANarrowPanelStillShowsIt() {
        XCTAssertTrue(TerminalPreview.hasBackgroundTerminals(in: [
            "• started", "  Worked for 5s • 10:08 PM", "  1 background terminal running · /ps",
            "› Ask Codex to do anything", "  GPT-5.6-Luna low · ~/Projects/linkC…",
        ]))
        XCTAssertTrue(TerminalPreview.hasBackgroundTerminals(in: [
            "• done", "  3 background terminals running · /ps to view · /stop to close", "› Ask Codex to do anything",
        ]))
    }

    func testAFinishedTurnWithNoBackgroundTerminalShowsNone() throws {
        XCTAssertFalse(TerminalPreview.hasBackgroundTerminals(in: try screen("codex-0.159-turn-finished")))
    }

    /// The phrase quoted in output well above the input box is not Codex's footer.
    func testTheFooterQuotedInOutputHigherUpIsNotTheFooter() throws {
        var rows = try screen("codex-0.159-turn-finished")
        rows.insert("  1 background terminal running · /ps to view · /stop to close", at: 2)
        XCTAssertFalse(TerminalPreview.hasBackgroundTerminals(in: rows))
    }
}

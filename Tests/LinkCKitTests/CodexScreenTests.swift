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
}

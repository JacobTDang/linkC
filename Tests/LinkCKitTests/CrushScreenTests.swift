import XCTest
@testable import LinkCKit

/// Crush's screens, captured from the real TUI (v0.101.0) at 92 and 46 columns, read the way the
/// once-a-second sweep reads them. See `.superpowers/sdd/task-C4-report.md` for how each was captured.
final class CrushScreenTests: XCTestCase {
    private func screen(_ name: String) throws -> [String] { try CodexScreenFixture.rows("crush-0.101.0-\(name)") }

    private let idle = ["idle", "idle-narrow", "done", "done-narrow"]
    private let working = ["working-thinking", "working-streaming", "working-cancel-confirm", "working-narrow", "working-narrow-early",
                           "ratelimit-retrying"]
    private let permission = ["permission", "permission-narrow"]
    private let setup = ["nokey-no-provider", "nokey-model-picker", "nokey-enter-key"]
    private let limited = ["ratelimit", "ratelimit-narrow"]

    func testAnIdleScreenReadsIdle() throws {
        for name in idle {
            XCTAssertEqual(CrushScreen.state(in: try screen(name)), .idle, name)
            XCTAssertNil(TerminalPreview.liveActivity(from: try screen(name), agent: .crush), name)
        }
    }

    func testEveryWorkingStageReadsWorking() throws {
        for name in working {
            XCTAssertEqual(CrushScreen.state(in: try screen(name)), .working, name)
            XCTAssertEqual(TerminalPreview.liveActivity(from: try screen(name), agent: .crush), "Working", name)
        }
    }

    /// The permission dialog covers a running turn, and the footer under it still says "esc cancel":
    /// the dialog is what the screen is waiting on.
    func testAPermissionPromptIsWaitingNotWorking() throws {
        for name in permission {
            XCTAssertEqual(CrushScreen.state(in: try screen(name)), .waitingPermission, name)
            XCTAssertNil(TerminalPreview.liveActivity(from: try screen(name), agent: .crush), name)
        }
    }

    /// Without an OpenRouter key Crush asks for a provider, then a model, then the key. None is a turn.
    func testTheNoKeyScreensNeedSetup() throws {
        for name in setup {
            XCTAssertEqual(CrushScreen.state(in: try screen(name)), .needsSetup, name)
            XCTAssertNil(TerminalPreview.liveActivity(from: try screen(name), agent: .crush), name)
        }
    }

    func testTheNoKeyScreenNamesTheKeyItAsksFor() throws {
        XCTAssertEqual(CrushScreen.keyRequested(in: try screen("nokey-enter-key")), "OpenRouter")
        XCTAssertNil(CrushScreen.keyRequested(in: try screen("nokey-no-provider")))
        XCTAssertNil(CrushScreen.keyRequested(in: try screen("idle")))
    }

    /// Once its retries are spent, Crush shows the error and is ready for the next prompt; the error
    /// replaces the footer, so the screen has no footer to read.
    func testARateLimitedScreenIsIdleOnceTheErrorShows() throws {
        for name in limited {
            XCTAssertEqual(CrushScreen.state(in: try screen(name)), .idle, name)
            XCTAssertNil(TerminalPreview.liveActivity(from: try screen(name), agent: .crush), name)
        }
    }

    /// Words from the footer, quoted in the transcript, are not the footer.
    func testQuotedFooterTextIsNotAState() throws {
        var rows = try screen("idle")
        let footer = try XCTUnwrap(rows.firstIndex { $0.contains("YOLO MODE") })
        rows.insert("   esc cancel • tab focus chat", at: footer - 2)
        XCTAssertEqual(CrushScreen.state(in: rows), .idle)
        XCTAssertNil(TerminalPreview.liveActivity(from: rows, agent: .crush))
    }

    /// A dialog title quoted in the transcript has no choices under it.
    func testAQuotedPermissionTitleIsNotAPrompt() throws {
        var rows = try screen("done")
        let footer = try XCTUnwrap(rows.firstIndex { $0.contains("YOLO MODE") })
        rows.insert("   Permission Required", at: footer - 3)
        XCTAssertEqual(CrushScreen.state(in: rows), .idle)
    }

    /// A tip or banner is never a state: only the footer row, last on the screen, says a turn runs.
    func testRowsAboveTheFooterNeverMakeATurn() throws {
        var rows = try screen("done")
        rows.insert(contentsOf: ["     Reading file...", "     Writing tests…", "     ⠋ Thinking"], at: 3)
        XCTAssertEqual(CrushScreen.state(in: rows), .idle)
        XCTAssertNil(TerminalPreview.liveActivity(from: rows, agent: .crush))
    }

    /// The scrambled-glyph spinner and its clock redraw on their own; neither is progress.
    func testTheSpinnerRowIsNotProgress() throws {
        let rows = try screen("working-thinking")
        let spinner = try XCTUnwrap(rows.firstIndex { CrushScreen.isSpinnerRow(TerminalPreview.visibleText($0)) })
        XCTAssertTrue(TerminalPreview.isLiveMarkerRow(rows[spinner]), rows[spinner])
        var redrawn = rows
        redrawn[spinner] = "   ^&!40*bB~=%A!d8 7s"
        XCTAssertEqual(TerminalPreview.progressSignature(rows: rows), TerminalPreview.progressSignature(rows: redrawn))
    }

    /// Ordinary output that happens to end in a duration is not the spinner.
    func testOrdinaryRowsAreNotTheSpinner() {
        for row in ["Elapsed 3s", "Ran 24 tests in 12s", "internationalise 5s", "abcdefghijklmno 5s", "$(E*%B5F+f€b67 3s extra"] {
            XCTAssertFalse(CrushScreen.isSpinnerRow(row), row)
        }
        XCTAssertTrue(CrushScreen.isSpinnerRow("%$(E*%B5F+f€b67 3s"))
        XCTAssertTrue(CrushScreen.isSpinnerRow("1*@b1b0DAfA€+D9 1m 30s"))
    }

    /// Crush's reader runs only for Crush sessions.
    func testACrushLookingScreenInANonCrushSessionIsReadTheGenericWay() throws {
        let rows = try screen("working-narrow")
        XCTAssertEqual(TerminalPreview.liveActivity(from: rows, agent: .crush), "Working")
        for agent in AgentKind.allCases where agent != .crush {
            XCTAssertEqual(TerminalPreview.liveActivity(from: rows, agent: agent), TerminalPreview.genericLiveActivity(from: rows), "\(agent)")
        }
    }

    /// Every fixture that is not Crush's, whatever agent it was captured from.
    func testOtherAgentsScreensAreNotCrushs() throws {
        let others = CodexScreenFixture.allNames().filter { !$0.hasPrefix("crush-") }
        XCTAssertFalse(others.isEmpty, "no other agent's screens to check")
        for name in others {
            XCTAssertNil(CrushScreen.state(in: try CodexScreenFixture.rows(name)), name)
        }
    }

    /// The five required screens exist, in both widths where the width changes the layout.
    func testEveryRequiredScreenIsCaptured() {
        let names = Set(CodexScreenFixture.allNames())
        for name in idle + working + permission + setup + limited {
            XCTAssertTrue(names.contains("crush-0.101.0-\(name)"), name)
        }
    }
}

import XCTest
@testable import LinkCKit

/// Bookkeeping tests for the terminal manager. `makeSession` deliberately does NOT spawn a
/// process (the view + PTY are created lazily by `TerminalSession.start`/`.terminalView`), so
/// add / select / remove / terminate can all be exercised without a live PTY.
@MainActor
final class TerminalSessionManagerTests: XCTestCase {

    func testMakeSessionAddsAndSelectsIt() {
        let manager = TerminalSessionManager()
        let session = manager.makeSession(id: "L1", cwd: "/tmp", title: "api")
        XCTAssertEqual(manager.sessions.count, 1)
        XCTAssertEqual(session.id, "L1")
        XCTAssertEqual(manager.selectedId, "L1", "a newly made session must become selected")
    }

    func testMakeSecondSessionSelectsTheLatest() {
        let manager = TerminalSessionManager()
        manager.makeSession(id: "L1", cwd: "/a", title: "a")
        manager.makeSession(id: "L2", cwd: "/b", title: "b")
        XCTAssertEqual(manager.sessions.count, 2)
        XCTAssertEqual(manager.selectedId, "L2")
    }

    func testSelectChangesSelectionAndIgnoresUnknownIds() {
        let manager = TerminalSessionManager()
        manager.makeSession(id: "L1", cwd: "/a", title: "a")
        manager.makeSession(id: "L2", cwd: "/b", title: "b")

        manager.select("L1")
        XCTAssertEqual(manager.selectedId, "L1")

        manager.select("nope")
        XCTAssertEqual(manager.selectedId, "L1", "selecting an unknown id must not change the selection")
    }

    func testSessionLookup() {
        let manager = TerminalSessionManager()
        manager.makeSession(id: "L1", cwd: "/a", title: "a")
        XCTAssertEqual(manager.session(id: "L1")?.cwd, "/a")
        XCTAssertNil(manager.session(id: "nope"))
    }

    func testRemovingSelectedFallsBackToLastRemaining() {
        let manager = TerminalSessionManager()
        manager.makeSession(id: "L1", cwd: "/a", title: "a")
        manager.makeSession(id: "L2", cwd: "/b", title: "b") // selected

        manager.remove("L2")
        XCTAssertEqual(manager.sessions.map(\.id), ["L1"])
        XCTAssertEqual(manager.selectedId, "L1", "removing the selected session must reselect a remaining one")

        manager.remove("L1")
        XCTAssertTrue(manager.sessions.isEmpty)
        XCTAssertNil(manager.selectedId, "removing the last session must clear the selection")
    }

    func testRemovingNonSelectedKeepsSelection() {
        let manager = TerminalSessionManager()
        manager.makeSession(id: "L1", cwd: "/a", title: "a")
        manager.makeSession(id: "L2", cwd: "/b", title: "b") // selected

        manager.remove("L1")
        XCTAssertEqual(manager.selectedId, "L2", "removing a non-selected session must not change the selection")
    }

    func testDeselectClearsSelectionWithoutRemovingSessions() {
        // Returning to the home overview clears the selection but keeps every terminal alive.
        let manager = TerminalSessionManager()
        manager.makeSession(id: "L1", cwd: "/a", title: "a")
        manager.makeSession(id: "L2", cwd: "/b", title: "b") // selected

        manager.deselect()
        XCTAssertNil(manager.selectedId, "deselect must clear the selection (return to home overview)")
        XCTAssertEqual(manager.sessions.map(\.id), ["L1", "L2"], "deselect must not remove any session")
    }

    func testTerminateNeverStartedSessionRemovesItWithoutSpawning() {
        // terminate() on a session whose PTY was never started is a no-op kill followed by a
        // plain removal — no view, no process, no crash.
        let manager = TerminalSessionManager()
        manager.makeSession(id: "L1", cwd: "/a", title: "a")
        manager.terminate("L1")
        XCTAssertTrue(manager.sessions.isEmpty)
        XCTAssertNil(manager.selectedId)
    }

    func testTerminateUnknownIdIsIgnored() {
        let manager = TerminalSessionManager()
        manager.makeSession(id: "L1", cwd: "/a", title: "a")
        manager.terminate("nope")
        XCTAssertEqual(manager.sessions.map(\.id), ["L1"])
    }
}

@MainActor
final class TerminalSessionTests: XCTestCase {
    func testTerminateBeforeStartIsSafeNoOp() {
        let session = TerminalSession(id: "L1", cwd: "/tmp", title: "api")
        session.terminate() // must not force-create the view or crash
        XCTAssertEqual(session.id, "L1")
        XCTAssertEqual(session.cwd, "/tmp")
        XCTAssertEqual(session.title, "api")
    }

    func testRecentOutputBeforeStartIsEmpty() {
        // A session whose PTY was never started has no buffer to read. Reading it must return
        // "" — and, like terminate(), must not force the lazy view/PTY into existence.
        let session = TerminalSession(id: "L1", cwd: "/tmp", title: "api")
        XCTAssertEqual(session.recentOutput(lines: 3), "")
        session.terminate() // still a safe no-op — proves recentOutput didn't spawn a view
    }

    func testScrubbedEnvironmentDropsClaudeCodeMarkers() {
        // linkC may itself be running inside a claude session (opened from a terminal there).
        // Its inherited CLAUDECODE/CLAUDE_CODE_* markers must not leak into spawned sessions,
        // which would make claude treat them as child sessions (transcript saving off).
        let base = [
            "PATH": "/usr/bin",
            "HOME": "/Users/x",
            "CLAUDECODE": "1",
            "CLAUDE_CODE_CHILD_SESSION": "1",
            "CLAUDE_CODE_ENTRYPOINT": "cli",
        ]
        XCTAssertEqual(
            TerminalSession.scrubbedEnvironment(base),
            ["PATH": "/usr/bin", "HOME": "/Users/x"]
        )
    }
}

/// The preview cleaner turns raw terminal rows into home-card content: chrome rows — box-drawing
/// frames, horizontal rules, bare prompt markers, blanks — are dropped so the 3-line preview
/// shows what the session is actually saying, not its furniture.
final class TerminalPreviewTests: XCTestCase {

    func testDropsBoxDrawingFrameRows() {
        let rows = ["Build complete!", "╭──────────╮", "│ >        │", "╰──────────╯"]
        XCTAssertEqual(TerminalPreview.excerpt(rows: rows, lines: 3), "Build complete!")
    }

    func testDropsRulesAndBlankRows() {
        let rows = ["one", "", "────────────", "two"]
        XCTAssertEqual(TerminalPreview.excerpt(rows: rows, lines: 3), "one\ntwo")
    }

    func testKeepsLastNContentRowsInOrder() {
        let rows = ["a", "b", "c", "d"]
        XCTAssertEqual(TerminalPreview.excerpt(rows: rows, lines: 3), "b\nc\nd")
    }

    func testBarePromptDroppedButPromptWithCommandKept() {
        let rows = ["❯", "❯ swift test"]
        XCTAssertEqual(TerminalPreview.excerpt(rows: rows, lines: 3), "❯ swift test")
    }

    func testTextInsideBoxFrameIsKept() {
        // A framed row with real words keeps its words; only the frame glyphs go.
        let rows = ["│ Claude is thinking… │"]
        XCTAssertEqual(TerminalPreview.excerpt(rows: rows, lines: 3), "│ Claude is thinking… │")
    }

    func testDropsClaudeStatusFurnitureRows() {
        // Claude Code's status-bar banners are text-only chrome: the permission-mode line,
        // the MCP-auth banner, and the transcript warning. None of them is session output.
        let rows = [
            "Fixed the bug in PanelView.",
            "⚠5 MCP servers need authentication · run /mcp",
            "⚠ Transcript saving is off — inherited CLAUDE_CODE_CHILD_SESSION marker · restart with CLAUDE_CODE_FORCE_SESSIO…",
            "⏵⏵ bypass permissions on (shift+tab to cycle)",
        ]
        XCTAssertEqual(TerminalPreview.excerpt(rows: rows, lines: 3), "Fixed the bug in PanelView.")
    }

    func testKeepsRealOutputMentioningWarningsOrMCP() {
        // The furniture patterns must stay anchored: real output that merely carries a ⚠ or
        // mentions MCP is content, not chrome.
        let rows = [
            "⚠ deprecation warning in Foo.swift",
            "Added 3 MCP servers to the config",
        ]
        XCTAssertEqual(
            TerminalPreview.excerpt(rows: rows, lines: 3),
            "⚠ deprecation warning in Foo.swift\nAdded 3 MCP servers to the config"
        )
    }

    func testEmptyAndChromeOnlyInputGivesEmptyString() {
        XCTAssertEqual(TerminalPreview.excerpt(rows: [], lines: 3), "")
        XCTAssertEqual(TerminalPreview.excerpt(rows: ["────", "", "❯"], lines: 3), "")
    }
}

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

    func testMakeSessionCanLeaveTheSelectionAlone() {
        let manager = TerminalSessionManager()
        manager.makeSession(id: "L1", cwd: "/a", title: "a", select: false)
        XCTAssertNil(manager.selectedId, "an unselected make must not leave the overview")

        manager.select("L1")
        manager.makeSession(id: "L2", cwd: "/b", title: "b", select: false)
        XCTAssertEqual(manager.sessions.count, 2)
        XCTAssertEqual(manager.selectedId, "L1", "an unselected make must not switch away from the current terminal")
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

    func testLiveActivityLineBeforeStartIsNil() {
        let session = TerminalSession(id: "L1", cwd: "/tmp", title: "api")
        XCTAssertNil(session.liveActivityLine())
        session.terminate()
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

    func testLinkCTerminalViewDisablesWindowDragging() {
        let view = LinkCTerminalView(frame: .zero)
        XCTAssertFalse(view.mouseDownCanMoveWindow, "Terminal view must disable window dragging so text highlighting works")
    }

    func testTerminalHostViewMouseDownCanMoveWindowBehavior() {
        let hostView = TerminalHostView(frame: .zero)
        XCTAssertTrue(hostView.mouseDownCanMoveWindow, "Empty host view allows window dragging")

        let terminal = LinkCTerminalView(frame: .zero)
        hostView.show(terminal)
        XCTAssertFalse(hostView.mouseDownCanMoveWindow, "Host view with active terminal must disallow window dragging")

        hostView.show(nil)
        XCTAssertTrue(hostView.mouseDownCanMoveWindow, "Detaching terminal restores window dragging")
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

    func testDropsRemainingStatusFurnitureVariants() {
        // The rest of claude's bottom-strip furniture: spinner rows, shortcut hints,
        // context/usage warnings, update failures, queued-message hints.
        let rows = [
            "Deployed the fix.",
            "✻ Sautéing… (12s · esc to interrupt)",
            "? for shortcuts",
            "Context left until auto-compact: 8%",
            "Context low (11% remaining) · Run /compact to compact & continue",
            "Approaching Opus usage limit · resets at 7pm",
            "✗ Auto-update failed · Try claude doctor or npm i -g @anthropic-ai/claude-code",
            "Press up to edit queued messages",
        ]
        XCTAssertEqual(TerminalPreview.excerpt(rows: rows, lines: 3), "Deployed the fix.")
    }

    func testDropsTokenSpinnerAndSessionLimitBanners() {
        // Spinner rows carry the token counter even when a narrow pane cuts off the
        // "esc to interrupt" hint that usually marks them; the session-limit banner is
        // strip furniture, not output.
        let rows = [
            "Shipped the sidebar.",
            "✳ Boondoggling… (50s · ↓2.5k tokens · thinking with xhigh effort)",
            "* Frolicking… (1m 11s · ↓ 271 tokens)",
            "You've used 98% of your session limit · resets 1am (America/Chicago) · /upgrade to keep using Claude",
        ]
        XCTAssertEqual(TerminalPreview.excerpt(rows: rows, lines: 3), "Shipped the sidebar.")
    }

    func testTokenTalkInRealOutputIsKept() {
        XCTAssertTrue(TerminalPreview.hasContent("The request used 2.5k tokens in total."))
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

    func testExtractsClaudeSpinnerActivity() {
        let rows = [
            "Running build...",
            "✻ Sautéing… (12s · esc to interrupt)",
        ]
        XCTAssertEqual(TerminalPreview.liveActivity(from: rows), "Sautéing…")

        let tokenRows = [
            "Output text",
            "✳ Boondoggling… (50s · ↓2.5k tokens · thinking with xhigh effort)",
        ]
        XCTAssertEqual(TerminalPreview.liveActivity(from: tokenRows), "Boondoggling…")

        let commandRows = [
            "Building target...",
            "Running swift test… (3s · esc to interrupt)",
        ]
        XCTAssertEqual(TerminalPreview.liveActivity(from: commandRows), "Running swift test…")
    }

    func testExtractsAgyAndOtherAgentSpinners() {
        let rows = [
            "Some output",
            "⠋ Thinking...",
        ]
        XCTAssertEqual(TerminalPreview.liveActivity(from: rows), "Thinking...")

        let runningRows = [
            "Some output",
            "⠙ Running tests...",
        ]
        XCTAssertEqual(TerminalPreview.liveActivity(from: runningRows), "Running tests...")
    }

    func testExtractsActionEllipsisActivity() {
        let rows = [
            "Preparing environment",
            "Writing Sources/LinkCKit/TerminalSession.swift…",
        ]
        XCTAssertEqual(TerminalPreview.liveActivity(from: rows), "Writing Sources/LinkCKit/TerminalSession.swift…")

        let thinkingRows = [
            "Thinking…",
        ]
        XCTAssertEqual(TerminalPreview.liveActivity(from: thinkingRows), "Thinking…")
    }

    func testLiveActivityIgnoresBannersAndChrome() {
        let rows = [
            "Done",
            "⏵⏵ bypass permissions on (shift+tab to cycle)",
            "? for shortcuts",
            "Context left until auto-compact: 8%",
            "❯",
        ]
        XCTAssertNil(TerminalPreview.liveActivity(from: rows))
    }

    func testLiveActivityReturnsNilWhenIdlePromptPresentAtBottom() {
        let rowsWithPastThinking = [
            "⠋ Thinking...",
            "Here is the final output from your request.",
            "❯"
        ]
        XCTAssertNil(TerminalPreview.liveActivity(from: rowsWithPastThinking), "Past activity above an idle prompt must return nil")

        let rowsWithPromptSpace = [
            "Writing Sources/LinkCKit/TerminalSession.swift…",
            "Done writing file.",
            "❯ "
        ]
        XCTAssertNil(TerminalPreview.liveActivity(from: rowsWithPromptSpace))
    }

    func testLiveActivityReturnsNilForCodexIdleStartupPrompt() {
        let codexStartupRows = [
            "╭───────────────────────────────────────╮",
            "│ >_ OpenAI Codex (v0.153.4)            │",
            "│                                       │",
            "│ model:     loading   /model to change │",
            "│ directory: loading                    │",
            "╰───────────────────────────────────────╯",
            "  › Ask Codex to do anything",
            "  ? for shortcuts"
        ]
        XCTAssertNil(TerminalPreview.liveActivity(from: codexStartupRows), "Codex startup idle prompt must return nil")
    }

    func testLiveActivityReturnsNilForClaudeIdleBoxPromptWithPastActivity() {
        let claudeIdleRows = [
            "✻ Sautéing… (12s · esc to interrupt)",
            "Fixed the issue in PanelView.",
            "╭───────────────────────────────────────╮",
            "│ >                                     │",
            "╰───────────────────────────────────────╯",
            "  ? for shortcuts"
        ]
        XCTAssertNil(TerminalPreview.liveActivity(from: claudeIdleRows), "Claude idle boxed prompt must return nil even if past sautéing was in recent rows")
    }

    func testExtractsCursorBrailleSpinnerActivity() {
        let workingRows1 = [
            "echo hello",
            "⠀⠞ Working",
            "  → Add a follow-up                               ctrl+c to stop",
            "  Auto                                            Run Everything"
        ]
        XCTAssertEqual(TerminalPreview.liveActivity(from: workingRows1), "Working")

        let workingRows2 = [
            "what is 2+2",
            "⠠⠜ Working",
            "  → Add a follow-up                               ctrl+c to stop"
        ]
        XCTAssertEqual(TerminalPreview.liveActivity(from: workingRows2), "Working")

        let runningRows = [
            "Running that now.",
            "⠀⠞ Running  23 tokens",
            "  → Add a follow-up                               ctrl+c to stop"
        ]
        XCTAssertEqual(TerminalPreview.liveActivity(from: runningRows), "Running")
    }

    func testLiveActivityReturnsNilForCursorIdleAndFinishedPrompts() {
        let cursorStartupRows = [
            "  Cursor Agent",
            "  v2026.09.08-6caf4ff",
            "  Tip: Use /config to customize Cursor settings and behavior.",
            "  → Plan, search, build anything",
            "  Auto                                    Run Everything",
            "  ~/projects/linkC · main"
        ]
        XCTAssertNil(TerminalPreview.liveActivity(from: cursorStartupRows), "Cursor initial prompt must be idle")

        let cursorFinishedRows = [
            "echo hello",
            "hello",
            "  → Add a follow-up",
            "  Auto                                    Run Everything",
            "  ~/projects/linkC · main"
        ]
        XCTAssertNil(TerminalPreview.liveActivity(from: cursorFinishedRows), "Cursor prompt without 'ctrl+c to stop' must be idle")
    }

    // MARK: Real screens
    //
    // Captured 2026-09-15 at 100 columns with linkC's launch flags (account rows removed). Every
    // agent keeps its input box on screen while it works: the working marker is in the footer
    // below the box, and the phrase is on a spinner row above it. A finished turn keeps its
    // output — including lines truncated with "..." — above the same box.

    func testLiveActivityReadsAgyAsWorkingPastItsAlwaysVisibleInputBox() {
        let rule = String(repeating: "─", count: 100)
        let working = [
            "> Run the shell command `sleep 15 && echo finished` and then reply with just its output. Do not",
            "  create or edit any files.",
            "▸ Thought for 2s, 613 tokens",
            "  The task involves executing a shell command that includes a sleep operation, followed by an ec...",
            "● Read(~/.gemini/config/skills/using-superpowers/SKILL.md)",
            "● Bash(sleep 15 && echo finished) (ctrl+o to expand)",
            "⣾  Running command...",
            "└ Tip: You can switch conversations with /resume.",
            rule,
            ">",
            rule,
            "esc to cancel                                                                Gemini 3.8 Flash · high",
        ]
        XCTAssertEqual(TerminalPreview.liveActivity(from: working), "Running command...")
    }

    func testLiveActivityReadsAFinishedAgyTurnAsIdleDespiteTruncatedLinesAboveTheBox() {
        let rule = String(repeating: "─", count: 100)
        let finished = [
            "  The task involves executing a shell command that includes a sleep operation, followed by an ec...",
            "● Read(~/.gemini/config/skills/using-superpowers/SKILL.md)",
            "● Bash(sleep 15 && echo finished) (ctrl+o to expand)",
            "▸ Thought for 4s, 1.3k tokens",
            "  The task has completed and its output is available. The system resumed execution after task co...",
            "  I have launched the command and will wait for it to finish.",
            "● ManageTask(status task-4) (ctrl+o to expand)",
            "  finished",
            rule,
            ">",
            rule,
            "? for shortcuts                                                              Gemini 3.8 Flash · high",
        ]
        XCTAssertNil(TerminalPreview.liveActivity(from: finished))
    }

    func testLiveActivityReadsClaudesSpinnerAboveTheInputBoxNotItsFooter() {
        let rule = String(repeating: "─", count: 100)
        let working = [
            "❯ Run the shell command sleep 15 && echo finished and then reply with just its output. Do not",
            "  create or edit any files.",
            "⏺ Sleeping 15 seconds then printing finished · 9s",
            "  ⎿  $ sleep 15 && echo finished (9s)",
            "     (ctrl+b ctrl+b (twice) to run in background)",
            "✻ Percolating… (12s · ↓ 115 tokens)",
            "  tmux focus-events off · add 'set -g focus-events on' to ~/.tmux.conf and reattach for focus tra…",
            rule,
            "❯ ",
            rule,
            "  ⏵⏵ bypass permissions on (shift+tab to cycle) · esc to interrupt · ← for agents",
        ]
        XCTAssertEqual(TerminalPreview.liveActivity(from: working), "Percolating…")
    }

    func testLiveActivityReadsAFinishedClaudeTurnAsIdle() {
        let rule = String(repeating: "─", count: 100)
        let finished = [
            "❯ Run the shell command sleep 15 && echo finished and then reply with just its output. Do not",
            "  create or edit any files.",
            "  Ran 1 shell command",
            "⏺ finished",
            "✻ Brewed for 18s · done 4:40 PM",
            rule,
            "❯ ",
            rule,
            "  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents",
        ]
        XCTAssertNil(TerminalPreview.liveActivity(from: finished))
    }

    /// Codex has no working footer: its status row sits right above the input box.
    func testLiveActivityReadsCodexsStatusRowRightAboveItsInputBox() {
        let justStarted = [
            "  Tip: New Use /fast to enable our fastest inference with increased plan usage.",
            "• You have 2 usage limit resets available. Run /usage to use one.",
            "› Run the shell command `sleep 15 && echo finished` and then reply with just its output. Do not",
            "  create or edit any files.",
            "• I’m running the command now.",
            "• Working (3s • esc to interrupt)",
            "› Ask Codex to do anything",
            "  gpt-5.6-sol low · ~/projects/linkC/.worktrees/state-repro · renaming... ⠋",
        ]
        XCTAssertEqual(TerminalPreview.liveActivity(from: justStarted), "Working")

        let withBackgroundTerminal = [
            "  Tip: New Use /fast to enable our fastest inference with increased plan usage.",
            "• You have 2 usage limit resets available. Run /usage to use one.",
            "› Run the shell command `sleep 15 && echo finished` and then reply with just its output. Do not",
            "  create or edit any files.",
            "• I’m running the command now.",
            "• Working (9s • esc to interrupt) · 1 background terminal running · /ps to view · /stop to close",
            "› Ask Codex to do anything",
            "  gpt-5.6-sol low · ~/projects/linkC/.worktrees/state-repro · Run sleep command",
        ]
        XCTAssertEqual(TerminalPreview.liveActivity(from: withBackgroundTerminal), "Working")
    }

    func testLiveActivityReadsAFinishedCodexTurnAsIdle() {
        let rule = String(repeating: "─", count: 100)
        let finished = [
            "• I’m running the command now.",
            "• Ran sleep 15 && echo finished",
            "  └ finished",
            rule,
            "• finished",
            rule,
            "› Ask Codex to do anything",
            "  gpt-5.6-sol low · ~/projects/linkC/.worktrees/state-repro · Run sleep command",
        ]
        XCTAssertNil(TerminalPreview.liveActivity(from: finished))
    }

    func testLiveActivitySaysWorkingWhenTheFooterDoesButNoSpinnerRowIsOnScreen() {
        let rule = String(repeating: "─", count: 100)
        let rows = [
            "⏺ Reading 3 files",
            rule,
            "❯ ",
            rule,
            "  ⏵⏵ bypass permissions on (shift+tab to cycle) · esc to interrupt · ← for agents",
        ]
        XCTAssertEqual(TerminalPreview.liveActivity(from: rows), "Working")
    }

    // MARK: Trust dialogs (captured with the app's launch flags; paths shortened)

    func testRecognizesCodexAndAgyTrustDialogs() {
        let codex = [
            "> You are in ~/projects/new-app",
            "  Do you trust the contents of this directory? Working with untrusted contents comes with higher",
            "  risk of prompt injection. Trusting the directory allows project-local config, hooks, and exec",
            "  policies to load.",
            "› 1. Yes, continue",
            "  2. No, quit",
            "  Press enter to continue",
        ]
        XCTAssertTrue(TerminalPreview.isTrustPrompt(codex))

        let agy = [
            "Accessing workspace:",
            "~/projects/new-app",
            "Do you trust the contents of this project?",
            "Antigravity CLI requires permission to read, edit, and execute files here.",
            "> Yes, I trust this folder",
            "  No, exit",
            "  ↑/↓ Navigate · enter Confirm",
            "                                                                             Gemini 3.8 Flash · high",
        ]
        XCTAssertTrue(TerminalPreview.isTrustPrompt(agy))
    }

    /// Constructed, not captured: the two screens the check must not mistake for a dialog.
    func testATrustQuestionInOutputOrAnAnsweredDialogIsNotATrustPrompt() {
        let quoted = [
            "• Codex asks whether you trust a folder on first launch:",
            "Do you trust the contents of this directory? is shown once per folder.",
            "• finished",
            "› Ask Codex to do anything",
            "  gpt-5.6-sol low · ~/projects/new-app",
        ]
        XCTAssertFalse(TerminalPreview.isTrustPrompt(quoted))

        let answered = [
            "  Do you trust the contents of this directory? Working with untrusted contents comes with higher",
            "› 1. Yes, continue",
            "  2. No, quit",
            "│ >_ OpenAI Codex (v0.154.0)                           │",
            "│ model:       gpt-5.6-sol low   /model to change      │",
            "╰──────────────────────────────────────────────────────╯",
            "› Ask Codex to do anything",
            "  gpt-5.6-sol low · ~/projects/new-app",
        ]
        XCTAssertFalse(TerminalPreview.isTrustPrompt(answered))

        // A live Codex session printing the dialog's text: its input box sits under the choice.
        let printedAboveTheInputBox = [
            "Do you trust the contents of this directory? Working with untrusted contents comes with higher",
            "› 1. Yes, continue",
            "› Ask Codex to do anything",
            "  gpt-5.6-sol low · ~/projects/new-app",
        ]
        XCTAssertFalse(TerminalPreview.isTrustPrompt(printedAboveTheInputBox))
    }

    /// Constructed from the Codex capture: a narrow panel wraps the question before "of this".
    func testRecognizesATrustDialogWhoseQuestionWraps() {
        let narrow = [
            "  Do you trust the contents",
            "  of this directory? Working",
            "  with untrusted contents comes",
            "  with higher risk of prompt",
            "  injection.",
            "› 1. Yes, continue",
            "  2. No, quit",
            "  Press enter to continue",
        ]
        XCTAssertTrue(TerminalPreview.isTrustPrompt(narrow))
    }

    /// Rows that redraw on their own each second — a working footer, a timer, an animated
    /// spinner — say nothing about progress. Everything else does.
    func testLiveMarkerRowsAreOnlyTheOnesThatTickOnTheirOwn() {
        XCTAssertTrue(TerminalPreview.isLiveMarkerRow("  ⏵⏵ bypass permissions on (shift+tab to cycle) · esc to interrupt · ← for agents"))
        XCTAssertTrue(TerminalPreview.isLiveMarkerRow("esc to cancel                                    Gemini 3.8 Flash · high"))
        XCTAssertTrue(TerminalPreview.isLiveMarkerRow("• Working (9s • esc to interrupt) · 1 background terminal running"))
        XCTAssertTrue(TerminalPreview.isLiveMarkerRow("✻ Percolating… (12s · ↓ 115 tokens)"))
        XCTAssertTrue(TerminalPreview.isLiveMarkerRow("⣾  Running command..."))

        XCTAssertFalse(TerminalPreview.isLiveMarkerRow("● Bash(sleep 15 && echo finished) (ctrl+o to expand)"))
        XCTAssertFalse(TerminalPreview.isLiveMarkerRow("  Ran 1 shell command"))
        XCTAssertFalse(TerminalPreview.isLiveMarkerRow("⏺ finished"))
        XCTAssertFalse(TerminalPreview.isLiveMarkerRow("   "))
    }
}

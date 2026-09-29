import AppKit
import SwiftTerm
import XCTest
@testable import LinkCKit

private final class TerminalTitleRecorder: NSObject, LocalProcessTerminalViewDelegate {
    var title: String?

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) { self.title = title }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {}
}

/// A window whose visibility a test flips — shown, ordered out, or on but covered — without asking
/// AppKit to put anything on screen.
private final class SwitchableTestWindow: NSWindow {
    enum Presence { case shown, occluded, hidden }
    var presence = Presence.shown

    override var isVisible: Bool { presence != .hidden }
    override var occlusionState: NSWindow.OcclusionState { presence == .shown ? [.visible] : [] }
}

/// What a terminal shows and which modes it is in: everything a mangled stream would change.
private struct TerminalContent: Equatable {
    var rows: [String]
    var cursorColumn: Int
    var cursorRow: Int
    var bracketedPasteMode: Bool
    var applicationCursor: Bool
    var synchronizedOutputActive: Bool

    init(_ terminal: Terminal) {
        rows = (0..<terminal.rows).map { terminal.getLine(row: $0)?.translateToString(trimRight: true) ?? "" }
        let cursor = terminal.getCursorLocation()
        cursorColumn = cursor.x
        cursorRow = cursor.y
        bracketedPasteMode = terminal.bracketedPasteMode
        applicationCursor = terminal.applicationCursor
        synchronizedOutputActive = terminal.synchronizedOutputActive
    }
}

@MainActor
extension TerminalSessionTests {

    func testDetachedFeedUpdatesModelWithoutSchedulingDisplayWork() {
        let view = LinkCTerminalView(frame: NSRect(x: 0, y: 0, width: 760, height: 460))
        let titleRecorder = TerminalTitleRecorder()
        view.processDelegate = titleRecorder
        settleInitialDisplay(of: view)

        let output = "\u{1b}]0;detached title\u{7}alpha\r\nbeta\u{1b}[?2004h"
        view.dataReceived(slice: Array(output.utf8)[...])

        let terminal = view.getTerminal()
        XCTAssertEqual(terminal.getLine(row: 0)?.translateToString(trimRight: true), "alpha")
        XCTAssertEqual(terminal.getLine(row: 1)?.translateToString(trimRight: true), "beta")
        XCTAssertEqual(terminal.getCursorLocation().y, 1)
        XCTAssertTrue(terminal.bracketedPasteMode)
        XCTAssertEqual(titleRecorder.title, "detached title")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertNotNil(terminal.getUpdateRange(),
                        "detached output must remain dirty until attachment, not be consumed by updateDisplay")
    }

    func testDetachedFeedRequestsFullDisplayWhenReattached() {
        let view = LinkCTerminalView(frame: NSRect(x: 0, y: 0, width: 760, height: 460))
        settleInitialDisplay(of: view)
        view.dataReceived(slice: Array("reattached content".utf8)[...])
        XCTAssertNotNil(view.getTerminal().getUpdateRange())

        let host = TerminalHostView(frame: view.bounds)
        let window = SwitchableTestWindow(
            contentRect: view.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        host.show(view)

        XCTAssertEqual(view.getTerminal().getUpdateRange()?.endY, view.getTerminal().rows,
                       "reattaching must invalidate the full terminal before drawing")
        XCTAssertTrue(waitUntil(timeout: 2) { view.getTerminal().getUpdateRange() == nil },
                      "reattaching must run the deferred full redraw")
        XCTAssertEqual(view.getTerminal().getLine(row: 0)?.translateToString(trimRight: true), "reattached content")
        window.orderOut(nil)
    }

    func testDetachedSynchronizedOutputKeepsItsDirtyRange() {
        let view = LinkCTerminalView(frame: NSRect(x: 0, y: 0, width: 760, height: 460))
        settleInitialDisplay(of: view)

        let output = "\u{1b}[?2026hwrapped output\u{1b}[?2026l"
        view.dataReceived(slice: Array(output.utf8)[...])
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertNotNil(view.getTerminal().getUpdateRange(),
                        "synchronized-output end must not schedule a display pass while detached")
    }

    func testHiddenWindowDefersDisplayAndRedrawsWhenShownAgain() {
        let view = LinkCTerminalView(frame: NSRect(x: 0, y: 0, width: 760, height: 460))
        let host = TerminalHostView(frame: view.bounds)
        let window = NSWindow(contentRect: view.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.show(view)
        settleInitialDisplay(of: view)

        window.orderOut(nil)
        view.dataReceived(slice: Array("hidden output".utf8)[...])
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertNotNil(view.getTerminal().getUpdateRange(),
                        "an ordered-out panel must not consume terminal display work")

        window.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        XCTAssertTrue(waitUntil(timeout: 2) { view.getTerminal().getUpdateRange() == nil },
                      "showing the panel must render output deferred while it was hidden")
        window.orderOut(nil)
    }

    func testOccludedWindowDefersDisplayAndRedrawsWhenUncovered() {
        let (view, window) = terminalView(in: .shown)
        settleInitialDisplay(of: view)

        window.presence = .occluded
        view.dataReceived(slice: bytes("covered output"))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertNotNil(view.getTerminal().getUpdateRange(),
                        "a window that is on but covered must not consume terminal display work")

        setPresence(.shown, of: window)
        XCTAssertTrue(waitUntil(timeout: 2) { view.getTerminal().getUpdateRange() == nil },
                      "uncovering the window must render output deferred while it was covered")
    }

    func testReattachRestoresTheSynchronizedOutputModeAFrameLeftOn() {
        let (view, window) = terminalView(in: .hidden)
        let terminal = view.getTerminal()

        view.dataReceived(slice: bytes("\u{1b}[?2026hhalf a frame"))
        XCTAssertFalse(terminal.synchronizedOutputActive, "the toggle must not reach SwiftTerm while hidden")

        setPresence(.shown, of: window)
        XCTAssertTrue(terminal.synchronizedOutputActive, "the app is mid-frame, so SwiftTerm must be once shown")
        XCTAssertEqual(terminal.getLine(row: 0)?.translateToString(trimRight: true), "half a frame")

        view.dataReceived(slice: bytes("\u{1b}[?2026l"))
        XCTAssertFalse(terminal.synchronizedOutputActive, "the app's own end of frame must still reach SwiftTerm")
    }

    func testReattachEndsAFrameThatFinishedWhileHidden() {
        let (view, window) = terminalView(in: .shown)
        let terminal = view.getTerminal()
        view.dataReceived(slice: bytes("\u{1b}[?2026hstart"))
        XCTAssertTrue(terminal.synchronizedOutputActive)

        setPresence(.hidden, of: window)
        view.dataReceived(slice: bytes("end\u{1b}[?2026l"))
        setPresence(.shown, of: window)

        XCTAssertFalse(terminal.synchronizedOutputActive, "the frame ended while hidden; SwiftTerm must not wait it out")
        XCTAssertEqual(terminal.getLine(row: 0)?.translateToString(trimRight: true), "startend")
    }

    func testAFrameThatEndedWhileShownIsNotRevivedByLaterHiddenOutput() {
        let (view, window) = terminalView(in: .hidden)
        let terminal = view.getTerminal()
        view.dataReceived(slice: bytes("\u{1b}[?2026hone"))
        setPresence(.shown, of: window)
        XCTAssertTrue(terminal.synchronizedOutputActive)
        view.dataReceived(slice: bytes("\u{1b}[?2026l"))
        XCTAssertFalse(terminal.synchronizedOutputActive)

        setPresence(.hidden, of: window)
        view.dataReceived(slice: bytes("two"))
        setPresence(.shown, of: window)

        XCTAssertFalse(terminal.synchronizedOutputActive,
                       "the app is not mid-frame; display and echo must not stall on SwiftTerm's timeout")
        XCTAssertEqual(terminal.getLine(row: 0)?.translateToString(trimRight: true), "onetwo")
    }

    func testAToggleSplitAcrossHiddenChunksIsStillFiltered() {
        let (view, window) = terminalView(in: .hidden)
        let terminal = view.getTerminal()

        view.dataReceived(slice: bytes("abc\u{1b}[?20"))
        view.dataReceived(slice: bytes("26h def"))
        XCTAssertFalse(terminal.synchronizedOutputActive)
        setPresence(.shown, of: window)

        XCTAssertEqual(terminal.getLine(row: 0)?.translateToString(trimRight: true), "abc def")
        XCTAssertTrue(terminal.synchronizedOutputActive)
    }

    /// The stream reaches a hidden terminal in whatever pieces the PTY read it in. Cut at every byte
    /// (and, for a shorter stream, at every pair of bytes), the terminal that is then shown must
    /// match one that parsed the whole stream, toggles and all: the withheld toggles restored, every
    /// other private mode and escape sequence intact. What arrives after the terminal is shown
    /// follows on from whatever the hidden stretch left held, so it is part of the comparison.
    func testHiddenOutputSplitAnywhereEndsUpAsTheUnsplitStreamWould() {
        let host = TerminalHostView(frame: NSRect(x: 0, y: 0, width: 760, height: 460))
        let window = SwitchableTestWindow(contentRect: host.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host

        func hiddenThenShown(_ chunks: [ArraySlice<UInt8>], then shownOutput: ArraySlice<UInt8>) -> TerminalContent {
            window.presence = .hidden
            let view = LinkCTerminalView(frame: host.bounds)
            host.show(view)
            for chunk in chunks { view.dataReceived(slice: chunk) }
            setPresence(.shown, of: window)
            view.dataReceived(slice: shownOutput)
            return TerminalContent(view.getTerminal())
        }

        let esc = "\u{1b}"
        let cases: [(stream: String, then: String, everyPair: Bool)] = [
            ("\(esc)[?2026hab\(esc)[?2004h\(esc)[?1h\(esc)[31mcd\(esc)[0m\r\n\(esc)[?2026lef\(esc)[?2026h",
             "gh\(esc)[?2026l", false),
            ("\(esc)[?2026hgh\(esc)[?2026lij\(esc)[?25l\(esc)[?2026hkl\(esc)[?20", "04hxyz", false),
            ("\(esc)[?2026hab\(esc)[?2004hcd\(esc)[?2026lef", "gh", true),
        ]

        for (stream, then, everyPair) in cases.map({ (bytes($0.stream), bytes($0.then), $0.everyPair) }) {
            let whole = LinkCTerminalView(frame: host.bounds).getTerminal()
            whole.feed(buffer: stream)
            whole.feed(buffer: then)
            let expected = TerminalContent(whole)
            XCTAssertFalse(expected.rows[0].isEmpty, "the reference must have parsed something")

            var differing: [String] = []
            for first in 0...stream.count {
                if hiddenThenShown([stream[..<first], stream[first...]], then: then) != expected {
                    differing.append("\(first)")
                }
                guard everyPair else { continue }
                for second in first...stream.count {
                    if hiddenThenShown([stream[..<first], stream[first..<second], stream[second...]], then: then) != expected {
                        differing.append("\(first),\(second)")
                    }
                }
            }
            XCTAssertEqual(differing, [],
                           "cuts that changed what \(String(decoding: stream, as: UTF8.self).debugDescription) shows")
        }
        window.presence = .hidden
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    func testAnEscapeHeldAtReattachStillStartsTheSequenceItBegan() {
        let (view, window) = terminalView(in: .hidden)
        let terminal = view.getTerminal()
        view.dataReceived(slice: bytes("\u{1b}[?2026habc\u{1b}"))

        setPresence(.shown, of: window)
        view.dataReceived(slice: bytes("[31mred"))

        XCTAssertEqual(terminal.getLine(row: 0)?.translateToString(trimRight: true), "abcred",
                       "the mode change must not land inside the sequence the held escape begins")
    }

    func testAPartialToggleHeldAtReattachCompletesAsAnotherMode() {
        let (view, window) = terminalView(in: .hidden)
        let terminal = view.getTerminal()
        view.dataReceived(slice: bytes("\u{1b}[?2026habc\u{1b}[?20"))

        setPresence(.shown, of: window)
        view.dataReceived(slice: bytes("04hxyz"))

        XCTAssertEqual(terminal.getLine(row: 0)?.translateToString(trimRight: true), "abcxyz")
        XCTAssertTrue(terminal.bracketedPasteMode, "the sequence held over must still enable bracketed paste")
        XCTAssertTrue(terminal.synchronizedOutputActive)
    }

    func testAPartialToggleHeldAtReattachCompletesAsTheEndOfTheFrame() {
        let (view, window) = terminalView(in: .hidden)
        let terminal = view.getTerminal()
        view.dataReceived(slice: bytes("\u{1b}[?2026habc\u{1b}[?2026"))

        setPresence(.shown, of: window)
        XCTAssertTrue(terminal.synchronizedOutputActive)
        view.dataReceived(slice: bytes("lxyz"))

        XCTAssertEqual(terminal.getLine(row: 0)?.translateToString(trimRight: true), "abcxyz")
        XCTAssertFalse(terminal.synchronizedOutputActive)
    }

    func testOutputArrivingShownBeforeTheVisibilityNoticeStillGetsTheHeldEscape() {
        let (view, window) = terminalView(in: .hidden)
        let terminal = view.getTerminal()
        view.dataReceived(slice: bytes("\u{1b}[?2026habc\u{1b}"))

        window.presence = .shown
        view.dataReceived(slice: bytes("[31mred"))

        XCTAssertEqual(terminal.getLine(row: 0)?.translateToString(trimRight: true), "abcred",
                       "shown output must first receive what hidden output left held")
        XCTAssertTrue(terminal.synchronizedOutputActive)
    }

    func testManagerRetainsTerminatingSessionUntilChildIsReaped() async throws {
        let manager = TerminalSessionManager()
        var session: TerminalSession? = manager.makeSession(
            id: "reap-on-close",
            cwd: FileManager.default.currentDirectoryPath,
            title: "delayed exit"
        )
        try session?.start(
            executable: "/bin/sh",
            args: ["-c", "trap '' TERM; sleep 1"],
            env: [:]
        )
        let pid = try XCTUnwrap(session?.processId)
        try await Task.sleep(for: .milliseconds(100))

        manager.terminate("reap-on-close")
        session = nil
        XCTAssertTrue(manager.sessions.isEmpty, "the closed terminal must disappear from the UI immediately")

        // `waitid` with WNOWAIT looks without reaping: a zombie is still there to see, and ECHILD means
        // SwiftTerm has reaped it. The test's own `waitpid` could reap it first and hide the answer.
        let deadline = ContinuousClock.now + .seconds(5)
        var reaped = false
        repeat {
            var info = siginfo_t()
            errno = 0
            if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == -1, errno == ECHILD {
                reaped = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < deadline
        if !reaped {
            var status: Int32 = 0
            kill(pid, SIGKILL)
            waitpid(pid, &status, 0)
        }
        XCTAssertTrue(reaped, "the closed terminal's child was still a zombie or still running at the deadline")
    }

    func testManagerReleasesTerminatingSessionAfterChildExit() async throws {
        let manager = TerminalSessionManager()
        var session: TerminalSession? = manager.makeSession(
            id: "release-on-exit",
            cwd: FileManager.default.currentDirectoryPath,
            title: "delayed exit"
        )
        weak let weakSession = session
        try session?.start(executable: "/bin/sh", args: ["-c", "trap '' TERM; sleep 1"], env: [:])

        manager.terminate("release-on-exit")
        session = nil
        let deadline = ContinuousClock.now + .seconds(5)
        while weakSession != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertNil(weakSession, "the manager must release a terminating session after SwiftTerm reaps its child")
    }

    func testAOneLineMessageWaitsForTheSettleThenSubmitsOnce() {
        XCTAssertEqual(TerminalSession.inputPlan(for: "[linkC task X] done (unverified)\n", negotiatedPaste: true),
                       [.text("[linkC task X] done (unverified)"), .wait(milliseconds: TerminalSession.pasteSettleMilliseconds), .submit])
        XCTAssertEqual(TerminalSession.inputPlan(for: "ls\r\n", negotiatedPaste: false),
                       [.text("ls"), .wait(milliseconds: TerminalSession.pasteSettleMilliseconds), .submit])
    }

    func testAMultiLineMessagePastesThenSubmitsOnceAfterTheSettle() {
        XCTAssertEqual(TerminalSession.inputPlan(for: "a\nb", negotiatedPaste: true),
                       [.pasteStart, .text("a\nb"), .pasteEnd, .wait(milliseconds: TerminalSession.pasteSettleMilliseconds), .submit])
    }

    func testARawShellGetsMultiLineTextAsIs() {
        XCTAssertEqual(TerminalSession.inputPlan(for: "a\nb", negotiatedPaste: false), [.text("a\nb"), .submit])
    }

    func testEveryPlanSubmitsExactlyOnce() {
        for (text, paste) in [("x", true), ("x", false), ("a\nb", true), ("a\nb", false), ("", true)] {
            XCTAssertEqual(TerminalSession.inputPlan(for: text, negotiatedPaste: paste).filter { $0 == .submit }.count, 1, "\(text) \(paste)")
        }
    }


    func testOneLineInputEchoesExactlyOneReturnAfterTheSettle() async throws {
        let session = TerminalSession(id: "return-once", cwd: FileManager.default.currentDirectoryPath, title: "cat")
        try session.start(executable: "/bin/sh", args: ["-c", "stty -echo; printf '\\033[?2004h'; exec /bin/cat"], env: [:])
        defer { session.terminate() }
        for _ in 0..<100 {
            if session.acceptsPaste { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(session.acceptsPaste)
        let initialRow = session.terminalView.getTerminal().getCursorLocation().y
        session.sendInput("one submission\r\n")
        try await Task.sleep(for: .milliseconds(TerminalSession.pasteSettleMilliseconds + 400))
        XCTAssertTrue(session.recentOutput(lines: 10).contains("one submission"))
        XCTAssertEqual(session.terminalView.getTerminal().getCursorLocation().y - initialRow, 1)
    }

    func testTwoBackToBackSendInputCallsNeverInterleave() async throws {
        // A second `sendInput` arriving during the first plan's 300 ms settle must not write its
        // text until the first plan's submit has gone out. `tee` captures the raw bytes written
        // to the pty in order, so an interleaved delivery (text1text2\r\r) is distinguishable
        // from the required text1\rtext2\r.
        let capture = FileManager.default.temporaryDirectory
            .appendingPathComponent("terminal-interleave-\(UUID().uuidString)")
        let session = TerminalSession(id: "interleave", cwd: FileManager.default.currentDirectoryPath, title: "cat")
        try session.start(executable: "/bin/sh",
                           args: ["-c", "stty raw -echo; printf '\\033[?2004h'; exec /usr/bin/tee '\(capture.path)'"],
                           env: [:])
        defer {
            session.terminate()
            try? FileManager.default.removeItem(at: capture)
        }
        for _ in 0..<100 {
            if session.acceptsPaste { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(session.acceptsPaste)

        session.sendInput("text1")
        session.sendInput("text2")

        try await Task.sleep(for: .milliseconds(2 * TerminalSession.pasteSettleMilliseconds + 600))
        let received = try String(contentsOf: capture, encoding: .utf8)
        XCTAssertEqual(received, "text1\rtext2\r",
                        "the second delivery must wait for the first plan's submit, never interleave")
    }

    func testSendInputBeforeStartIsSafeNoOp() {
        let session = TerminalSession(id: "test-unstarted", cwd: "/tmp", title: "unstarted")
        // Calling sendInput on an unstarted session must be a safe no-op.
        session.sendInput("echo unstarted")
        XCTAssertEqual(session.recentOutput(lines: 5), "")
        session.terminate()
    }

    func testSendInputWithLiveProcessAppendsNewlineAndEchoes() async throws {
        let session = TerminalSession(id: "test-cat-live", cwd: "/tmp", title: "cat")
        try session.start(executable: "/bin/cat", args: [], env: [:])

        // Input without trailing newline — sendInput must append '\n'
        session.sendInput("hello linkc pty")

        let matched = await waitForOutput(session: session, containing: "hello linkc pty", timeout: 3.0)
        XCTAssertTrue(matched, "Expected terminal output to contain 'hello linkc pty', got: \(session.recentOutput(lines: 10))")

        // Input already ending in newline — sendInput must not duplicate or corrupt
        session.sendInput("second line with newline\n")
        let matchedSecond = await waitForOutput(session: session, containing: "second line with newline", timeout: 3.0)
        XCTAssertTrue(matchedSecond, "Expected terminal output to contain second line, got: \(session.recentOutput(lines: 10))")

        session.terminate()
    }

    func testSendInputAfterTerminationIsSafeNoOp() async throws {
        let session = TerminalSession(id: "test-cat-term", cwd: "/tmp", title: "cat")
        try session.start(executable: "/bin/cat", args: [], env: [:])
        session.terminate()

        // Wait brief moment for process termination to reap
        try? await Task.sleep(for: .milliseconds(500))

        // Sending input to terminated session must be safe no-op
        session.sendInput("should not be sent")
    }

    func testManagerSendInputRoutesToSession() async throws {
        let manager = TerminalSessionManager()
        let session = manager.makeSession(id: "mgr-cat", cwd: "/tmp", title: "cat")
        try session.start(executable: "/bin/cat", args: [], env: [:])

        manager.sendInput(sessionId: "mgr-cat", text: "manager message")

        let matched = await waitForOutput(session: session, containing: "manager message", timeout: 3.0)
        XCTAssertTrue(matched, "Expected output via manager to contain 'manager message', got: \(session.recentOutput(lines: 10))")

        manager.terminate("mgr-cat")
    }

    func testManagerSendInputUnknownSessionIsSafeNoOp() {
        let manager = TerminalSessionManager()
        // Must not crash or throw on non-existent session id
        manager.sendInput(sessionId: "non-existent-id", text: "nowhere")
        XCTAssertTrue(manager.sessions.isEmpty)
    }

    func testSendInputCarriageReturnSubmitsInteractiveShellCommand() async throws {
        let session = TerminalSession(id: "test-sh-live", cwd: "/tmp", title: "sh")
        try session.start(executable: "/bin/sh", args: [], env: [:])

        // Send input without any newline — sendInput must submit via Return (cmdRet / insertNewline)
        session.sendInput("echo __AUTO_SUBMITTED__")

        let matched = await waitForOutput(session: session, containing: "__AUTO_SUBMITTED__", timeout: 3.0)
        XCTAssertTrue(matched, "Expected shell to autonomously execute command and output '__AUTO_SUBMITTED__', got: \(session.recentOutput(lines: 10))")

        // Send input with trailing CR/LF
        session.sendInput("echo __WITH_CRLF__\r\n")
        let matchedCrlf = await waitForOutput(session: session, containing: "__WITH_CRLF__", timeout: 3.0)
        XCTAssertTrue(matchedCrlf, "Expected shell to autonomously execute CRLF command, got: \(session.recentOutput(lines: 10))")

        session.terminate()
    }

    private func waitForOutput(session: TerminalSession, containing snippet: String, timeout: TimeInterval) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if session.recentOutput(lines: 10).contains(snippet) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return session.recentOutput(lines: 10).contains(snippet)
    }

    private func bytes(_ text: String) -> ArraySlice<UInt8> { Array(text.utf8)[...] }

    /// A terminal view hosted in a window that starts out `presence`.
    private func terminalView(in presence: SwitchableTestWindow.Presence) -> (LinkCTerminalView, SwitchableTestWindow) {
        let view = LinkCTerminalView(frame: NSRect(x: 0, y: 0, width: 760, height: 460))
        let host = TerminalHostView(frame: view.bounds)
        let window = SwitchableTestWindow(contentRect: view.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.presence = presence
        window.contentView = host
        host.show(view)
        return (view, window)
    }

    private func setPresence(_ presence: SwitchableTestWindow.Presence, of window: SwitchableTestWindow) {
        window.presence = presence
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
    }

    /// Waits out the display pass a new view queues for itself, so the only dirty range a test sees is
    /// the one its own feed makes. A fixed sleep is not enough: under ThreadSanitizer that pass can run
    /// after it and consume the range the test is about to check.
    private func settleInitialDisplay(of view: LinkCTerminalView) {
        XCTAssertTrue(waitUntil(timeout: 5) { view.getTerminal().getUpdateRange() == nil },
                      "the display pass a new view queues never ran")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }
}

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

@MainActor
extension TerminalSessionTests {

    func testDetachedFeedUpdatesModelWithoutSchedulingDisplayWork() {
        let view = LinkCTerminalView(frame: NSRect(x: 0, y: 0, width: 760, height: 460))
        let titleRecorder = TerminalTitleRecorder()
        view.processDelegate = titleRecorder
        view.needsDisplay = false
        view.getTerminal().clearUpdateRange()

        let output = "\u{1b}]0;detached title\u{7}alpha\r\nbeta\u{1b}[?2004h"
        view.dataReceived(slice: Array(output.utf8)[...])

        let terminal = view.getTerminal()
        XCTAssertEqual(terminal.getLine(row: 0)?.translateToString(trimRight: true), "alpha")
        XCTAssertEqual(terminal.getLine(row: 1)?.translateToString(trimRight: true), "beta")
        XCTAssertEqual(terminal.getCursorLocation().y, 1)
        XCTAssertTrue(terminal.bracketedPasteMode)
        XCTAssertEqual(titleRecorder.title, "detached title")
        XCTAssertTrue(view.hasDeferredDisplay)
        XCTAssertNotNil(terminal.getUpdateRange(),
                        "detached output must remain dirty until attachment, not be consumed by updateDisplay")
    }

    func testDetachedFeedRequestsFullDisplayWhenReattached() {
        let view = LinkCTerminalView(frame: NSRect(x: 0, y: 0, width: 760, height: 460))
        view.needsDisplay = false
        view.getTerminal().clearUpdateRange()
        view.dataReceived(slice: Array("reattached content".utf8)[...])
        XCTAssertTrue(view.hasDeferredDisplay)
        XCTAssertNotNil(view.getTerminal().getUpdateRange())

        let host = TerminalHostView(frame: view.bounds)
        let window = NSWindow(contentRect: view.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.show(view)

        XCTAssertTrue(view.needsDisplay, "reattaching after background output must invalidate the full terminal")
        XCTAssertFalse(view.hasDeferredDisplay)
        XCTAssertEqual(view.getTerminal().getLine(row: 0)?.translateToString(trimRight: true), "reattached content")
    }

    func testDetachedFeedUsesLessCPUThanTheInheritedDisplayPath() {
        let detached = LinkCTerminalView(frame: NSRect(x: 0, y: 0, width: 760, height: 460))
        let inherited = LocalProcessTerminalView(frame: detached.frame)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let chunk = Array((0..<8).map { "\u{1b}[32mstreamed line \($0)\u{1b}[0m\r\n" }.joined().utf8)[...]

        let before = ThreadCPUTime.elapsed {
            for _ in 0..<50 {
                inherited.dataReceived(slice: chunk)
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
        }
        let after = ThreadCPUTime.elapsed {
            for _ in 0..<50 {
                detached.dataReceived(slice: chunk)
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
        }

        print(String(format: "Detached terminal feed CPU: before %.6fs, after %.6fs", before, after))
        XCTAssertLessThan(after, before)
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
        try await Task.sleep(for: .milliseconds(900))

        var status: Int32 = 0
        errno = 0
        let result = waitpid(pid, &status, WNOHANG)
        let waitError = errno
        if result == 0 {
            kill(pid, SIGKILL)
            waitpid(pid, &status, 0)
        }
        XCTAssertEqual(result, -1, "waitpid returned \(result); returning the pid proves the child was left as a zombie")
        XCTAssertEqual(waitError, ECHILD, "SwiftTerm must already have reaped the closed terminal child")
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
}

import XCTest
@testable import LinkCKit

@MainActor
extension TerminalSessionTests {

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

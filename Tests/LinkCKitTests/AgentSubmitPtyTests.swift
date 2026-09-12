import XCTest
@testable import LinkCKit

/// Live guard for autonomous delivery: a task frame is multi-line, so `sendInput` wraps it in a
/// bracketed paste. Agent TUIs buffer that paste and process it on a later runloop tick, which
/// swallows a Return sent in the same read — the frame then sits unsent in the composer and the
/// worker never sees the task. Single-line input never exercises that path.
@MainActor
final class AgentSubmitPtyTests: XCTestCase {
    /// The agent must answer, so the marker cannot be satisfied by the echoed prompt.
    private static let marker = "179"

    func testMultiLineSendInputAutoSubmitsToClaude() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LINKC_LIVE_AGENT_TESTS"] == "1", "Drives the real Claude CLI over the network; set LINKC_LIVE_AGENT_TESTS=1 to run it.")
        guard let path = AgentDescriptor.resolveExecutable(for: .claude),
              FileManager.default.isExecutableFile(atPath: path) else { return }

        let session = TerminalSession(id: "test-claude-multiline", cwd: FileManager.default.currentDirectoryPath, title: "claude", agentKind: .claude)
        try session.start(executable: path, args: AgentDescriptor.arguments(for: .claude, mode: .new), env: [:])
        try await Task.sleep(for: .seconds(6))

        session.sendInput("[linkC test frame]\nAdd one hundred thirty seven to forty two. Reply with the digits only, nothing else.\n\nA second paragraph, so the input takes the bracketed-paste path.")

        var answered = false
        for _ in 0..<80 {
            try await Task.sleep(for: .milliseconds(250))
            if session.recentOutput(lines: 40).contains(Self.marker) {
                answered = true
                break
            }
        }
        session.terminate()
        XCTAssertTrue(answered, "A multi-line frame must submit itself; it stayed in the composer unsent.")
    }

    func testMultiLineSendInputAutoSubmitsToCodex() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LINKC_LIVE_AGENT_TESTS"] == "1", "Drives the real Codex CLI over the network; set LINKC_LIVE_AGENT_TESTS=1 to run it.")
        guard let path = AgentDescriptor.resolveExecutable(for: .codex),
              FileManager.default.isExecutableFile(atPath: path) else { return }

        let session = TerminalSession(id: "test-codex-multiline", cwd: FileManager.default.currentDirectoryPath, title: "codex", agentKind: .codex)
        try session.start(executable: path, args: AgentDescriptor.arguments(for: .codex, mode: .new), env: [:])
        try await Task.sleep(for: .seconds(8))

        session.sendInput("[linkC test frame]\nAdd one hundred thirty seven to forty two. Reply with the digits only, nothing else.\n\nA second paragraph, so the input takes the bracketed-paste path.")

        var answered = false
        for _ in 0..<80 {
            try await Task.sleep(for: .milliseconds(250))
            if session.recentOutput(lines: 40).contains(Self.marker) {
                answered = true
                break
            }
        }
        session.terminate()
        XCTAssertTrue(answered, "A multi-line frame must submit itself to Codex; it stayed in the composer unsent.")
    }
}

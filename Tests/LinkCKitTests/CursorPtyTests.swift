import XCTest
@testable import LinkCKit

@MainActor
final class CursorPtyTests: XCTestCase {
    func testCursorSendInputAutoSubmitsAndDetectsWorkingActivity() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LINKC_LIVE_CURSOR_TESTS"] == "1", "Drives the real Cursor CLI over the network; set LINKC_LIVE_CURSOR_TESTS=1 to run it.")
        guard let cursorPath = AgentDescriptor.resolveExecutable(for: .cursor),
              FileManager.default.isExecutableFile(atPath: cursorPath) else { return }

        let session = TerminalSession(id: "test-cursor-auto", cwd: FileManager.default.currentDirectoryPath, title: "cursor", agentKind: .cursor)
        let args = AgentDescriptor.arguments(for: .cursor, mode: .new)
        try session.start(executable: cursorPath, args: args, env: [:])

        try await Task.sleep(for: .seconds(3))

        session.sendInput("what is 2+2")

        var detectedActivity: String? = nil
        for _ in 0..<25 {
            try await Task.sleep(for: .milliseconds(200))
            if let act = session.liveActivityLine() {
                detectedActivity = act
                break
            }
        }
        session.terminate()
        XCTAssertNotNil(detectedActivity, "Cursor live activity must be detected as active while processing")
    }
}

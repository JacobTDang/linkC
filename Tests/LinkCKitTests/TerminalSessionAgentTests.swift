import XCTest
@testable import LinkCKit

@MainActor
final class TerminalSessionAgentTests: XCTestCase {
    func testTerminalSessionAgentKindInit() {
        let defaultSession = TerminalSession(id: "s1", cwd: "/tmp", title: "Test")
        XCTAssertEqual(defaultSession.agentKind, .shell)

        let claudeSession = TerminalSession(id: "s2", cwd: "/tmp", title: "Claude", agentKind: .claude)
        XCTAssertEqual(claudeSession.agentKind, .claude)

        let agySession = TerminalSession(id: "s3", cwd: "/tmp", title: "Agy", agentKind: .agy)
        XCTAssertEqual(agySession.agentKind, .agy)
    }

    func testShellRowTracksDetectedAgent() {
        var row = ShellRow(id: "r1", cwd: "/tmp", title: "Shell", state: .running)
        XCTAssertNil(row.detectedAgent)

        row.detectedAgent = .agy
        XCTAssertEqual(row.detectedAgent, .agy)

        let store = ShellTerminalStore()
        store.add(id: "r1", cwd: "/tmp", title: "Shell")
        XCTAssertNil(store.row(id: "r1")?.detectedAgent)

        store.updateDetectedAgent(id: "r1", agent: .codex)
        XCTAssertEqual(store.row(id: "r1")?.detectedAgent, .codex)
    }

    func testSessionStoreSupportsAgentKind() {
        let store = SessionStore()
        let s1 = store.create(cwd: "/tmp", title: "Claude", agentKind: .claude)
        XCTAssertEqual(s1.agentKind, .claude)

        let s2 = store.create(cwd: "/tmp", title: "Cursor", agentKind: .cursor)
        XCTAssertEqual(s2.agentKind, .cursor)
    }
}

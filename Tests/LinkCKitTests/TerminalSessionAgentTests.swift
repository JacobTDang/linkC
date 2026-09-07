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

    func testSessionStateBuckets() {
        XCTAssertEqual(SessionState.working.bucket, .active)
        XCTAssertEqual(SessionState.ready.bucket, .idle)
        XCTAssertEqual(SessionState.starting.bucket, .idle)
        XCTAssertEqual(SessionState.ended.bucket, .idle)
        XCTAssertEqual(SessionState.waitingPermission.bucket, .needsYou)
        XCTAssertEqual(SessionState.waitingIdle.bucket, .needsYou)
        XCTAssertEqual(SessionState.finished.bucket, .needsYou)
        XCTAssertEqual(SessionState.error.bucket, .needsYou)
    }

    func testAgentRunLifecycle() {
        var run = AgentRun(id: "tool-1", description: "Search docs", type: "Explore", startedAt: Date())
        XCTAssertTrue(run.isRunning)
        XCTAssertEqual(run.type, "Explore")

        run.endedAt = Date()
        run.resultText = "Found 3 files"
        XCTAssertFalse(run.isRunning)
        XCTAssertEqual(run.resultText, "Found 3 files")
    }

    func testAgentKindBrandColorsAndPills() {
        XCTAssertEqual(AgentKind.claude.pillText, "CLAUDE")
        XCTAssertEqual(AgentKind.agy.pillText, "AGY")
        XCTAssertEqual(AgentKind.cursor.pillText, "CURSOR")
        XCTAssertEqual(AgentKind.codex.pillText, "CODEX")
        XCTAssertEqual(AgentKind.shell.pillText, "SHELL")

        XCTAssertEqual(AgentKind.claude.brandColorHex, "#D97757")
        XCTAssertEqual(AgentKind.agy.brandColorHex, "#7AA2F7")
        XCTAssertEqual(AgentKind.cursor.brandColorHex, "#00E5FF")
        XCTAssertEqual(AgentKind.codex.brandColorHex, "#10A37F")
        XCTAssertEqual(AgentKind.shell.brandColorHex, "#8E8E93")
    }

    func testAgentDescriptorCLIArgs() {
        let cursorArgs = AgentDescriptor.arguments(for: .cursor, mode: .continueLast)
        XCTAssertEqual(cursorArgs, ["agent", "--yolo", "--continue"])

        let agyArgs = AgentDescriptor.arguments(for: .agy, mode: .continueLast)
        XCTAssertEqual(agyArgs, ["--dangerously-skip-permissions", "--continue"])

        let codexArgs = AgentDescriptor.arguments(for: .codex, mode: .continueLast)
        XCTAssertEqual(codexArgs, ["--dangerously-bypass-approvals-and-sandbox", "resume", "--last"])

        let claudeArgs = AgentDescriptor.arguments(for: .claude, mode: .continueLast)
        XCTAssertEqual(claudeArgs, ["--dangerously-skip-permissions", "--continue"])
    }

    func testAgentDescriptorResolvesInstalledExecutables() {
        let claudePath = AgentDescriptor.resolveExecutable(for: .claude)
        XCTAssertNotNil(claudePath)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: claudePath!))

        let codexPath = AgentDescriptor.resolveExecutable(for: .codex)
        XCTAssertNotNil(codexPath)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: codexPath!))

        let cursorPath = AgentDescriptor.resolveExecutable(for: .cursor)
        XCTAssertNotNil(cursorPath)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: cursorPath!))

        let agyPath = AgentDescriptor.resolveExecutable(for: .agy)
        XCTAssertNotNil(agyPath)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: agyPath!))
    }
}

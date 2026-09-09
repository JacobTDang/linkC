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
        XCTAssertEqual(cursorArgs, ["agent", "--yolo", "--trust", "--approve-mcps", "--continue"])

        let agyArgs = AgentDescriptor.arguments(for: .agy, mode: .continueLast)
        XCTAssertEqual(agyArgs, ["--dangerously-skip-permissions", "--continue"])

        let codexArgs = AgentDescriptor.arguments(for: .codex, mode: .continueLast)
        XCTAssertEqual(codexArgs, ["--dangerously-bypass-approvals-and-sandbox", "resume", "--last"])

        let claudeArgs = AgentDescriptor.arguments(for: .claude, mode: .continueLast)
        XCTAssertEqual(claudeArgs, ["--dangerously-skip-permissions", "--continue"])
    }

    private final class MockFileManager: FileManager, @unchecked Sendable {
        let executablePaths: Set<String>
        init(executablePaths: Set<String>) {
            self.executablePaths = executablePaths
            super.init()
        }
        override func isExecutableFile(atPath path: String) -> Bool {
            executablePaths.contains(path)
        }
    }

    func testAgentDescriptorResolvesInstalledExecutables() {
        // Hermetic resolution verification using mock file manager
        let mockFM = MockFileManager(executablePaths: ["/opt/homebrew/bin/claude", "/opt/homebrew/bin/codex"])
        XCTAssertEqual(AgentDescriptor.resolveExecutable(for: .claude, fileManager: mockFM), "/opt/homebrew/bin/claude")
        XCTAssertEqual(AgentDescriptor.resolveExecutable(for: .codex, fileManager: mockFM), "/opt/homebrew/bin/codex")
        XCTAssertNil(AgentDescriptor.resolveExecutable(for: .cursor, fileManager: MockFileManager(executablePaths: [])))

        // On host machine, any resolved executable must be verified as executable
        for kind in [AgentKind.claude, .codex, .cursor, .agy] {
            if let path = AgentDescriptor.resolveExecutable(for: kind) {
                XCTAssertTrue(FileManager.default.isExecutableFile(atPath: path))
            }
        }
    }

    func testSessionStoreUpdateStateAndAgentKind() {
        let store = SessionStore()
        let s = store.create(cwd: "/tmp", title: "AGY Project", agentKind: .agy)
        XCTAssertEqual(s.state, .starting)
        XCTAssertEqual(s.state.bucket, .idle)

        store.updateState(id: s.id, to: .working)
        XCTAssertEqual(store.session(id: s.id)?.state, .working)
        XCTAssertEqual(store.session(id: s.id)?.state.bucket, .active)

        store.updateState(id: s.id, to: .finished)
        XCTAssertEqual(store.session(id: s.id)?.state, .finished)
        XCTAssertEqual(store.session(id: s.id)?.state.bucket, .needsYou)

        store.updateAgentKind(id: s.id, to: .cursor)
        XCTAssertEqual(store.session(id: s.id)?.agentKind, .cursor)
    }

    func testTerminalPreviewLiveActivityWithoutEllipsis() {
        let rows = [
            "Some earlier output",
            "⠋ Searching 31 websites"
        ]
        let activity = TerminalPreview.liveActivity(from: rows)
        XCTAssertEqual(activity, "Searching 31 websites")

        let actionRows = [
            "Building project",
            "Running tests"
        ]
        let actionActivity = TerminalPreview.liveActivity(from: actionRows)
        XCTAssertEqual(actionActivity, "Running tests")
    }

    func testProcessSnooperHasChildProcesses() {
        XCTAssertFalse(ProcessSnooper.hasChildProcesses(of: -1))
        XCTAssertFalse(ProcessSnooper.hasChildProcesses(of: 0))
    }
}

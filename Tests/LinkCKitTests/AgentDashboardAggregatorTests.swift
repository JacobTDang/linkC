import XCTest
@testable import LinkCKit

final class AgentDashboardAggregatorTests: XCTestCase {
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-aggregator-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testAggregateEmptyWorkspaceReturnsCleanDefaults() {
        let aggregator = AgentDashboardAggregator()
        let data = aggregator.aggregateProject(workspacePath: tempDir.path, liveSessions: [])

        XCTAssertEqual(data.workspacePath, (tempDir.path as NSString).standardizingPath)
        XCTAssertTrue(data.activityItems.isEmpty)
        XCTAssertTrue(data.dossiers.isEmpty)
        XCTAssertTrue(data.sharedNotes.isEmpty)
        XCTAssertTrue(data.collisions.isEmpty)
    }

    func testAggregateExtractsDelegationsCompletionsAndDossiers() throws {
        let ws = (tempDir.path as NSString).standardizingPath
        let inbox = InboxStore(workspaceRoot: ws)
        let blackboard = BlackboardStore(workspaceRoot: ws)

        // 1. Delegated task from Claude to Cursor
        let msg1 = try inbox.enqueue(
            from: .claude,
            to: .cursor,
            prompt: "Build authentication module",
            files: ["Auth.swift"]
        )
        try inbox.markDelivered(id: msg1.id)

        // 2. Completed task returned from Cursor to Claude
        let completionPrompt = """
        [Task Completed by Cursor Agent]
        Original Task: Build authentication module

        Result / Output:
        Generated Auth.swift with 5 tests passing.
        """
        _ = try inbox.enqueue(
            from: .cursor,
            to: .claude,
            prompt: completionPrompt,
            files: ["Auth.swift"]
        )

        // 3. Shared note on blackboard
        _ = try blackboard.addSharedNote(
            authorAgent: .claude,
            title: "Architecture Guide",
            content: "Use Swift 6 strict concurrency",
            tags: ["arch"]
        )

        let aggregator = AgentDashboardAggregator()
        let liveSessions = [(id: "s1", agent: AgentKind.cursor, status: "working", activity: Optional("Compiling Auth.swift"))]
        let data = aggregator.aggregateProject(workspacePath: ws, liveSessions: liveSessions)

        XCTAssertEqual(data.activityItems.count, 3)
        // Check completed task parsed
        let completed = data.activityItems.first(where: { $0.kind == .completedTask })
        XCTAssertNotNil(completed)
        XCTAssertEqual(completed?.fromAgent, .cursor)
        XCTAssertEqual(completed?.toAgent, .claude)
        XCTAssertTrue(completed?.body.contains("Generated Auth.swift") ?? false)

        // Check delegated task parsed
        let delegated = data.activityItems.first(where: { $0.kind == .delegatedTask })
        XCTAssertNotNil(delegated)
        XCTAssertEqual(delegated?.fromAgent, .claude)
        XCTAssertEqual(delegated?.toAgent, .cursor)

        // Check dossier for Cursor
        let cursorDossier = data.dossiers.first(where: { $0.agent == .cursor })
        XCTAssertNotNil(cursorDossier)
        XCTAssertEqual(cursorDossier?.completedTasksCount, 1)
        XCTAssertEqual(cursorDossier?.status, "working")
        XCTAssertEqual(cursorDossier?.liveActivity, "Compiling Auth.swift")
        XCTAssertEqual(cursorDossier?.claimedFiles, ["Auth.swift"])
    }

    func testAggregateGlobalCombinesMultipleWorkspaces() throws {
        let ws1URL = tempDir.appendingPathComponent("ws1")
        let ws2URL = tempDir.appendingPathComponent("ws2")
        try FileManager.default.createDirectory(at: ws1URL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ws2URL, withIntermediateDirectories: true)

        let ws1 = (ws1URL.path as NSString).standardizingPath
        let ws2 = (ws2URL.path as NSString).standardizingPath

        let inbox1 = InboxStore(workspaceRoot: ws1)
        let blackboard2 = BlackboardStore(workspaceRoot: ws2)

        _ = try inbox1.enqueue(from: .claude, to: .codex, prompt: "Refactor router")
        _ = try blackboard2.addSharedNote(authorAgent: .codex, title: "DB Spec", content: "SQLite schema v2")

        let aggregator = AgentDashboardAggregator()
        let liveSessions: [(id: String, workspace: String, agent: AgentKind, status: String, activity: String?)] = [
            (id: "s1", workspace: ws1, agent: AgentKind.codex, status: "working", activity: "Editing Router.swift"),
            (id: "s2", workspace: ws2, agent: AgentKind.claude, status: "idle", activity: nil)
        ]

        let globalData = aggregator.aggregateGlobal(workspaces: [ws1, ws2], liveSessions: liveSessions)

        XCTAssertEqual(globalData.activeProjectCount, 2)
        XCTAssertEqual(globalData.activityItems.count, 2)
        XCTAssertEqual(globalData.dossiers.count, 4) // (claude, codex) in ws1 + (claude, codex) in ws2
    }

    func testAggregateDetectsCollisionWarnings() throws {
        let ws = (tempDir.path as NSString).standardizingPath
        let blackboard = BlackboardStore(workspaceRoot: ws)

        _ = try blackboard.broadcastIntent(
            agentKind: .claude,
            pid: 1001,
            goal: "Refactor auth",
            files: ["Auth.swift"]
        )
        _ = try blackboard.broadcastIntent(
            agentKind: .cursor,
            pid: 1002,
            goal: "Add auth tests",
            files: ["Auth.swift"]
        )

        let aggregator = AgentDashboardAggregator()
        let data = aggregator.aggregateProject(workspacePath: ws, liveSessions: [])

        XCTAssertFalse(data.collisions.isEmpty)
        XCTAssertEqual(data.collisions.first?.conflictingFiles, ["Auth.swift"])
    }

    func testAggregateWithGitModifiedFiles() throws {
        let ws = (tempDir.path as NSString).standardizingPath
        let initProcess = Process()
        initProcess.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        initProcess.arguments = ["-C", ws, "init"]
        try initProcess.run()
        initProcess.waitUntilExit()

        // Create an untracked/modified file
        let testFile = tempDir.appendingPathComponent("Auth.swift")
        try "func authenticate() {}".write(to: testFile, atomically: true, encoding: .utf8)

        let liveSessions = [(id: "s1", agent: AgentKind.cursor, status: "working", activity: Optional("Writing code"))]
        let aggregator = AgentDashboardAggregator()
        let data = aggregator.aggregateProject(workspacePath: ws, liveSessions: liveSessions)

        let cursorDossier = data.dossiers.first(where: { $0.agent == .cursor })
        XCTAssertNotNil(cursorDossier)
        XCTAssertTrue(cursorDossier?.modifiedFiles.contains("Auth.swift") ?? false)
    }
}

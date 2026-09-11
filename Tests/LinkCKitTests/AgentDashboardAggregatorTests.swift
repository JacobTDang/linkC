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
        let task = try inbox.createTask(
            from: .claude,
            to: .cursor,
            prompt: "Build authentication module",
            files: ["Auth.swift"]
        )
        try inbox.markTaskDelivered(taskId: task.id, sessionId: "s")

        // 2. Completed task returned from Cursor to Claude
        _ = try inbox.enqueue(
            from: .cursor,
            to: .claude,
            kind: .completion,
            taskId: task.id,
            body: "done by Cursor Agent — Generated Auth.swift with 5 tests passing."
        )

        // 3. Shared note on blackboard
        _ = try blackboard.addSharedNote(
            authorAgent: .claude,
            title: "Architecture Guide",
            content: "Use Swift 6 strict concurrency",
            tags: ["arch"]
        )

        let aggregator = AgentDashboardAggregator()
        let liveSessions = [(id: "s1", agent: AgentKind.cursor, status: "working", activity: Optional("Compiling Auth.swift"), recentOutput: "")]
        let data = aggregator.aggregateProject(workspacePath: ws, liveSessions: liveSessions)

        XCTAssertEqual(data.activityItems.count, 4)
        // Check completed task parsed
        let completed = data.activityItems.first(where: { $0.kind == .completedTask })
        XCTAssertNotNil(completed)
        XCTAssertEqual(completed?.fromAgent, .cursor)
        XCTAssertEqual(completed?.toAgent, .claude)
        XCTAssertEqual(completed?.body, "done by Cursor Agent — Generated Auth.swift with 5 tests passing.")

        // Check delegated task parsed
        let delegated = data.activityItems.first(where: { $0.kind == .delegatedTask })
        XCTAssertNotNil(delegated)
        XCTAssertEqual(delegated?.fromAgent, .claude)
        XCTAssertEqual(delegated?.toAgent, .cursor)
        XCTAssertTrue(data.activityItems.contains { $0.id == "task-\(task.id)" && $0.kind == .delegatedTask && $0.title.contains("delegated task to Cursor Agent") })

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

        _ = try inbox1.createTask(from: .claude, to: .codex, prompt: "Refactor router", files: [])
        _ = try blackboard2.addSharedNote(authorAgent: .codex, title: "DB Spec", content: "SQLite schema v2")

        let aggregator = AgentDashboardAggregator()
        let liveSessions: [(id: String, workspace: String, agent: AgentKind, status: String, activity: String?, recentOutput: String)] = [
            (id: "s1", workspace: ws1, agent: AgentKind.codex, status: "working", activity: "Editing Router.swift", recentOutput: ""),
            (id: "s2", workspace: ws2, agent: AgentKind.claude, status: "idle", activity: nil, recentOutput: "")
        ]

        let globalData = aggregator.aggregateGlobal(workspaces: [ws1, ws2], liveSessions: liveSessions)

        XCTAssertEqual(globalData.activeProjectCount, 2)
        XCTAssertEqual(globalData.activityItems.count, 3)
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
        XCTAssertEqual(data.collisions.count, 1) // Deduplicated reciprocal warning
        XCTAssertEqual(data.collisions.first?.conflictingFiles, ["Auth.swift"])
    }

    func testAggregateSingleActiveAgentProducesNoCollision() throws {
        let ws = (tempDir.path as NSString).standardizingPath
        let blackboard = BlackboardStore(workspaceRoot: ws)

        _ = try blackboard.broadcastIntent(
            agentKind: .claude,
            pid: 1001,
            goal: "Refactor auth",
            files: ["Auth.swift"]
        )

        let aggregator = AgentDashboardAggregator()
        let data = aggregator.aggregateProject(workspacePath: ws, liveSessions: [])

        XCTAssertTrue(data.collisions.isEmpty)
    }

    func testAggregateDisjointActiveAgentsProduceNoCollision() throws {
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
            goal: "Build database",
            files: ["Database.swift"]
        )

        let aggregator = AgentDashboardAggregator()
        let data = aggregator.aggregateProject(workspacePath: ws, liveSessions: [])

        XCTAssertTrue(data.collisions.isEmpty)
    }

    func testAggregateExtractsRateLimitsAndIntentBroadcasts() throws {
        let ws = (tempDir.path as NSString).standardizingPath
        let inbox = InboxStore(workspaceRoot: ws)
        let blackboard = BlackboardStore(workspaceRoot: ws)

        // 1. Record rate limit
        try inbox.recordLimit(
            agent: .codex,
            reason: "HTTP 429 Too Many Requests: TPM limit exceeded",
            cooldown: 120.0
        )

        // 2. Broadcast intent
        _ = try blackboard.broadcastIntent(
            agentKind: .claude,
            pid: 2001,
            goal: "Implement query caching",
            files: ["Cache.swift"]
        )

        let aggregator = AgentDashboardAggregator()
        let data = aggregator.aggregateProject(workspacePath: ws, liveSessions: [])

        // Verify .rateLimited item
        let rateLimitItem = data.activityItems.first(where: { $0.kind == .rateLimited })
        XCTAssertNotNil(rateLimitItem)
        XCTAssertEqual(rateLimitItem?.fromAgent, .codex)
        XCTAssertNil(rateLimitItem?.toAgent)
        XCTAssertEqual(rateLimitItem?.title, "Codex Rate Limited")
        XCTAssertEqual(rateLimitItem?.body, "HTTP 429 Too Many Requests: TPM limit exceeded")

        // Verify .intentBroadcast item
        let intentItem = data.activityItems.first(where: { $0.kind == .intentBroadcast })
        XCTAssertNotNil(intentItem)
        XCTAssertEqual(intentItem?.fromAgent, .claude)
        XCTAssertNil(intentItem?.toAgent)
        XCTAssertEqual(intentItem?.title, "Claude Code broadcast goal")
        XCTAssertTrue(intentItem?.body.contains("Implement query caching") ?? false)
    }

    func testAggregateRetainsLatestDeliverableByTimestamp() throws {
        let ws = (tempDir.path as NSString).standardizingPath
        let inbox = InboxStore(workspaceRoot: ws)

        let olderDate = Date().addingTimeInterval(-1000)
        let newerDate = Date().addingTimeInterval(-500)

        // Older completion
        let olderMsg = PendingMessage(
            fromAgent: .cursor,
            toAgent: .claude,
            prompt: "[linkC task abcdef12] Old initial implementation",
            claimedFiles: ["Auth.swift"],
            status: .delivered,
            createdAt: olderDate,
            deliveredAt: olderDate,
            kind: .completion,
            taskId: "abcdef12-0000"
        )

        // Newer completion
        let newerMsg = PendingMessage(
            fromAgent: .cursor,
            toAgent: .claude,
            prompt: "[linkC task abcdef12] New polished implementation with full test suite",
            claimedFiles: ["Auth.swift"],
            status: .delivered,
            createdAt: newerDate,
            deliveredAt: newerDate,
            kind: .completion,
            taskId: "abcdef12-0000"
        )

        // Save messages in reverse order (newer first, older second) to test order independence
        var rawInbox = try inbox.load()
        rawInbox.messages = [newerMsg, olderMsg]
        try inbox.saveRaw(rawInbox)

        let aggregator = AgentDashboardAggregator()
        let data = aggregator.aggregateProject(workspacePath: ws, liveSessions: [])

        let cursorDossier = data.dossiers.first(where: { $0.agent == .cursor })
        XCTAssertNotNil(cursorDossier)
        XCTAssertEqual(cursorDossier?.lastDeliverable, "New polished implementation with full test suite")
        XCTAssertEqual(cursorDossier?.completedTasksCount, 2)
    }

    func testAggregateGlobalDeduplicatesWorkspaces() throws {
        let ws1URL = tempDir.appendingPathComponent("ws1")
        try FileManager.default.createDirectory(at: ws1URL, withIntermediateDirectories: true)
        let ws1 = ws1URL.path

        let inbox1 = InboxStore(workspaceRoot: ws1)
        _ = try inbox1.createTask(from: .claude, to: .codex, prompt: "Refactor router", files: [])

        let aggregator = AgentDashboardAggregator()
        // Pass ws1 three times with trailing slash / standardization differences
        let duplicatedWorkspaces = [ws1, "\(ws1)/", (ws1 as NSString).standardizingPath]
        let globalData = aggregator.aggregateGlobal(workspaces: duplicatedWorkspaces, liveSessions: [])

        XCTAssertEqual(globalData.activeProjectCount, 1)
        XCTAssertEqual(globalData.activityItems.count, 1)
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

        let liveSessions = [(id: "s1", agent: AgentKind.cursor, status: "working", activity: Optional("Writing code"), recentOutput: "")]
        let aggregator = AgentDashboardAggregator()
        let data = aggregator.aggregateProject(workspacePath: ws, liveSessions: liveSessions)

        let cursorDossier = data.dossiers.first(where: { $0.agent == .cursor })
        XCTAssertNotNil(cursorDossier)
        XCTAssertTrue(cursorDossier?.modifiedFiles.contains("Auth.swift") ?? false)
    }

    func testAggregateExtractsLiveSessionScrollbackAndGeneratesLiveActivity() {
        let ws = (tempDir.path as NSString).standardizingPath
        let aggregator = AgentDashboardAggregator()

        let liveSessions = [(
            id: "s-live-1",
            agent: AgentKind.cursor,
            status: "working",
            activity: Optional("Compiling Auth.swift"),
            recentOutput: "Running build step...\nGenerated 12 symbols.\nAll clear."
        )]

        let data = aggregator.aggregateProject(workspacePath: ws, liveSessions: liveSessions)

        // Dossier should fall back lastDeliverable to recentOutput when no inbox message exists
        let cursorDossier = data.dossiers.first(where: { $0.agent == .cursor })
        XCTAssertNotNil(cursorDossier)
        XCTAssertEqual(cursorDossier?.lastDeliverable, "Running build step...\nGenerated 12 symbols.\nAll clear.")
        XCTAssertEqual(cursorDossier?.liveActivity, "Compiling Auth.swift")

        // Timeline should include an activity item for the live active session
        let liveItem = data.activityItems.first(where: { $0.fromAgent == .cursor && $0.title.contains("active in terminal") })
        XCTAssertNotNil(liveItem)
        XCTAssertTrue(liveItem?.body.contains("Generated 12 symbols") ?? false)
    }

    func testTaskItemBodyShowsTheVerdict() throws {
        let ws = (tempDir.path as NSString).standardizingPath
        let inbox = InboxStore(workspaceRoot: ws)
        let base = String(repeating: "b", count: 40)
        let sha = String(repeating: "d", count: 40)
        let verification = Verification(branch: "task/x", baseSha: base, command: "./check.sh", testPaths: ["check.sh"])
        func verdict(_ passed: Bool, _ sha: String, _ exit: Int32, _ reason: String? = nil) -> Verdict {
            Verdict(passed: passed, sha: sha, exitStatus: exit, reason: reason, stdoutTail: "", stderrTail: "")
        }

        let passed = try inbox.createTask(from: .claude, to: .codex, prompt: "Pass", files: [], verification: verification)
        try inbox.resolveGate(taskId: passed.id, verdict: verdict(true, base, 1))
        try inbox.markTaskDelivered(taskId: passed.id, sessionId: "s")
        try inbox.reportTask(taskId: passed.id, report: TaskReport(status: "done", summary: "ok", sha: sha))
        try inbox.adjudicate(taskId: passed.id, verdict: verdict(true, sha, 0))

        let refused = try inbox.createTask(from: .claude, to: .cursor, prompt: "Refused", files: [], verification: verification)
        try inbox.resolveGate(taskId: refused.id, verdict: verdict(false, base, 0, "tests already pass at bbbbbbb; brief refused"))

        let plain = try inbox.createTask(from: .claude, to: .agy, prompt: "Plain", files: [])
        try inbox.markTaskDelivered(taskId: plain.id, sessionId: "s2")
        try inbox.reportTask(taskId: plain.id, report: TaskReport(status: "done", summary: "ok"))
        try inbox.acceptUnverified(taskId: plain.id)

        let open = try inbox.createTask(from: .claude, to: .codex, prompt: "Still open", files: [])

        let data = AgentDashboardAggregator().aggregateProject(workspacePath: ws, liveSessions: [])
        func body(_ t: TaskRecord) -> String? { data.activityItems.first { $0.id == "task-\(t.id)" }?.body }
        XCTAssertEqual(body(passed), "verified at ddddddd")
        XCTAssertEqual(body(refused), "tests already pass at bbbbbbb; brief refused")
        XCTAssertEqual(body(plain), "unverified")
        XCTAssertEqual(body(open), "Still open")
    }
}

import XCTest
@testable import LinkCKit

final class BlackboardStoreTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-blackboard-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    func testEmptyBlackboardInitializesCleanly() throws {
        let store = BlackboardStore(workspaceRoot: tempDir.path)
        let board = try store.load()
        XCTAssertEqual(board.version, 1)
        XCTAssertEqual(board.projectPath, tempDir.path)
        XCTAssertTrue(board.activeAgents.isEmpty)
        XCTAssertTrue(board.sharedNotes.isEmpty)
    }

    func testBroadcastIntentAndConflictDetection() throws {
        let store = BlackboardStore(workspaceRoot: tempDir.path)

        // Agent 1 (Claude, PID 101) claims A.swift
        let conflicts1 = try store.broadcastIntent(
            agentKind: .claude,
            pid: 101,
            goal: "Refactor A",
            files: ["Sources/A.swift"],
            status: "working"
        )
        XCTAssertTrue(conflicts1.isEmpty, "First agent should have 0 conflicts")

        // Agent 2 (Cursor, PID 102) claims A.swift and B.swift
        let conflicts2 = try store.broadcastIntent(
            agentKind: .cursor,
            pid: 102,
            goal: "Improve UI in A and B",
            files: ["Sources/A.swift", "Sources/B.swift"],
            status: "working"
        )
        XCTAssertEqual(conflicts2.count, 1)
        XCTAssertEqual(conflicts2.first?.conflictingAgent, .claude)
        XCTAssertEqual(conflicts2.first?.pid, 101)
        XCTAssertEqual(conflicts2.first?.conflictingFiles, ["Sources/A.swift"])

        // Agent 1 updates its own claim with no self-conflict
        let conflicts1Update = try store.broadcastIntent(
            agentKind: .claude,
            pid: 101,
            goal: "Refactor A finished",
            files: ["Sources/A.swift"],
            status: "done"
        )
        // Note: Agent 2 is also claiming A.swift now, so Agent 1 will be alerted about Agent 2
        XCTAssertEqual(conflicts1Update.count, 1)
        XCTAssertEqual(conflicts1Update.first?.pid, 102)
    }

    func testCheckConflictsLightweightQuery() throws {
        let store = BlackboardStore(workspaceRoot: tempDir.path)

        _ = try store.broadcastIntent(
            agentKind: .agy,
            pid: 201,
            goal: "Database indexing",
            files: ["Sources/DB.swift"],
            status: "working"
        )

        // Querying DB.swift from different PID flags conflict
        let conflictsForeign = try store.checkConflicts(files: ["Sources/DB.swift"], excludingPid: 999)
        XCTAssertEqual(conflictsForeign.count, 1)
        XCTAssertEqual(conflictsForeign.first?.conflictingAgent, .agy)

        // Querying DB.swift from own PID flags no conflict
        let conflictsOwn = try store.checkConflicts(files: ["Sources/DB.swift"], excludingPid: 201)
        XCTAssertTrue(conflictsOwn.isEmpty)

        // Querying unreserved file flags no conflict
        let conflictsClean = try store.checkConflicts(files: ["Sources/Clean.swift"], excludingPid: 999)
        XCTAssertTrue(conflictsClean.isEmpty)
    }

    func testSharedNotesPostAndRetrieve() throws {
        let store = BlackboardStore(workspaceRoot: tempDir.path)

        let note = try store.postNote(
            authorAgent: .codex,
            title: "API contract update",
            content: "Changed endpoint to /v2/auth",
            tags: ["auth", "api"]
        )

        XCTAssertEqual(note.title, "API contract update")
        XCTAssertEqual(note.authorAgent, .codex)
        XCTAssertEqual(note.tags, ["auth", "api"])

        let board = try store.getProjectContext()
        XCTAssertEqual(board.sharedNotes.count, 1)
        XCTAssertEqual(board.sharedNotes.first?.id, note.id)
    }

    func testStaleHeartbeatPruning() throws {
        let store = BlackboardStore(workspaceRoot: tempDir.path)

        _ = try store.broadcastIntent(
            agentKind: .claude,
            pid: 301,
            goal: "Old task",
            files: ["Sources/Old.swift"],
            status: "working"
        )

        // Artificially age the agent's heartbeat
        var board = try store.load()
        board.activeAgents[0].lastHeartbeat = Date().addingTimeInterval(-3600) // 1 hour ago
        try store.saveRaw(board)

        // Prune older than 15 minutes (900 seconds)
        try store.pruneStale(olderThan: 900)

        let updated = try store.load()
        XCTAssertTrue(updated.activeAgents.isEmpty, "Stale agent should be pruned")
    }

    func testHeartbeatInsertsIdleRecordAndRefreshesWithoutOverwritingGoal() throws {
        let store = BlackboardStore(workspaceRoot: tempDir.path)
        try store.heartbeat(agentKind: .cursor, pid: 4242)
        var board = try store.load()
        let inserted = try XCTUnwrap(board.activeAgents.first { $0.pid == 4242 })
        XCTAssertEqual(inserted.agentKind, .cursor)
        XCTAssertEqual(inserted.goal, "(idle)")
        XCTAssertEqual(inserted.status, "active")
        XCTAssertTrue(inserted.claimedFiles.isEmpty)

        _ = try store.broadcastIntent(agentKind: .cursor, pid: 4242, goal: "Real goal", files: ["A.swift"])
        let before = try XCTUnwrap(try store.load().activeAgents.first { $0.pid == 4242 }).lastHeartbeat
        try store.heartbeat(agentKind: .cursor, pid: 4242)
        board = try store.load()
        let refreshed = try XCTUnwrap(board.activeAgents.first { $0.pid == 4242 })
        XCTAssertEqual(refreshed.goal, "Real goal")
        XCTAssertEqual(refreshed.claimedFiles, ["A.swift"])
        XCTAssertGreaterThanOrEqual(refreshed.lastHeartbeat, before)
        XCTAssertEqual(board.activeAgents.filter { $0.pid == 4242 }.count, 1)
    }

    /// Presence only has to outlive the 15-minute prune. Rewriting the board on every heartbeat —
    /// once a second per agent, plus once per MCP call — showed every agent that had read the file a
    /// diff on each edit. The record is seeded 10 s old so a rewrite could never produce identical
    /// bytes by landing in the same second.
    func testAFreshHeartbeatDoesNotRewriteTheBoard() throws {
        let store = BlackboardStore(workspaceRoot: tempDir.path)
        try store.heartbeat(agentKind: .cursor, pid: 4242)
        var board = try store.load()
        board.activeAgents[0].lastHeartbeat = Date().addingTimeInterval(-10)
        try store.saveRaw(board)
        let file = tempDir.appendingPathComponent(".linkc/blackboard.json")
        let before = try Data(contentsOf: file)

        try store.heartbeat(agentKind: .cursor, pid: 4242)

        XCTAssertEqual(try Data(contentsOf: file), before, "a heartbeat within the refresh interval must not rewrite the file")
    }

    func testAHeartbeatOlderThanTheRefreshIntervalIsRefreshed() throws {
        let store = BlackboardStore(workspaceRoot: tempDir.path)
        try store.heartbeat(agentKind: .cursor, pid: 4242)
        var board = try store.load()
        let aged = Date().addingTimeInterval(-6 * 60)
        board.activeAgents[0].lastHeartbeat = aged
        try store.saveRaw(board)

        try store.heartbeat(agentKind: .cursor, pid: 4242)

        let refreshed = try XCTUnwrap(try store.load().activeAgents.first { $0.pid == 4242 })
        XCTAssertGreaterThan(refreshed.lastHeartbeat, aged.addingTimeInterval(60))
    }

    func testAStaleAgentIsStillPrunedWhenTheCallerIsFresh() throws {
        let store = BlackboardStore(workspaceRoot: tempDir.path)
        try store.heartbeat(agentKind: .cursor, pid: 4242)
        var board = try store.load()
        board.activeAgents.append(AgentRecord(
            agentId: "agent-codex-99", agentKind: .codex, pid: 99, goal: "(idle)",
            claimedFiles: [], lastHeartbeat: Date().addingTimeInterval(-3600), status: "active"
        ))
        try store.saveRaw(board)

        try store.heartbeat(agentKind: .cursor, pid: 4242)

        XCTAssertEqual(try store.load().activeAgents.map(\.pid), [4242], "pruning still happens when nothing else changed")
    }

    /// A crash between the temp write and its rename leaves `.linkc/blackboard.tmp.<uuid>`
    /// behind forever unless something sweeps it. Every successful save does, but only for a
    /// sibling old enough to actually be orphaned — a temp file mid-write by a concurrent
    /// process must survive.
    func testSaveSweepsAStaleTempFileButKeepsAFreshOne() throws {
        let store = BlackboardStore(workspaceRoot: tempDir.path)
        try store.heartbeat(agentKind: .cursor, pid: 1) // prime the .linkc directory

        let linkcDir = tempDir.appendingPathComponent(".linkc")
        let stale = linkcDir.appendingPathComponent("blackboard.tmp.\(UUID().uuidString)")
        let fresh = linkcDir.appendingPathComponent("blackboard.tmp.\(UUID().uuidString)")
        try Data("stale".utf8).write(to: stale)
        try Data("fresh".utf8).write(to: fresh)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3700)], // just past the 1h cutoff
            ofItemAtPath: stale.path
        )

        try store.heartbeat(agentKind: .cursor, pid: 2) // trigger another save

        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path), "a temp file crash-orphaned over an hour ago must be swept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path), "a fresh temp file must survive the sweep")
    }
}

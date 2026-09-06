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
}

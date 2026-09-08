import XCTest
import Darwin
@testable import LinkCKit

final class BlackboardStoreStressTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-blackboard-stress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    /// 1. Verifies that concurrent threads hammering the blackboard simultaneously
    /// never produce corrupted JSON, deadlocks, or lost agent registrations.
    func testConcurrentWritersNoCorruptedData() throws {
        let store = BlackboardStore(workspaceRoot: tempDir.path)
        let threadCount = 8
        let iterationsPerThread = 15

        let agents: [AgentKind] = [.claude, .agy, .cursor, .codex]
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "linkc.stress.queue", attributes: .concurrent)

        final class SafeErrorCollector: @unchecked Sendable {
            private let lock = NSLock()
            private var errors: [String] = []
            func record(_ error: String) {
                lock.lock()
                defer { lock.unlock() }
                errors.append(error)
            }
            var all: [String] {
                lock.lock()
                defer { lock.unlock() }
                return errors
            }
        }
        let failureErrors = SafeErrorCollector()

        for t in 0..<threadCount {
            group.enter()
            queue.async {
                let agentKind = agents[t % agents.count]
                let pid = pid_t(1000 + t)

                for iter in 0..<iterationsPerThread {
                    do {
                        let goal = "Task \(iter) by thread \(t)"
                        let files = ["Sources/Feature_\(t).swift", "Sources/Shared.swift"]
                        _ = try store.broadcastIntent(
                            agentKind: agentKind,
                            pid: pid,
                            goal: goal,
                            files: files,
                            status: iter == iterationsPerThread - 1 ? "idle" : "working",
                            timeout: 10.0
                        )

                        if iter % 5 == 0 {
                            _ = try store.postNote(
                                authorAgent: agentKind,
                                title: "Note \(iter) from thread \(t)",
                                content: "Everything green on iteration \(iter)",
                                timeout: 10.0
                            )
                        }

                        _ = try store.checkConflicts(files: ["Sources/Shared.swift"], timeout: 10.0)
                    } catch {
                        failureErrors.record("Thread \(t) iter \(iter) failed: \(error)")
                    }
                }
                group.leave()
            }
        }

        let waitResult = group.wait(timeout: .now() + 20.0)
        XCTAssertEqual(waitResult, .success, "Concurrent operations must complete within 20s without deadlock")
        XCTAssertTrue(failureErrors.all.isEmpty, "No errors should occur during concurrent writes: \(failureErrors.all)")

        // Verify final state integrity
        let finalBoard = try store.getProjectContext(timeout: 5.0)
        XCTAssertEqual(finalBoard.activeAgents.count, threadCount)
        XCTAssertFalse(finalBoard.sharedNotes.isEmpty)
        XCTAssertFalse(finalBoard.recentEvents.isEmpty)
        XCTAssertLessThanOrEqual(finalBoard.recentEvents.count, 50, "Events must respect 50-item cap")
    }

    /// 2. Verifies that when another process holds an exclusive flock, linkC times out gracefully
    /// instead of freezing the UI thread, and resumes normal operation once the lock is released.
    func testLockTimeoutWhenForeignProcessHoldsLock() throws {
        let store = BlackboardStore(workspaceRoot: tempDir.path)

        let lockDir = tempDir.appendingPathComponent(".linkc", isDirectory: true)
        try FileManager.default.createDirectory(at: lockDir, withIntermediateDirectories: true)
        let lockFilePath = lockDir.appendingPathComponent(".blackboard.lock").path

        // Simulate a foreign process holding an exclusive lock
        let foreignFd = open(lockFilePath, O_CREAT | O_RDWR, 0o600)
        XCTAssertGreaterThanOrEqual(foreignFd, 0)
        let lockAcquired = flock(foreignFd, LOCK_EX) == 0
        XCTAssertTrue(lockAcquired, "Foreign process should acquire the lock")

        // Attempting to read or write with a short timeout should throw a timeout error
        let start = Date()
        XCTAssertThrowsError(try store.load(timeout: 0.15)) { error in
            guard let linkcErr = error as? LinkCError else {
                XCTFail("Expected LinkCError, got \(error)")
                return
            }
            XCTAssertTrue(linkcErr.errorDescription?.contains("Timed out acquiring blackboard lock") ?? false)
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThanOrEqual(elapsed, 0.10, "Should wait approximately the specified timeout")
        XCTAssertLessThan(elapsed, 1.0, "Should not hang indefinitely")

        // Release the foreign lock
        flock(foreignFd, LOCK_UN)
        close(foreignFd)

        // Store should now acquire the lock immediately without error
        let board = try store.load(timeout: 1.0)
        XCTAssertEqual(board.projectPath, tempDir.path)
    }

    /// 3. Verifies that a corrupted or truncated blackboard.json on disk does not crash
    /// the store or cause unhandled exceptions; it resets safely to a fresh blackboard.
    func testCorruptedJSONRecovery() throws {
        let store = BlackboardStore(workspaceRoot: tempDir.path)

        // Seed an initial valid state
        _ = try store.broadcastIntent(
            agentKind: .claude,
            pid: 501,
            goal: "Initial setup",
            files: ["Sources/Main.swift"]
        )

        let blackboardPath = tempDir.appendingPathComponent(".linkc/blackboard.json").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: blackboardPath))

        // Deliberately corrupt the file with truncated invalid JSON bytes
        let garbage = "{\"version\": 1, \"activeAgents\": [{\"incomplete\": tr".data(using: .utf8)!
        try garbage.write(to: URL(fileURLWithPath: blackboardPath))

        // Store should gracefully recover to an empty blackboard rather than crashing
        let recovered = try store.load()
        XCTAssertEqual(recovered.projectPath, tempDir.path)
        XCTAssertTrue(recovered.activeAgents.isEmpty)

        // Subsequent writes should succeed cleanly and repair the file
        let warnings = try store.broadcastIntent(
            agentKind: .cursor,
            pid: 502,
            goal: "After recovery",
            files: ["Sources/New.swift"]
        )
        XCTAssertTrue(warnings.isEmpty)

        let refreshed = try store.load()
        XCTAssertEqual(refreshed.activeAgents.count, 1)
        XCTAssertEqual(refreshed.activeAgents.first?.goal, "After recovery")
    }

    /// 4. Verifies multiple independent store instances in the same process pointing to the same
    /// workspace maintain mutual exclusion across instances.
    func testMultipleStoreInstancesMutualExclusion() throws {
        let store1 = BlackboardStore(workspaceRoot: tempDir.path)
        let store2 = BlackboardStore(workspaceRoot: tempDir.path)

        _ = try store1.broadcastIntent(
            agentKind: .agy,
            pid: 601,
            goal: "Task from store1",
            files: ["Sources/SharedA.swift"]
        )

        let conflicts = try store2.checkConflicts(files: ["Sources/SharedA.swift"], excludingPid: 999)
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts.first?.conflictingAgent, .agy)

        let note = try store2.postNote(authorAgent: .codex, title: "Store2 note", content: "Hi")
        let board1 = try store1.load()
        XCTAssertEqual(board1.sharedNotes.first?.id, note.id)
    }
}

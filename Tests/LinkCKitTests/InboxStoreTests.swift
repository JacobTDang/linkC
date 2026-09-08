import XCTest
import Darwin
@testable import LinkCKit

final class InboxStoreTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-inbox-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    func testEmptyInboxInitializesCleanly() throws {
        let store = InboxStore(workspaceRoot: tempDir.path)
        let inbox = try store.load()
        XCTAssertEqual(inbox.version, 1)
        XCTAssertEqual(inbox.workspacePath, tempDir.path)
        XCTAssertTrue(inbox.messages.isEmpty)
        XCTAssertTrue(inbox.agentLimits.isEmpty)
    }

    func testEnqueueAddsMessageWithQueuedStatus() throws {
        let store = InboxStore(workspaceRoot: tempDir.path)
        let msg = try store.enqueue(
            from: .claude,
            to: .codex,
            prompt: "Implement ShellTerminalStore tests",
            files: ["Tests/LinkCKitTests/ShellTerminalStoreTests.swift"]
        )

        XCTAssertFalse(msg.id.isEmpty)
        XCTAssertEqual(msg.fromAgent, .claude)
        XCTAssertEqual(msg.toAgent, .codex)
        XCTAssertEqual(msg.prompt, "Implement ShellTerminalStore tests")
        XCTAssertEqual(msg.claimedFiles, ["Tests/LinkCKitTests/ShellTerminalStoreTests.swift"])
        XCTAssertEqual(msg.status, .queued)
        XCTAssertEqual(msg.rerouteCount, 0)
        XCTAssertNil(msg.deliveredAt)

        let inbox = try store.load()
        XCTAssertEqual(inbox.messages.count, 1)
        XCTAssertEqual(inbox.messages.first?.id, msg.id)
        XCTAssertEqual(inbox.messages.first?.status, .queued)
    }

    func testFetchPendingReturnsQueuedMessagesInFIFOOrder() throws {
        let store = InboxStore(workspaceRoot: tempDir.path)
        let msg1 = try store.enqueue(from: .claude, to: .codex, prompt: "Task 1", files: [])
        let msg2 = try store.enqueue(from: .cursor, to: .agy, prompt: "Task 2", files: [])
        let msg3 = try store.enqueue(from: .agy, to: .claude, prompt: "Task 3", files: [])

        let pending = try store.fetchPending()
        XCTAssertEqual(pending.count, 3)
        XCTAssertEqual(pending.map(\.id), [msg1.id, msg2.id, msg3.id])
    }

    func testMarkDeliveredTransitionsStatusAndStampsDeliveredAt() throws {
        let store = InboxStore(workspaceRoot: tempDir.path)
        let msg1 = try store.enqueue(from: .claude, to: .codex, prompt: "Task 1", files: [])
        let msg2 = try store.enqueue(from: .cursor, to: .agy, prompt: "Task 2", files: [])

        try store.markDelivered(id: msg1.id)

        let inbox = try store.load()
        let deliveredMsg = inbox.messages.first(where: { $0.id == msg1.id })
        XCTAssertNotNil(deliveredMsg)
        XCTAssertEqual(deliveredMsg?.status, .delivered)
        XCTAssertNotNil(deliveredMsg?.deliveredAt)

        let pending = try store.fetchPending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.id, msg2.id)

        // Non-existent ID throws
        XCTAssertThrowsError(try store.markDelivered(id: "non-existent-id"))
    }

    func testRecordLimitAndIsAgentLimitedWithCooldownExpiration() throws {
        let store = InboxStore(workspaceRoot: tempDir.path)

        // Initially not limited
        XCTAssertNil(try store.isAgentLimited(agent: .codex))

        // Record limit with 60s cooldown
        try store.recordLimit(agent: .codex, reason: "429 Too Many Requests", cooldown: 60)

        let activeLimit = try store.isAgentLimited(agent: .codex)
        XCTAssertNotNil(activeLimit)
        XCTAssertEqual(activeLimit?.agent, .codex)
        XCTAssertEqual(activeLimit?.reason, "429 Too Many Requests")
        XCTAssertTrue((activeLimit?.cooldownExpiresAt ?? Date()) > Date())

        // Other agent is not limited
        XCTAssertNil(try store.isAgentLimited(agent: .claude))

        // Record expired limit by saving inbox with past cooldown
        var inbox = try store.load()
        if let idx = inbox.agentLimits.firstIndex(where: { $0.agent == .codex }) {
            inbox.agentLimits[idx] = AgentLimitStatus(
                agent: .codex,
                reason: "429 Too Many Requests",
                limitedAt: Date().addingTimeInterval(-120),
                cooldownExpiresAt: Date().addingTimeInterval(-10) // Expired 10s ago
            )
        }
        try store.saveRaw(inbox)

        // Now should report nil because cooldown expired
        XCTAssertNil(try store.isAgentLimited(agent: .codex))
    }

    func testCorruptFileFallbackInitializesCleanInbox() throws {
        let store = InboxStore(workspaceRoot: tempDir.path)
        let inboxURL = tempDir.appendingPathComponent(".linkc/inbox.json")
        try FileManager.default.createDirectory(at: inboxURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "invalid json content".data(using: .utf8)!.write(to: inboxURL)

        let inbox = try store.load()
        XCTAssertEqual(inbox.version, 1)
        XCTAssertTrue(inbox.messages.isEmpty)
    }

    func testConcurrentFlockPreventsCorruption() throws {
        let store = InboxStore(workspaceRoot: tempDir.path)
        let writeCount = 30
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "test.concurrent.inbox", attributes: .concurrent)

        for i in 0..<writeCount {
            group.enter()
            queue.async {
                do {
                    _ = try store.enqueue(
                        from: .claude,
                        to: .codex,
                        prompt: "Concurrent prompt \(i)",
                        files: ["File\(i).swift"]
                    )
                } catch {
                    XCTFail("Concurrent write \(i) failed: \(error)")
                }
                group.leave()
            }
        }

        let result = group.wait(timeout: .now() + 10)
        XCTAssertEqual(result, .success, "Concurrent writes did not complete in time")

        let inbox = try store.load()
        XCTAssertEqual(inbox.messages.count, writeCount, "All concurrent writes must be preserved without corruption")
    }
}

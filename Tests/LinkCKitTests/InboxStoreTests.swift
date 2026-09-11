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
        XCTAssertEqual(inbox.version, 2)
        XCTAssertEqual(inbox.workspacePath, tempDir.path)
        XCTAssertTrue(inbox.messages.isEmpty)
        XCTAssertTrue(inbox.agentLimits.isEmpty)
        XCTAssertTrue(inbox.tasks.isEmpty)
    }

    func testEnqueueAddsMessageWithQueuedStatus() throws {
        let store = InboxStore(workspaceRoot: tempDir.path)
        let msg = try store.enqueue(
            from: .claude,
            to: .codex,
            kind: .peerNote,
            body: "Implement ShellTerminalStore tests"
        )

        XCTAssertFalse(msg.id.isEmpty)
        XCTAssertEqual(msg.fromAgent, .claude)
        XCTAssertEqual(msg.toAgent, .codex)
        XCTAssertEqual(msg.kind, .peerNote)
        XCTAssertEqual(msg.prompt, "[Peer Note from Claude Code]: Implement ShellTerminalStore tests")
        XCTAssertTrue(msg.claimedFiles.isEmpty)
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
        let msg1 = try store.enqueue(from: .claude, to: .codex, kind: .peerNote, body: "Task 1")
        let msg2 = try store.enqueue(from: .cursor, to: .agy, kind: .peerNote, body: "Task 2")
        let msg3 = try store.enqueue(from: .agy, to: .claude, kind: .peerNote, body: "Task 3")

        let pending = try store.fetchPending()
        XCTAssertEqual(pending.count, 3)
        XCTAssertEqual(pending.map(\.id), [msg1.id, msg2.id, msg3.id])
    }

    func testMarkDeliveredTransitionsStatusAndStampsDeliveredAt() throws {
        let store = InboxStore(workspaceRoot: tempDir.path)
        let msg1 = try store.enqueue(from: .claude, to: .codex, kind: .peerNote, body: "Task 1")
        let msg2 = try store.enqueue(from: .cursor, to: .agy, kind: .peerNote, body: "Task 2")

        try store.markMessageDelivered(id: msg1.id)

        let inbox = try store.load()
        let deliveredMsg = inbox.messages.first(where: { $0.id == msg1.id })
        XCTAssertNotNil(deliveredMsg)
        XCTAssertEqual(deliveredMsg?.status, .delivered)
        XCTAssertNotNil(deliveredMsg?.deliveredAt)

        let pending = try store.fetchPending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.id, msg2.id)

        // Non-existent ID throws
        XCTAssertThrowsError(try store.markMessageDelivered(id: "non-existent-id"))
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
        XCTAssertEqual(inbox.version, 2)
        XCTAssertTrue(inbox.messages.isEmpty)
    }

    func testDecodesV1InboxWithInferredKindsAndEmptyTasks() throws {
        let v1 = """
        {
          "version": 1,
          "workspacePath": "\(tempDir.path)",
          "updatedAt": "2026-09-09T10:00:00Z",
          "agentLimits": [],
          "messages": [
            {"id": "a", "fromAgent": "claude", "toAgent": "codex", "prompt": "Build it", "claimedFiles": [], "status": "queued", "rerouteCount": 0, "createdAt": "2026-09-09T10:00:00Z"},
            {"id": "b", "fromAgent": "codex", "toAgent": "claude", "prompt": "[Task Completed by Codex]\\nOriginal Task: x", "claimedFiles": [], "status": "delivered", "rerouteCount": 0, "createdAt": "2026-09-09T10:00:00Z", "deliveredAt": "2026-09-09T10:01:00Z"},
            {"id": "c", "fromAgent": "codex", "toAgent": "claude", "prompt": "[System Notice] limit", "claimedFiles": [], "status": "queued", "rerouteCount": 0, "createdAt": "2026-09-09T10:00:00Z"},
            {"id": "d", "fromAgent": "cursor", "toAgent": "agy", "prompt": "[Peer Note from Cursor Agent]: hi", "claimedFiles": [], "status": "queued", "rerouteCount": 0, "createdAt": "2026-09-09T10:00:00Z"}
          ]
        }
        """
        let inboxURL = tempDir.appendingPathComponent(".linkc/inbox.json")
        try FileManager.default.createDirectory(at: inboxURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try v1.data(using: .utf8)!.write(to: inboxURL)

        let store = InboxStore(workspaceRoot: tempDir.path)
        let inbox = try store.load()
        XCTAssertTrue(inbox.tasks.isEmpty)
        let byId = Dictionary(uniqueKeysWithValues: inbox.messages.map { ($0.id, $0) })
        XCTAssertEqual(byId["a"]?.kind, .task)
        XCTAssertEqual(byId["b"]?.kind, .completion)
        XCTAssertEqual(byId["c"]?.kind, .notice)
        XCTAssertEqual(byId["d"]?.kind, .peerNote)
        XCTAssertNil(byId["a"]?.taskId)
        XCTAssertEqual(byId["a"]?.contentHash, LinkCFrame.contentHash(from: .claude, to: .codex, kind: .task, prompt: "Build it"))
    }

    func testTaskStateTransitionTable() {
        XCTAssertTrue(TaskState.queued.canTransition(to: .delivered))
        XCTAssertTrue(TaskState.queued.canTransition(to: .cancelled))
        XCTAssertTrue(TaskState.queued.canTransition(to: .expired))
        XCTAssertFalse(TaskState.queued.canTransition(to: .started))
        XCTAssertTrue(TaskState.delivered.canTransition(to: .started))
        XCTAssertTrue(TaskState.delivered.canTransition(to: .done))
        XCTAssertTrue(TaskState.delivered.canTransition(to: .failed))
        XCTAssertTrue(TaskState.started.canTransition(to: .done))
        XCTAssertFalse(TaskState.started.canTransition(to: .delivered))
        for terminal in [TaskState.done, .failed, .cancelled, .expired] {
            for next in [TaskState.queued, .delivered, .started, .done, .failed, .cancelled, .expired] {
                XCTAssertFalse(terminal.canTransition(to: next), "\(terminal) -> \(next) must be illegal")
            }
            XCTAssertFalse(terminal.isOpen)
        }
        XCTAssertTrue(TaskState.queued.isOpen && TaskState.delivered.isOpen && TaskState.started.isOpen)
    }

    func testFrameMarkerDetection() {
        XCTAssertTrue(LinkCFrame.beginsWithMarker("[linkC task 1234abcd] done"))
        XCTAssertTrue(LinkCFrame.beginsWithMarker("  [linkC notice] x"))
        XCTAssertTrue(LinkCFrame.beginsWithMarker("[Peer Note from Codex]: hi"))
        XCTAssertTrue(LinkCFrame.beginsWithMarker("[Task Completed by Codex]"))
        XCTAssertTrue(LinkCFrame.beginsWithMarker("[System Notice] limit"))
        XCTAssertFalse(LinkCFrame.beginsWithMarker("Implement the [linkC task] parser"))
        XCTAssertFalse(LinkCFrame.beginsWithMarker("plain brief"))
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
                        kind: .peerNote,
                        body: "Concurrent prompt \(i)"
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

    func testPrunesDeliveredMessagesOlderThan24Hours() throws {
        let store = InboxStore(workspaceRoot: tempDir.path)

        // Seed 1 delivered message from 25 hours ago, 1 delivered message from 1 hour ago, and 1 queued message from 30 hours ago
        let oldDelivered = PendingMessage(
            id: "old-delivered",
            fromAgent: .claude,
            toAgent: .codex,
            prompt: "Old task",
            claimedFiles: [],
            status: .delivered,
            rerouteCount: 0,
            createdAt: Date().addingTimeInterval(-26 * 3600),
            deliveredAt: Date().addingTimeInterval(-25 * 3600)
        )
        let recentDelivered = PendingMessage(
            id: "recent-delivered",
            fromAgent: .claude,
            toAgent: .codex,
            prompt: "Recent task",
            claimedFiles: [],
            status: .delivered,
            rerouteCount: 0,
            createdAt: Date().addingTimeInterval(-2 * 3600),
            deliveredAt: Date().addingTimeInterval(-1 * 3600)
        )
        let oldQueued = PendingMessage(
            id: "old-queued",
            fromAgent: .cursor,
            toAgent: .agy,
            prompt: "Queued task",
            claimedFiles: [],
            status: .queued,
            rerouteCount: 0,
            createdAt: Date().addingTimeInterval(-30 * 3600),
            deliveredAt: nil
        )

        var inbox = Inbox(workspacePath: tempDir.path)
        inbox.messages = [oldDelivered, recentDelivered, oldQueued]
        try store.saveRaw(inbox)

        let loaded = try store.load()
        XCTAssertEqual(loaded.messages.count, 2)
        XCTAssertFalse(loaded.messages.contains(where: { $0.id == "old-delivered" }))
        XCTAssertTrue(loaded.messages.contains(where: { $0.id == "recent-delivered" }))
        XCTAssertTrue(loaded.messages.contains(where: { $0.id == "old-queued" }))
    }

    func testLimitsMessagesTo100OnSave() throws {
        let store = InboxStore(workspaceRoot: tempDir.path)

        var messages: [PendingMessage] = []
        for i in 0..<120 {
            messages.append(PendingMessage(
                id: "msg-\(i)",
                fromAgent: .claude,
                toAgent: .codex,
                prompt: "Task \(i)",
                claimedFiles: [],
                status: .queued,
                rerouteCount: 0,
                createdAt: Date().addingTimeInterval(Double(i)),
                deliveredAt: nil
            ))
        }

        var inbox = Inbox(workspacePath: tempDir.path)
        inbox.messages = messages
        try store.saveRaw(inbox)

        let loaded = try store.load()
        XCTAssertEqual(loaded.messages.count, 100)
        // Kept the last 100 (msg-20 through msg-119)
        XCTAssertEqual(loaded.messages.first?.id, "msg-20")
        XCTAssertEqual(loaded.messages.last?.id, "msg-119")
    }

    func testKindAwareEnqueueComposesFrames() throws {
        let store = InboxStore(workspaceRoot: tempDir.path)
        let completion = try store.enqueue(from: .codex, to: .claude, kind: .completion, taskId: "abcdef12-3456", body: "done by Codex — shipped")
        XCTAssertEqual(completion.prompt, "[linkC task abcdef12] done by Codex — shipped")
        XCTAssertEqual(completion.kind, .completion)
        XCTAssertEqual(completion.taskId, "abcdef12-3456")

        let note = try store.enqueue(from: .cursor, to: .agy, kind: .peerNote, body: "heads up")
        XCTAssertEqual(note.prompt, "[Peer Note from Cursor Agent]: heads up")

        let notice = try store.enqueue(from: .codex, to: .claude, kind: .notice, body: "Codex is rate limited")
        XCTAssertEqual(notice.prompt, "[linkC notice] Codex is rate limited")

        let cmd = try store.enqueue(from: .claude, to: .claude, kind: .command, body: "/model sonnet")
        XCTAssertEqual(cmd.prompt, "/model sonnet")
    }

    func testEnqueueRejectsFramedBodiesTaskKindAndMissingTaskId() throws {
        let store = InboxStore(workspaceRoot: tempDir.path)
        XCTAssertThrowsError(try store.enqueue(from: .codex, to: .claude, kind: .peerNote, body: "[linkC task 1234abcd] echo")) {
            XCTAssertEqual($0 as? InboxError, .framedBody)
        }
        XCTAssertThrowsError(try store.enqueue(from: .codex, to: .claude, kind: .peerNote, body: "[Task Completed by Codex]\nOriginal Task: x")) {
            XCTAssertEqual($0 as? InboxError, .framedBody)
        }
        XCTAssertThrowsError(try store.enqueue(from: .codex, to: .claude, kind: .task, body: "brief")) {
            XCTAssertEqual($0 as? InboxError, .kindNotAllowed(.task))
        }
        XCTAssertThrowsError(try store.enqueue(from: .codex, to: .claude, kind: .completion, body: "done")) {
            XCTAssertEqual($0 as? InboxError, .missingTaskId)
        }
        XCTAssertTrue(try store.load().messages.isEmpty)
    }

    func testEnqueueDedupesIdenticalContentWithin24h() throws {
        let store = InboxStore(workspaceRoot: tempDir.path)
        let a = try store.enqueue(from: .codex, to: .claude, kind: .peerNote, body: "same")
        let b = try store.enqueue(from: .codex, to: .claude, kind: .peerNote, body: "same")
        XCTAssertEqual(a.id, b.id)
        XCTAssertEqual(try store.load().messages.count, 1)
        // Different recipient is not a duplicate
        _ = try store.enqueue(from: .codex, to: .cursor, kind: .peerNote, body: "same")
        XCTAssertEqual(try store.load().messages.count, 2)
    }
}

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

    /// The relay re-detects an unhandled limit from the same terminal output on every tick, so
    /// `recordLimit` is called far more than once per real limit. Overwriting a still-live
    /// cooldown's expiry on every re-record would push it out by another full cooldown window
    /// each time — the agent would never actually clear. No sleep needed: two back-to-back
    /// calls already land at measurably different wall-clock times (recordLimit itself does a
    /// disk write in between), so an overwrite is caught by exact equality without waiting.
    func testRecordLimitKeepsALiveCooldownsEarlierExpiryInsteadOfPushingItOut() throws {
        let store = InboxStore(workspaceRoot: tempDir.path)

        // Seed a live cooldown whose expiry sits ~60s out — far from where an unconditional
        // overwrite would move it, so no whole-second rounding of the stored ISO8601 timestamp
        // can hide the difference.
        var inbox = try store.load()
        let seededExpiry = Date().addingTimeInterval(60)
        inbox.agentLimits.append(AgentLimitStatus(
            agent: .claude,
            reason: "Rate limit reached",
            limitedAt: Date(),
            cooldownExpiresAt: seededExpiry
        ))
        try store.saveRaw(inbox)

        // Re-recording the same still-live limit with the full cooldown, as a relay tick that
        // keeps re-detecting the same banner would, must not push the expiry out. Unconditional
        // overwrite would jump this to roughly now + 900s — about 840s later than seeded.
        try store.recordLimit(agent: .claude, reason: "Rate limit reached", cooldown: 900)
        let after = try XCTUnwrap(try store.isAgentLimited(agent: .claude)?.cooldownExpiresAt)

        XCTAssertEqual(
            after.timeIntervalSince1970, seededExpiry.timeIntervalSince1970, accuracy: 1.0,
            "a live cooldown must keep its expiry, not be pushed out by a re-record"
        )
    }

    /// An expired cooldown, unlike a live one, may still be replaced — recordLimit must not get
    /// stuck refusing forever once the earlier limit has actually cleared.
    func testRecordLimitReplacesAnExpiredCooldown() throws {
        let store = InboxStore(workspaceRoot: tempDir.path)
        var inbox = try store.load()
        inbox.agentLimits.append(AgentLimitStatus(
            agent: .claude,
            reason: "Rate limit reached",
            limitedAt: Date().addingTimeInterval(-1000),
            cooldownExpiresAt: Date().addingTimeInterval(-10) // already expired
        ))
        try store.saveRaw(inbox)

        try store.recordLimit(agent: .claude, reason: "Rate limit reached", cooldown: 900)

        let status = try XCTUnwrap(try store.isAgentLimited(agent: .claude))
        XCTAssertTrue(status.cooldownExpiresAt > Date().addingTimeInterval(800), "an expired cooldown may be replaced with a fresh one")
    }

    /// A crash between the temp write and its rename leaves `.linkc/inbox.tmp.<uuid>` behind
    /// forever unless something sweeps it. Every successful save does, but only for a sibling
    /// old enough to actually be orphaned — a temp file mid-write by a concurrent process must
    /// survive.
    func testSaveSweepsAStaleTempFileButKeepsAFreshOne() throws {
        let store = InboxStore(workspaceRoot: tempDir.path)
        _ = try store.enqueue(from: .claude, to: .codex, kind: .peerNote, body: "prime the .linkc directory")

        let linkcDir = tempDir.appendingPathComponent(".linkc")
        let stale = linkcDir.appendingPathComponent("inbox.tmp.\(UUID().uuidString)")
        let fresh = linkcDir.appendingPathComponent("inbox.tmp.\(UUID().uuidString)")
        try Data("stale".utf8).write(to: stale)
        try Data("fresh".utf8).write(to: fresh)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3700)], // just past the 1h cutoff
            ofItemAtPath: stale.path
        )

        // Any successful save sweeps stale temp siblings.
        _ = try store.enqueue(from: .claude, to: .codex, kind: .peerNote, body: "trigger another save")

        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path), "a temp file crash-orphaned over an hour ago must be swept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path), "a fresh temp file must survive the sweep")
    }

    // MARK: - An inbox this build cannot decode

    /// Garbage, or a file written by a newer linkC (an unknown task state).
    private let undecodableInboxes = [
        "invalid json content",
        #"{"version": 3, "workspacePath": "/w", "tasks": [{"id": "T1", "state": "teleported"}]}"#
    ]

    private func writeInbox(_ contents: String) throws -> (url: URL, bytes: Data) {
        let url = tempDir.appendingPathComponent(".linkc/inbox.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data(contents.utf8)
        try bytes.write(to: url)
        return (url, bytes)
    }

    private func assertUndecodable(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(error.localizedDescription.contains("could not be decoded"), "\(error)", file: file, line: line)
    }

    /// Read as empty, the next write would replace the file and destroy every task in it.
    func testUndecodableInboxThrowsOnLoad() throws {
        let store = InboxStore(workspaceRoot: tempDir.path)
        for contents in undecodableInboxes {
            _ = try writeInbox(contents)
            XCTAssertThrowsError(try store.load(), contents) { error in
                let message = error.localizedDescription
                XCTAssertTrue(message.contains("\(tempDir.lastPathComponent)/.linkc/inbox.json"), message)
                XCTAssertTrue(message.contains("leaving it untouched"), message)
            }
        }
    }

    func testUndecodableInboxRefusesEveryWriteAndLeavesTheFileUntouched() throws {
        let store = InboxStore(workspaceRoot: tempDir.path)
        let file = try writeInbox(undecodableInboxes[1])

        XCTAssertThrowsError(try store.createTask(from: .claude, to: .codex, prompt: "Build", files: [])) { assertUndecodable($0) }
        XCTAssertThrowsError(try store.enqueue(from: .claude, to: .codex, kind: .peerNote, body: "hi")) { assertUndecodable($0) }
        XCTAssertThrowsError(try store.recordLimit(agent: .codex, reason: "429", cooldown: 60)) { assertUndecodable($0) }
        XCTAssertThrowsError(try store.cancelTask(taskId: "T1", reason: "stop")) { assertUndecodable($0) }

        XCTAssertEqual(try Data(contentsOf: file.url), file.bytes, "a refused write leaves inbox.json byte-for-byte unchanged")
    }

    func testMissingInboxFileStillLoadsAsEmpty() throws {
        let store = InboxStore(workspaceRoot: tempDir.path)
        try FileManager.default.createDirectory(at: tempDir.appendingPathComponent(".linkc"), withIntermediateDirectories: true)

        let inbox = try store.load()

        XCTAssertTrue(inbox.messages.isEmpty && inbox.tasks.isEmpty && inbox.agentLimits.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent(".linkc/inbox.json").path), "a load never writes")
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
        XCTAssertFalse(TaskState.delivered.canTransition(to: .done))
        XCTAssertTrue(TaskState.delivered.canTransition(to: .failed))
        XCTAssertFalse(TaskState.started.canTransition(to: .done))
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

    /// Replaces the old `testLimitsMessagesTo100OnSave`, which asserted that the cap dropped the
    /// oldest 20 of 120 queued rows — encoding the very loss this task fixes. The cap must never
    /// sacrifice undelivered work: it may only trim delivered rows, and only once queued rows
    /// alone fit within it.
    func testTheMessageCapDropsDeliveredRowsBeforeQueuedOnes() throws {
        let store = InboxStore(workspaceRoot: tempDir.path)
        var inbox = Inbox(workspacePath: tempDir.path)
        let base = Date().addingTimeInterval(-1000)
        // 20 queued first, then 95 delivered, and OLDER than the delivered rows: a plain
        // array-order `suffix(100)` would drop the oldest of the 115 rows first — sacrificing
        // queued rows to keep newer delivered ones. The cap must instead sacrifice delivered
        // rows regardless of age, so every queued row must survive.
        for i in 0..<20 {
            inbox.messages.append(PendingMessage(id: "new-\(i)", fromAgent: .codex, toAgent: .claude,
                                                 prompt: "result \(i)", status: .queued,
                                                 createdAt: base.addingTimeInterval(Double(i)),
                                                 kind: .completion))
        }
        for i in 0..<95 {
            inbox.messages.append(PendingMessage(id: "old-\(i)", fromAgent: .claude, toAgent: .codex,
                                                 prompt: "old \(i)", status: .delivered,
                                                 createdAt: base.addingTimeInterval(100 + Double(i)),
                                                 deliveredAt: Date(),
                                                 kind: .completion))
        }
        try store.saveRaw(inbox)

        let saved = try store.load().messages
        XCTAssertEqual(saved.filter { $0.status == .queued }.count, 20, "no undelivered message may be dropped")
        XCTAssertLessThanOrEqual(saved.count, 100)
    }

    /// If queued rows alone exceed the cap, every one of them is kept — the cap is cosmetic,
    /// never a reason to lose undelivered work.
    func testTheMessageCapNeverDropsQueuedRowsEvenWhenTheyAloneExceedIt() throws {
        let store = InboxStore(workspaceRoot: tempDir.path)
        var inbox = Inbox(workspacePath: tempDir.path)
        for i in 0..<110 {
            inbox.messages.append(PendingMessage(id: "queued-\(i)", fromAgent: .claude, toAgent: .codex,
                                                 prompt: "result \(i)", status: .queued, kind: .completion))
        }
        try store.saveRaw(inbox)

        let saved = try store.load().messages
        XCTAssertEqual(saved.count, 110, "queued rows alone exceeding the cap must all be kept")
        XCTAssertTrue(saved.allSatisfy { $0.status == .queued })
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

    /// The dedupe must only match an undelivered row. Once a message is delivered, an identical
    /// re-send is a fresh request, not a duplicate — `dispatchMessages` only ever picks up
    /// `.queued` rows, so returning the delivered one silently drops the re-send.
    func testResendingAfterDeliveryQueuesAgainRatherThanReturningTheDeliveredRow() throws {
        let store = InboxStore(workspaceRoot: tempDir.path)
        let first = try store.enqueue(from: .claude, to: .codex, kind: .peerNote, body: "same body")
        try store.markMessageDelivered(id: first.id)
        let second = try store.enqueue(from: .claude, to: .codex, kind: .peerNote, body: "same body")
        XCTAssertNotEqual(second.id, first.id, "a delivered row must not satisfy a fresh send")
        XCTAssertEqual(second.status, .queued)
    }

    // MARK: - transitionAndNotify atomicity

    /// `transitionAndNotify` (backing `acceptUnverifiedAndNotify` and its siblings) folds a
    /// task's state change and its delegator-facing completion line into one locked write, so a
    /// failure partway through can never land one without the other. Prove that at the store
    /// level, without any lock-contention timing: cap how large a file this process may write
    /// (`RLIMIT_FSIZE`, with `SIGXFSZ` ignored so the write fails with an error instead of
    /// killing the process) to a size that fits the state change alone — `finishedAt` flipping
    /// from null to a timestamp, a few dozen bytes — but not the state change plus a whole new
    /// completion message appended to it, which costs a full `PendingMessage` row (id, agents,
    /// prompt, content hash, timestamps: several hundred bytes). `transitionAndNotify` applies
    /// both changes to its in-memory copy of the inbox before ever touching disk, so this cap
    /// can only ever reject the save as a whole, not the line by itself — proving the write
    /// really is one indivisible unit rather than two writes that merely run back to back.
    func testAcceptUnverifiedAndNotifyPersistsNeitherHalfWhenTheSharedWriteFails() throws {
        let store = InboxStore(workspaceRoot: tempDir.path)
        let task = try store.createTask(from: .claude, to: .codex, prompt: "reported without a gate", files: [])
        try store.markTaskDelivered(taskId: task.id, sessionId: "sess-1")
        try store.reportTask(taskId: task.id, report: TaskReport(status: "done", summary: "Shipped"))

        let inboxPath = tempDir.appendingPathComponent(".linkc/inbox.json").path
        let sizeBefore = (try FileManager.default.attributesOfItem(atPath: inboxPath)[.size] as? NSNumber)?.uint64Value ?? 0

        var original = rlimit()
        XCTAssertEqual(getrlimit(RLIMIT_FSIZE, &original), 0)
        defer {
            var restore = original
            _ = setrlimit(RLIMIT_FSIZE, &restore)
            signal(SIGXFSZ, SIG_DFL)
        }
        // 200 bytes of headroom clears the lone `finishedAt` flip with room to spare, but a new
        // completion message's row is easily several times that, so only a save carrying it
        // crosses the cap.
        var capped = rlimit(rlim_cur: sizeBefore + 200, rlim_max: original.rlim_max)
        XCTAssertEqual(setrlimit(RLIMIT_FSIZE, &capped), 0)
        signal(SIGXFSZ, SIG_IGN)

        XCTAssertThrowsError(
            try store.acceptUnverifiedAndNotify(taskId: task.id, notifyBody: "done (unverified)"),
            "the write must fail rather than silently succeed"
        )

        var restore = original
        XCTAssertEqual(setrlimit(RLIMIT_FSIZE, &restore), 0)
        signal(SIGXFSZ, SIG_DFL)

        let reloaded = try XCTUnwrap(store.task(id: task.id))
        XCTAssertEqual(reloaded.state, .reported,
                       "the state change must not persist when the write it shares a lock with fails")
        let completions = try store.load().messages.filter { $0.taskId == task.id }
        XCTAssertTrue(completions.isEmpty, "and the outcome line must not persist either")
    }

    func testTheStuckMarkIsSetClearedAndOptionalOnOldRows() throws {
        let store = InboxStore(workspaceRoot: tempDir.path)
        let task = try store.createTask(from: .claude, to: .codex, prompt: "Refactor migrations", files: [])
        XCTAssertNil(try store.task(id: task.id)?.stuckNotifiedAt)

        let at = Date(timeIntervalSince1970: 1_800_000_000)
        try store.setStuckNotified(taskId: task.id, at: at)
        XCTAssertEqual(try store.task(id: task.id)?.stuckNotifiedAt, at)

        try store.setStuckNotified(taskId: task.id, at: nil)
        XCTAssertNil(try store.task(id: task.id)?.stuckNotifiedAt, "a task that moves again must be reportable later")

        XCTAssertThrowsError(try store.setStuckNotified(taskId: "no-such-task", at: at))

        // A row written before this field existed must still decode: the store throws on a decode
        // error, which would take the whole inbox down.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(task)) as? [String: Any])
        json.removeValue(forKey: "stuckNotifiedAt")
        let legacy = try JSONDecoder().decode(TaskRecord.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.stuckNotifiedAt)
    }
}

import XCTest
@testable import LinkCKit

final class ModelPoolLimitTests: XCTestCase {
    private var tempDir: URL!
    private var store: InboxStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-pool-limit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = InboxStore(workspaceRoot: tempDir.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    func testAgyGeminiLimitDoesNotLimitClaudePool() throws {
        try store.recordLimit(agent: .agy, reason: "quota", cooldown: 3600, pool: "gemini")
        XCTAssertNotNil(try store.isAgentLimited(agent: .agy, model: "gemini-3.8-flash-medium"))
        XCTAssertNil(try store.isAgentLimited(agent: .agy, model: "claude-opus-4-6-thinking"))
        XCTAssertNil(try store.isAgentLimited(agent: .agy, model: "claude-sonnet-4-6"))
        XCTAssertNil(try store.isAgentLimited(agent: .agy, model: "gpt-oss-120b-medium"))
    }

    func testNilPoolLimitAppliesToEveryModel() throws {
        try store.recordLimit(agent: .agy, reason: "old row", cooldown: 3600, pool: nil)
        XCTAssertNotNil(try store.isAgentLimited(agent: .agy, model: "claude-opus-4-6-thinking"))
        XCTAssertNotNil(try store.isAgentLimited(agent: .agy, model: "gemini-3.8-flash-medium"))
        try store.recordLimit(agent: .codex, reason: "cap", cooldown: 3600)
        XCTAssertNotNil(try store.isAgentLimited(agent: .codex, model: "gpt-6-astra"))
    }

    /// The relay builds a refusal on the main actor, so it tells the refusal how long a store read may
    /// wait for the inbox lock; the refusal gives up then rather than after the store's 5 seconds.
    func testARefusalWaitsForAHeldInboxLockOnlyAsLongAsItIsTold() throws {
        try store.recordLimit(agent: .agy, reason: "weekly", cooldown: 3600, pool: "gemini")
        let limit = AgentLimitStatus(
            agent: .agy, reason: "weekly", cooldownExpiresAt: Date().addingTimeInterval(3600), pool: "gemini")
        let lockPath = tempDir.appendingPathComponent(".linkc/.inbox.lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
        XCTAssertGreaterThan(fd, 0)
        XCTAssertEqual(flock(fd, LOCK_EX), 0)
        defer { flock(fd, LOCK_UN); close(fd) }

        let start = Date()
        XCTAssertThrowsError(try MCPServer.limitRefusal(
            agent: .agy, limit: limit, model: "gemini-3.8-flash-medium", readLists: { [:] },
            settings: .seeded, inboxStore: store, lockTimeout: 0.2)) { error in
            guard case LinkCError.lockTimeout = error else { return XCTFail("expected a lock timeout, got \(error)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
    }

    func testDelegationRefusalNamesWhatIsNotLimited() throws {
        try store.recordLimit(agent: .agy, reason: "weekly", cooldown: 3600, pool: "gemini")
        let lists: [AgentKind: AgentModelList] = [
            .agy: AgentModelList(
                models: [
                    ListedModel(id: "claude-opus-4-6-thinking", name: "Opus"),
                    ListedModel(id: "claude-sonnet-4-6", name: "Sonnet"),
                    ListedModel(id: "gpt-oss-120b-medium", name: "GPT"),
                    ListedModel(id: "gemini-3.8-flash-medium", name: "Flash"),
                ],
                fetchedAt: Date(), error: nil),
        ]
        let server = MCPServer(
            workspaceRoot: tempDir.path,
            inboxStore: store,
            environment: ["LINKC_AGENT": "claude"],
            ancestorResolver: { _ in nil },
            sessionResolver: { nil },
            usageReaders: [:],
            modelLists: { lists })
        let request: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": [
                "name": "linkc_delegate_task",
                "arguments": ["to": "agy", "prompt": "x", "model": "gemini-3.8-flash-medium"],
            ],
        ]
        let data = try XCTUnwrap(server.handleMessage(try JSONSerialization.data(withJSONObject: request)))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try XCTUnwrap(json["result"] as? [String: Any])
        let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertTrue(text.contains("agy's Gemini pool is limited"), text)
        XCTAssertTrue(text.contains("Not limited:"), text)
        XCTAssertTrue(text.contains("agy's Claude/GPT pool"), text)
        XCTAssertTrue(text.contains("claude-opus-4-6-thinking"), text)
        XCTAssertTrue(text.contains("cursor"), text)
        XCTAssertTrue(text.contains("opencode"), text)
        XCTAssertTrue(try store.openTasks().isEmpty)
    }

    // MARK: - One limit row per pool

    func testEachPoolHasItsOwnRow() throws {
        try store.recordLimit(agent: .agy, reason: "gemini out", cooldown: 3600, pool: "gemini")
        try store.recordLimit(agent: .agy, reason: "claude out", cooldown: 7200, pool: "claude-gpt")
        try store.recordLimit(agent: .agy, reason: "again", cooldown: 9000, pool: "gemini")   // live: left as it was

        let rows = try store.load().agentLimits
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first { $0.pool == "gemini" }?.reason, "gemini out")
        XCTAssertEqual(rows.first { $0.pool == "claude-gpt" }?.reason, "claude out")
        XCTAssertEqual(try store.liveLimits(agent: .agy).count, 2)
    }

    func testExtendLimitExtendsOnlyItsPoolsRow() throws {
        try store.recordLimit(agent: .agy, reason: "gemini out", cooldown: 3600, pool: "gemini")
        try store.recordLimit(agent: .agy, reason: "claude out", cooldown: 3600, pool: "claude-gpt")
        let before = try store.load().agentLimits
        let later = Date().addingTimeInterval(5 * 3600)

        try store.extendLimit(agent: .agy, until: later, pool: "gemini")

        let rows = try store.load().agentLimits
        XCTAssertEqual(rows.first { $0.pool == "gemini" }?.cooldownExpiresAt.timeIntervalSince1970 ?? 0,
                       later.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(rows.first { $0.pool == "claude-gpt" }?.cooldownExpiresAt,
                       before.first { $0.pool == "claude-gpt" }?.cooldownExpiresAt,
                       "the other pool's row is untouched")
    }

    func testExtendLimitForAPoolDoesNotTouchAWholeAgentRow() throws {
        try store.recordLimit(agent: .agy, reason: "whole", cooldown: 3600, pool: nil)
        let before = try XCTUnwrap(try store.load().agentLimits.first)

        try store.extendLimit(agent: .agy, until: Date().addingTimeInterval(9 * 3600), pool: "gemini")

        XCTAssertEqual(try store.load().agentLimits, [before])
    }

    /// An expired row of one pool is replaced when that pool is limited again, and only that row.
    func testAnExpiredPoolRowIsReplacedInPlace() throws {
        var inbox = try store.load()
        inbox.agentLimits = [
            AgentLimitStatus(agent: .agy, reason: "old", limitedAt: Date(timeIntervalSinceNow: -7200),
                             cooldownExpiresAt: Date(timeIntervalSinceNow: -3600), pool: "gemini"),
        ]
        try store.saveRaw(inbox)

        try store.recordLimit(agent: .agy, reason: "new", cooldown: 3600, pool: "gemini")

        let rows = try store.load().agentLimits
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.reason, "new")
    }

    func testTheLatestEndingLimitIsTheOneReported() throws {
        try store.recordLimit(agent: .agy, reason: "short", cooldown: 3600, pool: "gemini")
        try store.recordLimit(agent: .agy, reason: "long", cooldown: 9000, pool: "claude-gpt")

        XCTAssertEqual(try store.isAgentLimited(agent: .agy)?.reason, "long")
        XCTAssertEqual(try store.load().liveLimit(for: .agy)?.reason, "long")
    }

    /// The sidebar looks at every live row: an expired first row must not hide a live one.
    func testALiveRowIsFoundEvenWhenAnEarlierRowHasExpired() {
        let now = Date()
        let inbox = Inbox(workspacePath: "/p", agentLimits: [
            AgentLimitStatus(agent: .agy, reason: "old", limitedAt: now.addingTimeInterval(-7200),
                             cooldownExpiresAt: now.addingTimeInterval(-60), pool: "gemini"),
            AgentLimitStatus(agent: .agy, reason: "live", limitedAt: now.addingTimeInterval(-60),
                             cooldownExpiresAt: now.addingTimeInterval(600), pool: "claude-gpt"),
        ])
        XCTAssertEqual(inbox.liveLimit(for: .agy, now: now)?.reason, "live")
        XCTAssertEqual(inbox.liveLimit(for: .agy, now: now)?.pool, "claude-gpt")
        XCTAssertNil(inbox.liveLimit(for: .codex, now: now))
        XCTAssertNil(inbox.liveLimit(for: .agy, now: now.addingTimeInterval(3600)))
    }

    // MARK: - Old files still decode

    /// A row as an older build wrote it: the encoding of today's row with the new key taken out.
    private func encodedWithout<T: Encodable>(_ value: T, key: String) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: try encoder.encode(value)) as? [String: Any])
        XCTAssertNotNil(object[key], "the row carries \(key) today")
        object.removeValue(forKey: key)
        return try JSONSerialization.data(withJSONObject: object)
    }

    func testAnAgentLimitWrittenBeforePoolsDecodes() throws {
        let row = AgentLimitStatus(agent: .agy, reason: "quota", limitedAt: Date(timeIntervalSince1970: 1_000),
                                   cooldownExpiresAt: Date(timeIntervalSince1970: 4_600), pool: "gemini")
        let old = try encodedWithout(row, key: "pool")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let status = try decoder.decode(AgentLimitStatus.self, from: old)
        XCTAssertEqual(status.agent, .agy)
        XCTAssertEqual(status.reason, "quota")
        XCTAssertNil(status.pool, "a row without a pool limits the whole agent")
    }

    func testATaskWrittenBeforeModelsDecodes() throws {
        let task = TaskRecord(fromAgent: .claude, tier: .standard, model: "gemini-3.8-flash-medium",
                              toAgent: .agy, prompt: "x")
        let old = try encodedWithout(task, key: "model")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(TaskRecord.self, from: old)
        XCTAssertNil(decoded.model)
        XCTAssertEqual(decoded.tier, .standard)
        XCTAssertEqual(decoded.prompt, "x")
    }

    /// And a whole inbox file of the old shape loads through the store.
    func testAnInboxFileWithoutTheNewKeysLoads() throws {
        try store.recordLimit(agent: .agy, reason: "quota", cooldown: 3600, pool: "gemini")
        _ = try store.createTask(from: .claude, to: .agy, model: "gemini-3.8-flash-medium", prompt: "x", files: [])
        let url = tempDir.appendingPathComponent(".linkc/inbox.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var limits = try XCTUnwrap(object["agentLimits"] as? [[String: Any]])
        var tasks = try XCTUnwrap(object["tasks"] as? [[String: Any]])
        for i in limits.indices { limits[i].removeValue(forKey: "pool") }
        for i in tasks.indices { tasks[i].removeValue(forKey: "model") }
        object["agentLimits"] = limits
        object["tasks"] = tasks
        try JSONSerialization.data(withJSONObject: object).write(to: url)

        let loaded = try store.load()
        XCTAssertNil(loaded.agentLimits.first?.pool)
        XCTAssertNil(loaded.tasks.first?.model)
    }

    // MARK: - Pools match in any case

    func testAPoolIsFoundWhateverTheCaseOfTheModel() {
        XCTAssertEqual(ModelPool.pool(of: "Gemini-3.8-Flash-Medium", agent: .agy), "gemini")
        XCTAssertEqual(ModelPool.pool(of: "CLAUDE-opus-4-6-thinking", agent: .agy), "claude-gpt")
        XCTAssertEqual(ModelPool.pool(of: "GPT-OSS-120b-medium", agent: .agy), "claude-gpt")
        XCTAssertNil(ModelPool.pool(of: "Gemini-3.8-Flash-Medium", agent: .codex))
    }

    func testALimitOnTheGeminiPoolAppliesToAModelTypedInAnotherCase() throws {
        try store.recordLimit(agent: .agy, reason: "quota", cooldown: 3600, pool: "gemini")
        XCTAssertNotNil(try store.isAgentLimited(agent: .agy, model: "Gemini-3.8-Flash-Medium"))
        XCTAssertNil(try store.isAgentLimited(agent: .agy, model: "Claude-Opus-4-6-Thinking"))
    }

    // MARK: - A task's tier does not make two tasks different

    /// Dedupe compares the prompt, the target and the model, as before models existed: the same
    /// brief at another tier is the same task.
    func testTheSameBriefAtAnotherTierIsTheSameTask() throws {
        let first = try store.createTask(from: .claude, to: .agy, tier: .light, prompt: "same", files: [])
        let second = try store.createTask(from: .claude, to: .agy, tier: .deep, prompt: "same", files: [])
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(try store.openTasks().count, 1)
    }

    func testTheSameBriefForAnotherModelIsAnotherTask() throws {
        let flash = try store.createTask(from: .claude, to: .agy, model: "gemini-3.8-flash-medium", prompt: "same", files: [])
        let opus = try store.createTask(from: .claude, to: .agy, model: "claude-opus-4-6-thinking", prompt: "same", files: [])
        let again = try store.createTask(from: .claude, to: .agy, model: "claude-opus-4-6-thinking", prompt: "same", files: [])
        XCTAssertNotEqual(flash.id, opus.id)
        XCTAssertEqual(opus.id, again.id)
    }
}

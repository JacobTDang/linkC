import XCTest
@testable import LinkCKit

final class MCPServerUsageTests: XCTestCase {
    var tempDir: URL!
    var inbox: InboxStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-mcp-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        inbox = InboxStore(workspaceRoot: tempDir.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private func server(readers: [AgentKind: MCPServer.UsageReader]) -> MCPServer {
        MCPServer(workspaceRoot: tempDir.path, inboxStore: inbox,
                  environment: ["LINKC_AGENT": "claude"], ancestorResolver: { _ in nil },
                  modelSettings: { .seeded }, sessionResolver: { nil }, usageReaders: readers)
    }

    private func call(_ server: MCPServer, _ name: String, _ args: [String: Any] = [:]) throws -> (text: String, isError: Bool) {
        let req: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": args]]
        let data = try JSONSerialization.data(withJSONObject: req)
        let res = try XCTUnwrap(server.handleMessage(data))
        let json = try JSONSerialization.jsonObject(with: res) as? [String: Any]
        let result = json?["result"] as? [String: Any]
        let text = ((result?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        return (text, result?["isError"] as? Bool ?? false)
    }

    func testItReportsWhatEachAgentHasLeft() throws {
        let codex = AgentUsage(agent: .codex,
                               windows: [UsageWindow(label: "5h", usedPercent: 23, tokens: nil, resetsAt: Date().addingTimeInterval(3600)),
                                         UsageWindow(label: "7d", usedPercent: 39, tokens: nil, resetsAt: nil)],
                               planType: "plus", observedAt: Date(), unavailableReason: nil)
        let agy = AgentUsage(agent: .agy, windows: [], planType: nil, observedAt: nil,
                             unavailableReason: "agy writes no local session records")
        let res = try call(server(readers: [.codex: { codex }, .agy: { agy }]), "linkc_get_usage_status")

        XCTAssertFalse(res.isError, res.text)
        XCTAssertTrue(res.text.contains("23%"), res.text)
        XCTAssertTrue(res.text.contains("plan plus"), res.text)
        XCTAssertTrue(res.text.contains("agy writes no local session records"), res.text)
        XCTAssertFalse(res.text.contains("gpt-4o"), "the stale catalog must not appear: \(res.text)")
        XCTAssertFalse(res.text.contains("Default Model"), "the default-model line is gone: \(res.text)")
    }

    func testAThrowingReaderStillReturnsAResult() throws {
        let res = try call(server(readers: [.codex: { AgentUsage.unavailable(.codex, reason: "reader failed") }]),
                           "linkc_get_usage_status")
        XCTAssertFalse(res.isError, "usage is informational; it never fails the call")
        XCTAssertTrue(res.text.contains("reader failed"), res.text)
    }

    func testAStaleReadingSaysSo() throws {
        let old = AgentUsage(agent: .codex,
                             windows: [UsageWindow(label: "5h", usedPercent: 23, tokens: nil, resetsAt: nil)],
                             planType: nil, observedAt: Date().addingTimeInterval(-3 * 3600), unavailableReason: nil)
        let res = try call(server(readers: [.codex: { old }]), "linkc_get_usage_status")
        XCTAssertTrue(res.text.lowercased().contains("stale"), res.text)
    }

    /// Task 10's transcript usage reader sets `tokensAreLowerBound` when its byte budget ran out
    /// before it could prove a window's total complete — the figure is then a floor, not the
    /// true count, and must say so rather than presenting a truncated read as exact.
    func testALowerBoundTokenCountSaysAtLeast() throws {
        let claude = AgentUsage(agent: .claude,
                                windows: [UsageWindow(label: "7d", usedPercent: nil, tokens: 443_000_000,
                                                       resetsAt: nil, tokensAreLowerBound: true)],
                                planType: nil, observedAt: Date(), unavailableReason: nil)
        let res = try call(server(readers: [.claude: { claude }]), "linkc_get_usage_status")
        XCTAssertFalse(res.isError, res.text)
        XCTAssertTrue(res.text.contains("at least"), res.text)
    }

    func testANonLowerBoundTokenCountDoesNotSayAtLeast() throws {
        let claude = AgentUsage(agent: .claude,
                                windows: [UsageWindow(label: "7d", usedPercent: nil, tokens: 443_000_000,
                                                       resetsAt: nil, tokensAreLowerBound: false)],
                                planType: nil, observedAt: Date(), unavailableReason: nil)
        let res = try call(server(readers: [.claude: { claude }]), "linkc_get_usage_status")
        XCTAssertFalse(res.isError, res.text)
        XCTAssertFalse(res.text.contains("at least"), res.text)
    }

    /// A `resetsAt` in the past is stale information, not a future promise. Rendering it as if
    /// it were still ahead ("resets 14:04") would show a moment that has already happened; the
    /// report must say the window has moved on instead, with no clock control needed since the
    /// reset is well behind whenever this test actually runs.
    func testAPastResetRendersAsResetSinceThisReadingRatherThanAPastTime() throws {
        let codex = AgentUsage(agent: .codex,
                               windows: [UsageWindow(label: "5h", usedPercent: 95, tokens: nil,
                                                      resetsAt: Date().addingTimeInterval(-600))],
                               planType: nil, observedAt: Date(), unavailableReason: nil)
        let res = try call(server(readers: [.codex: { codex }]), "linkc_get_usage_status")
        XCTAssertFalse(res.isError, res.text)
        XCTAssertTrue(res.text.contains("reset since this reading"), res.text)
        XCTAssertFalse(res.text.contains("resets "), "a past reset must never be shown as a future one: \(res.text)")
    }

    // MARK: - BackgroundRefreshedUsageReader (D22a: never block the stdio loop)

    func testBackgroundRefreshedUsageReaderNeverBlocksOnTheRealRead() throws {
        let real = AgentUsage(agent: .claude,
                              windows: [UsageWindow(label: "5h", usedPercent: 42, tokens: nil, resetsAt: nil)],
                              planType: nil, observedAt: Date(), unavailableReason: nil)
        let reader = BackgroundRefreshedUsageReader(agent: .claude) {
            usleep(200_000) // stand-in for ClaudeUsageReader's ~1.3s transcript scan
            return real
        }

        let start = Date()
        let first = reader()
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 0.05, "the first call must return immediately, not block on the real read")
        XCTAssertEqual(first.unavailableReason, "usage not read yet — check again shortly")

        let deadline = Date().addingTimeInterval(2)
        var second = reader()
        while second.windows.isEmpty && Date() < deadline {
            usleep(20_000)
            second = reader()
        }
        XCTAssertEqual(second, real, "once the background read completes, later calls must surface it")
    }

    // MARK: - TTLCachedUsageReader (D22b-2: a burst of delegations pays for one read)

    /// Lock-protected mutable state shared with a `@Sendable` reader closure — plain `var`
    /// captures fail Swift 6's strict-concurrency check, matching `EventBox`/`ReadingBox` in
    /// `HooksTests.swift`.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var callCount = 0
        private var current: Date
        init(_ start: Date) { current = start }
        var calls: Int { lock.withLock { callCount } }
        func advance(by seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
        func now() -> Date { lock.withLock { current } }
        func recordCall() -> Int { lock.withLock { callCount += 1; return callCount } }
    }

    func testTTLCachedUsageReaderReusesAReadWithinItsTTLThenRefreshesAfter() throws {
        let clock = Clock(Date())
        let reader = TTLCachedUsageReader(agent: .codex, ttl: 5, now: clock.now) {
            let n = clock.recordCall()
            return AgentUsage(agent: .codex,
                              windows: [UsageWindow(label: "5h", usedPercent: Double(n), tokens: nil, resetsAt: nil)],
                              planType: nil, observedAt: clock.now(), unavailableReason: nil)
        }

        let first = reader()
        XCTAssertEqual(clock.calls, 1)
        XCTAssertEqual(first.windows.first?.usedPercent, 1)

        clock.advance(by: 2) // still inside the 5s TTL
        let second = reader()
        XCTAssertEqual(clock.calls, 1, "a call inside the TTL must not repeat the real read")
        XCTAssertEqual(second.windows.first?.usedPercent, 1)

        clock.advance(by: 4) // 6s since the first read, past the 5s TTL
        let third = reader()
        XCTAssertEqual(clock.calls, 2, "a call past the TTL must read again")
        XCTAssertEqual(third.windows.first?.usedPercent, 2)
    }

    // MARK: - ClaudeRateLimits.usageReader (D22b-1: one Claude usage source everywhere)

    private let rateLimitsBody = Data(
        #"{"session_id":"c1","rate_limits":{"five_hour":{"used_percentage":66,"resets_at":1789980000},"seven_day":{"used_percentage":92,"resets_at":1790017200}}}"#.utf8)

    func testUsageReaderPrefersTheCachedStatusLineOverTheFallback() throws {
        let cacheFile = tempDir.appendingPathComponent("status-line.json")
        try rateLimitsBody.write(to: cacheFile)
        let fallbackCalled = Clock(Date())
        let reader = ClaudeRateLimits.usageReader(cacheURL: cacheFile, fallback: {
            _ = fallbackCalled.recordCall()
            return AgentUsage.unavailable(.claude, reason: "should never be called")
        })

        let usage = reader()

        XCTAssertEqual(fallbackCalled.calls, 0, "a cached status line must win over the fallback")
        XCTAssertEqual(usage.windows.map(\.usedPercent), [66, 92])
    }

    func testUsageReaderFallsBackAndLabelsTheWindowsWhenNoStatusLineWasEverCached() throws {
        let neverWritten = tempDir.appendingPathComponent("never-written.json")
        let transcript = AgentUsage(agent: .claude,
                                    windows: [UsageWindow(label: "7d", usedPercent: nil, tokens: 443_000_000, resetsAt: nil)],
                                    planType: nil, observedAt: Date(), unavailableReason: nil)
        let reader = ClaudeRateLimits.usageReader(cacheURL: neverWritten, fallback: { transcript })

        let usage = reader()

        XCTAssertEqual(usage.windows.first?.tokens, 443_000_000)
        XCTAssertTrue(usage.windows.first?.label.contains("no status line seen yet") ?? false, "\(usage.windows)")
    }
}

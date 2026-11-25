import XCTest
@testable import LinkCKit

final class ClaudeSessionStatusTests: XCTestCase {
    func testTheModelIsTheOneTheSessionRunsNow() throws {
        let body = #"{"session_id":"c1","model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"},"rate_limits":{}}"#
        XCTAssertEqual(try ClaudeSessionStatus.modelId(in: Data(body.utf8)), "claude-opus-5-5")
    }

    func testThePromptCacheExpiryIsWhenTheReportSaysItGoesCold() throws {
        let body = #"{"prompt_cache":{"warm":true,"ttl":"1h","expires_at":1795560237}}"#
        XCTAssertEqual(try ClaudeSessionStatus.cacheExpiry(in: Data(body.utf8)), Date(timeIntervalSince1970: 1_795_560_237))
    }

    func testAReportWithoutAModelHasNone() throws {
        XCTAssertNil(try ClaudeSessionStatus.modelId(in: Data(#"{"session_id":"c1"}"#.utf8)))
        XCTAssertNil(try ClaudeSessionStatus.cacheExpiry(in: Data(#"{"session_id":"c1"}"#.utf8)))
    }

    func testAReportThatIsNotJSONIsAnError() {
        XCTAssertThrowsError(try ClaudeSessionStatus.modelId(in: Data("not json".utf8)))
        XCTAssertThrowsError(try ClaudeSessionStatus.cacheExpiry(in: Data("not json".utf8)))
    }

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func append(_ line: String) { lock.lock(); stored.append(line); lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return stored.count }
        var first: String? { lock.lock(); defer { lock.unlock() }; return stored.first }
    }

    func testTheStoreKeepsEachSessionsLatestReportUntilItEnds() {
        let logged = Lines()
        let store = ClaudeSessionStatuses(log: { logged.append($0) })
        store.accept(sessionId: "A", body: Data(#"{"model":{"id":"claude-sonnet-5-5"}}"#.utf8))
        store.accept(sessionId: "A", body: Data(#"{"model":{"id":"claude-opus-5-5"}}"#.utf8))
        store.accept(sessionId: "B", body: Data("not json".utf8))

        XCTAssertEqual(store.status(for: "A")?.modelId, "claude-opus-5-5")
        XCTAssertNil(store.status(for: "B"))
        XCTAssertEqual(logged.count, 1, "a report that is not JSON is said, not dropped quietly")

        store.forget(sessionId: "A")
        XCTAssertNil(store.status(for: "A"))
    }

    /// A cache field that changes shape costs the session its cache clock, not its model, and is said.
    func testAMalformedPromptCacheKeepsTheModelAndIsLogged() {
        let logged = Lines()
        let store = ClaudeSessionStatuses(log: { logged.append($0) })
        store.accept(sessionId: "A", body: Data(#"{"model":{"id":"claude-sonnet-5-5"},"prompt_cache":{"expires_at":1795560237}}"#.utf8))
        store.accept(sessionId: "A", body: Data(#"{"model":{"id":"claude-opus-5-5"},"prompt_cache":"warm"}"#.utf8))

        XCTAssertEqual(store.status(for: "A")?.modelId, "claude-opus-5-5")
        XCTAssertNil(store.status(for: "A")?.cacheExpiresAt,
                     "a cache time that cannot be read is dropped: kept past its moment it would read as cold")
        XCTAssertEqual(logged.count, 1)
        XCTAssertEqual(logged.first?.contains("its prompt cache"), true)
        XCTAssertEqual(logged.first?.contains("its model"), false)
    }

    /// The status line refreshes several times a turn: the same failure is said once, a new one again.
    func testTheSameFailureIsLoggedOncePerSession() {
        let logged = Lines()
        let store = ClaudeSessionStatuses(log: { logged.append($0) })
        store.accept(sessionId: "A", body: Data("not json".utf8))
        store.accept(sessionId: "A", body: Data("not json".utf8))
        XCTAssertEqual(logged.count, 1)

        store.accept(sessionId: "A", body: Data(#"{"model":{"id":"claude-opus-5-5"}}"#.utf8))
        store.accept(sessionId: "A", body: Data("not json".utf8))
        XCTAssertEqual(logged.count, 2, "a failure after a good report is news again")
    }
}

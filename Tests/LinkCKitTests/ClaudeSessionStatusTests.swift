import XCTest
@testable import LinkCKit

final class ClaudeSessionStatusTests: XCTestCase {
    func testTheModelIsTheOneTheSessionRunsNow() throws {
        let body = #"{"session_id":"c1","model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"},"rate_limits":{}}"#
        let status = try ClaudeSessionStatus.decode(Data(body.utf8))
        XCTAssertEqual(status.modelId, "claude-opus-5-5")
    }

    func testThePromptCacheExpiryIsWhenTheReportSaysItGoesCold() throws {
        let body = #"{"prompt_cache":{"warm":true,"ttl":"1h","expires_at":1795560237}}"#
        let status = try ClaudeSessionStatus.decode(Data(body.utf8))
        XCTAssertEqual(status.cacheExpiresAt, Date(timeIntervalSince1970: 1_795_560_237))
    }

    func testAReportWithoutAModelHasNone() throws {
        let status = try ClaudeSessionStatus.decode(Data(#"{"session_id":"c1"}"#.utf8))
        XCTAssertNil(status.modelId)
    }

    func testAReportThatIsNotJSONIsAnError() {
        XCTAssertThrowsError(try ClaudeSessionStatus.decode(Data("not json".utf8)))
    }

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func append(_ line: String) { lock.lock(); stored.append(line); lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return stored.count }
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

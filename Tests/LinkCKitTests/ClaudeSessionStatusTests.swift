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

    /// Claude reports how much of the context window the conversation fills, as a percent.
    func testTheContextUseIsThePercentOfTheWindowTheReportGives() throws {
        let body = #"{"context_window":{"context_window_size":200000,"used_percentage":41,"remaining_percentage":59}}"#
        XCTAssertEqual(try ClaudeSessionStatus.contextPercent(in: Data(body.utf8)), 41)
    }

    /// A percent no window can have is refused as a read failure; `Int(1e30)` is a trap, not a number.
    func testAContextUseOutsideZeroToOneHundredIsRefused() {
        for percent in ["1e30", "-5", "250", "100.5"] {
            let body = Data(#"{"context_window":{"used_percentage":\#(percent)}}"#.utf8)
            XCTAssertThrowsError(try ClaudeSessionStatus.contextPercent(in: body), "used_percentage \(percent)") { error in
                XCTAssertTrue(String(describing: error).contains("is not a percentage from 0 to 100"), "\(error)")
            }
        }
    }

    func testTheEdgesOfTheContextRangeAreKept() throws {
        for (percent, whole) in [("0", 0), ("41.6", 42), ("100", 100)] {
            let body = Data(#"{"context_window":{"used_percentage":\#(percent)}}"#.utf8)
            XCTAssertEqual(try ClaudeSessionStatus.contextPercent(in: body), whole, "used_percentage \(percent)")
        }
    }

    func testAReportWithoutAContextWindowHasNoContextUse() throws {
        XCTAssertNil(try ClaudeSessionStatus.contextPercent(in: Data(#"{"session_id":"c1"}"#.utf8)))
        XCTAssertNil(try ClaudeSessionStatus.contextPercent(in: Data(#"{"context_window":{"context_window_size":200000}}"#.utf8)))
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

    func testTheStoreKeepsTheContextUseOfTheLatestReport() {
        let store = ClaudeSessionStatuses(log: { _ in })
        store.accept(sessionId: "A", body: Data(#"{"model":{"id":"claude-opus-5-5"},"context_window":{"used_percentage":12}}"#.utf8))
        store.accept(sessionId: "A", body: Data(#"{"model":{"id":"claude-opus-5-5"},"context_window":{"used_percentage":64}}"#.utf8))

        XCTAssertEqual(store.status(for: "A")?.contextPercent, 64)
    }

    /// A context field that changes shape costs the session its context use, not its model, and is said.
    func testAMalformedContextUseKeepsTheModelAndIsLogged() {
        let logged = Lines()
        let store = ClaudeSessionStatuses(log: { logged.append($0) })
        store.accept(sessionId: "A", body: Data(#"{"model":{"id":"claude-opus-5-5"},"context_window":{"used_percentage":"lots"}}"#.utf8))

        XCTAssertEqual(store.status(for: "A")?.modelId, "claude-opus-5-5")
        XCTAssertNil(store.status(for: "A")?.contextPercent)
        XCTAssertEqual(logged.count, 1)
        XCTAssertEqual(logged.first?.contains("its context use"), true)
    }

    /// A context use no window can have costs the session its context use, not its model or the
    /// app, and is said once.
    func testAnImpossibleContextUseKeepsTheModelAndIsLogged() {
        let logged = Lines()
        let store = ClaudeSessionStatuses(log: { logged.append($0) })
        let body = Data(#"{"model":{"id":"claude-opus-5-5"},"context_window":{"used_percentage":1e30}}"#.utf8)
        store.accept(sessionId: "A", body: body)
        store.accept(sessionId: "A", body: body)

        XCTAssertEqual(store.status(for: "A")?.modelId, "claude-opus-5-5")
        XCTAssertNil(store.status(for: "A")?.contextPercent)
        XCTAssertEqual(logged.count, 1)
        XCTAssertEqual(logged.first?.contains("its context use"), true)
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

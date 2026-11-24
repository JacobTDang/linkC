import XCTest
@testable import LinkCKit

final class ClaudeSessionStatusTests: XCTestCase {
    func testTheModelIsTheOneTheSessionRunsNow() throws {
        let body = #"{"session_id":"c1","model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"},"rate_limits":{}}"#
        let status = try ClaudeSessionStatus.decode(Data(body.utf8))
        XCTAssertEqual(status.modelId, "claude-opus-5-5")
        XCTAssertEqual(status.modelName, "Opus 5.5")
    }

    func testAReportWithoutAModelHasNone() throws {
        let status = try ClaudeSessionStatus.decode(Data(#"{"session_id":"c1"}"#.utf8))
        XCTAssertNil(status.modelId)
        XCTAssertNil(status.modelName)
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
        store.accept(sessionId: "A", body: Data(#"{"model":{"id":"claude-sonnet-5-5","display_name":"Sonnet 5.5"}}"#.utf8))
        store.accept(sessionId: "A", body: Data(#"{"model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"}}"#.utf8))
        store.accept(sessionId: "B", body: Data("not json".utf8))

        XCTAssertEqual(store.status(for: "A")?.modelName, "Opus 5.5")
        XCTAssertNil(store.status(for: "B"))
        XCTAssertEqual(logged.count, 1, "a report that is not JSON is said, not dropped quietly")

        store.forget(sessionId: "A")
        XCTAssertNil(store.status(for: "A"))
    }
}

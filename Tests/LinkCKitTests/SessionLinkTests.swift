import XCTest
@testable import LinkCKit

final class SessionLinkTests: XCTestCase {
    func testASessionsLinkNamesTheSession() {
        let id = "68C5073E-35E7-470D-B7B3-137588DF9A7A"
        XCTAssertEqual(SessionLink.url(for: id).absoluteString, "linkc://session/\(id)")
        XCTAssertEqual(SessionLink.sessionId(in: SessionLink.url(for: id)), id)
    }

    func testOnlyALinkcSessionLinkNamesASession() {
        XCTAssertNil(SessionLink.sessionId(in: URL(string: "https://session/abc")!))
        XCTAssertNil(SessionLink.sessionId(in: URL(string: "linkc://board/abc")!))
        XCTAssertNil(SessionLink.sessionId(in: URL(string: "linkc://session/")!))
        XCTAssertNil(SessionLink.sessionId(in: URL(string: "linkc://session/a/b")!))
    }
}

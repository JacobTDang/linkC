import XCTest
@testable import LinkCKit

final class StartNoticeTextTests: XCTestCase {
    func testJoinUsesMiddleDotSoSingleLineErrorBarShowsBoth() {
        XCTAssertEqual(
            StartNoticeText.joining("mod failed", "update swapped"),
            "mod failed · update swapped"
        )
        XCTAssertEqual(StartNoticeText.joining(nil, "only"), "only")
        XCTAssertEqual(StartNoticeText.joining("", "only"), "only")
    }
}

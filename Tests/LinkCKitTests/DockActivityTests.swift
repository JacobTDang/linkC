import XCTest
@testable import LinkCKit

final class DockActivityTests: XCTestCase {
    func testPanelScreenActivityEnumCaseExists() {
        XCTAssertTrue(PanelScreen.allCases.contains(.activity))
        XCTAssertEqual(PanelScreen.activity.rawValue, "activity")
        XCTAssertEqual(PanelScreen.activity.id, "activity")
    }
}

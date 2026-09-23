import XCTest
@testable import LinkCKit

final class ShownActivityTests: XCTestCase {
    func testAWorkingSessionShowsItsActionAndShimmers() throws {
        let shown = try XCTUnwrap(ShownActivity(activity: "Read the panel's drag gate", state: .working))
        XCTAssertEqual(shown.text, "Read the panel's drag gate")
        XCTAssertTrue(shown.isWorking)
    }

    func testAPermissionWaitShowsItsLineWithoutTheShimmer() throws {
        let shown = try XCTUnwrap(ShownActivity(activity: "Permission required", state: .waitingPermission))
        XCTAssertFalse(shown.isWorking)
    }

    func testEveryOtherStateShowsTheName() {
        for state in SessionState.allCases where state != .working && state != .waitingPermission {
            XCTAssertNil(ShownActivity(activity: "$ swift test", state: state), "\(state) shows the name")
        }
    }

    func testNoActionShowsTheName() {
        XCTAssertNil(ShownActivity(activity: nil, state: .working))
        XCTAssertNil(ShownActivity(activity: "", state: .working))
        XCTAssertNil(ShownActivity(activity: "  \n", state: .working))
    }

    func testTheTextIsTrimmed() {
        XCTAssertEqual(ShownActivity(activity: "  ▸ Final fix wave \n", state: .working)?.text, "▸ Final fix wave")
    }
}

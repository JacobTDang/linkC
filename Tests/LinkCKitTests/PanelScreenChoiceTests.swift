import XCTest
@testable import LinkCKit

final class PanelScreenChoiceTests: XCTestCase {
    func testAUserMoveOffAConnectedDisplayIsSavedAndTracked() {
        let move = PanelScreenChoice.afterMove(to: 10, placed: 20, connected: [10, 20])
        XCTAssertEqual(move.save, 10)
        XCTAssertEqual(move.placed, 10)
    }

    func testStayingOnThePlacedDisplaySavesNothing() {
        let move = PanelScreenChoice.afterMove(to: 20, placed: 20, connected: [10, 20])
        XCTAssertNil(move.save)
        XCTAssertEqual(move.placed, 20)
    }

    func testAnEvacuationIsTrackedButNotSaved() {
        let move = PanelScreenChoice.afterMove(to: 10, placed: 20, connected: [10])
        XCTAssertNil(move.save, "macOS moving the panel off an unplugged display is not the user's choice")
        XCTAssertEqual(move.placed, 10, "the panel really is on the MacBook now")
    }

    func testAfterAnEvacuationAReplugAndTheHideAnimationSaveNothing() {
        // Placed on the monitor (20); it is unplugged while the panel is visible, then plugged back in,
        // and the hide animation nudges the panel on the MacBook (10).
        let evacuated = PanelScreenChoice.afterMove(to: 10, placed: 20, connected: [10])
        let nudged = PanelScreenChoice.afterMove(to: 10, placed: evacuated.placed, connected: [10, 20])
        XCTAssertNil(evacuated.save)
        XCTAssertNil(nudged.save, "the saved monitor must survive, so the next show returns to it")
    }

    func testANoScreenOrNeverShownMoveSavesNothing() {
        XCTAssertEqual(PanelScreenChoice.afterMove(to: nil, placed: 20, connected: [10, 20]).placed, 20)
        XCTAssertNil(PanelScreenChoice.afterMove(to: nil, placed: 20, connected: [10, 20]).save)
        XCTAssertNil(PanelScreenChoice.afterMove(to: 10, placed: nil, connected: [10, 20]).save)
        XCTAssertEqual(PanelScreenChoice.afterMove(to: 10, placed: nil, connected: [10, 20]).placed, 10)
    }

    func testRememberedDisplayWinsWhileConnected() {
        XCTAssertEqual(PanelScreenChoice.pick(remembered: 20, connected: [10, 20], underMouse: 10, statusItem: 10), 20)
        // Disconnecting does not mutate the saved ID; it wins again after reconnection.
        XCTAssertEqual(PanelScreenChoice.pick(remembered: 20, connected: [10], underMouse: 10, statusItem: 10), 10)
        XCTAssertEqual(PanelScreenChoice.pick(remembered: 20, connected: [10, 20], underMouse: 10, statusItem: 10), 20)
    }

    func testDisconnectedRememberedDisplayFallsBackToMouse() {
        XCTAssertEqual(PanelScreenChoice.pick(remembered: 99, connected: [10, 20], underMouse: 20, statusItem: 10), 20)
        XCTAssertEqual(PanelScreenChoice.pick(remembered: nil, connected: [10, 20], underMouse: 20, statusItem: 10), 20)
    }

    func testMissingMouseDisplayFallsBackToStatusItem() {
        XCTAssertEqual(PanelScreenChoice.pick(remembered: 99, connected: [10, 20], underMouse: 98, statusItem: 20), 20)
        XCTAssertEqual(PanelScreenChoice.pick(remembered: nil, connected: [10, 20], underMouse: nil, statusItem: 20), 20)
    }

    func testMissingPreferredDisplaysFallsBackToFirstConnectedDisplay() {
        XCTAssertEqual(PanelScreenChoice.pick(remembered: 99, connected: [20, 10], underMouse: 98, statusItem: 97), 20)
        XCTAssertEqual(PanelScreenChoice.pick(remembered: nil, connected: [20, 10], underMouse: nil, statusItem: nil), 20)
    }

    func testNoConnectedDisplaysReturnsNil() {
        XCTAssertNil(PanelScreenChoice.pick(remembered: 20, connected: [], underMouse: 10, statusItem: 30))
        XCTAssertNil(PanelScreenChoice.pick(remembered: nil, connected: [], underMouse: nil, statusItem: nil))
    }
}

import XCTest
@testable import LinkCKit

final class SplitDropHoverTests: XCTestCase {
    func testNothingIsLitBeforeADragArrives() {
        XCTAssertNil(SplitDropHover().edge)
    }

    func testEnteringLightsTheEdge() {
        var hover = SplitDropHover()
        hover.entered(.left)
        XCTAssertEqual(hover.edge, .left)
    }

    func testAnUpdateMovesAHighlightThatIsShowing() {
        var hover = SplitDropHover()
        hover.entered(.left)
        hover.updated(.bottom)
        XCTAssertEqual(hover.edge, .bottom)
    }

    func testExitingClearsIt() {
        var hover = SplitDropHover()
        hover.entered(.left)
        hover.exited()
        XCTAssertNil(hover.edge)
    }

    func testDroppingClearsIt() {
        var hover = SplitDropHover()
        hover.entered(.left)
        hover.dropped()
        XCTAssertNil(hover.edge)
    }

    /// SwiftUI reports the position once more as a drop concludes, after the drop has cleared the
    /// highlight, and no exit follows. That last update must not light the pane again.
    func testTheUpdateThatConcludesADropDoesNotBringTheHighlightBack() {
        var hover = SplitDropHover()
        hover.entered(.top)
        hover.updated(.left)
        hover.dropped()
        hover.updated(.left)
        XCTAssertNil(hover.edge)
    }

    func testAnUpdateAfterExitingDoesNotBringTheHighlightBack() {
        var hover = SplitDropHover()
        hover.entered(.top)
        hover.exited()
        hover.updated(.left)
        XCTAssertNil(hover.edge)
    }

    /// Only an entry starts a hover: nothing tells an update that opens a drag from one that closes
    /// a drop, so an update on its own leaves the pane dark.
    func testAnUpdateWithoutAnEntryLightsNothing() {
        var hover = SplitDropHover()
        hover.updated(.right)
        XCTAssertNil(hover.edge)
    }

    func testTheNextDragLightsThePaneAgainAfterADrop() {
        var hover = SplitDropHover()
        hover.entered(.top)
        hover.dropped()
        hover.updated(.top)
        hover.entered(.right)
        XCTAssertEqual(hover.edge, .right)
        hover.updated(.bottom)
        XCTAssertEqual(hover.edge, .bottom)
    }
}

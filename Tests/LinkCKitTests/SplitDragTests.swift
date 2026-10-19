import XCTest
@testable import LinkCKit

final class SplitDragTests: XCTestCase {
    /// The first boundary of row 0 moved `distance` points in a 600 pt row.
    private func widen(_ sizes: SplitSizes, by distance: Double) -> SplitSizes {
        sizes.resizingColumns(inRow: 0, divider: 0, by: distance, rowWidth: 600)
    }

    func testTheFirstStepStartsFromTheShownSizes() {
        let shown = SplitSizes.even(for: 2)
        let drag = SplitDrag.step(nil, over: shown) { widen($0, by: 30) }
        XCTAssertEqual(drag.start, shown)
        XCTAssertEqual(drag.current, widen(shown, by: 30))
    }

    /// Each step carries the drag's whole translation, so it applies to where the drag started, not
    /// to the last step.
    func testALaterStepAppliesToWhereTheDragStarted() {
        let shown = SplitSizes.even(for: 2)
        let first = SplitDrag.step(nil, over: shown) { widen($0, by: 30) }
        let second = SplitDrag.step(first, over: first.current) { widen($0, by: 50) }
        XCTAssertEqual(second.start, shown)
        XCTAssertEqual(second.current, widen(shown, by: 50))
    }

    /// A drag whose handle went away mid-drag never ended. A step on a grid of another number of panes
    /// starts over from what that grid shows, rather than resizing sizes made for another grid.
    func testAStepOnAGridOfAnotherShapeStartsOver() {
        let stale = SplitDrag.step(nil, over: SplitSizes.even(for: 4)) { widen($0, by: 40) }
        let shown = SplitSizes.even(for: 5)
        let drag = SplitDrag.step(stale, over: shown) { widen($0, by: 30) }
        XCTAssertEqual(drag.start, shown)
        XCTAssertEqual(drag.current, widen(shown, by: 30))
    }

    func testADragShowsOnlyOnAGridItFits() {
        let drag = SplitDrag.step(nil, over: SplitSizes.even(for: 3)) { widen($0, by: 30) }
        XCTAssertEqual(drag.sizes(forPanes: 3), drag.current)
        XCTAssertNil(drag.sizes(forPanes: 2))
    }
}

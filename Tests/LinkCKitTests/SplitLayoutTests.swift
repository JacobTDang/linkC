import XCTest
@testable import LinkCKit

final class SplitLayoutTests: XCTestCase {
    func testRowsForEachPaneCount() {
        XCTAssertEqual(SplitLayout.rows(for: 0), [])
        XCTAssertEqual(SplitLayout.rows(for: 1), [])
        XCTAssertEqual(SplitLayout.rows(for: 2), [2])
        XCTAssertEqual(SplitLayout.rows(for: 3), [2, 1])
        XCTAssertEqual(SplitLayout.rows(for: 4), [2, 2])
        XCTAssertEqual(SplitLayout.rows(for: 5), [3, 2])
        XCTAssertEqual(SplitLayout.rows(for: 6), [3, 3])
        XCTAssertEqual(SplitLayout.rows(for: 7), [4, 3])
        XCTAssertEqual(SplitLayout.rows(for: 8), [4, 4])
        XCTAssertEqual(SplitLayout.rows(for: 12), [4, 4], "never more than the cap")
    }

    func testRowRangesCoverEveryPaneInOrder() {
        XCTAssertEqual(SplitLayout.rowRanges(for: 5), [0..<3, 3..<5])
        XCTAssertEqual(SplitLayout.rowRanges(for: 2), [0..<2])
        XCTAssertEqual(SplitLayout.rowRanges(for: 1), [])
        XCTAssertEqual(SplitLayout.rowRanges(for: 12), [0..<4, 4..<8], "never more than the cap")
    }

    func testAJoiningTerminalGoesBeforeOnLeftOrTopAndAfterOnRightOrBottom() {
        XCTAssertEqual(SplitLayout.insertionIndex(droppingOn: 1, edge: .left, movingFrom: nil), 1)
        XCTAssertEqual(SplitLayout.insertionIndex(droppingOn: 1, edge: .top, movingFrom: nil), 1)
        XCTAssertEqual(SplitLayout.insertionIndex(droppingOn: 1, edge: .right, movingFrom: nil), 2)
        XCTAssertEqual(SplitLayout.insertionIndex(droppingOn: 1, edge: .bottom, movingFrom: nil), 2)
    }

    /// A member being moved leaves the list first, so a target after it shifts down by one.
    func testAMovedMemberCountsAsRemovedFirst() {
        XCTAssertEqual(SplitLayout.insertionIndex(droppingOn: 3, edge: .right, movingFrom: 0), 3)
        XCTAssertEqual(SplitLayout.insertionIndex(droppingOn: 3, edge: .left, movingFrom: 0), 2)
        XCTAssertEqual(SplitLayout.insertionIndex(droppingOn: 0, edge: .left, movingFrom: 3), 0)
        XCTAssertEqual(SplitLayout.insertionIndex(droppingOn: 2, edge: .right, movingFrom: 2), 2)
        XCTAssertEqual(SplitLayout.insertionIndex(droppingOn: 2, edge: .left, movingFrom: 2), 2)
    }

    /// The edge nearest the pointer, relative to the pane's size; y grows downward.
    func testTheNearestEdgeWins() {
        let size = CGSize(width: 400, height: 200)
        XCTAssertEqual(SplitLayout.edge(at: CGPoint(x: 10, y: 100), in: size), .left)
        XCTAssertEqual(SplitLayout.edge(at: CGPoint(x: 390, y: 100), in: size), .right)
        XCTAssertEqual(SplitLayout.edge(at: CGPoint(x: 200, y: 5), in: size), .top)
        XCTAssertEqual(SplitLayout.edge(at: CGPoint(x: 200, y: 195), in: size), .bottom)
        XCTAssertEqual(SplitLayout.edge(at: CGPoint(x: 100, y: 100), in: size), .left, "a quarter across is nearer the side than the middle row is to top or bottom")
        XCTAssertEqual(SplitLayout.edge(at: CGPoint(x: 100, y: 60), in: size), .left, "measured as a fraction of each side: 100/400 = 0.25 from the left beats 60/200 = 0.30 from the top; raw pixels would say top")
    }
}

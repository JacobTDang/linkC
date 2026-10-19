import XCTest
@testable import LinkCKit

final class SplitSizesTests: XCTestCase {
    private let accuracy = 1e-9

    func testAnEvenGridSharesEachRowAndTheRowsEqually() {
        for count in 2...SplitLayout.maxPanes {
            let sizes = SplitSizes.even(for: count)
            let layout = SplitLayout.rows(for: count)
            XCTAssertEqual(sizes.paneCount, count)
            XCTAssertEqual(sizes.rows, Array(repeating: 1 / Double(layout.count), count: layout.count), "\(count) panes")
            XCTAssertEqual(sizes.columns, layout.map { Array(repeating: 1 / Double($0), count: $0) }, "\(count) panes")
        }
    }

    /// Six panes are two rows of three; a 900 pt row gives each pane 300 pt.
    func testAColumnDragMovesOnlyItsTwoPanes() {
        let sizes = SplitSizes.even(for: 6)
        let wider = sizes.resizingColumns(inRow: 0, divider: 0, by: 90, rowWidth: 900)
        XCTAssertEqual(wider.columns[0][0] * 900, 390, accuracy: accuracy)
        XCTAssertEqual(wider.columns[0][1] * 900, 210, accuracy: accuracy)
        XCTAssertEqual(wider.columns[0][2], sizes.columns[0][2])
        XCTAssertEqual(wider.columns[1], sizes.columns[1])
        XCTAssertEqual(wider.rows, sizes.rows)
        XCTAssertEqual(wider.columns[0].reduce(0, +), 1, accuracy: accuracy)

        let narrower = sizes.resizingColumns(inRow: 1, divider: 1, by: -60, rowWidth: 900)
        XCTAssertEqual(narrower.columns[1][1] * 900, 240, accuracy: accuracy)
        XCTAssertEqual(narrower.columns[1][2] * 900, 360, accuracy: accuracy)
        XCTAssertEqual(narrower.columns[1][0], sizes.columns[1][0])
        XCTAssertEqual(narrower.columns[0], sizes.columns[0])
    }

    func testAColumnDragStopsAtTheMinimumWidth() {
        let sizes = SplitSizes.even(for: 2)
        let left = sizes.resizingColumns(inRow: 0, divider: 0, by: -500, rowWidth: 600)
        XCTAssertEqual(left.columns[0][0] * 600, SplitSizes.minPaneWidth, accuracy: accuracy)
        XCTAssertEqual(left.columns[0][1] * 600, 600 - SplitSizes.minPaneWidth, accuracy: accuracy)
        let right = sizes.resizingColumns(inRow: 0, divider: 0, by: 500, rowWidth: 600)
        XCTAssertEqual(right.columns[0][1] * 600, SplitSizes.minPaneWidth, accuracy: accuracy)
    }

    func testNothingMovesWhenTheRowIsTooNarrowForTwoMinimums() {
        let sizes = SplitSizes.even(for: 2)
        XCTAssertEqual(sizes.resizingColumns(inRow: 0, divider: 0, by: 40, rowWidth: 2 * SplitSizes.minPaneWidth - 1), sizes)
    }

    func testARowDragMovesTheBoundaryBetweenTheRows() {
        let sizes = SplitSizes.even(for: 4)
        let taller = sizes.resizingRows(by: 100, gridHeight: 600)
        XCTAssertEqual(taller.rows[0] * 600, 400, accuracy: accuracy)
        XCTAssertEqual(taller.rows[1] * 600, 200, accuracy: accuracy)
        XCTAssertEqual(taller.columns, sizes.columns)
    }

    func testARowDragStopsAtTheMinimumHeight() {
        let sizes = SplitSizes.even(for: 4)
        XCTAssertEqual(sizes.resizingRows(by: 1000, gridHeight: 600).rows[1] * 600, SplitSizes.minPaneHeight, accuracy: accuracy)
        XCTAssertEqual(sizes.resizingRows(by: -1000, gridHeight: 600).rows[0] * 600, SplitSizes.minPaneHeight, accuracy: accuracy)
        XCTAssertEqual(sizes.resizingRows(by: 10, gridHeight: 2 * SplitSizes.minPaneHeight - 1), sizes)
    }

    func testAOneRowGridHasNoRowsToResize() {
        let sizes = SplitSizes.even(for: 2)
        XCTAssertEqual(sizes.resizingRows(by: 100, gridHeight: 600), sizes)
    }

    /// Five panes are a row of three over a row of two.
    func testEveningARowLeavesTheOtherRowAndTheHeights() {
        let resized = SplitSizes.even(for: 5)
            .resizingColumns(inRow: 0, divider: 1, by: 50, rowWidth: 900)
            .resizingColumns(inRow: 1, divider: 0, by: 50, rowWidth: 900)
            .resizingRows(by: 50, gridHeight: 600)
        let evened = resized.evenedRow(0)
        XCTAssertEqual(evened.columns[0], SplitSizes.even(for: 5).columns[0])
        XCTAssertEqual(evened.columns[1], resized.columns[1])
        XCTAssertEqual(evened.rows, resized.rows)
    }

    func testEveningTheRowsLeavesTheColumns() {
        let resized = SplitSizes.even(for: 4)
            .resizingColumns(inRow: 1, divider: 0, by: 50, rowWidth: 900)
            .resizingRows(by: 50, gridHeight: 600)
        let evened = resized.evenedRows()
        XCTAssertEqual(evened.rows, SplitSizes.even(for: 4).rows)
        XCTAssertEqual(evened.columns, resized.columns)
    }

    func testSizesFitOnlyTheirOwnPaneCount() {
        let sizes = SplitSizes.even(for: 5)
        XCTAssertTrue(sizes.fits(paneCount: 5))
        XCTAssertFalse(sizes.fits(paneCount: 4))
        XCTAssertFalse(sizes.fits(paneCount: 6))
    }

    func testPaneSpaceIsTheLengthLessTheGaps() {
        XCTAssertEqual(SplitSizes.paneSpace(906, count: 3, gap: 6), 894)
        XCTAssertEqual(SplitSizes.paneSpace(300, count: 1, gap: 6), 300)
        XCTAssertEqual(SplitSizes.paneSpace(4, count: 3, gap: 6), 0, "never negative")
    }

    // MARK: - Stored sizes

    func testSizesRoundTrip() throws {
        let sizes = SplitSizes.even(for: 5)
            .resizingColumns(inRow: 0, divider: 0, by: 40, rowWidth: 900)
            .resizingRows(by: -30, gridHeight: 600)
        XCTAssertEqual(try JSONDecoder().decode(SplitSizes.self, from: JSONEncoder().encode(sizes)), sizes)
    }

    private func decode(_ json: String) throws -> SplitSizes {
        try JSONDecoder().decode(SplitSizes.self, from: Data(json.utf8))
    }

    func testStoredSizesThatDoNotDescribeTheirGridAreRefused() {
        let bad = [
            #"{"paneCount":3,"rows":[1],"columns":[[0.5,0.5]]}"#,                      // one row where three panes make two
            #"{"paneCount":3,"rows":[0.5,0.5],"columns":[[0.5,0.5],[0.5,0.5]]}"#,      // the second row holds one pane, not two
            #"{"paneCount":2,"rows":[1],"columns":[[1.2,-0.2]]}"#,                      // a share that is not positive
            #"{"paneCount":2,"rows":[1],"columns":[[0,1]]}"#,                           // a share of nothing
            #"{"paneCount":2,"rows":[1],"columns":[[0.6,0.6]]}"#,                       // shares adding up to 1.2
            #"{"paneCount":1,"rows":[],"columns":[]}"#,                                 // no grid
            #"{"paneCount":9,"rows":[0.5,0.5],"columns":[[0.25,0.25,0.25,0.25],[0.25,0.25,0.25,0.25]]}"#,  // more than the most panes
        ]
        for json in bad {
            XCTAssertThrowsError(try decode(json), json)
        }
    }

    func testStoredSharesWithinTheToleranceAreRead() throws {
        let sizes = try decode(#"{"paneCount":3,"rows":[0.4,0.6005],"columns":[[0.3335,0.667],[1]]}"#)
        XCTAssertEqual(sizes.paneCount, 3)
        XCTAssertEqual(sizes.rows, [0.4, 0.6005])
        XCTAssertEqual(sizes.columns, [[0.3335, 0.667], [1]])
    }
}

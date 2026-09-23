import XCTest
@testable import LinkCKit

final class WorkbenchLayoutTests: XCTestCase {
    private func component(_ name: String, at: GridPoint? = nil) -> SystemComponent {
        SystemComponent(name: name, kind: .service, at: at)
    }

    func testAPositionedComponentKeepsItsPlace() {
        let positions = WorkbenchLayout.positions(for: [component("api", at: GridPoint(x: 3, y: 1))])
        XCTAssertEqual(positions["api"], GridPoint(x: 3, y: 1))
    }

    /// Two machines opening the same unpositioned map must draw the same board.
    func testUnpositionedComponentsFillTheGridInNameOrder() {
        let names = ["worker", "api", "postgres"]
        let positions = WorkbenchLayout.positions(for: names.map { component($0) })
        XCTAssertEqual(positions["api"], GridPoint(x: 0, y: 0))
        XCTAssertEqual(positions["postgres"], GridPoint(x: 1, y: 0))
        XCTAssertEqual(positions["worker"], GridPoint(x: 2, y: 0))

        let shuffled = WorkbenchLayout.positions(for: names.reversed().map { component($0) })
        XCTAssertEqual(positions, shuffled, "order in the file must not change the layout")
    }

    func testTheGridWrapsAfterItsColumns() {
        let names = (1...(WorkbenchLayout.columns + 2)).map { String(format: "c%02d", $0) }
        let positions = WorkbenchLayout.positions(for: names.map { component($0) })
        XCTAssertEqual(positions[names[WorkbenchLayout.columns]], GridPoint(x: 0, y: 1))
        XCTAssertEqual(positions[names[WorkbenchLayout.columns + 1]], GridPoint(x: 1, y: 1))
    }

    /// A free cell is one no positioned tile already holds.
    func testAnUnpositionedComponentNeverLandsOnAPositionedOne() {
        let positions = WorkbenchLayout.positions(for: [
            component("pinned", at: GridPoint(x: 0, y: 0)),
            component("floating"),
        ])
        XCTAssertEqual(positions["pinned"], GridPoint(x: 0, y: 0))
        XCTAssertEqual(positions["floating"], GridPoint(x: 1, y: 0))
    }

    func testAnEmptyMapLaysOutToNothing() {
        XCTAssertTrue(WorkbenchLayout.positions(for: []).isEmpty)
    }

    /// A negative cell never collides with an auto-filled one — those are always >= 0 — so it
    /// must be honoured exactly like any other position.
    func testANegativePositionIsKept() {
        let positions = WorkbenchLayout.positions(for: [component("offboard", at: GridPoint(x: -1, y: -2))])
        XCTAssertEqual(positions["offboard"], GridPoint(x: -1, y: -2))
    }

    /// When two components claim the same cell, the first in name order keeps it and the other
    /// falls back to the same free-cell rule the unpositioned components use.
    func testTwoComponentsClaimingTheSameCellGiveItToTheFirstByName() {
        let positions = WorkbenchLayout.positions(for: [
            component("apple", at: GridPoint(x: 0, y: 0)),
            component("banana", at: GridPoint(x: 0, y: 0)),
        ])
        XCTAssertEqual(positions["apple"], GridPoint(x: 0, y: 0))
        XCTAssertEqual(positions["banana"], GridPoint(x: 1, y: 0))
    }

    /// The same file, listed in the opposite order, must lay out identically — the outcome is
    /// decided by name order, never by position in the file.
    func testTwoComponentsClaimingTheSameCellInReverseFileOrderIsIdentical() {
        let positions = WorkbenchLayout.positions(for: [
            component("banana", at: GridPoint(x: 0, y: 0)),
            component("apple", at: GridPoint(x: 0, y: 0)),
        ])
        XCTAssertEqual(positions["apple"], GridPoint(x: 0, y: 0))
        XCTAssertEqual(positions["banana"], GridPoint(x: 1, y: 0))
    }
}

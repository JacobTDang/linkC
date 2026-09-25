import XCTest
@testable import LinkCKit

final class BoardFocusTests: XCTestCase {
    private func map() -> BoardMap {
        var m = BoardMap()
        m.components = [
            BoardComponent(name: "A", kind: .service, uses: ["B": "calls"]),
            BoardComponent(name: "B", kind: .service, uses: ["C": "calls"]),
            BoardComponent(name: "C", kind: .service),
            BoardComponent(name: "D", kind: .service, uses: ["B": "reads"]),
            BoardComponent(name: "E", kind: .service, uses: ["C": "writes"]),
        ]
        return m
    }

    func testAPartKeepsItselfAndItsDirectNeighboursBothWays() throws {
        let visible = try XCTUnwrap(BoardFocus.visible(aroundPart: "B", in: map()))
        XCTAssertEqual(visible.parts, ["A", "B", "C", "D"])
        XCTAssertEqual(visible.arrows, [.init(from: "A", to: "B"), .init(from: "B", to: "C"), .init(from: "D", to: "B")])
    }

    func testAnArrowKeepsOnlyItsTwoEnds() throws {
        let visible = try XCTUnwrap(BoardFocus.visible(aroundArrow: .init(from: "E", to: "C"), in: map()))
        XCTAssertEqual(visible.parts, ["E", "C"])
        XCTAssertEqual(visible.arrows, [.init(from: "E", to: "C")])
    }

    /// A part or arrow that's gone — deleted, undone, or removed by an agent — has nothing to
    /// focus around, so Focus hides nothing rather than everything.
    func testAGoneItemHasNoFocus() {
        XCTAssertNil(BoardFocus.visible(aroundPart: "Z", in: map()))
        XCTAssertNil(BoardFocus.visible(aroundArrow: .init(from: "A", to: "C"), in: map()))
        XCTAssertNil(BoardFocus.visible(aroundArrow: .init(from: "Z", to: "B"), in: map()))
    }
}

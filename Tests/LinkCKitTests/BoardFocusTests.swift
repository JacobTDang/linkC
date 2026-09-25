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

    func testAPartKeepsItselfAndItsDirectNeighboursBothWays() {
        let visible = BoardFocus.visible(aroundPart: "B", in: map())
        XCTAssertEqual(visible.parts, ["A", "B", "C", "D"])
        XCTAssertEqual(visible.arrows, [.init(from: "A", to: "B"), .init(from: "B", to: "C"), .init(from: "D", to: "B")])
    }

    func testAnArrowKeepsOnlyItsTwoEnds() {
        let visible = BoardFocus.visible(aroundArrow: .init(from: "E", to: "C"), in: map())
        XCTAssertEqual(visible.parts, ["E", "C"])
        XCTAssertEqual(visible.arrows, [.init(from: "E", to: "C")])
    }
}

import XCTest
@testable import LinkCKit

final class BoardHitTestTests: XCTestCase {
    private let routes: [BoardModel.ArrowKey: BoardRoute] = [
        .init(from: "a", to: "b"): BoardRoute(points: [BoardPoint(x: 0, y: 0), BoardPoint(x: 100, y: 0)], bundle: nil),
        .init(from: "c", to: "d"): BoardRoute(points: [BoardPoint(x: 0, y: 10), BoardPoint(x: 100, y: 10)], bundle: nil),
        .init(from: "e", to: "f"): BoardRoute(points: [BoardPoint(x: 50, y: -50), BoardPoint(x: 50, y: 50)], bundle: nil),
    ]

    func testTheNearestArrowWithinTheToleranceWins() {
        XCTAssertEqual(BoardHitTest.arrow(atX: 20, y: 3, routes: routes, tolerance: 6), .init(from: "a", to: "b"))
        XCTAssertEqual(BoardHitTest.arrow(atX: 20, y: 7, routes: routes, tolerance: 6), .init(from: "c", to: "d"))
    }

    func testNothingBeyondTheTolerance() {
        XCTAssertNil(BoardHitTest.arrow(atX: 20, y: 30, routes: routes, tolerance: 6))
    }

    func testATieBreaksByTheArrowKey() {
        // (50, 5) is 5 from a→b, 5 from c→d and 0 from e→f. e→f is nearest.
        XCTAssertEqual(BoardHitTest.arrow(atX: 50, y: 5, routes: routes, tolerance: 6), .init(from: "e", to: "f"))
        // (20, 5) is exactly 5 from a→b and from c→d. The key order picks a→b.
        XCTAssertEqual(BoardHitTest.arrow(atX: 20, y: 5, routes: routes, tolerance: 6), .init(from: "a", to: "b"))
    }

    func testTheFilterExcludesArrows() {
        XCTAssertEqual(BoardHitTest.arrow(atX: 20, y: 3, routes: routes, tolerance: 7,
                                          including: { $0.from != "a" }), .init(from: "c", to: "d"))
    }

    func testPickPrefersArrowOverComponent() {
        let arrow = BoardModel.ArrowKey(from: "a", to: "b")
        XCTAssertEqual(BoardHitTest.pick(arrow: arrow, component: "Mux"), .arrow(arrow))
        XCTAssertEqual(BoardHitTest.pick(arrow: nil, component: "Mux"), .component("Mux"))
        XCTAssertNil(BoardHitTest.pick(arrow: nil, component: nil))
    }
}

import XCTest
@testable import LinkCKit

final class BoardLensTests: XCTestCase {
    func testEachLensKeepsItsStyles() {
        XCTAssertTrue(BoardArrowStyle.allCases.allSatisfy { BoardLens.all.includes($0) })
        XCTAssertEqual(BoardArrowStyle.allCases.filter { BoardLens.data.includes($0) }, [.plain, .bus])
        XCTAssertEqual(BoardArrowStyle.allCases.filter { BoardLens.control.includes($0) }, [.conditional, .control])
    }

    func testAViewportSavedBeforeLensesDecodesAsAll() throws {
        let saved = #"{"originX": 10, "originY": -20, "zoom": 0.5}"#
        let viewport = try JSONDecoder().decode(BoardViewport.self, from: Data(saved.utf8))
        XCTAssertEqual(viewport.lens, .all)
        XCTAssertEqual(viewport.zoom, 0.5)
    }

    func testTheLensRoundTrips() throws {
        let viewport = BoardViewport(originX: 1, originY: 2, zoom: 1, lens: .control)
        let decoded = try JSONDecoder().decode(BoardViewport.self, from: JSONEncoder().encode(viewport))
        XCTAssertEqual(decoded, viewport)
    }
}

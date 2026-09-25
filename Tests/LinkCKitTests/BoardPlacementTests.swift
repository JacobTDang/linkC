import XCTest
@testable import LinkCKit

/// The Board's placement rules, called the way the MCP tool calls them: off the main actor.
final class BoardPlacementTests: XCTestCase {
    private func rects(_ map: BoardMap) -> [BoardRect] {
        map.components.compactMap { $0.at.map(BoardGeometry.rect(ofComponentAt:)) }
            + map.notes.compactMap { $0.at.map(BoardGeometry.rect(ofNoteAt:)) }
    }

    private func assertNoOverlaps(_ map: BoardMap, file: StaticString = #filePath, line: UInt = #line) {
        let all = rects(map)
        for i in all.indices { for j in all.indices where j > i {
            XCTAssertFalse(all[i].intersects(all[j]), "\(all[i]) overlaps \(all[j])", file: file, line: line)
        } }
    }

    func testAComponentPlacedInAFrameLandsInsideItClearOfItsNotes() throws {
        var map = BoardMap()
        map.frames = [BoardFrame(label: "Local docker", rect: BoardRect(x: 0, y: 0, w: 344, h: 200))]
        map.notes = [BoardNote(text: "keep", at: BoardPoint(x: 8, y: 8))]
        let placed = BoardModel.placeComponent(BoardComponent(name: "redis", kind: .cache), inFrame: "Local docker", into: &map)
        XCTAssertTrue(placed)
        let redis = try XCTUnwrap(map.components.first)
        XCTAssertEqual(redis.place, "Local docker")
        let frame = try XCTUnwrap(map.frames.first?.rect)
        XCTAssertTrue(BoardGeometry.interior(of: frame).contains(BoardGeometry.rect(ofComponentAt: try XCTUnwrap(redis.at))))
        assertNoOverlaps(map)
    }

    func testAFullFrameGrowsToTakeTheComponent() throws {
        var map = BoardMap()
        map.frames = [BoardFrame(label: "Tight", rect: BoardRect(x: 0, y: 0, w: 192, h: 100))]
        map.components = [BoardComponent(name: "a", kind: .service, place: "Tight", at: BoardPoint(x: 8, y: 8))]
        XCTAssertTrue(BoardModel.placeComponent(BoardComponent(name: "b", kind: .service), inFrame: "Tight", into: &map))
        let frame = try XCTUnwrap(map.frames.first?.rect)
        XCTAssertGreaterThan(frame.w * frame.h, 192 * 100, "the frame grew")
        XCTAssertEqual(map.components.map(\.place), ["Tight", "Tight"])
        assertNoOverlaps(map)
    }

    func testANewFrameAndALooseComponentGoToTheRightOfEverything() throws {
        var map = BoardMap()
        map.components = [BoardComponent(name: "api", kind: .service, at: BoardPoint(x: 400, y: 0))]
        BoardModel.appendFrame(label: "Oracle box", size: BoardGeometry.frameMinSize, into: &map)
        let frame = try XCTUnwrap(map.frames.first?.rect)
        XCTAssertGreaterThanOrEqual(frame.x, 400 + BoardGeometry.componentSize.x)
        BoardModel.placeLoose(BoardComponent(name: "cdn", kind: .external), into: &map)
        let cdn = try XCTUnwrap(map.components.last?.at)
        XCTAssertGreaterThanOrEqual(cdn.x, frame.maxX)
        XCTAssertEqual(map.components.last?.place, BoardMap.notPlaced)
        assertNoOverlaps(map)
    }
    func testPlacementFindsAFreeSpotForATallTable() throws {
        var map = BoardMap()
        map.frames = [BoardFrame(label: "Schema", rect: BoardRect(x: 0, y: 0, w: 400, h: 120))]
        map.components = [BoardComponent(name: "existing", kind: .service, place: "Schema", at: BoardPoint(x: 8, y: 8))]
        let table = BoardComponent(name: "accounts", kind: .table, columns: (1...10).map { BoardColumn(name: "c\($0)", type: "int") })
        XCTAssertTrue(BoardModel.placeComponent(table, inFrame: "Schema", into: &map))
        let placed = try XCTUnwrap(map.components.last)
        let placedRect = try XCTUnwrap(BoardGeometry.rect(of: placed))
        XCTAssertEqual(placedRect.w, 176)
        XCTAssertEqual(placedRect.h, 264, "the table's own height, not the fixed 84")
        let existingRect = try XCTUnwrap(BoardGeometry.rect(of: map.components[0]))
        XCTAssertFalse(placedRect.intersects(existingRect))
        let frame = try XCTUnwrap(map.frames.first?.rect)
        XCTAssertTrue(BoardGeometry.interior(of: frame).contains(placedRect), "the frame grew to fit the table's real height")
    }
}

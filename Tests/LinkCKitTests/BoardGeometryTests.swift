import XCTest
@testable import LinkCKit

final class BoardGeometryTests: XCTestCase {
    private func box(_ x: Int, _ y: Int, _ w: Int = 16, _ h: Int = 16) -> BoardRect { BoardRect(x: x, y: y, w: w, h: h) }

    func testElementSizes() {
        XCTAssertEqual(BoardGeometry.rect(ofComponentAt: BoardPoint(x: 8, y: 16)), BoardRect(x: 8, y: 16, w: 176, h: 84))
        XCTAssertEqual(BoardGeometry.rect(ofNoteAt: BoardPoint(x: 0, y: 0)), BoardRect(x: 0, y: 0, w: 176, h: 120))
        let title = BoardText(text: "June", style: .title, at: BoardPoint(x: 0, y: 0), width: 64)
        XCTAssertEqual(BoardGeometry.rect(of: title), BoardRect(x: 0, y: 0, w: 64, h: 32))
    }

    func testAFrameHoldsWhatItsCentreIsIn() {
        let frames = [BoardFrame(label: "Docker", rect: box(0, 0, 400, 200)), BoardFrame(label: "Oracle", rect: box(500, 0, 200, 200))]
        XCTAssertEqual(BoardGeometry.frame(containing: box(380, 90, 152, 56), frames: frames)?.label, nil,
                       "centre at x 456 is outside both")
        XCTAssertEqual(BoardGeometry.frame(containing: box(300, 90, 152, 56), frames: frames)?.label, "Docker")
        XCTAssertNil(BoardGeometry.frame(containing: box(0, 0), frames: [BoardFrame(label: "No rect")]))
    }

    func testAFreeSpotIsLeftAlone() {
        XCTAssertEqual(BoardGeometry.nearestFreeSpot(for: box(40, 40), avoiding: [box(0, 0)]), box(40, 40))
    }

    /// On a tie the order is right, then down, then left, then up — the same answer every time.
    func testTiesBreakRightDownLeftUp() {
        let obstacle = box(0, 0)
        XCTAssertEqual(BoardGeometry.nearestFreeSpot(for: box(0, 0), avoiding: [obstacle]), box(16, 0))
        XCTAssertEqual(BoardGeometry.nearestFreeSpot(for: box(0, 0), avoiding: [obstacle, box(16, 0)]), box(0, 16))
        XCTAssertEqual(BoardGeometry.nearestFreeSpot(for: box(0, 0), avoiding: [obstacle, box(16, 0), box(0, 16)]), box(-16, 0))
        XCTAssertEqual(BoardGeometry.nearestFreeSpot(for: box(0, 0), avoiding: [obstacle, box(16, 0), box(0, 16), box(-16, 0)]), box(0, -16))
    }

    func testTheSmallestMoveWinsOverDirection() {
        // Moving down 56 beats moving right 152.
        let component = BoardRect(x: 0, y: 0, w: 152, h: 56)
        XCTAssertEqual(BoardGeometry.nearestFreeSpot(for: component, avoiding: [component]), BoardRect(x: 0, y: 56, w: 152, h: 56))
    }

    func testAnElementDroppedInAFrameStaysWhollyInside() throws {
        let frame = box(0, 0, 320, 160)
        let dropped = BoardRect(x: 200, y: 20, w: 152, h: 56)   // centre (276, 48) is inside; right edge sticks out
        let placed = BoardGeometry.elementDrop(dropped, otherElements: [], frames: [frame])
        XCTAssertTrue(BoardGeometry.interior(of: frame).contains(placed), "\(placed)")
    }

    func testAnElementDroppedAcrossAnEdgeWithItsCentreOutsideGoesWhollyOutside() {
        let frame = box(0, 0, 320, 160)
        let dropped = BoardRect(x: 300, y: 20, w: 152, h: 56)   // centre (376, 48) is outside
        let placed = BoardGeometry.elementDrop(dropped, otherElements: [], frames: [frame])
        XCTAssertFalse(placed.intersects(frame), "\(placed)")
    }

    func testAFullFrameSendsTheElementOutside() {
        let frame = box(0, 0, 168, 72)      // interior fits exactly one component
        let resident = BoardRect(x: 8, y: 8, w: 152, h: 56)
        let placed = BoardGeometry.elementDrop(BoardRect(x: 8, y: 8, w: 152, h: 56), otherElements: [resident], frames: [frame])
        XCTAssertFalse(placed.intersects(frame))
        XCTAssertFalse(placed.intersects(resident))
    }

    func testAFrameNeverLandsOnAnotherFrameOrSomethingNotItsOwn() {
        let other = box(0, 0, 200, 200)
        let stranger = box(260, 0, 152, 56)
        let placed = BoardGeometry.frameDrop(box(100, 0, 200, 200), otherFrames: [other], foreignElements: [stranger])
        XCTAssertFalse(placed.intersects(other))
        XCTAssertFalse(placed.intersects(stranger))
    }

    func testAResizeNeverShrinksPastItsMembersOrGrowsOverAnything() {
        let original = box(0, 0, 400, 200)
        let member = BoardRect(x: 200, y: 100, w: 152, h: 56)
        let shrunk = BoardGeometry.frameResize(box(0, 0, 100, 100), original: original, members: [member], otherFrames: [], foreignElements: [])
        XCTAssertTrue(BoardGeometry.interior(of: shrunk).contains(member), "\(shrunk)")

        let neighbour = box(480, 0, 100, 100)
        let grown = BoardGeometry.frameResize(box(0, 0, 600, 200), original: original, members: [], otherFrames: [neighbour], foreignElements: [])
        XCTAssertFalse(grown.intersects(neighbour), "\(grown)")
        XCTAssertGreaterThanOrEqual(grown.w, 400, "it grows up to the neighbour")
    }

    func testAFrameGrowsDownToFitOneMore() throws {
        let frame = box(0, 0, 192, 100)
        let resident = BoardRect(x: 8, y: 8, w: 176, h: 84)
        let grown = try XCTUnwrap(BoardGeometry.grow(frame, toFit: BoardGeometry.componentSize, members: [resident], otherFrames: [], foreignElements: []))
        XCTAssertEqual(grown.x, 0)
        XCTAssertEqual(grown.w, 192)
        XCTAssertGreaterThan(grown.h, 100)
        XCTAssertNil(BoardGeometry.grow(frame, toFit: BoardGeometry.componentSize, members: [resident], otherFrames: [box(0, 100, 192, 400)], foreignElements: []),
                     "a frame hemmed in below cannot grow")
    }

    func testOnlyWhatIsOnScreenIsKept() {
        let rects = [box(0, 0), box(900, 900), box(100, 100)]
        XCTAssertEqual(BoardGeometry.visibleIndices(of: rects, in: box(0, 0, 200, 200)), [0, 2])
    }

    /// The budget: 200 drops on a 200-component board, well under a second even in a debug build.
    func testTwoHundredComponentsStayFast() {
        var placed: [BoardRect] = []
        for index in 0..<200 {
            placed.append(BoardRect(x: (index % 20) * 168, y: (index / 20) * 72, w: 152, h: 56))
        }
        let start = Date()
        for index in 0..<200 {
            _ = BoardGeometry.elementDrop(placed[index].offsetBy(dx: 40, dy: 40),
                                          otherElements: placed.enumerated().filter { $0.offset != index }.map(\.element),
                                          frames: [])
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }

    /// When the board is crowded and the nearest free spot is far away, the search must
    /// stay fast even when examining many rings — only the ring's edge matters.
    /// The needle is in the middle of a 40×40 obstacle grid, so the search must traverse ~20 rings
    /// in all directions before finding free space outside the entire block.
    func testASearchThatFindsNothingNearbyStaysFast() {
        var obstacles: [BoardRect] = []
        for row in 0..<40 {
            for col in 0..<40 {
                obstacles.append(box(col * 16, row * 16))
            }
        }

        let needle = box(320, 320)  // Middle of the obstacle grid; free spot must be ~20 rings away
        let start = Date()
        let result = BoardGeometry.nearestFreeSpot(for: needle, avoiding: obstacles)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertNotNil(result, "should find a spot")
        XCTAssertTrue(obstacles.allSatisfy { !$0.intersects(result!) }, "spot should overlap no obstacles")
        // Grid spans (0,0) to (640,640); result must be outside.
        let outside = result!.minX < 0 || result!.minY < 0 || result!.minX >= 640 || result!.minY >= 640
        XCTAssertTrue(outside, "spot at \(result!) must be outside grid bounds [0,640)×[0,640)")
        XCTAssertLessThan(elapsed, 0.5, "search should complete in under 500ms, took \(elapsed)s")
    }
    func testATablesSizeComesFromItsColumns() {
        XCTAssertEqual(BoardGeometry.size(of: BoardComponent(name: "t", kind: .table)), BoardPoint(x: 176, y: 72))
        let profiles = BoardComponent(name: "profiles", kind: .table, columns: [
            BoardColumn(name: "id", type: "uuid", pk: true, references: BoardColumnReference(table: "auth.users", column: "id")),
            BoardColumn(name: "handle", type: "character varying(40)", nullable: false, unique: true),
            BoardColumn(name: "status", type: "text"),
            BoardColumn(name: "avatar_url", type: "text", planned: true),
        ])
        XCTAssertEqual(BoardGeometry.size(of: profiles), BoardPoint(x: 272, y: 136))
        let tall = BoardComponent(name: "wide", kind: .table, columns: (1...10).map { BoardColumn(name: "c\($0)", type: "int") })
        XCTAssertEqual(BoardGeometry.size(of: tall), BoardPoint(x: 176, y: 264), "the floor wins on width; height grows with rows")
        XCTAssertEqual(BoardGeometry.size(of: BoardComponent(name: "api", kind: .service)), BoardGeometry.componentSize)
    }

    func testATablesRectComesFromItsOwnPositionAndSize() {
        var table = BoardComponent(name: "t", kind: .table, at: BoardPoint(x: 40, y: 40))
        XCTAssertEqual(BoardGeometry.rect(of: table), BoardRect(x: 40, y: 40, w: 176, h: 72))
        table.at = nil
        XCTAssertNil(BoardGeometry.rect(of: table), "not placed yet")
    }
}

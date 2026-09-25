import XCTest
@testable import LinkCKit

final class BoardLabelsTests: XCTestCase {
    private func arranged() throws -> BoardMap {
        BoardLayout.arranged(try BoardMap.decode(Data("""
        { "version": 2, "places": {
          "App": { "api": {"kind":"service","uses":{"db":"reads and writes","cache":"session cache","jobs":"enqueues"}},
                   "hub": {"kind":"service","uses":{"w1":"hosts","w2":"hosts","w3":"hosts"}} },
          "Data": { "db": {"kind":"database"}, "cache": {"kind":"cache"}, "jobs": {"kind":"queue"} },
          "Workers": { "w1": {"kind":"service"}, "w2": {"kind":"service"}, "w3": {"kind":"service"} },
          "Not placed": {} } }
        """.utf8)))
    }

    private func labels(_ m: BoardMap) -> [BoardModel.ArrowKey: String] {
        var out: [BoardModel.ArrowKey: String] = [:]
        for c in m.components { for (t, arrow) in c.uses where !arrow.label.isEmpty { out[BoardModel.ArrowKey(from: c.name, to: t)] = arrow.label } }
        return out
    }

    func testNoPillOverlapsABoxAFrameTitleOrAnotherPill() throws {
        let m = try arranged()
        let obstacles = BoardLabels.obstacles(for: m)
        let placed = BoardLabels.placed(routes: BoardRouter.routes(for: m), labels: labels(m), obstacles: obstacles)
        XCTAssertFalse(placed.isEmpty)
        let pills = Array(placed.values)
        for p in pills { for o in obstacles { XCTAssertFalse(p.intersects(o)) } }
        for i in pills.indices { for j in pills.indices where j > i { XCTAssertFalse(pills[i].intersects(pills[j])) } }
    }

    func testABundleIsLabelledOnce() throws {
        let m = try arranged()
        let placed = BoardLabels.placed(routes: BoardRouter.routes(for: m), labels: labels(m), obstacles: BoardLabels.obstacles(for: m))
        XCTAssertEqual(placed.keys.filter { $0.from == "hub" }.count, 1)
    }

    func testNoRoomMeansNotPlaced() {
        var m = BoardMap()
        m.components = [BoardComponent(name: "a", kind: .service, uses: ["b": "a label far too long to fit in this gap"], at: BoardPoint(x: 0, y: 0)),
                        BoardComponent(name: "b", kind: .service, at: BoardPoint(x: 200, y: 0))]
        let placed = BoardLabels.placed(routes: BoardRouter.routes(for: m), labels: labels(m), obstacles: BoardLabels.obstacles(for: m))
        XCTAssertTrue(placed.isEmpty)
    }

    func testTheSameInputPlacesTheSameWay() throws {
        let m = try arranged()
        let routes = BoardRouter.routes(for: m)
        XCTAssertEqual(BoardLabels.placed(routes: routes, labels: labels(m), obstacles: BoardLabels.obstacles(for: m)),
                       BoardLabels.placed(routes: routes, labels: labels(m), obstacles: BoardLabels.obstacles(for: m)))
    }

    func testThePillCarriesTheWidth() {
        XCTAssertEqual(BoardLabels.pillText(for: BoardArrow(label: "rs1 data", style: .bus, bits: 32)), "rs1 data  32")
        XCTAssertEqual(BoardLabels.pillText(for: BoardArrow(label: "", style: .bus, bits: 32)), "32")
        XCTAssertEqual(BoardLabels.pillText(for: BoardArrow(label: "RegWrite", style: .control)), "RegWrite")
        XCTAssertNil(BoardLabels.pillText(for: BoardArrow(label: "", style: .plain)))
    }

    func testAnUnlabelledBusGetsAPlacedPill() throws {
        var m = BoardMap()
        m.components = [BoardComponent(name: "a", kind: .register, uses: ["b": BoardArrow(label: "", style: .bus, bits: 32)], at: BoardPoint(x: 0, y: 0)),
                        BoardComponent(name: "b", kind: .alu, at: BoardPoint(x: 500, y: 0))]
        let placed = try XCTUnwrap(BoardModel.routesAndLabels(for: m, isCancelled: { false }))
        let rect = try XCTUnwrap(placed.labelRects[.init(from: "a", to: "b")])
        XCTAssertEqual(rect.w, BoardLabels.width(of: "32"))
    }

    /// A width alone draws in bold, whose digits run about 7 pt each at 10 pt: "64" measures
    /// 13.9 pt, so its pill needs at least 28 pt with the 14 pt of padding.
    func testABoldWidthGetsRoomForItsDigits() {
        XCTAssertGreaterThanOrEqual(BoardLabels.width(of: "64"), 28)
        XCTAssertGreaterThanOrEqual(BoardLabels.width(of: "128"), 33)
    }
}

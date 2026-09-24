import XCTest
@testable import LinkCKit

final class BoardRouterTests: XCTestCase {
    private func segments(_ r: BoardRoute) -> [(BoardPoint, BoardPoint)] { Array(zip(r.points, r.points.dropFirst())) }

    /// A segment crosses a rect's interior (touching the border is allowed).
    private func crosses(_ a: BoardPoint, _ b: BoardPoint, _ r: BoardRect) -> Bool {
        let minX = min(a.x, b.x), maxX = max(a.x, b.x), minY = min(a.y, b.y), maxY = max(a.y, b.y)
        return minX < r.maxX && maxX > r.minX && minY < r.maxY && maxY > r.minY
            && (a.x == b.x ? (a.x > r.minX && a.x < r.maxX) : (a.y > r.minY && a.y < r.maxY))
    }

    private func arranged() throws -> BoardMap {
        BoardLayout.arranged(try BoardMap.decode(Data("""
        { "version": 2, "places": {
          "App": { "api": {"kind":"service","uses":{"db":"reads","cache":"reads","jobs":"enqueues"}}, "worker": {"kind":"service","uses":{"jobs":"consumes","db":"writes"}} },
          "Data": { "db": {"kind":"database"}, "cache": {"kind":"cache"}, "jobs": {"kind":"queue","uses":{"api":"callbacks"}} },
          "Not placed": {} } }
        """.utf8)))
    }

    func testNoRouteCrossesAComponentOrAForeignFrame() throws {
        let m = try arranged()
        let routes = BoardRouter.routes(for: m)
        XCTAssertEqual(routes.count, 6)
        for (key, route) in routes {
            for c in m.components where c.name != key.from && c.name != key.to {
                let box = BoardGeometry.rect(ofComponentAt: c.at!)
                for (a, b) in segments(route) { XCTAssertFalse(crosses(a, b, box), "\(key) crosses \(c.name)") }
            }
            let own = Set(m.components.filter { $0.name == key.from || $0.name == key.to }.map(\.place))
            for f in m.frames where !own.contains(f.label) {
                for (a, b) in segments(route) { XCTAssertFalse(crosses(a, b, f.rect!), "\(key) crosses frame \(f.label)") }
            }
            for (a, b) in segments(route) { XCTAssertTrue(a.x == b.x || a.y == b.y, "orthogonal") }
        }
    }

    func testSameRowNeighboursGetOneStraightSegment() {
        var m = BoardMap()
        m.components = [BoardComponent(name: "a", kind: .service, uses: ["b": "x"], at: BoardPoint(x: 0, y: 0)),
                        BoardComponent(name: "b", kind: .service, at: BoardPoint(x: 400, y: 0))]
        let route = BoardRouter.routes(for: m)[BoardModel.ArrowKey(from: "a", to: "b")]
        XCTAssertEqual(route?.points.count, 2)
    }

    func testABundleSharesItsPort() throws {
        var m = BoardMap()
        m.components = [BoardComponent(name: "hub", kind: .service, uses: ["a": "hosts", "b": "hosts", "c": "hosts"], at: BoardPoint(x: 0, y: 200)),
                        BoardComponent(name: "a", kind: .service, at: BoardPoint(x: 480, y: 0)),
                        BoardComponent(name: "b", kind: .service, at: BoardPoint(x: 480, y: 200)),
                        BoardComponent(name: "c", kind: .service, at: BoardPoint(x: 480, y: 400))]
        let routes = BoardRouter.routes(for: m)
        let firsts = Set(["a", "b", "c"].compactMap { routes[BoardModel.ArrowKey(from: "hub", to: $0)]?.points.first })
        XCTAssertEqual(firsts.count, 1, "one shared port")
        XCTAssertEqual(Set(["a", "b", "c"].compactMap { routes[BoardModel.ArrowKey(from: "hub", to: $0)]?.bundle }).count, 1)
    }

    func testParallelArrowsInOneCorridorGetSeparateLanes() {
        var m = BoardMap()
        m.components = [BoardComponent(name: "a1", kind: .service, uses: ["b1": "", "b2": ""], at: BoardPoint(x: 0, y: 0)),
                        BoardComponent(name: "a2", kind: .service, uses: ["b1": ""], at: BoardPoint(x: 0, y: 132)),
                        BoardComponent(name: "b1", kind: .service, at: BoardPoint(x: 600, y: 264)),
                        BoardComponent(name: "b2", kind: .service, at: BoardPoint(x: 600, y: 396))]
        let routes = BoardRouter.routes(for: m)
        var vertical: [Int: Int] = [:]
        for route in routes.values { for (a, b) in segments(route) where a.x == b.x && abs(a.y - b.y) > 40 { vertical[a.x, default: 0] += 1 } }
        XCTAssertTrue(vertical.values.allSatisfy { $0 == 1 }, "no two long vertical runs share an x: \(vertical)")
    }

    func testAHandDraggedOffGridBoardStillRoutesClear() {
        var m = BoardMap()
        m.components = [BoardComponent(name: "a", kind: .service, uses: ["d": ""], at: BoardPoint(x: 13, y: 7)),
                        BoardComponent(name: "wall1", kind: .service, at: BoardPoint(x: 230, y: -40)),
                        BoardComponent(name: "wall2", kind: .service, at: BoardPoint(x: 230, y: 60)),
                        BoardComponent(name: "d", kind: .service, at: BoardPoint(x: 470, y: 29))]
        let route = BoardRouter.routes(for: m)[BoardModel.ArrowKey(from: "a", to: "d")]!
        for wall in ["wall1", "wall2"] {
            let box = BoardGeometry.rect(ofComponentAt: m.components.first { $0.name == wall }!.at!)
            for (p, q) in segments(route) { XCTAssertFalse(crosses(p, q, box), wall) }
        }
    }

    func testTheSameMapRoutesTheSameWay() throws {
        let m = try arranged()
        XCTAssertEqual(BoardRouter.routes(for: m), BoardRouter.routes(for: m))
    }

    // MARK: - Frames are soft; boxes are hard

    /// Four frames form a closed ring — a courtyard with no gap — and the target sits in the
    /// hole in the middle, sealed on every side. The route must still exist, stay orthogonal,
    /// cross no box, and cross the fewest frames possible: one, not a tour through two.
    func testATargetSealedByFramesRoutesThroughExactlyOneFrame() {
        var m = BoardMap()
        m.frames = [
            BoardFrame(label: "Top", rect: BoardRect(x: 100, y: 100, w: 400, h: 100)),
            BoardFrame(label: "Left", rect: BoardRect(x: 100, y: 200, w: 100, h: 200)),
            BoardFrame(label: "Right", rect: BoardRect(x: 400, y: 200, w: 100, h: 200)),
            BoardFrame(label: "Bottom", rect: BoardRect(x: 100, y: 400, w: 400, h: 100)),
        ]
        m.components = [
            BoardComponent(name: "target", kind: .service, at: BoardPoint(x: 212, y: 258)),
            BoardComponent(name: "source", kind: .service, uses: ["target": ""], at: BoardPoint(x: 600, y: 258)),
        ]
        let route = BoardRouter.routes(for: m)[BoardModel.ArrowKey(from: "source", to: "target")]!
        for (a, b) in segments(route) { XCTAssertTrue(a.x == b.x || a.y == b.y, "orthogonal") }
        for box in [BoardGeometry.rect(ofComponentAt: BoardPoint(x: 600, y: 258)), BoardGeometry.rect(ofComponentAt: BoardPoint(x: 212, y: 258))] {
            for (a, b) in segments(route) { XCTAssertFalse(crosses(a, b, box), "crosses a box") }
        }
        let crossedFrames = m.frames.filter { frame in segments(route).contains { crosses($0.0, $0.1, frame.rect!) } }
        XCTAssertEqual(crossedFrames.map(\.label), ["Right"], "crosses exactly one frame border region")
    }

    /// The endpoint is walled in by hard obstacles on all four sides, touching with no gap — no
    /// route exists even through frames (there are none here). The last resort is a single
    /// straight segment between the two ports.
    func testAnImpossibleBoardFallsBackToAStraightSegment() {
        var m = BoardMap()
        m.components = [
            BoardComponent(name: "source", kind: .service, uses: ["target": ""], at: BoardPoint(x: 0, y: 400)),
            BoardComponent(name: "target", kind: .service, at: BoardPoint(x: 400, y: 400)),
            BoardComponent(name: "wallLeft", kind: .service, at: BoardPoint(x: 224, y: 400)),
            BoardComponent(name: "wallRight", kind: .service, at: BoardPoint(x: 576, y: 400)),
            BoardComponent(name: "wallTop", kind: .service, at: BoardPoint(x: 400, y: 316)),
            BoardComponent(name: "wallBottom", kind: .service, at: BoardPoint(x: 400, y: 484)),
        ]
        let route = BoardRouter.routes(for: m)[BoardModel.ArrowKey(from: "source", to: "target")]!
        XCTAssertEqual(route.points, [BoardPoint(x: 176, y: 442), BoardPoint(x: 400, y: 442)])
    }

    /// A component that geometrically sits inside Frame1's rect, but whose hand-edited `place`
    /// says "Frame2" — the reviewer's map. Frame1 must not be treated as foreign: geometry, not
    /// `place`, decides, so the straight line through it is not penalised.
    func testAFrameIsForeignByGeometryNotByPlace() {
        var m = BoardMap()
        m.frames = [
            BoardFrame(label: "Frame1", rect: BoardRect(x: 0, y: 0, w: 300, h: 300)),
            BoardFrame(label: "Frame2", rect: BoardRect(x: 0, y: 500, w: 300, h: 300)),
        ]
        m.components = [
            BoardComponent(name: "comp", kind: .service, uses: ["target": ""], place: "Frame2", at: BoardPoint(x: 50, y: 108)),
            BoardComponent(name: "target", kind: .service, at: BoardPoint(x: 700, y: 108)),
        ]
        let route = BoardRouter.routes(for: m)[BoardModel.ArrowKey(from: "comp", to: "target")]!
        XCTAssertEqual(route.points.count, 2, "a straight line through its own (mislabelled) frame is not penalised")
    }


    func testTwoHundredComponentsRouteWithinBudget() {
        var m = BoardMap()
        for i in 0..<200 {
            let uses = i + 1 < 200 ? ["c\(i + 1)": ""] : [:]
            var extra = uses
            if i + 7 < 200 && i % 2 == 0 { extra["c\(i + 7)"] = "" }
            m.components.append(BoardComponent(name: "c\(i)", kind: .service, uses: extra, at: BoardPoint(x: (i % 20) * 312, y: (i / 20) * 132)))
        }
        let start = Date()
        let routes = BoardRouter.routes(for: m)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThanOrEqual(routes.count, 290)
        XCTAssertLessThan(elapsed, 1.5, "debug-build guard; report the measured time")
    }

    /// A shared-database hub: 200 components in the same grid layout as the test above, but each
    /// with one arrow into a single central component instead of into its neighbour — the shape
    /// that made every other arrow's obstacle window, and the proximity scan against everything
    /// already routed toward that one point, balloon.
    func testTwoHundredComponentHubRoutesWithinBudget() {
        var m = BoardMap()
        m.components.append(BoardComponent(name: "hub", kind: .service, at: BoardPoint(x: 3120, y: 660)))
        for i in 0..<200 where i != 110 {
            m.components.append(BoardComponent(name: "s\(i)", kind: .service, uses: ["hub": ""], at: BoardPoint(x: (i % 20) * 312, y: (i / 20) * 132)))
        }
        let start = Date()
        let routes = BoardRouter.routes(for: m)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(routes.count, 199)
        XCTAssertLessThan(elapsed, 1.5, "debug-build guard; report the measured time")
    }
}

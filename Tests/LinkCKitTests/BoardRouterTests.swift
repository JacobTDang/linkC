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

    /// The endpoint is walled in by hard obstacles on every side, with no gap anywhere — no route
    /// exists even through frames (there are none here). The last resort is a single straight
    /// segment between the two ports.
    ///
    /// Four walls touching the target only at their own corners are not enough to seal it: since
    /// a margin is now only ever a cost, never a wall, an orthogonal route can still thread the
    /// single point (or the shared edge between two stacked walls) where two obstacles merely
    /// touch, without ever entering either one's raw body — touching a border was always meant to
    /// stay legal (`BoardGeometry.segmentIntersects`), so it does here too, corners included. A
    /// dense ring of walls, each offset from its neighbours by half its own size in both
    /// directions, overlaps every one of them by half — so every line a route could try to hug
    /// runs through some wall's *interior*, not just its border, leaving genuinely no way out.
    func testAnImpossibleBoardFallsBackToAStraightSegment() {
        var m = BoardMap()
        m.components = [
            BoardComponent(name: "source", kind: .service, uses: ["target": ""], at: BoardPoint(x: 0, y: 400)),
            BoardComponent(name: "target", kind: .service, at: BoardPoint(x: 400, y: 400)),
        ]
        let xs = [224, 312, 400, 488]
        let ys = [316, 358, 400, 442]
        for x in xs {
            for y in ys where !(x == 400 && y == 400) {
                m.components.append(BoardComponent(name: "wall\(x)_\(y)", kind: .service, at: BoardPoint(x: x, y: y)))
            }
        }
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

    // MARK: - Nudging re-checks neighbours
    //
    // No test constructs a naive nudge pushing a neighbouring segment into a box: every reachable
    // bend coordinate in this router's grid is either a source/target stub (exactly `clearance`
    // from that box) or an obstacle's own inflated boundary — A*'s cost minimises away any slack,
    // so it never leaves room between a bend and the obstacle that placed it there. A trap
    // obstacle wide enough to reach the few-point nudge window (at most a handful of `laneGap`
    // steps) around that bend is, at minimum-component-width 176, also wide enough to already
    // overlap the unshifted neighbour's own span — so it either changes the pre-nudge route too
    // (no longer isolating the nudge) or overlaps an existing box outright. The fix (re-checking
    // both neighbours and reverting the shift) is implemented in `applyNudge` regardless.

    // MARK: - An arrow to itself

    /// A loop on the box's top-right: out the right side, up past the top, left to the top's 3/4
    /// point, and down into the top. It must never cross the box.
    func testAnArrowToItselfDrawsALoopAtTheTopRight() {
        var m = BoardMap()
        m.components = [BoardComponent(name: "a", kind: .service, uses: ["a": ""], at: BoardPoint(x: 100, y: 100))]
        let route = BoardRouter.routes(for: m)[BoardModel.ArrowKey(from: "a", to: "a")]!
        let box = BoardGeometry.rect(ofComponentAt: BoardPoint(x: 100, y: 100))
        XCTAssertEqual(route.points.count, 5)
        for (a, b) in segments(route) {
            XCTAssertFalse(crosses(a, b, box), "loop crosses its own box")
            XCTAssertTrue(a.x == b.x || a.y == b.y, "orthogonal")
        }
    }

    // MARK: - Bundles after fan-out

    /// Three members of one out-bundle share `hub`'s port, then fan out: `a` and `c` mirror each
    /// other above and below the shared exit, and `e` sits above, close to `a` — its fanned-out
    /// run genuinely overlaps `a`'s, not merely touching where they meet the shared port.
    func testBundleMembersFanOutToSeparateLanes() {
        var m = BoardMap()
        m.components = [BoardComponent(name: "hub", kind: .service, uses: ["a": "hosts", "c": "hosts", "e": "hosts"], at: BoardPoint(x: 0, y: 200)),
                        BoardComponent(name: "a", kind: .service, at: BoardPoint(x: 480, y: 0)),
                        BoardComponent(name: "c", kind: .service, at: BoardPoint(x: 480, y: 400)),
                        BoardComponent(name: "e", kind: .service, at: BoardPoint(x: 480, y: 90))]
        let routes = BoardRouter.routes(for: m)
        var vertical: [Int: Int] = [:]
        for route in routes.values { for (a, b) in segments(route) where a.x == b.x && abs(a.y - b.y) > 40 { vertical[a.x, default: 0] += 1 } }
        XCTAssertTrue(vertical.values.allSatisfy { $0 == 1 }, "no two members' long vertical runs share an x: \(vertical)")
    }

    func testTwoHundredComponentsRouteWithinBudget() {
        var m = BoardMap()
        for i in 0..<200 {
            let uses: [String: BoardArrow] = i + 1 < 200 ? ["c\(i + 1)": ""] : [:]
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

    /// "Add what's running" packs boxes a few points apart — well inside `clearance` — so a
    /// stub's push-out from one box's edge lands inside its immediate neighbour's own inflated
    /// margin. A* must not give up and fall back to one straight (possibly diagonal, possibly
    /// box-crossing) segment; it must still find an orthogonal path around, never through a raw
    /// box.
    func testPackedRowRoutesAroundWithoutCrossingRawBoxesOrGoingDiagonal() {
        var m = BoardMap()
        m.frames = [BoardFrame(label: "Row", rect: BoardRect(x: 0, y: 0, w: 1460, h: 140))]
        let gap = 4
        var components: [BoardComponent] = (0..<8).map { i in
            BoardComponent(name: "c\(i)", kind: .service, place: "Row", at: BoardPoint(x: 8 + i * (176 + gap), y: 28))
        }
        components[0].uses = ["c3": ""]
        components[1].uses = ["c5": ""]
        components[2].uses = ["c6": ""]
        m.components = components

        let routes = BoardRouter.routes(for: m)
        XCTAssertEqual(routes.count, 3)
        for (key, route) in routes {
            for c in m.components where c.name != key.from && c.name != key.to {
                let box = BoardGeometry.rect(ofComponentAt: c.at!)
                for (a, b) in segments(route) { XCTAssertFalse(crosses(a, b, box), "\(key) crosses \(c.name): \(route.points)") }
            }
            for (a, b) in segments(route) { XCTAssertTrue(a.x == b.x || a.y == b.y, "\(key) not diagonal: \(route.points)") }
        }
    }

    // MARK: - Packed multi-row boards (a whole grid, not just one row)

    /// A 4×3 block of 12 packed boxes — "Add what's running" packs containers 4 to a row, and
    /// packs the rows themselves just as tight (0–4 pt gaps in both directions), not only along
    /// one row. `arrows` names each (from, to) pair by grid index, row-major: index = row * 4 +
    /// col.
    private func packedGrid(arrows: [(from: Int, to: Int)]) -> BoardMap {
        var m = BoardMap()
        let cols = 4, rows = 3, gap = 4, inset = 8
        let width = 2 * inset + cols * 176 + (cols - 1) * gap
        let height = 2 * inset + rows * 84 + (rows - 1) * gap
        m.frames = [BoardFrame(label: "Grid", rect: BoardRect(x: 0, y: 0, w: width, h: height))]
        var components: [BoardComponent] = (0..<(rows * cols)).map { i in
            let row = i / cols, col = i % cols
            return BoardComponent(name: "svc\(i)", kind: .service, place: "Grid",
                                  at: BoardPoint(x: inset + col * (176 + gap), y: inset + row * (84 + gap)))
        }
        for (from, to) in arrows { components[from].uses["svc\(to)"] = "" }
        m.components = components
        return m
    }

    /// No route crosses any raw box's interior — not another arrow's box, and not its own two end
    /// boxes past their stub — and every segment is orthogonal.
    private func assertRoutesStayClearAndOrthogonal(_ routes: [BoardModel.ArrowKey: BoardRoute], in m: BoardMap) {
        for (key, route) in routes {
            for c in m.components {
                let box = BoardGeometry.rect(ofComponentAt: c.at!)
                for (a, b) in segments(route) { XCTAssertFalse(crosses(a, b, box), "\(key) crosses \(c.name): \(route.points)") }
            }
            for (a, b) in segments(route) { XCTAssertTrue(a.x == b.x || a.y == b.y, "\(key) not diagonal: \(route.points)") }
        }
    }

    /// The sparse set from the bug report: svc4→svc11 alone drew one straight diagonal through
    /// svc7 and svc8's raw boxes, since the grid had no line through the 0–4 pt gaps and the
    /// middle-row boxes were fenced in by their neighbours' margins.
    func testPackedGridSparseArrowsRouteWithoutCrossingBoxesOrDiagonals() throws {
        let arrows: [(from: Int, to: Int)] = [(4, 11), (0, 9), (1, 10), (2, 5), (3, 6), (7, 8)]
        let m = packedGrid(arrows: arrows)
        let routes = BoardRouter.routes(for: m)
        XCTAssertEqual(routes.count, arrows.count)
        assertRoutesStayClearAndOrthogonal(routes, in: m)
    }

    /// The dense set from the bug report: every box to the box two columns right and one row
    /// down, where one exists — 36 arrows on the real board gave 6 diagonals and 35 crossings.
    func testPackedGridDenseArrowsRouteWithoutCrossingBoxesOrDiagonals() throws {
        var arrows: [(from: Int, to: Int)] = []
        for row in 0..<3 {
            for col in 0..<4 {
                let targetRow = row + 1, targetCol = col + 2
                guard targetRow < 3, targetCol < 4 else { continue }
                arrows.append((row * 4 + col, targetRow * 4 + targetCol))
            }
        }
        let m = packedGrid(arrows: arrows)
        let routes = BoardRouter.routes(for: m)
        XCTAssertEqual(routes.count, arrows.count)
        assertRoutesStayClearAndOrthogonal(routes, in: m)
    }

    // MARK: - Cancellation

    /// `routes(for:)` checks `isCancelled` between arrows and returns whatever is routed so far —
    /// the caller drops a cancelled result outright, so finishing the rest is wasted work.
    /// `isCancelled` is injectable so the test drives it deterministically instead of racing a
    /// real `Task`.
    func testCancelledRoutingReturnsEarly() {
        var m = BoardMap()
        m.components = (0..<5).map { i in
            BoardComponent(name: "c\(i)", kind: .service, uses: i + 1 < 5 ? ["c\(i + 1)": ""] : [:], at: BoardPoint(x: i * 400, y: 0))
        }
        var calls = 0
        let routes = BoardRouter.routes(for: m, isCancelled: {
            calls += 1
            return calls > 1
        })
        XCTAssertEqual(routes.count, 1, "stops after the first arrow once cancellation is seen")
    }

    // MARK: - Spread ends

    /// The ALU case from the RISC-V Board: two differently labelled buses into one side.
    private func twoIntoOneSide() -> BoardMap {
        var m = BoardMap()
        m.components = [
            BoardComponent(name: "rf", kind: .register, uses: ["alu": BoardArrow(label: "rs1 data", style: .bus, bits: 32)], at: BoardPoint(x: 0, y: 0)),
            BoardComponent(name: "fwd", kind: .mux, uses: ["alu": BoardArrow(label: "operand A", style: .bus, bits: 32)], at: BoardPoint(x: 0, y: 300)),
            BoardComponent(name: "alu", kind: .alu, at: BoardPoint(x: 500, y: 150)),
        ]
        return m
    }

    func testUnbundledArrowsIntoOneSideGetTheirOwnEnds() throws {
        let routes = BoardRouter.routes(for: twoIntoOneSide())
        let top = try XCTUnwrap(routes[.init(from: "rf", to: "alu")]?.points.last)
        let bottom = try XCTUnwrap(routes[.init(from: "fwd", to: "alu")]?.points.last)
        XCTAssertEqual(top.x, bottom.x, "both land on the ALU's left side")
        XCTAssertGreaterThanOrEqual(abs(top.y - bottom.y), 12, "they no longer share one point")
        XCTAssertLessThan(top.y, bottom.y, "ordered by their sources: rf above fwd")
    }

    func testSpreadEndsStayDeterministic() {
        XCTAssertEqual(BoardRouter.routes(for: twoIntoOneSide()), BoardRouter.routes(for: twoIntoOneSide()))
    }

    /// Two ends on a left or right side sit 16 pt apart, ±8 pt from the side's midpoint — already
    /// past the 12 pt minimum, so they stay near the middle, where every shape has an outline.
    func testTwoUnbundledEndsStayNearTheMiddle() throws {
        let routes = BoardRouter.routes(for: twoIntoOneSide())
        let top = try XCTUnwrap(routes[.init(from: "rf", to: "alu")]?.points.last?.y)
        let bottom = try XCTUnwrap(routes[.init(from: "fwd", to: "alu")]?.points.last?.y)
        let mid = BoardGeometry.rect(ofComponentAt: BoardPoint(x: 500, y: 150)).center.y
        XCTAssertEqual(top, mid - 8)
        XCTAssertEqual(bottom, mid + 8)
    }

    /// Three sources into one side of the ALU: an even split of the ±16 pt band would put them
    /// only 11 pt apart, where arrowheads touch, so they sit the 12 pt minimum apart instead —
    /// the ±16 pt band allows it.
    private func threeIntoOneSide() -> BoardMap {
        var m = BoardMap()
        m.components = [
            BoardComponent(name: "s0", kind: .service, uses: ["alu": ""], at: BoardPoint(x: 0, y: 0)),
            BoardComponent(name: "s1", kind: .service, uses: ["alu": ""], at: BoardPoint(x: 0, y: 300)),
            BoardComponent(name: "s2", kind: .service, uses: ["alu": ""], at: BoardPoint(x: 0, y: 600)),
            BoardComponent(name: "alu", kind: .alu, at: BoardPoint(x: 500, y: 150)),
        ]
        return m
    }

    func testThreeEndsOnASideAreTwelvePointsApart() throws {
        let routes = BoardRouter.routes(for: threeIntoOneSide())
        let y0 = try XCTUnwrap(routes[.init(from: "s0", to: "alu")]?.points.last?.y)
        let y1 = try XCTUnwrap(routes[.init(from: "s1", to: "alu")]?.points.last?.y)
        let y2 = try XCTUnwrap(routes[.init(from: "s2", to: "alu")]?.points.last?.y)
        let mid = BoardGeometry.rect(ofComponentAt: BoardPoint(x: 500, y: 150)).center.y
        XCTAssertEqual(y0, mid - 12)
        XCTAssertEqual(y1, mid)
        XCTAssertEqual(y2, mid + 12)
    }

    // MARK: - Straight case's multi-end branches

    /// `a` sits in `t1`'s own row, but `t1`'s left side already carries two ends — `a`'s own
    /// right side has only the one, so it's free to move to `t1`'s slot instead of forcing the
    /// row's raw midpoint.
    private func sourceInTargetsRowTwoEndsOnTargetSide() -> BoardMap {
        var m = BoardMap()
        m.components = [
            BoardComponent(name: "a", kind: .service, uses: ["t1": ""], at: BoardPoint(x: 0, y: 0)),
            BoardComponent(name: "b", kind: .service, uses: ["t1": ""], at: BoardPoint(x: 0, y: 200)),
            BoardComponent(name: "t1", kind: .service, at: BoardPoint(x: 500, y: 0)),
        ]
        return m
    }

    /// (a) The existing router test's boxes never share a row, so `straightCase` always returns
    /// nil before either multi-end branch runs. Here `a` and `t1` do share a row, and `t1`'s left
    /// side already carries two ends (from `a` and `b`) — the line must run straight, at the
    /// slot `spreadEnds` gave that side, not the row's own midpoint.
    func testStraightLineUsesTheTargetsSlotWhenItsSideHasTwoEnds() throws {
        let routes = BoardRouter.routes(for: sourceInTargetsRowTwoEndsOnTargetSide())
        let route = try XCTUnwrap(routes[.init(from: "a", to: "t1")])
        XCTAssertEqual(route.points, [BoardPoint(x: 176, y: 34), BoardPoint(x: 500, y: 34)],
                       "straight, at t1's own slot — not the row's raw midpoint, 42")
    }

    /// `s`'s own right side and `t1`'s left side both already carry two ends of their own (`s`
    /// also feeds `t2`; `t1` also receives from `s2`) — even though `s` and `t1` share a row, a
    /// straight line through that row's raw midpoint must never appear: neither side is free to
    /// move to it.
    private func bothSidesAlreadySpread() -> BoardMap {
        var m = BoardMap()
        m.components = [
            BoardComponent(name: "s", kind: .service, uses: ["t1": "", "t2": ""], at: BoardPoint(x: 0, y: 0)),
            BoardComponent(name: "s2", kind: .service, uses: ["t1": ""], at: BoardPoint(x: 0, y: 300)),
            BoardComponent(name: "t1", kind: .service, at: BoardPoint(x: 500, y: 0)),
            BoardComponent(name: "t2", kind: .service, at: BoardPoint(x: 500, y: 300)),
        ]
        return m
    }

    /// (b) Two ends on both the source's and the target's facing sides: it must never fall back
    /// to the row's raw midpoint (176, 42)–(500, 42) — the straight branch only ever moves a side
    /// with just one end.
    func testStraightLineNeverFallsBackToTheMidpointWhenBothSidesHaveTwoEnds() throws {
        let routes = BoardRouter.routes(for: bothSidesAlreadySpread())
        let route = try XCTUnwrap(routes[.init(from: "s", to: "t1")])
        XCTAssertNotEqual(route.points, [BoardPoint(x: 176, y: 42), BoardPoint(x: 500, y: 42)])
    }
    func testRouterRoutesAroundATallTablesRealRect() throws {
        var map = BoardMap()
        map.components = [
            BoardComponent(name: "orders", kind: .table, at: BoardPoint(x: 200, y: 0),
                           columns: (1...10).map { BoardColumn(name: "c\($0)", type: "int") }),
            BoardComponent(name: "sender", kind: .service, uses: ["receiver": ""], at: BoardPoint(x: 0, y: 158)),
            BoardComponent(name: "receiver", kind: .service, at: BoardPoint(x: 500, y: 158)),
        ]
        let tableRect = try XCTUnwrap(BoardGeometry.rect(of: map.components[0]))
        XCTAssertEqual(tableRect, BoardRect(x: 200, y: 0, w: 176, h: 264), "the table really is 264 tall, not 84")
        let route = try XCTUnwrap(BoardRouter.routes(for: map)[BoardModel.ArrowKey(from: "sender", to: "receiver")])
        for (a, b) in zip(route.points, route.points.dropFirst()) {
            XCTAssertFalse(crosses(a, b, tableRect), "\(a)->\(b) crosses the table's real rect")
        }
    }

    // MARK: - Foreign keys

    func testForeignKeyPortsSitAtExactRowCentresOnTheFacingSides() throws {
        var m = BoardMap()
        m.components = [
            BoardComponent(name: "orders", kind: .table, at: BoardPoint(x: 0, y: 0), columns: [
                BoardColumn(name: "id", type: "uuid", pk: true),
                BoardColumn(name: "cust_id", type: "bigint", references: BoardColumnReference(table: "customers", column: "id")),
            ]),
            BoardComponent(name: "customers", kind: .table, at: BoardPoint(x: 400, y: 0), columns: [
                BoardColumn(name: "id", type: "uuid", pk: true),
            ]),
        ]
        let ordersBox = try XCTUnwrap(BoardGeometry.rect(of: m.components[0]))
        let customersBox = try XCTUnwrap(BoardGeometry.rect(of: m.components[1]))
        XCTAssertEqual(ordersBox, BoardRect(x: 0, y: 0, w: 176, h: 88))
        XCTAssertEqual(customersBox, BoardRect(x: 400, y: 0, w: 176, h: 72))

        let key = BoardForeignKey(table: "orders", column: "cust_id", refTable: "customers", refColumn: "id")
        let route = try XCTUnwrap(BoardRouter.foreignKeyRoutes(for: m)[key])
        XCTAssertEqual(route.points.first, BoardPoint(x: 176, y: 69), "orders' right side, the cust_id row")
        XCTAssertEqual(route.points.last, BoardPoint(x: 400, y: 47), "customers' left side, the id row")
        for (a, b) in zip(route.points, route.points.dropFirst()) {
            XCTAssertTrue(a.x == b.x || a.y == b.y, "orthogonal")
        }
        XCTAssertNil(BoardRouter.foreignKeyStubs(for: m)[key], "resolved: a route, not a stub")
    }

    func testForeignKeyRouteBendsAroundABoxBetweenTheTables() throws {
        var m = BoardMap()
        m.components = [
            BoardComponent(name: "orders", kind: .table, at: BoardPoint(x: 0, y: 0), columns: [
                BoardColumn(name: "id", type: "uuid", pk: true),
                BoardColumn(name: "cust_id", type: "bigint", references: BoardColumnReference(table: "customers", column: "id")),
            ]),
            BoardComponent(name: "customers", kind: .table, at: BoardPoint(x: 400, y: 0), columns: [
                BoardColumn(name: "id", type: "uuid", pk: true),
            ]),
            BoardComponent(name: "wall", kind: .service, at: BoardPoint(x: 200, y: 0)),
        ]
        let wallBox = try XCTUnwrap(BoardGeometry.rect(of: m.components[2]))
        XCTAssertEqual(wallBox, BoardRect(x: 200, y: 0, w: 176, h: 84), "spans both rows' y (47 and 69), blocking a direct line")

        let key = BoardForeignKey(table: "orders", column: "cust_id", refTable: "customers", refColumn: "id")
        let route = try XCTUnwrap(BoardRouter.foreignKeyRoutes(for: m)[key])
        XCTAssertEqual(route.points.first, BoardPoint(x: 176, y: 69))
        XCTAssertEqual(route.points.last, BoardPoint(x: 400, y: 47))
        for (a, b) in zip(route.points, route.points.dropFirst()) {
            XCTAssertFalse(crosses(a, b, wallBox), "\(a)->\(b) crosses the wall")
        }
    }

    func testForeignKeySelfReferenceLoopsOutTheRightSide() throws {
        var m = BoardMap()
        m.components = [
            BoardComponent(name: "categories", kind: .table, at: BoardPoint(x: 0, y: 0), columns: [
                BoardColumn(name: "id", type: "uuid", pk: true),
                BoardColumn(name: "parent_id", type: "uuid", references: BoardColumnReference(table: "categories", column: "id")),
            ]),
        ]
        let box = try XCTUnwrap(BoardGeometry.rect(of: m.components[0]))
        XCTAssertEqual(box, BoardRect(x: 0, y: 0, w: 176, h: 88))
        let fromY = BoardGeometry.rowCenterY(ofColumnAt: 1, in: box)
        let toY = BoardGeometry.rowCenterY(ofColumnAt: 0, in: box)

        let key = BoardForeignKey(table: "categories", column: "parent_id", refTable: "categories", refColumn: "id")
        let route = try XCTUnwrap(BoardRouter.foreignKeyRoutes(for: m)[key])
        XCTAssertEqual(route.points, [
            BoardPoint(x: box.maxX, y: fromY),
            BoardPoint(x: box.maxX + 24, y: fromY),
            BoardPoint(x: box.maxX + 24, y: toY),
            BoardPoint(x: box.maxX, y: toY),
        ])
        XCTAssertTrue(route.points.allSatisfy { $0.x >= box.maxX }, "never crosses back into the table")
        XCTAssertNil(BoardRouter.foreignKeyStubs(for: m)[key])
    }

    func testAMissingReferencedTableGivesAStubAndNoRoute() throws {
        var m = BoardMap()
        m.components = [
            BoardComponent(name: "orders", kind: .table, at: BoardPoint(x: 0, y: 0), columns: [
                BoardColumn(name: "id", type: "uuid", pk: true),
                BoardColumn(name: "cust_id", type: "bigint", references: BoardColumnReference(table: "customers", column: "id")),
            ]),
        ]
        let box = try XCTUnwrap(BoardGeometry.rect(of: m.components[0]))
        let key = BoardForeignKey(table: "orders", column: "cust_id", refTable: "customers", refColumn: "id")

        XCTAssertNil(BoardRouter.foreignKeyRoutes(for: m)[key], "customers isn't on the board")
        let stub = try XCTUnwrap(BoardRouter.foreignKeyStubs(for: m)[key])
        let y = BoardGeometry.rowCenterY(ofColumnAt: 1, in: box)
        XCTAssertEqual(stub.from, BoardPoint(x: box.maxX, y: y))
        XCTAssertEqual(stub.to, BoardPoint(x: box.maxX + 40, y: y))
    }

    func testAPresentTableWithAMissingReferencedColumnAlsoGivesAStub() throws {
        var m = BoardMap()
        m.components = [
            BoardComponent(name: "orders", kind: .table, at: BoardPoint(x: 0, y: 0), columns: [
                BoardColumn(name: "id", type: "uuid", pk: true),
                BoardColumn(name: "cust_id", type: "bigint", references: BoardColumnReference(table: "customers", column: "ghost_id")),
            ]),
            BoardComponent(name: "customers", kind: .table, at: BoardPoint(x: 400, y: 0), columns: [
                BoardColumn(name: "id", type: "uuid", pk: true),
            ]),
        ]
        let key = BoardForeignKey(table: "orders", column: "cust_id", refTable: "customers", refColumn: "ghost_id")
        XCTAssertNil(BoardRouter.foreignKeyRoutes(for: m)[key])
        XCTAssertNotNil(BoardRouter.foreignKeyStubs(for: m)[key])
    }

    /// An unplaced part (no `at` yet) counts the same as one that isn't on the board at all: there
    /// is no row to point a route at, so this is a stub too, never a dangling, undrawn key.
    func testAnUnplacedReferencedTableAlsoGivesAStub() throws {
        var m = BoardMap()
        m.components = [
            BoardComponent(name: "orders", kind: .table, at: BoardPoint(x: 0, y: 0), columns: [
                BoardColumn(name: "id", type: "uuid", pk: true),
                BoardColumn(name: "cust_id", type: "bigint", references: BoardColumnReference(table: "customers", column: "id")),
            ]),
            BoardComponent(name: "customers", kind: .table, columns: [BoardColumn(name: "id", type: "uuid", pk: true)]),
        ]
        let key = BoardForeignKey(table: "orders", column: "cust_id", refTable: "customers", refColumn: "id")
        XCTAssertNil(BoardRouter.foreignKeyRoutes(for: m)[key])
        XCTAssertNotNil(BoardRouter.foreignKeyStubs(for: m)[key])
    }

    func testForeignKeyRoutesAndStubsAreDeterministic() throws {
        let decoded = try BoardMap.decode(Data(#"""
        { "version": 2, "places": { "Not placed": {
          "orders": {"kind":"table","columns":[
            {"name":"id","type":"uuid","pk":true},
            {"name":"cust_id","type":"bigint","references":"customers.id"}
          ]},
          "customers": {"kind":"table","columns":[{"name":"id","type":"uuid","pk":true}]}
        } } }
        """#.utf8))
        let arranged = BoardLayout.arranged(decoded)
        XCTAssertEqual(BoardRouter.foreignKeyRoutes(for: arranged), BoardRouter.foreignKeyRoutes(for: arranged))
        let firstStubs = BoardRouter.foreignKeyStubs(for: arranged).mapValues { [$0.from, $0.to] }
        let secondStubs = BoardRouter.foreignKeyStubs(for: arranged).mapValues { [$0.from, $0.to] }
        XCTAssertEqual(firstStubs, secondStubs)
    }
}

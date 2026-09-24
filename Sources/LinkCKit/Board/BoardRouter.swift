import Foundation

/// One arrow's orthogonal path across the board.
public struct BoardRoute: Equatable, Sendable {
    /// First point on the source's side, last on the target's.
    public var points: [BoardPoint]
    /// "out:<source>|<label>" or "in:<target>|<label>" when this route shares a port with others.
    public var bundle: String?
}

/// Routes every arrow between positioned components around every box and every foreign frame in
/// its way. Pure, nonisolated and deterministic — the same map always yields the same routes.
/// Ties break by lowercased name throughout.
public enum BoardRouter {
    public static let clearance = 12
    public static let laneGap = 8

    private static let windowMargin = 240
    private static let maxWindowDoublings = 3
    private static let turnPenalty = 40.0
    private static let proximityWeight = 0.3
    private static let proximityRadius = 4
    /// The extra cost, per unit of length, of running an arrow's route through a foreign frame's
    /// inflated rect. Component and note boxes are never this soft — they stay hard obstacles.
    private static let frameCrossingCost = 6.0
    /// How far outward and upward a self-loop reaches before turning back into the box.
    private static let selfLoopReach = 20

    // MARK: - Public entry point

    /// The Board never produces overlapping component or note boxes — `BoardModel.laidOut`
    /// separates them on load, and every spatial edit keeps that true — so this assumes no two
    /// boxes overlap and never checks for it.
    public static func routes(for map: BoardMap) -> [BoardModel.ArrowKey: BoardRoute] {
        let byLowercasedName = Dictionary(uniqueKeysWithValues: map.components.compactMap { c -> (String, BoardComponent)? in
            guard c.at != nil else { return nil }
            return (c.name.lowercased(), c)
        })
        guard !byLowercasedName.isEmpty else { return [:] }

        // 1. Arrows: every `uses` entry whose two ends are both positioned components, keyed by
        // the real names, in file order — a dictionary naturally dedupes a component naming the
        // same target through two differently-cased keys.
        var labelOf: [BoardModel.ArrowKey: String] = [:]
        for component in map.components {
            guard component.at != nil else { continue }
            for (targetName, label) in component.uses {
                guard let target = byLowercasedName[targetName.lowercased()] else { continue }
                labelOf[BoardModel.ArrowKey(from: component.name, to: target.name)] = label
            }
        }
        let arrowKeys = labelOf.keys.sorted(by: orderKey)
        guard !arrowKeys.isEmpty else { return [:] }

        // 2. Bundles. An arrow from a component to itself never bundles — it always draws its
        // own fixed corner loop, whatever label it shares with other arrows.
        let bundleableKeys = arrowKeys.filter { $0.from.lowercased() != $0.to.lowercased() }
        let (bundleOf, outAnchors, inAnchors) = bundles(arrowKeys: bundleableKeys, labelOf: labelOf, byLowercasedName: byLowercasedName)

        // Geometry shared by every arrow.
        let componentBox = Dictionary(uniqueKeysWithValues: map.components.compactMap { c -> (String, BoardRect)? in
            guard let at = c.at else { return nil }
            return (c.name.lowercased(), BoardGeometry.rect(ofComponentAt: at))
        })
        let noteBoxes = map.notes.compactMap { $0.at.map(BoardGeometry.rect(ofNoteAt:)) }

        var routedSegments: [(a: BoardPoint, b: BoardPoint, id: String)] = []
        var obstaclesByArrow: [BoardModel.ArrowKey: [BoardRect]] = [:]
        var results: [BoardModel.ArrowKey: BoardRoute] = [:]

        for key in arrowKeys {
            guard let source = byLowercasedName[key.from.lowercased()], let target = byLowercasedName[key.to.lowercased()],
                  let sourceAt = source.at, let targetAt = target.at
            else { continue }
            let sourceBox = BoardGeometry.rect(ofComponentAt: sourceAt)
            let targetBox = BoardGeometry.rect(ofComponentAt: targetAt)

            let (hardObstacles, frameObstacles) = obstaclesFor(
                map: map, sourceName: source.name, targetName: target.name,
                sourceBox: sourceBox, targetBox: targetBox, componentBox: componentBox, noteBoxes: noteBoxes)
            obstaclesByArrow[key] = hardObstacles

            // An arrow to itself: a small fixed loop, never bundled, never routed through A*.
            if key.from.lowercased() == key.to.lowercased() {
                let points = selfLoop(sourceBox)
                let selfId = arrowId(key)
                results[key] = BoardRoute(points: points, bundle: nil)
                for (a, b) in zip(points, points.dropFirst()) {
                    routedSegments.append((a: a, b: b, id: selfId))
                }
                continue
            }

            let bundleId = bundleOf[key]
            let selfId = bundleId ?? arrowId(key)

            var sourceSide: Side
            var targetSide: Side
            var sourcePort: BoardPoint
            var targetPort: BoardPoint
            let forced: Bool

            if let bundleId, bundleId.hasPrefix("out:"), let anchor = outAnchors[bundleId] {
                (sourceSide, sourcePort) = anchor
                targetSide = sides(from: sourceBox.center, to: targetBox.center).1
                targetPort = sidePort(targetBox, targetSide)
                forced = true
            } else if let bundleId, bundleId.hasPrefix("in:"), let anchor = inAnchors[bundleId] {
                (targetSide, targetPort) = anchor
                sourceSide = sides(from: sourceBox.center, to: targetBox.center).0
                sourcePort = sidePort(sourceBox, sourceSide)
                forced = true
            } else {
                (sourceSide, targetSide) = sides(from: sourceBox.center, to: targetBox.center)
                sourcePort = sidePort(sourceBox, sourceSide)
                targetPort = sidePort(targetBox, targetSide)
                forced = false
            }

            var points: [BoardPoint]
            if !forced, let straight = straightCase(sourceBox, sourceSide, targetBox, targetSide, hardObstacles + frameObstacles) {
                points = straight
            } else {
                let sourceStub = stub(sourcePort, sourceSide)
                let targetStub = stub(targetPort, targetSide)
                let path = aStar(
                    from: sourceStub, to: targetStub, hardObstacles: hardObstacles, frames: frameObstacles,
                    avoid: routedSegments, selfId: selfId) ?? lastResort()
                points = simplify([sourcePort] + path + [targetPort])
            }

            results[key] = BoardRoute(points: points, bundle: bundleId)
            for (a, b) in zip(points, points.dropFirst()) {
                routedSegments.append((a: a, b: b, id: selfId))
            }
        }

        nudge(&results, obstaclesByArrow: obstaclesByArrow)
        return results
    }

    // MARK: - Ordering

    private static func orderKey(_ a: BoardModel.ArrowKey, _ b: BoardModel.ArrowKey) -> Bool {
        (a.from.lowercased(), a.to.lowercased()) < (b.from.lowercased(), b.to.lowercased())
    }

    private static func arrowId(_ key: BoardModel.ArrowKey) -> String {
        "arrow:\(key.from.lowercased())|\(key.to.lowercased())"
    }

    // MARK: - Bundles

    private static func bundles(
        arrowKeys: [BoardModel.ArrowKey], labelOf: [BoardModel.ArrowKey: String], byLowercasedName: [String: BoardComponent]
    ) -> (bundleOf: [BoardModel.ArrowKey: String], outAnchors: [String: (Side, BoardPoint)], inAnchors: [String: (Side, BoardPoint)]) {
        struct GroupKey: Hashable { let name: String; let label: String }

        var outGroups: [GroupKey: [BoardModel.ArrowKey]] = [:]
        for key in arrowKeys {
            let label = labelOf[key] ?? ""
            guard !label.isEmpty else { continue }
            outGroups[GroupKey(name: key.from.lowercased(), label: label), default: []].append(key)
        }

        var bundleOf: [BoardModel.ArrowKey: String] = [:]
        var bundled: Set<BoardModel.ArrowKey> = []
        for key in outGroups.keys.sorted(by: { ($0.name, $0.label) < ($1.name, $1.label) }) {
            let keys = outGroups[key]!
            guard keys.count >= 2 else { continue }
            let source = keys.min(by: orderKey)!.from
            let id = "out:\(source)|\(key.label)"
            for k in keys { bundleOf[k] = id; bundled.insert(k) }
        }

        var inGroups: [GroupKey: [BoardModel.ArrowKey]] = [:]
        for key in arrowKeys where !bundled.contains(key) {
            let label = labelOf[key] ?? ""
            guard !label.isEmpty else { continue }
            inGroups[GroupKey(name: key.to.lowercased(), label: label), default: []].append(key)
        }
        for key in inGroups.keys.sorted(by: { ($0.name, $0.label) < ($1.name, $1.label) }) {
            let keys = inGroups[key]!
            guard keys.count >= 2 else { continue }
            let target = keys.min(by: orderKey)!.to
            let id = "in:\(target)|\(key.label)"
            for k in keys { bundleOf[k] = id }
        }

        // Anchors: one shared port per bundle, from the bundled box's centre toward the mean
        // centre of the other ends it bundles with.
        var outAnchors: [String: (Side, BoardPoint)] = [:]
        for (id, keys) in groupedById(bundleOf, prefix: "out:") {
            guard let source = byLowercasedName[keys[0].from.lowercased()], let at = source.at else { continue }
            let box = BoardGeometry.rect(ofComponentAt: at)
            let others = keys.compactMap { byLowercasedName[$0.to.lowercased()]?.at }.map(BoardGeometry.rect(ofComponentAt:))
            guard !others.isEmpty else { continue }
            let mean = meanCenter(others)
            let side = sides(from: box.center, to: mean).0
            outAnchors[id] = (side, sidePort(box, side))
        }
        var inAnchors: [String: (Side, BoardPoint)] = [:]
        for (id, keys) in groupedById(bundleOf, prefix: "in:") {
            guard let target = byLowercasedName[keys[0].to.lowercased()], let at = target.at else { continue }
            let box = BoardGeometry.rect(ofComponentAt: at)
            let others = keys.compactMap { byLowercasedName[$0.from.lowercased()]?.at }.map(BoardGeometry.rect(ofComponentAt:))
            guard !others.isEmpty else { continue }
            let mean = meanCenter(others)
            let side = sides(from: mean, to: box.center).1
            inAnchors[id] = (side, sidePort(box, side))
        }

        return (bundleOf, outAnchors, inAnchors)
    }

    private static func groupedById(_ bundleOf: [BoardModel.ArrowKey: String], prefix: String) -> [(String, [BoardModel.ArrowKey])] {
        var groups: [String: [BoardModel.ArrowKey]] = [:]
        for (key, id) in bundleOf where id.hasPrefix(prefix) {
            groups[id, default: []].append(key)
        }
        return groups.keys.sorted().map { id in (id, groups[id]!.sorted(by: orderKey)) }
    }

    private static func meanCenter(_ boxes: [BoardRect]) -> BoardPoint {
        let sumX = boxes.reduce(0) { $0 + $1.center.x }
        let sumY = boxes.reduce(0) { $0 + $1.center.y }
        return BoardPoint(x: sumX / boxes.count, y: sumY / boxes.count)
    }

    // MARK: - Sides and ports

    private enum Side { case left, right, top, bottom }

    private static func sides(from source: BoardPoint, to target: BoardPoint) -> (Side, Side) {
        let dx = target.x - source.x, dy = target.y - source.y
        if abs(dx) >= abs(dy) {
            return dx >= 0 ? (.right, .left) : (.left, .right)
        }
        return dy >= 0 ? (.bottom, .top) : (.top, .bottom)
    }

    private static func sidePort(_ box: BoardRect, _ side: Side) -> BoardPoint {
        switch side {
        case .left: return BoardPoint(x: box.minX, y: box.center.y)
        case .right: return BoardPoint(x: box.maxX, y: box.center.y)
        case .top: return BoardPoint(x: box.center.x, y: box.minY)
        case .bottom: return BoardPoint(x: box.center.x, y: box.maxY)
        }
    }

    private static func outward(_ side: Side) -> (dx: Int, dy: Int) {
        switch side {
        case .left: return (-1, 0)
        case .right: return (1, 0)
        case .top: return (0, -1)
        case .bottom: return (0, 1)
        }
    }

    private static func stub(_ port: BoardPoint, _ side: Side) -> BoardPoint {
        let o = outward(side)
        return BoardPoint(x: port.x + o.dx * clearance, y: port.y + o.dy * clearance)
    }

    // MARK: - Self-loop

    /// An arrow from a box to itself: out its right side, up past its top, left to the top's 3/4
    /// point, and down into the top — a small loop on the top-right corner that never crosses the
    /// box, since every leg runs at or beyond the box's own right or top edge.
    private static func selfLoop(_ box: BoardRect) -> [BoardPoint] {
        let topY = box.minY
        let rightX = box.maxX
        let aboveY = topY - selfLoopReach
        let entryX = box.minX + (box.w * 3) / 4
        return [
            BoardPoint(x: rightX, y: topY),
            BoardPoint(x: rightX + selfLoopReach, y: topY),
            BoardPoint(x: rightX + selfLoopReach, y: aboveY),
            BoardPoint(x: entryX, y: aboveY),
            BoardPoint(x: entryX, y: topY),
        ]
    }

    // MARK: - Straight case

    private static func straightCase(
        _ sourceBox: BoardRect, _ sourceSide: Side, _ targetBox: BoardRect, _ targetSide: Side, _ obstacles: [BoardRect]
    ) -> [BoardPoint]? {
        switch (sourceSide, targetSide) {
        case (.right, .left), (.left, .right):
            let lo = max(sourceBox.minY, targetBox.minY), hi = min(sourceBox.maxY, targetBox.maxY)
            guard lo < hi else { return nil }
            let midY = (lo + hi) / 2
            let sourceX = sourceSide == .right ? sourceBox.maxX : sourceBox.minX
            let targetX = targetSide == .left ? targetBox.minX : targetBox.maxX
            let a = BoardPoint(x: sourceX, y: midY), b = BoardPoint(x: targetX, y: midY)
            guard !obstacles.contains(where: { BoardGeometry.segmentIntersects(a, b, $0) }) else { return nil }
            return [a, b]
        case (.bottom, .top), (.top, .bottom):
            let lo = max(sourceBox.minX, targetBox.minX), hi = min(sourceBox.maxX, targetBox.maxX)
            guard lo < hi else { return nil }
            let midX = (lo + hi) / 2
            let sourceY = sourceSide == .bottom ? sourceBox.maxY : sourceBox.minY
            let targetY = targetSide == .top ? targetBox.minY : targetBox.maxY
            let a = BoardPoint(x: midX, y: sourceY), b = BoardPoint(x: midX, y: targetY)
            guard !obstacles.contains(where: { BoardGeometry.segmentIntersects(a, b, $0) }) else { return nil }
            return [a, b]
        default:
            return nil
        }
    }

    // MARK: - Obstacles

    private static func inflate(_ rect: BoardRect, by amount: Int) -> BoardRect {
        BoardRect(x: rect.x - amount, y: rect.y - amount, w: rect.w + 2 * amount, h: rect.h + 2 * amount)
    }

    /// Hard obstacles — every component and note box except this arrow's own two ends, inflated
    /// by `clearance` — and separately, the foreign frames: every frame rect inflated the same
    /// way, except one whose *geometry* holds either end's box centre. Geometry always wins over
    /// a hand-edited `place` that disagrees with it — a component's `place` plays no part here.
    private static func obstaclesFor(
        map: BoardMap, sourceName: String, targetName: String, sourceBox: BoardRect, targetBox: BoardRect,
        componentBox: [String: BoardRect], noteBoxes: [BoardRect]
    ) -> (hard: [BoardRect], frames: [BoardRect]) {
        var hard: [BoardRect] = []
        let sourceKey = sourceName.lowercased(), targetKey = targetName.lowercased()
        for component in map.components {
            let key = component.name.lowercased()
            guard key != sourceKey, key != targetKey, let box = componentBox[key] else { continue }
            hard.append(inflate(box, by: clearance))
        }
        for box in noteBoxes { hard.append(inflate(box, by: clearance)) }

        var frames: [BoardRect] = []
        for frame in map.frames {
            guard let rect = frame.rect, !rect.contains(sourceBox.center), !rect.contains(targetBox.center) else { continue }
            frames.append(inflate(rect, by: clearance))
        }
        return (hard, frames)
    }

    // MARK: - Simplify

    private static func simplify(_ points: [BoardPoint]) -> [BoardPoint] {
        guard points.count > 1 else { return points }
        var result: [BoardPoint] = [points[0]]
        for p in points.dropFirst() where p != result.last! {
            result.append(p)
        }
        guard result.count > 2 else { return result }
        var changed = true
        while changed {
            changed = false
            var next: [BoardPoint] = [result[0]]
            var i = 1
            while i < result.count - 1 {
                let prev = next.last!, cur = result[i], nxt = result[i + 1]
                let collinear = (prev.y == cur.y && cur.y == nxt.y) || (prev.x == cur.x && cur.x == nxt.x)
                if collinear {
                    changed = true
                } else {
                    next.append(cur)
                }
                i += 1
            }
            next.append(result[result.count - 1])
            result = next
        }
        return result
    }

    // MARK: - A*

    private struct GridState: Hashable {
        let ix: Int
        let iy: Int
        let dir: Int  // 0 = none, 1 = horizontal, 2 = vertical
    }

    private static func aStar(
        from start: BoardPoint, to goal: BoardPoint, hardObstacles: [BoardRect], frames: [BoardRect],
        avoid: [(a: BoardPoint, b: BoardPoint, id: String)], selfId: String
    ) -> [BoardPoint]? {
        // The proximity nudge only ever matters near one of the two ends — a long arrow's open
        // middle stretch has nothing to be nudged away from. Scoping `nearby` to two small boxes
        // around `start` and `goal`, instead of the whole (possibly huge) obstacle window, keeps
        // the per-edge proximity scan cheap even when hundreds of other arrows have already been
        // routed, without changing which obstacles are found (that window is untouched below).
        let nearMargin = 48
        let startBox = BoardRect(x: start.x - nearMargin, y: start.y - nearMargin, w: 2 * nearMargin, h: 2 * nearMargin)
        let goalBox = BoardRect(x: goal.x - nearMargin, y: goal.y - nearMargin, w: 2 * nearMargin, h: 2 * nearMargin)
        let nearby = avoid.filter {
            let lo = min($0.a.x, $0.b.x) - proximityRadius, hi = max($0.a.x, $0.b.x) + proximityRadius
            let top = min($0.a.y, $0.b.y) - proximityRadius, bottom = max($0.a.y, $0.b.y) + proximityRadius
            let segBox = BoardRect(x: lo, y: top, w: hi - lo, h: bottom - top)
            return segBox.intersects(startBox) || segBox.intersects(goalBox)
        }

        var expand = windowMargin
        for attempt in 0...maxWindowDoublings {
            if attempt > 0 { expand *= 2 }
            let minX = min(start.x, goal.x) - expand, maxX = max(start.x, goal.x) + expand
            let minY = min(start.y, goal.y) - expand, maxY = max(start.y, goal.y) + expand
            let window = BoardRect(x: minX, y: minY, w: maxX - minX, h: maxY - minY)
            let windowedHard = hardObstacles.filter { $0.intersects(window) }
            let windowedFrames = frames.filter { $0.intersects(window) }
            if let path = aStarAttempt(
                from: start, to: goal, hardObstacles: windowedHard, frames: windowedFrames, avoid: nearby, selfId: selfId) {
                return path
            }
        }
        return nil
    }

    private static func aStarAttempt(
        from start: BoardPoint, to goal: BoardPoint, hardObstacles: [BoardRect], frames: [BoardRect],
        avoid: [(a: BoardPoint, b: BoardPoint, id: String)], selfId: String
    ) -> [BoardPoint]? {
        var xsSet: Set<Int> = [start.x, goal.x]
        var ysSet: Set<Int> = [start.y, goal.y]
        for o in hardObstacles { xsSet.insert(o.minX); xsSet.insert(o.maxX); ysSet.insert(o.minY); ysSet.insert(o.maxY) }
        for o in frames { xsSet.insert(o.minX); xsSet.insert(o.maxX); ysSet.insert(o.minY); ysSet.insert(o.maxY) }
        let xs = insertMidpoints(xsSet.sorted())
        let ys = insertMidpoints(ysSet.sorted())
        guard let sx = xs.firstIndex(of: start.x), let sy = ys.firstIndex(of: start.y),
              let gx = xs.firstIndex(of: goal.x), let gy = ys.firstIndex(of: goal.y)
        else { return nil }

        // Only component and note boxes ever block a node — a foreign frame never does, so an
        // endpoint enclosed by frames still has somewhere to stand; it costs its way out instead.
        var blocked = [[Bool]](repeating: [Bool](repeating: false, count: ys.count), count: xs.count)
        for o in hardObstacles {
            let xLo = lowerBound(xs, strictlyGreaterThan: o.minX), xHi = upperBound(xs, strictlyLessThan: o.maxX)
            guard xLo <= xHi else { continue }
            let yLo = lowerBound(ys, strictlyGreaterThan: o.minY), yHi = upperBound(ys, strictlyLessThan: o.maxY)
            guard yLo <= yHi else { continue }
            for ix in xLo...xHi {
                for iy in yLo...yHi { blocked[ix][iy] = true }
            }
        }
        guard !blocked[sx][sy], !blocked[gx][gy] else { return nil }

        // Bucketed by exact coordinate so the cost function checks only the handful of existing
        // segments within `proximityRadius`, not every one of them, per edge.
        var avoidHorizontalByY: [Int: [(x0: Int, x1: Int, id: String)]] = [:]
        var avoidVerticalByX: [Int: [(y0: Int, y1: Int, id: String)]] = [:]
        for seg in avoid where seg.id != selfId {
            if seg.a.y == seg.b.y {
                avoidHorizontalByY[seg.a.y, default: []].append((min(seg.a.x, seg.b.x), max(seg.a.x, seg.b.x), seg.id))
            } else if seg.a.x == seg.b.x {
                avoidVerticalByX[seg.a.x, default: []].append((min(seg.a.y, seg.b.y), max(seg.a.y, seg.b.y), seg.id))
            }
        }

        // Every unit of length that runs strictly inside a foreign frame's inflated rect (not
        // merely touching its border) costs `frameCrossingCost` more — enough that A* only ever
        // crosses one when there is no way around it.
        func framePenalty(_ a: BoardPoint, _ b: BoardPoint) -> Double {
            guard !frames.isEmpty else { return 0 }
            var penalty = 0.0
            if a.y == b.y {
                let x0 = min(a.x, b.x), x1 = max(a.x, b.x)
                for rect in frames where a.y > rect.minY && a.y < rect.maxY {
                    let overlap = min(x1, rect.maxX) - max(x0, rect.minX)
                    if overlap > 0 { penalty += Double(overlap) * frameCrossingCost }
                }
            } else {
                let y0 = min(a.y, b.y), y1 = max(a.y, b.y)
                for rect in frames where a.x > rect.minX && a.x < rect.maxX {
                    let overlap = min(y1, rect.maxY) - max(y0, rect.minY)
                    if overlap > 0 { penalty += Double(overlap) * frameCrossingCost }
                }
            }
            return penalty
        }

        func cost(_ a: BoardPoint, _ b: BoardPoint) -> Double {
            let length = Double(abs(b.x - a.x) + abs(b.y - a.y))
            var penalty = framePenalty(a, b)
            guard !avoid.isEmpty else { return length + penalty }
            if a.y == b.y {
                let x0 = min(a.x, b.x), x1 = max(a.x, b.x)
                for dy in -proximityRadius...proximityRadius {
                    guard let bucket = avoidHorizontalByY[a.y + dy] else { continue }
                    for seg in bucket {
                        let overlap = min(x1, seg.x1) - max(x0, seg.x0)
                        if overlap > 0 { penalty += Double(overlap) * proximityWeight }
                    }
                }
            } else {
                let y0 = min(a.y, b.y), y1 = max(a.y, b.y)
                for dx in -proximityRadius...proximityRadius {
                    guard let bucket = avoidVerticalByX[a.x + dx] else { continue }
                    for seg in bucket {
                        let overlap = min(y1, seg.y1) - max(y0, seg.y0)
                        if overlap > 0 { penalty += Double(overlap) * proximityWeight }
                    }
                }
            }
            return length + penalty
        }

        func heuristic(_ ix: Int, _ iy: Int) -> Double {
            let dx = abs(xs[ix] - xs[gx]), dy = abs(ys[iy] - ys[gy])
            let bend = (dx != 0 && dy != 0) ? turnPenalty : 0.0
            return Double(dx + dy) + bend
        }

        // `bestG`/`cameFrom` are flat arrays keyed by a packed (ix, iy, dir) index rather than a
        // `GridState`-keyed dictionary — the search below pops a state per grid edge crossed, so
        // this is the hottest loop in the router; plain array indexing avoids hashing a struct on
        // every pop and every relaxed edge.
        let ysCount = ys.count
        func packed(_ ix: Int, _ iy: Int, _ dir: Int) -> Int { (ix * ysCount + iy) * 3 + dir }
        let stateCount = xs.count * ysCount * 3
        var bestG = [Double](repeating: .infinity, count: stateCount)
        var cameFrom = [Int](repeating: -1, count: stateCount)
        let startIndex = packed(sx, sy, 0)
        bestG[startIndex] = 0
        var heap = BinaryHeap<(state: GridState, index: Int, g: Double, f: Double)> { $0.f < $1.f }
        heap.push((GridState(ix: sx, iy: sy, dir: 0), startIndex, 0, heuristic(sx, sy)))

        while let current = heap.pop() {
            if current.g > bestG[current.index] { continue }
            if current.state.ix == gx, current.state.iy == gy {
                return reconstruct(cameFrom, current.index, xs: xs, ys: ys, ysCount: ysCount)
            }
            let (ix, iy, dir) = (current.state.ix, current.state.iy, current.state.dir)
            let a = BoardPoint(x: xs[ix], y: ys[iy])
            var neighbors: [(Int, Int, Int)] = []
            if ix > 0 { neighbors.append((ix - 1, iy, 1)) }
            if ix < xs.count - 1 { neighbors.append((ix + 1, iy, 1)) }
            if iy > 0 { neighbors.append((ix, iy - 1, 2)) }
            if iy < ys.count - 1 { neighbors.append((ix, iy + 1, 2)) }
            for (nix, niy, ndir) in neighbors {
                guard !blocked[nix][niy] else { continue }
                let b = BoardPoint(x: xs[nix], y: ys[niy])
                let turn = (dir != 0 && dir != ndir) ? turnPenalty : 0.0
                let newG = current.g + cost(a, b) + turn
                let newIndex = packed(nix, niy, ndir)
                if newG < bestG[newIndex] {
                    bestG[newIndex] = newG
                    cameFrom[newIndex] = current.index
                    heap.push((GridState(ix: nix, iy: niy, dir: ndir), newIndex, newG, newG + heuristic(nix, niy)))
                }
            }
        }
        return nil
    }

    /// The first index in the sorted `values` whose value is `> bound`; `values.count` when none is.
    private static func lowerBound(_ values: [Int], strictlyGreaterThan bound: Int) -> Int {
        var lo = 0, hi = values.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if values[mid] > bound { hi = mid } else { lo = mid + 1 }
        }
        return lo
    }

    /// The last index in the sorted `values` whose value is `< bound`; `-1` when none is.
    private static func upperBound(_ values: [Int], strictlyLessThan bound: Int) -> Int {
        var lo = 0, hi = values.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if values[mid] < bound { lo = mid + 1 } else { hi = mid }
        }
        return lo - 1
    }

    private static func insertMidpoints(_ values: [Int]) -> [Int] {
        guard values.count > 1 else { return values }
        var result: [Int] = []
        for i in values.indices {
            result.append(values[i])
            if i + 1 < values.count, values[i + 1] - values[i] >= 2 * clearance {
                let mid = (values[i] + values[i + 1]) / 2
                if mid != values[i], mid != values[i + 1] { result.append(mid) }
            }
        }
        return result
    }

    private static func reconstruct(_ cameFrom: [Int], _ end: Int, xs: [Int], ys: [Int], ysCount: Int) -> [BoardPoint] {
        var path: [Int] = [end]
        var current = end
        while cameFrom[current] != -1 {
            current = cameFrom[current]
            path.append(current)
        }
        return path.reversed().map { index in
            let ix = index / (ysCount * 3)
            let iy = (index / 3) % ysCount
            return BoardPoint(x: xs[ix], y: ys[iy])
        }
    }

    /// Last resort for an impossible board: A* found no path even after crossing every frame,
    /// which only happens when a stub itself sits inside a hard (box) obstacle — the endpoint is
    /// genuinely walled in. An empty path leaves just the source and target ports, so the route
    /// is a single straight segment between them; it may cut through a box, since nothing here
    /// promises a clean route once the board has sealed an endpoint in on every side.
    private static func lastResort() -> [BoardPoint] { [] }

    // MARK: - Binary heap

    private struct BinaryHeap<T> {
        private var items: [T] = []
        private let isLess: (T, T) -> Bool

        init(_ isLess: @escaping (T, T) -> Bool) { self.isLess = isLess }

        mutating func push(_ item: T) {
            items.append(item)
            var i = items.count - 1
            while i > 0 {
                let parent = (i - 1) / 2
                guard isLess(items[i], items[parent]) else { break }
                items.swapAt(i, parent)
                i = parent
            }
        }

        mutating func pop() -> T? {
            guard !items.isEmpty else { return nil }
            items.swapAt(0, items.count - 1)
            let result = items.removeLast()
            var i = 0
            while true {
                let l = 2 * i + 1, r = 2 * i + 2
                var smallest = i
                if l < items.count, isLess(items[l], items[smallest]) { smallest = l }
                if r < items.count, isLess(items[r], items[smallest]) { smallest = r }
                guard smallest != i else { break }
                items.swapAt(i, smallest)
                i = smallest
            }
            return result
        }
    }

    // MARK: - Nudging

    private enum Orientation { case horizontal, vertical }

    private struct NudgeSeg {
        let key: BoardModel.ArrowKey
        let index: Int
        let id: String
    }

    private static func nudge(
        _ routes: inout [BoardModel.ArrowKey: BoardRoute], obstaclesByArrow: [BoardModel.ArrowKey: [BoardRect]]
    ) {
        var horizontal: [Int: [NudgeSeg]] = [:]
        var vertical: [Int: [NudgeSeg]] = [:]

        for key in routes.keys.sorted(by: orderKey) {
            guard let points = routes[key]?.points, points.count >= 4 else { continue }
            // Per arrow, not per bundle: a bundle's shared segment is the one this loop's range
            // already excludes (index 0 for an out-bundle, the last for an in-bundle), so every
            // segment reaching here is already past the fan-out. Grouping those by the bundle's
            // id instead of the arrow's own would stop two members' fanned-out segments — now
            // genuinely different paths — from ever being recognised as different lanes.
            let id = arrowId(key)
            for i in 1..<(points.count - 2) {
                let a = points[i], b = points[i + 1]
                if a.y == b.y, a.x != b.x {
                    horizontal[a.y, default: []].append(NudgeSeg(key: key, index: i, id: id))
                } else if a.x == b.x, a.y != b.y {
                    vertical[a.x, default: []].append(NudgeSeg(key: key, index: i, id: id))
                }
            }
        }

        applyNudge(&routes, groups: horizontal, orientation: .horizontal, obstaclesByArrow: obstaclesByArrow)
        applyNudge(&routes, groups: vertical, orientation: .vertical, obstaclesByArrow: obstaclesByArrow)
    }

    private static func applyNudge(
        _ routes: inout [BoardModel.ArrowKey: BoardRoute], groups: [Int: [NudgeSeg]], orientation: Orientation,
        obstaclesByArrow: [BoardModel.ArrowKey: [BoardRect]]
    ) {
        for coord in groups.keys.sorted() {
            let segs = groups[coord]!
            let ranged: [(seg: NudgeSeg, lo: Int, hi: Int)] = segs.compactMap { seg in
                guard let points = routes[seg.key]?.points else { return nil }
                let a = points[seg.index], b = points[seg.index + 1]
                let (lo, hi) = orientation == .horizontal ? (min(a.x, b.x), max(a.x, b.x)) : (min(a.y, b.y), max(a.y, b.y))
                return (seg, lo, hi)
            }.sorted { $0.lo < $1.lo || ($0.lo == $1.lo && $0.seg.id < $1.seg.id) }

            var clusters: [[(seg: NudgeSeg, lo: Int, hi: Int)]] = []
            var current: [(seg: NudgeSeg, lo: Int, hi: Int)] = []
            var currentMax = Int.min
            for r in ranged {
                if !current.isEmpty, r.lo < currentMax {
                    current.append(r)
                    currentMax = max(currentMax, r.hi)
                } else {
                    if !current.isEmpty { clusters.append(current) }
                    current = [r]
                    currentMax = r.hi
                }
            }
            if !current.isEmpty { clusters.append(current) }

            for cluster in clusters {
                let distinctIds = Array(Set(cluster.map { $0.seg.id })).sorted()
                guard distinctIds.count >= 2 else { continue }
                let k = distinctIds.count
                var offsetFor: [String: Int] = [:]
                for (i, id) in distinctIds.enumerated() {
                    let raw = (Double(i) - Double(k - 1) / 2.0) * Double(laneGap)
                    offsetFor[id] = Int(raw.rounded())
                }
                for id in distinctIds {
                    guard let offset = offsetFor[id], offset != 0 else { continue }
                    let idSegs = cluster.filter { $0.seg.id == id }
                    var valid = true
                    for r in idSegs {
                        guard let points = routes[r.seg.key]?.points else { valid = false; break }
                        let a = points[r.seg.index], b = points[r.seg.index + 1]
                        let (newA, newB) = shifted(a, b, orientation: orientation, offset: offset)
                        let obstacles = obstaclesByArrow[r.seg.key] ?? []
                        if obstacles.contains(where: { BoardGeometry.segmentIntersects(newA, newB, $0) }) {
                            valid = false
                            break
                        }
                        // The two segments sharing this one's endpoints change shape too — one
                        // end moves with the shift, the other stays put — so a nudge that leaves
                        // the shifted segment clear can still swing a neighbour into a box. Both
                        // get the same check; either crossing reverts the whole shift.
                        if r.seg.index - 1 >= 0 {
                            let prevPoint = points[r.seg.index - 1]
                            if obstacles.contains(where: { BoardGeometry.segmentIntersects(prevPoint, newA, $0) }) {
                                valid = false
                                break
                            }
                        }
                        if r.seg.index + 2 < points.count {
                            let nextPoint = points[r.seg.index + 2]
                            if obstacles.contains(where: { BoardGeometry.segmentIntersects(newB, nextPoint, $0) }) {
                                valid = false
                                break
                            }
                        }
                    }
                    guard valid else { continue }
                    for r in idSegs {
                        guard var points = routes[r.seg.key]?.points else { continue }
                        let a = points[r.seg.index], b = points[r.seg.index + 1]
                        let (newA, newB) = shifted(a, b, orientation: orientation, offset: offset)
                        points[r.seg.index] = newA
                        points[r.seg.index + 1] = newB
                        routes[r.seg.key]?.points = points
                    }
                }
            }
        }
    }

    private static func shifted(_ a: BoardPoint, _ b: BoardPoint, orientation: Orientation, offset: Int) -> (BoardPoint, BoardPoint) {
        switch orientation {
        case .horizontal: return (BoardPoint(x: a.x, y: a.y + offset), BoardPoint(x: b.x, y: b.y + offset))
        case .vertical: return (BoardPoint(x: a.x + offset, y: a.y), BoardPoint(x: b.x + offset, y: b.y))
        }
    }
}

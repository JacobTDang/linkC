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

    // MARK: - Public entry point

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

        // 2. Bundles.
        let (bundleOf, outAnchors, inAnchors) = bundles(arrowKeys: arrowKeys, labelOf: labelOf, byLowercasedName: byLowercasedName)

        // Geometry shared by every arrow.
        let componentBox = Dictionary(uniqueKeysWithValues: map.components.compactMap { c -> (String, BoardRect)? in
            guard let at = c.at else { return nil }
            return (c.name.lowercased(), BoardGeometry.rect(ofComponentAt: at))
        })
        let noteBoxes = map.notes.compactMap { $0.at.map(BoardGeometry.rect(ofNoteAt:)) }
        let diagramBounds = boundsOfEverything(map: map, componentBoxes: Array(componentBox.values), noteBoxes: noteBoxes)

        var routedSegments: [(a: BoardPoint, b: BoardPoint, id: String)] = []
        var obstaclesByArrow: [BoardModel.ArrowKey: [BoardRect]] = [:]
        var results: [BoardModel.ArrowKey: BoardRoute] = [:]

        for key in arrowKeys {
            guard let source = byLowercasedName[key.from.lowercased()], let target = byLowercasedName[key.to.lowercased()],
                  let sourceAt = source.at, let targetAt = target.at
            else { continue }
            let sourceBox = BoardGeometry.rect(ofComponentAt: sourceAt)
            let targetBox = BoardGeometry.rect(ofComponentAt: targetAt)

            let obstacles = obstaclesFor(
                map: map, sourceName: source.name, targetName: target.name,
                sourcePlace: source.place, targetPlace: target.place, componentBox: componentBox, noteBoxes: noteBoxes)
            obstaclesByArrow[key] = obstacles

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
            if !forced, let straight = straightCase(sourceBox, sourceSide, targetBox, targetSide, obstacles) {
                points = straight
            } else {
                let sourceStub = stub(sourcePort, sourceSide)
                let targetStub = stub(targetPort, targetSide)
                let path = aStar(from: sourceStub, to: targetStub, obstacles: obstacles, avoid: routedSegments, selfId: selfId)
                    ?? outsideFallback(sourcePort: sourcePort, targetPort: targetPort, bounds: diagramBounds)
                points = simplify([sourcePort] + path + [targetPort])
            }

            results[key] = BoardRoute(points: points, bundle: bundleId)
            for (a, b) in zip(points, points.dropFirst()) {
                routedSegments.append((a: a, b: b, id: selfId))
            }
        }

        nudge(&results, obstaclesByArrow: obstaclesByArrow, bundleOf: bundleOf)
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

    private static func obstaclesFor(
        map: BoardMap, sourceName: String, targetName: String, sourcePlace: String, targetPlace: String,
        componentBox: [String: BoardRect], noteBoxes: [BoardRect]
    ) -> [BoardRect] {
        var result: [BoardRect] = []
        let sourceKey = sourceName.lowercased(), targetKey = targetName.lowercased()
        for component in map.components {
            let key = component.name.lowercased()
            guard key != sourceKey, key != targetKey, let box = componentBox[key] else { continue }
            result.append(inflate(box, by: clearance))
        }
        for box in noteBoxes { result.append(inflate(box, by: clearance)) }
        for frame in map.frames {
            guard let rect = frame.rect, frame.label != sourcePlace, frame.label != targetPlace else { continue }
            result.append(inflate(rect, by: clearance))
        }
        return result
    }

    private static func boundsOfEverything(map: BoardMap, componentBoxes: [BoardRect], noteBoxes: [BoardRect]) -> BoardRect {
        var rects = componentBoxes + noteBoxes
        rects.append(contentsOf: map.frames.compactMap(\.rect))
        guard !rects.isEmpty else { return BoardRect(x: 0, y: 0, w: 0, h: 0) }
        let minX = rects.map(\.minX).min()!, minY = rects.map(\.minY).min()!
        let maxX = rects.map(\.maxX).max()!, maxY = rects.map(\.maxY).max()!
        return BoardRect(x: minX, y: minY, w: maxX - minX, h: maxY - minY)
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
        from start: BoardPoint, to goal: BoardPoint, obstacles: [BoardRect],
        avoid: [(a: BoardPoint, b: BoardPoint, id: String)], selfId: String
    ) -> [BoardPoint]? {
        var expand = windowMargin
        for attempt in 0...maxWindowDoublings {
            if attempt > 0 { expand *= 2 }
            let minX = min(start.x, goal.x) - expand, maxX = max(start.x, goal.x) + expand
            let minY = min(start.y, goal.y) - expand, maxY = max(start.y, goal.y) + expand
            let window = BoardRect(x: minX, y: minY, w: maxX - minX, h: maxY - minY)
            let windowed = obstacles.filter { $0.intersects(window) }
            let nearby = avoid.filter {
                let lo = min($0.a.x, $0.b.x) - proximityRadius, hi = max($0.a.x, $0.b.x) + proximityRadius
                let top = min($0.a.y, $0.b.y) - proximityRadius, bottom = max($0.a.y, $0.b.y) + proximityRadius
                return lo <= window.maxX && hi >= window.minX && top <= window.maxY && bottom >= window.minY
            }
            if let path = aStarAttempt(from: start, to: goal, obstacles: windowed, avoid: nearby, selfId: selfId) {
                return path
            }
        }
        return nil
    }

    private static func aStarAttempt(
        from start: BoardPoint, to goal: BoardPoint, obstacles: [BoardRect],
        avoid: [(a: BoardPoint, b: BoardPoint, id: String)], selfId: String
    ) -> [BoardPoint]? {
        var xsSet: Set<Int> = [start.x, goal.x]
        var ysSet: Set<Int> = [start.y, goal.y]
        for o in obstacles { xsSet.insert(o.minX); xsSet.insert(o.maxX); ysSet.insert(o.minY); ysSet.insert(o.maxY) }
        let xs = insertMidpoints(xsSet.sorted())
        let ys = insertMidpoints(ysSet.sorted())
        guard let sx = xs.firstIndex(of: start.x), let sy = ys.firstIndex(of: start.y),
              let gx = xs.firstIndex(of: goal.x), let gy = ys.firstIndex(of: goal.y)
        else { return nil }

        var blocked = [[Bool]](repeating: [Bool](repeating: false, count: ys.count), count: xs.count)
        for o in obstacles {
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

        func cost(_ a: BoardPoint, _ b: BoardPoint) -> Double {
            let length = Double(abs(b.x - a.x) + abs(b.y - a.y))
            guard !avoid.isEmpty else { return length }
            var penalty = 0.0
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

        func heuristic(_ ix: Int, _ iy: Int) -> Double { Double(abs(xs[ix] - xs[gx]) + abs(ys[iy] - ys[gy])) }

        let startState = GridState(ix: sx, iy: sy, dir: 0)
        var bestG: [GridState: Double] = [startState: 0]
        var cameFrom: [GridState: GridState] = [:]
        var heap = BinaryHeap<(state: GridState, g: Double, f: Double)> { $0.f < $1.f }
        heap.push((startState, 0, heuristic(sx, sy)))

        while let current = heap.pop() {
            if current.g > (bestG[current.state] ?? .infinity) { continue }
            if current.state.ix == gx, current.state.iy == gy {
                return reconstruct(cameFrom, current.state, xs: xs, ys: ys)
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
                let newState = GridState(ix: nix, iy: niy, dir: ndir)
                if newG < (bestG[newState] ?? .infinity) {
                    bestG[newState] = newG
                    cameFrom[newState] = current.state
                    heap.push((newState, newG, newG + heuristic(nix, niy)))
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
            if i + 1 < values.count {
                let mid = (values[i] + values[i + 1]) / 2
                if mid != values[i], mid != values[i + 1] { result.append(mid) }
            }
        }
        return result
    }

    private static func reconstruct(_ cameFrom: [GridState: GridState], _ end: GridState, xs: [Int], ys: [Int]) -> [BoardPoint] {
        var path: [GridState] = [end]
        var current = end
        while let previous = cameFrom[current] {
            path.append(previous)
            current = previous
        }
        return path.reversed().map { BoardPoint(x: xs[$0.ix], y: ys[$0.iy]) }
    }

    /// A path around the outside of the whole diagram's bounding box — always obstacle-free
    /// since nothing on the map extends past it.
    private static func outsideFallback(sourcePort: BoardPoint, targetPort: BoardPoint, bounds: BoardRect) -> [BoardPoint] {
        let margin = clearance * 3
        let y = bounds.maxY + margin
        return [BoardPoint(x: sourcePort.x, y: y), BoardPoint(x: targetPort.x, y: y)]
    }

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
        _ routes: inout [BoardModel.ArrowKey: BoardRoute], obstaclesByArrow: [BoardModel.ArrowKey: [BoardRect]],
        bundleOf: [BoardModel.ArrowKey: String]
    ) {
        var horizontal: [Int: [NudgeSeg]] = [:]
        var vertical: [Int: [NudgeSeg]] = [:]

        for key in routes.keys.sorted(by: orderKey) {
            guard let points = routes[key]?.points, points.count >= 4 else { continue }
            let id = bundleOf[key] ?? arrowId(key)
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

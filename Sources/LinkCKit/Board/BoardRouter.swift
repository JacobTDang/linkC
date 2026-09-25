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
    /// inflated rect.
    private static let frameCrossingCost = 6.0
    /// The extra cost, per unit of length, of running through a box's inflated margin — its raw
    /// body stays a hard wall, but the 12 pt clearance band around it is only ever a cost, so two
    /// boxes packed a few points apart (well inside `clearance`) still leave a routable, if
    /// pricier, gap instead of sealing it off.
    private static let marginCrossingCost = 4.0
    /// How far outward and upward a self-loop reaches before turning back into the box.
    private static let selfLoopReach = 20

    // MARK: - Public entry point

    /// The Board never produces overlapping component or note boxes — `BoardModel.laidOut`
    /// separates them on load, and every spatial edit keeps that true — so this assumes no two
    /// boxes overlap and never checks for it.
    ///
    /// Checks `isCancelled` between arrows and returns whatever is routed so far the moment it
    /// sees one — the caller drops a cancelled result outright, so routing the rest would be
    /// wasted work. Sync and pure, so a plain closure can check it; `isCancelled` is injectable
    /// so a test can drive it deterministically instead of racing a real `Task`.
    public static func routes(for map: BoardMap, isCancelled: () -> Bool = { Task.isCancelled }) -> [BoardModel.ArrowKey: BoardRoute] {
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
            for (targetName, arrow) in component.uses {
                guard let target = byLowercasedName[targetName.lowercased()] else { continue }
                labelOf[BoardModel.ArrowKey(from: component.name, to: target.name)] = arrow.label
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

        // 3. Spread ends: which side, and which port on it, every non-self arrow's two ends use —
        // decided once, up front, so unbundled ends sharing a side of the same box spread across a
        // band instead of all landing on the exact same midpoint.
        let endAssignments = spreadEnds(
            keys: bundleableKeys, bundleOf: bundleOf, outAnchors: outAnchors, inAnchors: inAnchors, componentBox: componentBox)

        var routedSegments: [(a: BoardPoint, b: BoardPoint, id: String)] = []
        var obstaclesByArrow: [BoardModel.ArrowKey: [BoardRect]] = [:]
        var results: [BoardModel.ArrowKey: BoardRoute] = [:]

        for key in arrowKeys {
            guard !isCancelled() else { return results }
            guard let source = byLowercasedName[key.from.lowercased()], let target = byLowercasedName[key.to.lowercased()],
                  let sourceAt = source.at, let targetAt = target.at
            else { continue }
            let sourceBox = BoardGeometry.rect(ofComponentAt: sourceAt)
            let targetBox = BoardGeometry.rect(ofComponentAt: targetAt)

            let (othersRaw, frameObstacles) = obstaclesFor(
                map: map, sourceName: source.name, targetName: target.name,
                sourceBox: sourceBox, targetBox: targetBox, componentBox: componentBox, noteBoxes: noteBoxes)
            // This arrow's own two boxes stay hard too — a route may never run through its own
            // end box, only touch it at the stub where it leaves or enters — so they join every
            // other box's raw rect as an obstacle A* itself must route around, not just a target
            // the stub logic pushes away from.
            let rawObstacles = othersRaw + [sourceBox, targetBox]
            let marginObstacles = rawObstacles.map { inflate($0, by: clearance) }
            obstaclesByArrow[key] = rawObstacles

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

            guard let ends = endAssignments[key] else { continue }
            let sourceSide = ends.sourceSide
            let targetSide = ends.targetSide
            let sourcePort = ends.sourcePort
            let targetPort = ends.targetPort
            let forced = ends.forced

            var points: [BoardPoint]
            if !forced, let straight = straightCase(
                sourceBox, sourceSide, sourcePort, targetBox, targetSide, targetPort,
                sourceGroupSize: ends.sourceGroupSize, targetGroupSize: ends.targetGroupSize, othersRaw + frameObstacles
            ) {
                points = straight
            } else {
                // "Add what's running" packs boxes a few points apart, well inside `clearance` —
                // a stub pushed the full `clearance` out could land inside a neighbour's raw
                // body, not just its margin. The push stops at the nearest raw obstacle instead,
                // so the stub itself is never inside anything solid, only possibly its margin.
                // (Never this arrow's own boxes — a stub pushes outward, away from its own box,
                // so it can never land back inside it.)
                let sourceStub = stub(sourcePort, sourceSide, avoiding: othersRaw)
                let targetStub = stub(targetPort, targetSide, avoiding: othersRaw)
                let path = aStar(
                    from: sourceStub, to: targetStub, rawObstacles: rawObstacles, marginObstacles: marginObstacles,
                    frames: frameObstacles, avoid: routedSegments, selfId: selfId) ?? lastResort()
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

    /// A bundle's anchor: which side of its own box it leaves from, that box's lowercased name (so
    /// the spreading pass can group it with any unbundled arrow sharing the same box and side),
    /// and the mean centre of the other ends — the ordering key `bundles` already computes, spent
    /// again for the anchor's slot when the spreading pass orders it among siblings.
    private static func bundles(
        arrowKeys: [BoardModel.ArrowKey], labelOf: [BoardModel.ArrowKey: String], byLowercasedName: [String: BoardComponent]
    ) -> (
        bundleOf: [BoardModel.ArrowKey: String], outAnchors: [String: (side: Side, name: String, mean: BoardPoint)],
        inAnchors: [String: (side: Side, name: String, mean: BoardPoint)]
    ) {
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

        // Anchors: one shared side per bundle, from the bundled box's centre toward the mean
        // centre of the other ends it bundles with. The spreading pass turns this into the
        // bundle's actual slot point, once it knows who else shares that box's side.
        var outAnchors: [String: (side: Side, name: String, mean: BoardPoint)] = [:]
        for (id, keys) in groupedById(bundleOf, prefix: "out:") {
            guard let source = byLowercasedName[keys[0].from.lowercased()], let at = source.at else { continue }
            let box = BoardGeometry.rect(ofComponentAt: at)
            let others = keys.compactMap { byLowercasedName[$0.to.lowercased()]?.at }.map(BoardGeometry.rect(ofComponentAt:))
            guard !others.isEmpty else { continue }
            let mean = meanCenter(others)
            let side = sides(from: box.center, to: mean).0
            outAnchors[id] = (side, source.name.lowercased(), mean)
        }
        var inAnchors: [String: (side: Side, name: String, mean: BoardPoint)] = [:]
        for (id, keys) in groupedById(bundleOf, prefix: "in:") {
            guard let target = byLowercasedName[keys[0].to.lowercased()], let at = target.at else { continue }
            let box = BoardGeometry.rect(ofComponentAt: at)
            let others = keys.compactMap { byLowercasedName[$0.from.lowercased()]?.at }.map(BoardGeometry.rect(ofComponentAt:))
            guard !others.isEmpty else { continue }
            let mean = meanCenter(others)
            let side = sides(from: mean, to: box.center).1
            inAnchors[id] = (side, target.name.lowercased(), mean)
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

    private enum Side: Hashable { case left, right, top, bottom }

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

    /// How far `port` can push outward, on `side`, before it would enter a raw obstacle — capped
    /// at `clearance`, floored at 0 (right at the port, when a neighbour leaves no room at all).
    /// Raw boxes stay hard no matter how tightly the board is packed.
    private static func safePushDistance(from port: BoardPoint, side: Side, rawObstacles: [BoardRect]) -> Int {
        var distance = clearance
        for rect in rawObstacles {
            switch side {
            case .right:
                guard rect.minX >= port.x, port.y > rect.minY, port.y < rect.maxY else { continue }
                distance = min(distance, rect.minX - port.x)
            case .left:
                guard rect.maxX <= port.x, port.y > rect.minY, port.y < rect.maxY else { continue }
                distance = min(distance, port.x - rect.maxX)
            case .bottom:
                guard rect.minY >= port.y, port.x > rect.minX, port.x < rect.maxX else { continue }
                distance = min(distance, rect.minY - port.y)
            case .top:
                guard rect.maxY <= port.y, port.x > rect.minX, port.x < rect.maxX else { continue }
                distance = min(distance, port.y - rect.maxY)
            }
        }
        return max(0, distance)
    }

    private static func stub(_ port: BoardPoint, _ side: Side, avoiding rawObstacles: [BoardRect]) -> BoardPoint {
        let o = outward(side)
        let distance = safePushDistance(from: port, side: side, rawObstacles: rawObstacles)
        return BoardPoint(x: port.x + o.dx * distance, y: port.y + o.dy * distance)
    }

    // MARK: - Spread ends

    /// Half the width of the band, around a side's own midpoint, that its ends spread across: 16
    /// pt on a left or right side, 48 on a top or bottom one — wide enough on the short sides
    /// without the offset ever reaching past a component's own corner (half-height 42, half-width
    /// 88).
    private static func bandHalfWidth(_ side: Side) -> Double {
        switch side {
        case .left, .right: return 16
        case .top, .bottom: return 48
        }
    }

    private static func isHorizontalAxis(_ side: Side) -> Bool { side == .left || side == .right }

    /// Where one arrow's end lands, and how it was decided: `sourceSide`/`targetSide` exactly as
    /// the main loop would compute them today, `sourcePort`/`targetPort` its slot on that side —
    /// `sidePort` unchanged when it has that side to itself, spread across a band when it shares
    /// the side with others — and `forced`, true whenever either end is a bundle's anchor (so the
    /// main loop skips `straightCase` for it, as it always has). `sourceGroupSize`/
    /// `targetGroupSize` say how many ends share that box's side, for `straightCase` to know which
    /// port, if either, is still free to move.
    private struct EndAssignment {
        let sourceSide: Side
        let sourcePort: BoardPoint
        let targetSide: Side
        let targetPort: BoardPoint
        let forced: Bool
        let sourceGroupSize: Int
        let targetGroupSize: Int
    }

    private struct SideGroupKey: Hashable { let name: String; let side: Side }

    private enum SideParticipant {
        case individual(BoardModel.ArrowKey, isSource: Bool)
        case bundle(String)
    }

    private struct SideEntry {
        let orderValue: Int
        let id: String
        let participant: SideParticipant
    }

    /// A pre-pass, run once before the main loop routes anything: for every non-self arrow, the
    /// side and port each of its two ends attaches to. Unbundled ends attaching to the same side
    /// of the same box spread evenly across a band instead of all landing on the side's exact
    /// midpoint; a bundle counts once, at its anchor, for its bundled end. Deterministic: within a
    /// side, ends are ordered by their other end's centre along the side's axis, ties broken by
    /// the arrow id (or the bundle id).
    private static func spreadEnds(
        keys: [BoardModel.ArrowKey], bundleOf: [BoardModel.ArrowKey: String],
        outAnchors: [String: (side: Side, name: String, mean: BoardPoint)],
        inAnchors: [String: (side: Side, name: String, mean: BoardPoint)], componentBox: [String: BoardRect]
    ) -> [BoardModel.ArrowKey: EndAssignment] {
        struct KeySides { let sourceSide: Side; let sourceBundle: String?; let targetSide: Side; let targetBundle: String?; let forced: Bool }

        var keySides: [BoardModel.ArrowKey: KeySides] = [:]
        var groups: [SideGroupKey: [SideEntry]] = [:]

        for key in keys {
            guard let sourceBox = componentBox[key.from.lowercased()], let targetBox = componentBox[key.to.lowercased()] else { continue }
            let bundleId = bundleOf[key]
            let sourceSide: Side, targetSide: Side, sourceBundle: String?, targetBundle: String?, forced: Bool
            if let bundleId, bundleId.hasPrefix("out:"), let anchor = outAnchors[bundleId] {
                sourceSide = anchor.side
                targetSide = sides(from: sourceBox.center, to: targetBox.center).1
                sourceBundle = bundleId
                targetBundle = nil
                forced = true
            } else if let bundleId, bundleId.hasPrefix("in:"), let anchor = inAnchors[bundleId] {
                targetSide = anchor.side
                sourceSide = sides(from: sourceBox.center, to: targetBox.center).0
                targetBundle = bundleId
                sourceBundle = nil
                forced = true
            } else {
                (sourceSide, targetSide) = sides(from: sourceBox.center, to: targetBox.center)
                sourceBundle = nil
                targetBundle = nil
                forced = false
            }
            keySides[key] = KeySides(sourceSide: sourceSide, sourceBundle: sourceBundle, targetSide: targetSide, targetBundle: targetBundle, forced: forced)

            if sourceBundle == nil {
                let groupKey = SideGroupKey(name: key.from.lowercased(), side: sourceSide)
                let orderValue = isHorizontalAxis(sourceSide) ? targetBox.center.y : targetBox.center.x
                groups[groupKey, default: []].append(SideEntry(orderValue: orderValue, id: arrowId(key), participant: .individual(key, isSource: true)))
            }
            if targetBundle == nil {
                let groupKey = SideGroupKey(name: key.to.lowercased(), side: targetSide)
                let orderValue = isHorizontalAxis(targetSide) ? sourceBox.center.y : sourceBox.center.x
                groups[groupKey, default: []].append(SideEntry(orderValue: orderValue, id: arrowId(key), participant: .individual(key, isSource: false)))
            }
        }

        // Each bundle counts once, at its own anchor side, ordered by the mean centre `bundles`
        // already computed for it.
        for (id, anchor) in outAnchors {
            let groupKey = SideGroupKey(name: anchor.name, side: anchor.side)
            let orderValue = isHorizontalAxis(anchor.side) ? anchor.mean.y : anchor.mean.x
            groups[groupKey, default: []].append(SideEntry(orderValue: orderValue, id: id, participant: .bundle(id)))
        }
        for (id, anchor) in inAnchors {
            let groupKey = SideGroupKey(name: anchor.name, side: anchor.side)
            let orderValue = isHorizontalAxis(anchor.side) ? anchor.mean.y : anchor.mean.x
            groups[groupKey, default: []].append(SideEntry(orderValue: orderValue, id: id, participant: .bundle(id)))
        }

        var individualSourcePort: [BoardModel.ArrowKey: BoardPoint] = [:]
        var individualTargetPort: [BoardModel.ArrowKey: BoardPoint] = [:]
        var bundlePort: [String: BoardPoint] = [:]
        var groupSize: [SideGroupKey: Int] = [:]

        for (groupKey, entries) in groups {
            groupSize[groupKey] = entries.count
            guard let box = componentBox[groupKey.name] else { continue }
            let ordered = entries.sorted { $0.orderValue != $1.orderValue ? $0.orderValue < $1.orderValue : $0.id < $1.id }
            let n = ordered.count
            for (i, entry) in ordered.enumerated() {
                let point: BoardPoint
                if n == 1 {
                    point = sidePort(box, groupKey.side)
                } else {
                    let band = bandHalfWidth(groupKey.side)
                    let offset = Int((-band + (Double(i) + 0.5) * (2 * band / Double(n))).rounded())
                    switch groupKey.side {
                    case .left: point = BoardPoint(x: box.minX, y: box.center.y + offset)
                    case .right: point = BoardPoint(x: box.maxX, y: box.center.y + offset)
                    case .top: point = BoardPoint(x: box.center.x + offset, y: box.minY)
                    case .bottom: point = BoardPoint(x: box.center.x + offset, y: box.maxY)
                    }
                }
                switch entry.participant {
                case .individual(let key, let isSource):
                    if isSource { individualSourcePort[key] = point } else { individualTargetPort[key] = point }
                case .bundle(let id):
                    bundlePort[id] = point
                }
            }
        }

        var result: [BoardModel.ArrowKey: EndAssignment] = [:]
        for key in keys {
            guard let sides = keySides[key] else { continue }
            let sourcePort = sides.sourceBundle.flatMap { bundlePort[$0] } ?? individualSourcePort[key]
            let targetPort = sides.targetBundle.flatMap { bundlePort[$0] } ?? individualTargetPort[key]
            guard let sourcePort, let targetPort else { continue }
            let sourceGroupSize = groupSize[SideGroupKey(name: key.from.lowercased(), side: sides.sourceSide)] ?? 1
            let targetGroupSize = groupSize[SideGroupKey(name: key.to.lowercased(), side: sides.targetSide)] ?? 1
            result[key] = EndAssignment(
                sourceSide: sides.sourceSide, sourcePort: sourcePort, targetSide: sides.targetSide, targetPort: targetPort,
                forced: sides.forced, sourceGroupSize: sourceGroupSize, targetGroupSize: targetGroupSize)
        }
        return result
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

    /// A straight line needs one shared coordinate along the overlap of the two boxes. When a
    /// side has more than one end, its port is a fixed slot the other members are ordered
    /// against, so it can't move to meet the other side — but a side with only one end has
    /// nothing to stay in step with, and can freely take on the other port's coordinate instead of
    /// forcing the true midpoint. Prefers moving the target to the source, then the source to the
    /// target, then the shared midpoint when both are free to move; otherwise no straight line
    /// exists and A* routes it.
    private static func straightCase(
        _ sourceBox: BoardRect, _ sourceSide: Side, _ sourcePort: BoardPoint,
        _ targetBox: BoardRect, _ targetSide: Side, _ targetPort: BoardPoint,
        sourceGroupSize: Int, targetGroupSize: Int, _ obstacles: [BoardRect]
    ) -> [BoardPoint]? {
        switch (sourceSide, targetSide) {
        case (.right, .left), (.left, .right):
            let lo = max(sourceBox.minY, targetBox.minY), hi = min(sourceBox.maxY, targetBox.maxY)
            guard lo < hi else { return nil }
            let sourceX = sourceSide == .right ? sourceBox.maxX : sourceBox.minX
            let targetX = targetSide == .left ? targetBox.minX : targetBox.maxX
            let y: Int
            if targetPort.y >= lo, targetPort.y <= hi, sourceGroupSize == 1 {
                y = targetPort.y
            } else if sourcePort.y >= lo, sourcePort.y <= hi, targetGroupSize == 1 {
                y = sourcePort.y
            } else if sourceGroupSize == 1, targetGroupSize == 1 {
                y = (lo + hi) / 2
            } else {
                return nil
            }
            let a = BoardPoint(x: sourceX, y: y), b = BoardPoint(x: targetX, y: y)
            guard !obstacles.contains(where: { BoardGeometry.segmentIntersects(a, b, $0) }) else { return nil }
            return [a, b]
        case (.bottom, .top), (.top, .bottom):
            let lo = max(sourceBox.minX, targetBox.minX), hi = min(sourceBox.maxX, targetBox.maxX)
            guard lo < hi else { return nil }
            let sourceY = sourceSide == .bottom ? sourceBox.maxY : sourceBox.minY
            let targetY = targetSide == .top ? targetBox.minY : targetBox.maxY
            let x: Int
            if targetPort.x >= lo, targetPort.x <= hi, sourceGroupSize == 1 {
                x = targetPort.x
            } else if sourcePort.x >= lo, sourcePort.x <= hi, targetGroupSize == 1 {
                x = sourcePort.x
            } else if sourceGroupSize == 1, targetGroupSize == 1 {
                x = (lo + hi) / 2
            } else {
                return nil
            }
            let a = BoardPoint(x: x, y: sourceY), b = BoardPoint(x: x, y: targetY)
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

    /// Every component and note box's *raw* rect except this arrow's own two ends — the caller
    /// adds those back in, since they stay hard too but must never enter the stub-push
    /// calculation (a stub pushes outward from its own box, never toward it). Raw, not inflated:
    /// the caller derives the soft margin band from these itself. Separately, the foreign frames
    /// — inflated, and still soft everywhere — except one whose *geometry* holds either end's box
    /// centre. Geometry always wins over a hand-edited `place` that disagrees with it — a
    /// component's `place` plays no part here.
    private static func obstaclesFor(
        map: BoardMap, sourceName: String, targetName: String, sourceBox: BoardRect, targetBox: BoardRect,
        componentBox: [String: BoardRect], noteBoxes: [BoardRect]
    ) -> (othersRaw: [BoardRect], frames: [BoardRect]) {
        var othersRaw: [BoardRect] = []
        let sourceKey = sourceName.lowercased(), targetKey = targetName.lowercased()
        for component in map.components {
            let key = component.name.lowercased()
            guard key != sourceKey, key != targetKey, let box = componentBox[key] else { continue }
            othersRaw.append(box)
        }
        othersRaw.append(contentsOf: noteBoxes)

        var frames: [BoardRect] = []
        for frame in map.frames {
            guard let rect = frame.rect, !rect.contains(sourceBox.center), !rect.contains(targetBox.center) else { continue }
            frames.append(inflate(rect, by: clearance))
        }
        return (othersRaw, frames)
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
        from start: BoardPoint, to goal: BoardPoint, rawObstacles: [BoardRect], marginObstacles: [BoardRect], frames: [BoardRect],
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
            let windowedRaw = rawObstacles.filter { $0.intersects(window) }
            let windowedMargins = marginObstacles.filter { $0.intersects(window) }
            let windowedFrames = frames.filter { $0.intersects(window) }
            if let path = aStarAttempt(
                from: start, to: goal, rawObstacles: windowedRaw, marginObstacles: windowedMargins, frames: windowedFrames,
                avoid: nearby, selfId: selfId) {
                return path
            }
        }
        return nil
    }

    private static func aStarAttempt(
        from start: BoardPoint, to goal: BoardPoint, rawObstacles: [BoardRect], marginObstacles: [BoardRect], frames: [BoardRect],
        avoid: [(a: BoardPoint, b: BoardPoint, id: String)], selfId: String
    ) -> [BoardPoint]? {
        // `marginObstacles` never contributes coordinates of its own: `crossingPenalty` below
        // measures each edge's exact overlap with a margin rect directly, so a grid line at the
        // margin's own boundary is never needed for a correct cost — only for a waypoint exactly
        // there, which the search can live without. Doubling the grid to carry both a box's raw
        // edges and its margin's is real cost for no correctness gain.
        var xsSet: Set<Int> = [start.x, goal.x]
        var ysSet: Set<Int> = [start.y, goal.y]
        for o in rawObstacles { xsSet.insert(o.minX); xsSet.insert(o.maxX); ysSet.insert(o.minY); ysSet.insert(o.maxY) }
        for o in frames { xsSet.insert(o.minX); xsSet.insert(o.maxX); ysSet.insert(o.minY); ysSet.insert(o.maxY) }
        // A 0–4 pt gap between two packed raw boxes is narrower than the general dense-grid fill
        // below ever kicks in for (it only fires at `2 × clearance` or wider), so without this
        // the corridor between them would carry no line of its own to route down.
        let (gapXs, gapYs) = gapMidpoints(rawObstacles)
        xsSet.formUnion(gapXs)
        ysSet.formUnion(gapYs)
        let xs = insertMidpoints(xsSet.sorted())
        let ys = insertMidpoints(ysSet.sorted())
        guard let sx = xs.firstIndex(of: start.x), let sy = ys.firstIndex(of: start.y),
              let gx = xs.firstIndex(of: goal.x), let gy = ys.firstIndex(of: goal.y)
        else { return nil }

        // Only a box's *raw* rect ever blocks a node — its inflated margin, a foreign frame, and
        // another arrow's already-routed segments are all costs, never walls, so an endpoint
        // hemmed in by nothing but those still has somewhere to stand and costs its way out
        // instead. This arrow's own two end boxes are hard here too (the caller folds them into
        // `rawObstacles`); their ports and stubs always sit exactly on a raw edge, never inside
        // one, so they are never blocked by their own box.
        var blocked = [[Bool]](repeating: [Bool](repeating: false, count: ys.count), count: xs.count)
        for o in rawObstacles {
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

        // Every margin (unlike a frame) touches nearly every edge the search relaxes — this is
        // the hottest loop in the router — so which margins are even in play at a given grid line
        // is worth knowing up front rather than rescanning the full list per edge. Bucketed by
        // grid index (the axis an edge holds fixed), the same binary search the `blocked` pass
        // above uses. Frames get the same treatment for the same reason, even though they are
        // usually empty in practice.
        func bucketByLine(_ rects: [BoardRect], lines: [Int], onMinMax: (BoardRect) -> (Int, Int)) -> [[BoardRect]] {
            var buckets = [[BoardRect]](repeating: [], count: lines.count)
            guard !rects.isEmpty else { return buckets }
            for rect in rects {
                let (lo, hi) = onMinMax(rect)
                let iLo = lowerBound(lines, strictlyGreaterThan: lo), iHi = upperBound(lines, strictlyLessThan: hi)
                guard iLo <= iHi else { continue }
                for i in iLo...iHi { buckets[i].append(rect) }
            }
            return buckets
        }
        let marginsByYIndex = bucketByLine(marginObstacles, lines: ys) { ($0.minY, $0.maxY) }
        let marginsByXIndex = bucketByLine(marginObstacles, lines: xs) { ($0.minX, $0.maxX) }
        let framesByYIndex = bucketByLine(frames, lines: ys) { ($0.minY, $0.maxY) }
        let framesByXIndex = bucketByLine(frames, lines: xs) { ($0.minX, $0.maxX) }

        /// `fixedIndex` is the grid index of the axis this edge holds constant — `iy` for a
        /// horizontal edge, `ix` for a vertical one — so the margin/frame buckets above can be
        /// looked up directly instead of rescanned.
        func cost(_ a: BoardPoint, _ b: BoardPoint, fixedIndex: Int) -> Double {
            let length = Double(abs(b.x - a.x) + abs(b.y - a.y))
            var penalty = 0.0
            if a.y == b.y {
                let x0 = min(a.x, b.x), x1 = max(a.x, b.x)
                for rect in marginsByYIndex[fixedIndex] {
                    let overlap = min(x1, rect.maxX) - max(x0, rect.minX)
                    if overlap > 0 { penalty += Double(overlap) * marginCrossingCost }
                }
                for rect in framesByYIndex[fixedIndex] {
                    let overlap = min(x1, rect.maxX) - max(x0, rect.minX)
                    if overlap > 0 { penalty += Double(overlap) * frameCrossingCost }
                }
                guard !avoid.isEmpty else { return length + penalty }
                for dy in -proximityRadius...proximityRadius {
                    guard let bucket = avoidHorizontalByY[a.y + dy] else { continue }
                    for seg in bucket {
                        let overlap = min(x1, seg.x1) - max(x0, seg.x0)
                        if overlap > 0 { penalty += Double(overlap) * proximityWeight }
                    }
                }
            } else {
                let y0 = min(a.y, b.y), y1 = max(a.y, b.y)
                for rect in marginsByXIndex[fixedIndex] {
                    let overlap = min(y1, rect.maxY) - max(y0, rect.minY)
                    if overlap > 0 { penalty += Double(overlap) * marginCrossingCost }
                }
                for rect in framesByXIndex[fixedIndex] {
                    let overlap = min(y1, rect.maxY) - max(y0, rect.minY)
                    if overlap > 0 { penalty += Double(overlap) * frameCrossingCost }
                }
                guard !avoid.isEmpty else { return length + penalty }
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
                let newG = current.g + cost(a, b, fixedIndex: ndir == 1 ? iy : ix) + turn
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

    /// The midpoint of the gap between each pair of raw obstacles that face each other along one
    /// axis, with their other-axis spans overlapping — the coordinate a route needs in order to
    /// run straight down the middle of two boxes packed only a few points apart, where nothing
    /// else places a grid line inside that gap. Only gaps narrower than `insertMidpoints`' own
    /// `2 × clearance` threshold need this; a wider one already gets a midpoint from the general
    /// dense-grid fill it does. Sorted sweeps, each stopping once the next box is too far past
    /// `bound` to matter, keep this close to linear instead of the full pairwise scan a naive
    /// version would need.
    private static func gapMidpoints(_ rects: [BoardRect]) -> (xs: [Int], ys: [Int]) {
        let bound = 2 * clearance
        var xs: [Int] = []
        let byMinX = rects.sorted { $0.minX < $1.minX }
        for i in byMinX.indices {
            let a = byMinX[i]
            var j = i + 1
            // `byMinX[j].minX` only grows with `j`, so once this gap reaches `bound` no later
            // `j` can be closer — safe to stop the sweep there.
            while j < byMinX.count, byMinX[j].minX - a.maxX < bound {
                let b = byMinX[j]
                if a.maxX <= b.minX, a.minY < b.maxY, b.minY < a.maxY {
                    xs.append((a.maxX + b.minX) / 2)
                }
                j += 1
            }
        }
        var ys: [Int] = []
        let byMinY = rects.sorted { $0.minY < $1.minY }
        for i in byMinY.indices {
            let a = byMinY[i]
            var j = i + 1
            while j < byMinY.count, byMinY[j].minY - a.maxY < bound {
                let b = byMinY[j]
                if a.maxY <= b.minY, a.minX < b.maxX, b.minX < a.maxX {
                    ys.append((a.maxY + b.minY) / 2)
                }
                j += 1
            }
        }
        return (xs, ys)
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

    /// Last resort for an impossible board: A* found no path even after costing its way through
    /// every margin and every frame, which only happens when raw boxes themselves — always hard,
    /// however tightly the board is packed — leave no orthogonal way out at all. An empty path
    /// leaves just the source and target ports, so the route is a single straight segment between
    /// them; it may cut through a box, since nothing here promises a clean route once the board
    /// has sealed an endpoint in on every side.
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

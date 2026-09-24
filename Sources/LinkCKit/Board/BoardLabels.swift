import Foundation

/// Where each labelled arrow's pill goes, so it never overlaps a box, a frame title or another
/// label. Pure, nonisolated and deterministic — the same routes, labels and obstacles always
/// yield the same placement. Ties break by `ArrowKey`, via its names, lowercased.
public enum BoardLabels {
    public static let height = 18

    private static let charWidth = 5.8
    private static let horizontalPadding = 14
    /// How much longer than the pill a horizontal segment must be to be a candidate at all.
    private static let horizontalSlack = 8
    private static let horizontalStep = 10
    /// How long a vertical segment must be to be a candidate at all.
    private static let verticalMinLength = 30
    private static let verticalStep = 8

    /// The pill's width for a label: 10 pt text estimated at 5.8 pt per character, plus 14 pt of
    /// padding.
    public static func width(of label: String) -> Int {
        Int((Double(label.count) * charWidth).rounded()) + horizontalPadding
    }

    /// Where each labelled arrow's pill goes; an arrow with no room is absent.
    public static func placed(
        routes: [BoardModel.ArrowKey: BoardRoute], labels: [BoardModel.ArrowKey: String], obstacles: [BoardRect]
    ) -> [BoardModel.ArrowKey: BoardRect] {
        var result: [BoardModel.ArrowKey: BoardRect] = [:]
        var placedPills: [BoardRect] = []

        func accepted(_ rect: BoardRect) -> Bool {
            !obstacles.contains(where: rect.intersects) && !placedPills.contains(where: rect.intersects)
        }

        // Bundles first, one label each, taken from the bundle's lowest `ArrowKey`.
        var bundleMembers: [String: [BoardModel.ArrowKey]] = [:]
        for key in labels.keys {
            guard let bundle = routes[key]?.bundle else { continue }
            bundleMembers[bundle, default: []].append(key)
        }
        let bundleIds = bundleMembers.keys.sorted { lhs, rhs in
            orderKey(bundleMembers[lhs]!.min(by: orderKey)!, bundleMembers[rhs]!.min(by: orderKey)!)
        }

        var bundled: Set<BoardModel.ArrowKey> = []
        for id in bundleIds {
            let members = bundleMembers[id]!
            bundled.formUnion(members)
            guard let key = members.min(by: orderKey), let route = routes[key], let label = labels[key],
                  let segment = sharedSegment(of: route)
            else { continue }
            if let rect = place(label: label, segments: [segment], accepted: accepted) {
                result[key] = rect
                placedPills.append(rect)
            }
        }

        // Then the remaining arrows by route length, longest first, with ties by key.
        let remaining = labels.keys
            .filter { !bundled.contains($0) && routes[$0] != nil }
            .sorted { a, b in
                let la = length(of: routes[a]!.points), lb = length(of: routes[b]!.points)
                return la != lb ? la > lb : orderKey(a, b)
            }
        for key in remaining {
            guard let route = routes[key], let label = labels[key] else { continue }
            let segments = Array(zip(route.points, route.points.dropFirst()))
            if let rect = place(label: label, segments: segments, accepted: accepted) {
                result[key] = rect
                placedPills.append(rect)
            }
        }

        return result
    }

    /// The obstacles for a map: every component and note box, and each frame's title band.
    public static func obstacles(for map: BoardMap) -> [BoardRect] {
        var result: [BoardRect] = []
        for component in map.components {
            if let at = component.at { result.append(BoardGeometry.rect(ofComponentAt: at)) }
        }
        for note in map.notes {
            if let at = note.at { result.append(BoardGeometry.rect(ofNoteAt: at)) }
        }
        for frame in map.frames {
            if let rect = frame.rect {
                result.append(BoardRect(x: rect.x, y: rect.y, w: rect.w, h: BoardLayout.frameTitleBand))
            }
        }
        return result
    }

    // MARK: - Ordering

    private static func orderKey(_ a: BoardModel.ArrowKey, _ b: BoardModel.ArrowKey) -> Bool {
        (a.from.lowercased(), a.to.lowercased()) < (b.from.lowercased(), b.to.lowercased())
    }

    private static func length(of points: [BoardPoint]) -> Int {
        zip(points, points.dropFirst()).reduce(0) { $0 + abs($1.1.x - $1.0.x) + abs($1.1.y - $1.0.y) }
    }

    /// The segment a bundle shares: the first, out of the source, or the last, into the target.
    private static func sharedSegment(of route: BoardRoute) -> (BoardPoint, BoardPoint)? {
        guard let bundle = route.bundle, route.points.count >= 2 else { return nil }
        if bundle.hasPrefix("in:") {
            return (route.points[route.points.count - 2], route.points[route.points.count - 1])
        }
        return (route.points[0], route.points[1])
    }

    // MARK: - Candidate search

    /// The first accepted pill among a route's candidates: its horizontal segments long enough,
    /// longest first, sliding from each one's centre outwards in 10 pt steps; then its vertical
    /// segments long enough, the pill centred on the line, sliding the same way in 8 pt steps.
    private static func place(label: String, segments: [(BoardPoint, BoardPoint)], accepted: (BoardRect) -> Bool) -> BoardRect? {
        let pillWidth = width(of: label)

        let horizontals = segments.enumerated()
            .filter { $0.element.0.y == $0.element.1.y }
            .map { (length: abs($0.element.1.x - $0.element.0.x), index: $0.offset, segment: $0.element) }
            .filter { $0.length > pillWidth + horizontalSlack }
            .sorted { $0.length != $1.length ? $0.length > $1.length : $0.index < $1.index }

        for candidate in horizontals {
            let (a, b) = candidate.segment
            let y = a.y
            let minX = min(a.x, b.x), maxX = max(a.x, b.x)
            let mid = (minX + maxX) / 2
            let centers = centersOutward(from: mid, step: horizontalStep) { cx in
                let left = cx - pillWidth / 2
                return left >= minX && left + pillWidth <= maxX
            }
            for cx in centers {
                let rect = BoardRect(x: cx - pillWidth / 2, y: y - height / 2, w: pillWidth, h: height)
                if accepted(rect) { return rect }
            }
        }

        let verticals = segments.enumerated()
            .filter { $0.element.0.x == $0.element.1.x }
            .map { (length: abs($0.element.1.y - $0.element.0.y), index: $0.offset, segment: $0.element) }
            .filter { $0.length > verticalMinLength }
            .sorted { $0.length != $1.length ? $0.length > $1.length : $0.index < $1.index }

        for candidate in verticals {
            let (a, b) = candidate.segment
            let x = a.x
            let minY = min(a.y, b.y), maxY = max(a.y, b.y)
            let mid = (minY + maxY) / 2
            let centers = centersOutward(from: mid, step: verticalStep) { cy in
                let top = cy - height / 2
                return top >= minY && top + height <= maxY
            }
            for cy in centers {
                let rect = BoardRect(x: x - pillWidth / 2, y: cy - height / 2, w: pillWidth, h: height)
                if accepted(rect) { return rect }
            }
        }

        return nil
    }

    /// Candidate centres from `mid` outwards in `step` increments — the centre itself, then each
    /// side alternately further out — stopping once neither direction still fits.
    private static func centersOutward(from mid: Int, step: Int, fits: (Int) -> Bool) -> [Int] {
        var result: [Int] = []
        if fits(mid) { result.append(mid) }
        var offset = step
        while true {
            let plus = mid + offset, minus = mid - offset
            let plusFits = fits(plus), minusFits = fits(minus)
            guard plusFits || minusFits else { break }
            if plusFits { result.append(plus) }
            if minusFits { result.append(minus) }
            offset += step
        }
        return result
    }
}

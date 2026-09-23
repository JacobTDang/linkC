import Foundation

/// The board's plain maths: sizes, containment, collisions, arrow routes and what is on screen.
/// No UI, no state — every rule the canvas follows is here and tested here.
public enum BoardGeometry {
    public static let componentSize = BoardPoint(x: 152, y: 56)
    public static let noteSize = BoardPoint(x: 176, y: 120)
    public static let frameMinSize = BoardPoint(x: 176, y: 96)
    /// The margin kept between a frame's border and anything inside it.
    public static let frameInset = 8
    /// How far an arrow's elbow keeps clear of the box it bends around.
    static let clearance = 16
    /// The furthest an elbow may swing from the straight line; beyond it there is no simple route.
    static let maxDetour = 480

    public static func textHeight(_ style: BoardTextStyle) -> Int {
        style == .title ? 32 : 20
    }

    public static func rect(ofComponentAt point: BoardPoint) -> BoardRect {
        BoardRect(x: point.x, y: point.y, w: componentSize.x, h: componentSize.y)
    }

    public static func rect(ofNoteAt point: BoardPoint) -> BoardRect {
        BoardRect(x: point.x, y: point.y, w: noteSize.x, h: noteSize.y)
    }

    public static func rect(of text: BoardText) -> BoardRect {
        BoardRect(x: text.at.x, y: text.at.y, w: max(text.width, BoardPoint.grid), h: textHeight(text.style))
    }

    /// The frame whose rect holds the rect's centre; nil means the rect is not placed.
    public static func frame(containing rect: BoardRect, frames: [BoardFrame]) -> BoardFrame? {
        frames.first { $0.rect?.contains(rect.center) == true }
    }

    public static func interior(of frame: BoardRect) -> BoardRect {
        BoardRect(x: frame.x + frameInset, y: frame.y + frameInset,
                  w: max(0, frame.w - 2 * frameInset), h: max(0, frame.h - 2 * frameInset))
    }

    /// The nearest spot for `rect` that overlaps none of `obstacles`, lies wholly inside `container`
    /// when one is given, and touches none of `excluded`. The smallest move on the 8-point grid
    /// wins; ties go right, then down, then left, then up. nil when nothing within `maxRadius` fits.
    public static func nearestFreeSpot(
        for rect: BoardRect, avoiding obstacles: [BoardRect], inside container: BoardRect? = nil,
        outside excluded: [BoardRect] = [], maxRadius: Int = 4096
    ) -> BoardRect? {
        func fits(_ candidate: BoardRect) -> Bool {
            if let container, !container.contains(candidate) { return false }
            if obstacles.contains(where: { $0.intersects(candidate) }) { return false }
            if excluded.contains(where: { $0.intersects(candidate) }) { return false }
            return true
        }
        if fits(rect) { return rect }

        let step = BoardPoint.grid
        let maxSteps = maxRadius / step
        // Inside a container nothing further than its own size can fit, so the search stops there.
        let limit = container.map { min(maxSteps, max($0.w, $0.h) / step + 1) } ?? maxSteps
        var best: (distance: Int, rank: Int, j: Int, i: Int)?
        for ring in 1...max(1, limit) {
            // Nothing on this ring can be nearer than `ring` steps.
            if let best, ring * ring * step * step > best.distance { break }
            for i in -ring...ring {
                for j in -ring...ring where max(abs(i), abs(j)) == ring {
                    let candidate = rect.offsetBy(dx: i * step, dy: j * step)
                    guard fits(candidate) else { continue }
                    let key = (distance: (i * i + j * j) * step * step, rank: directionRank(i, j), j: j, i: i)
                    if let current = best {
                        if (key.distance, key.rank, key.j, key.i) < (current.distance, current.rank, current.j, current.i) { best = key }
                    } else {
                        best = key
                    }
                }
            }
        }
        guard let best else { return nil }
        return rect.offsetBy(dx: best.i * step, dy: best.j * step)
    }

    /// Right, down, left, up, then every other direction.
    private static func directionRank(_ i: Int, _ j: Int) -> Int {
        switch (i.signum(), j.signum()) {
        case (1, 0): return 0
        case (0, 1): return 1
        case (-1, 0): return 2
        case (0, -1): return 3
        default: return 4
        }
    }

    /// Where a component, note or text dropped at `rect` lands: overlapping nothing, and wholly
    /// inside the frame holding its centre — or wholly outside every frame when its centre is in
    /// none, or when that frame has no room.
    public static func elementDrop(_ rect: BoardRect, otherElements: [BoardRect], frames: [BoardRect]) -> BoardRect {
        if let container = frames.first(where: { $0.contains(rect.center) }),
           let inside = nearestFreeSpot(for: rect, avoiding: otherElements, inside: interior(of: container)) {
            return inside
        }
        return nearestFreeSpot(for: rect, avoiding: otherElements, outside: frames) ?? rect
    }

    /// Where a moved frame lands: overlapping no other frame and nothing that is not its own.
    public static func frameDrop(_ rect: BoardRect, otherFrames: [BoardRect], foreignElements: [BoardRect]) -> BoardRect {
        nearestFreeSpot(for: rect, avoiding: otherFrames + foreignElements) ?? rect
    }

    /// A frame resized from its bottom-right corner: never smaller than its minimum or than what
    /// it holds, and stopped at the first thing it would grow over.
    public static func frameResize(
        _ proposed: BoardRect, original: BoardRect, members: [BoardRect], otherFrames: [BoardRect], foreignElements: [BoardRect]
    ) -> BoardRect {
        var result = BoardRect(x: original.x, y: original.y, w: proposed.w, h: proposed.h)
        let membersRight = members.map(\.maxX).max().map { $0 + frameInset } ?? original.x
        let membersBottom = members.map(\.maxY).max().map { $0 + frameInset } ?? original.y
        result.w = max(result.w, frameMinSize.x, membersRight - original.x)
        result.h = max(result.h, frameMinSize.y, membersBottom - original.y)

        for obstacle in otherFrames + foreignElements where obstacle.intersects(result) {
            if obstacle.minX >= original.maxX {
                result.w = obstacle.minX - original.x
            } else if obstacle.minY >= original.maxY {
                result.h = obstacle.minY - original.y
            } else {
                return original
            }
        }
        let floor = BoardRect(x: original.x, y: original.y,
                              w: max(frameMinSize.x, membersRight - original.x), h: max(frameMinSize.y, membersBottom - original.y))
        guard result.w >= floor.w, result.h >= floor.h else { return original }
        return result
    }

    /// The frame grown downward, a row at a time, until an element of `size` fits inside —
    /// nil when growing would reach another frame or something not its own.
    public static func grow(
        _ frame: BoardRect, toFit size: BoardPoint, members: [BoardRect], otherFrames: [BoardRect], foreignElements: [BoardRect]
    ) -> BoardRect? {
        var candidate = frame
        for _ in 0..<32 {
            let seed = BoardRect(x: candidate.x + frameInset, y: candidate.y + frameInset, w: size.x, h: size.y)
            if nearestFreeSpot(for: seed, avoiding: members, inside: interior(of: candidate)) != nil { return candidate }
            candidate.h += size.y + frameInset
            if (otherFrames + foreignElements).contains(where: { $0.intersects(candidate) }) { return nil }
        }
        return nil
    }

    /// An arrow's path: from the side of `source` facing `target` to the side of `target` facing
    /// `source`. Straight when clear; otherwise an elbow around the boxes in the way, on whichever
    /// side is shorter; direct again when neither elbow is clear.
    public static func route(from source: BoardRect, to target: BoardRect, obstacles: [BoardRect]) -> [BoardPoint] {
        let blockers = obstacles.filter { $0 != source && $0 != target }
        let dx = target.center.x - source.center.x
        let dy = target.center.y - source.center.y
        let horizontal = abs(dx) >= abs(dy)

        let start: BoardPoint
        let end: BoardPoint
        if horizontal {
            start = BoardPoint(x: dx >= 0 ? source.maxX : source.minX, y: source.center.y)
            end = BoardPoint(x: dx >= 0 ? target.minX : target.maxX, y: target.center.y)
        } else {
            start = BoardPoint(x: source.center.x, y: dy >= 0 ? source.maxY : source.minY)
            end = BoardPoint(x: target.center.x, y: dy >= 0 ? target.minY : target.maxY)
        }

        let direct = [start, end]
        let inTheWay = blockers.filter { segmentIntersects(start, end, $0) }
        guard !inTheWay.isEmpty else { return direct }

        var options: [[BoardPoint]] = []
        if horizontal {
            let lead = dx >= 0 ? clearance : -clearance
            let above = (inTheWay.map(\.minY).min() ?? start.y) - clearance
            let below = (inTheWay.map(\.maxY).max() ?? start.y) + clearance
            for detour in [above, below] where abs(detour - start.y) <= maxDetour {
                options.append([start, BoardPoint(x: start.x + lead, y: start.y), BoardPoint(x: start.x + lead, y: detour),
                                BoardPoint(x: end.x - lead, y: detour), BoardPoint(x: end.x - lead, y: end.y), end])
            }
        } else {
            let lead = dy >= 0 ? clearance : -clearance
            let left = (inTheWay.map(\.minX).min() ?? start.x) - clearance
            let right = (inTheWay.map(\.maxX).max() ?? start.x) + clearance
            for detour in [left, right] where abs(detour - start.x) <= maxDetour {
                options.append([start, BoardPoint(x: start.x, y: start.y + lead), BoardPoint(x: detour, y: start.y + lead),
                                BoardPoint(x: detour, y: end.y - lead), BoardPoint(x: end.x, y: end.y - lead), end])
            }
        }

        let clear = options.filter { path in
            zip(path, path.dropFirst()).allSatisfy { a, b in !blockers.contains { segmentIntersects(a, b, $0) } }
        }
        return clear.min { length($0) < length($1) } ?? direct
    }

    private static func length(_ path: [BoardPoint]) -> Int {
        zip(path, path.dropFirst()).reduce(0) { total, pair in total + abs(pair.1.x - pair.0.x) + abs(pair.1.y - pair.0.y) }
    }

    /// Whether the segment from `a` to `b` passes through the inside of `rect` (touching an edge
    /// does not count). Liang–Barsky clipping.
    public static func segmentIntersects(_ a: BoardPoint, _ b: BoardPoint, _ rect: BoardRect) -> Bool {
        let x0 = Double(a.x), y0 = Double(a.y)
        let dx = Double(b.x - a.x), dy = Double(b.y - a.y)
        var t0 = 0.0, t1 = 1.0
        let edges: [(Double, Double)] = [
            (-dx, x0 - Double(rect.minX)), (dx, Double(rect.maxX) - x0),
            (-dy, y0 - Double(rect.minY)), (dy, Double(rect.maxY) - y0),
        ]
        for (p, q) in edges {
            if p == 0 {
                if q <= 0 { return false }
            } else {
                let r = q / p
                if p < 0 { t0 = max(t0, r) } else { t1 = min(t1, r) }
                if t0 >= t1 { return false }
            }
        }
        return true
    }

    /// The indices of the rects that intersect `viewport`, in order.
    public static func visibleIndices(of rects: [BoardRect], in viewport: BoardRect) -> [Int] {
        rects.indices.filter { rects[$0].intersects(viewport) }
    }
}

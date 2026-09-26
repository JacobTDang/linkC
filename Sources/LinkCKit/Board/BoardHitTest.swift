import Foundation

/// Which arrow a pointer is over: the one whose route passes nearest, within `tolerance`, in
/// board units. The caller divides its screen tolerance by the zoom. Ties break by the arrow key.
public enum BoardHitTest {
    public static func arrow(
        atX x: Double, y: Double, routes: [BoardModel.ArrowKey: BoardRoute], tolerance: Double,
        including include: (BoardModel.ArrowKey) -> Bool = { _ in true }
    ) -> BoardModel.ArrowKey? {
        var best: (key: BoardModel.ArrowKey, distance: Double)?
        let keys = routes.keys.sorted { ($0.from.lowercased(), $0.to.lowercased()) < ($1.from.lowercased(), $1.to.lowercased()) }
        for key in keys where include(key) {
            guard let points = routes[key]?.points, points.count >= 2 else { continue }
            let distance = zip(points, points.dropFirst()).map { distanceFrom(x, y, toSegment: $0, $1) }.min() ?? .infinity
            guard distance <= tolerance else { continue }
            if best == nil || distance < best!.distance { best = (key, distance) }
        }
        return best?.key
    }

    static func distanceFrom(_ x: Double, _ y: Double, toSegment a: BoardPoint, _ b: BoardPoint) -> Double {
        let ax = Double(a.x), ay = Double(a.y), bx = Double(b.x), by = Double(b.y)
        let dx = bx - ax, dy = by - ay
        let lengthSquared = dx * dx + dy * dy
        let t = lengthSquared == 0 ? 0 : max(0, min(1, ((x - ax) * dx + (y - ay) * dy) / lengthSquared))
        let px = ax + t * dx, py = ay + t * dy
        return ((x - px) * (x - px) + (y - py) * (y - py)).squareRoot()
    }

    /// What the pointer is over: an arrow, or a part.
    public enum Target: Equatable, Sendable {
        case arrow(BoardModel.ArrowKey)
        case component(String)
    }

    /// Picks between an arrow hit and a component: an arrow within tolerance wins over a part.
    public static func pick(arrow: BoardModel.ArrowKey?, component: String?) -> Target? {
        if let arrow { return .arrow(arrow) }
        if let component { return .component(component) }
        return nil
    }
}

import CoreGraphics

/// Which edge of a pane a terminal was dropped on.
public enum SplitEdge: String, Codable, Sendable, CaseIterable {
    case left, right, top, bottom
}

/// The even grid a project's split forms, and where a dropped terminal lands in it. Pure.
public enum SplitLayout {
    /// The most panes a split holds.
    public static let maxPanes = 8

    /// Panes per row, top to bottom: 2 → [2], 3 → [2, 1], 4 → [2, 2] … 8 → [4, 4]. Empty below two
    /// panes, which is no grid at all.
    public static func rows(for count: Int) -> [Int] {
        let clamped = min(count, maxPanes)
        guard clamped >= 2 else { return [] }
        guard clamped > 2 else { return [2] }
        let top = (clamped + 1) / 2
        return [top, clamped - top]
    }

    /// The member indexes each row holds, top to bottom.
    public static func rowRanges(for count: Int) -> [Range<Int>] {
        var start = 0
        return rows(for: count).map { width in
            defer { start += width }
            return start..<(start + width)
        }
    }

    /// Where a terminal dropped on `edge` of the pane at `target` goes, as an index into the members
    /// once the dragged terminal is out of the list. Left and top go before the target, right and
    /// bottom after it; the grid reflows, so top and bottom only mean before and after. `source` is
    /// the dragged terminal's own index when it is already a member (a move), nil when it is joining.
    public static func insertionIndex(droppingOn target: Int, edge: SplitEdge, movingFrom source: Int?) -> Int {
        var index = (edge == .left || edge == .top) ? target : target + 1
        if let source, source < index { index -= 1 }
        return index
    }

    /// The edge of a `size` pane nearest `point` (origin top-left), measured as a fraction of the
    /// pane's width or height so a wide pane doesn't favour top and bottom.
    public static func edge(at point: CGPoint, in size: CGSize) -> SplitEdge {
        let x = size.width > 0 ? point.x / size.width : 0.5
        let y = size.height > 0 ? point.y / size.height : 0.5
        let distances: [(SplitEdge, CGFloat)] = [(.left, x), (.right, 1 - x), (.top, y), (.bottom, 1 - y)]
        return distances.min { $0.1 < $1.1 }!.0
    }
}

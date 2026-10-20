import Foundation

/// A resize drag in progress on a split's grid: the sizes it started from, and the sizes it has made.
/// Each step applies the drag's whole translation to `start`, so the boundary stays under the pointer.
/// Pure value type.
public struct SplitDrag: Equatable, Sendable {
    public let start: SplitSizes
    public let current: SplitSizes

    /// The step of `drag` over a grid that shows `shown`: `resize` applied to where the drag started.
    /// With no drag, or one that started on a grid of another number of panes (its handle went away
    /// mid-drag and the drag never ended), the drag starts over from `shown`.
    public static func step(_ drag: SplitDrag?, over shown: SplitSizes,
                            _ resize: (SplitSizes) -> SplitSizes) -> SplitDrag {
        let start = drag.map(\.start).flatMap { $0.fits(paneCount: shown.paneCount) ? $0 : nil } ?? shown
        return SplitDrag(start: start, current: resize(start))
    }

    /// The sizes to show on a grid of `paneCount` panes: the drag's when they fit, else nil.
    public func sizes(forPanes paneCount: Int) -> SplitSizes? {
        current.fits(paneCount: paneCount) ? current : nil
    }
}

/// Which edge of a pane the drag over it would drop on, if any. Pure.
///
/// An entry starts a hover, an update moves one that is showing, and an exit or a drop ends it. An
/// update never starts one. SwiftUI reports the position once more as a drop concludes, after the
/// drop has cleared the highlight, and sends no exit after it; an update that could light the pane
/// would leave it lit. Nothing tells that update from the first one of a new drag, so the entry is
/// what starts a hover. That is safe because SwiftUI calls `dropEntered` before any `dropUpdated`: it
/// follows `dropEntered` with a `dropUpdated` inside the same entry of the drag, and AppKit delivers
/// the entry before the first update. The documentation promises no order, so this is observed
/// behaviour. If it ever failed, the pane would show no preview and the drop would still land.
public struct SplitDropHover: Equatable, Sendable {
    public private(set) var edge: SplitEdge?

    public init() {}

    public mutating func entered(_ edge: SplitEdge) { self.edge = edge }

    public mutating func updated(_ edge: SplitEdge) {
        if self.edge != nil { self.edge = edge }
    }

    public mutating func exited() { edge = nil }

    public mutating func dropped() { edge = nil }
}

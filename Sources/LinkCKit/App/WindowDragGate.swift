import Foundation

/// Whether a drag on the panel's body moves the window.
///
/// AppKit asks this once per drag, on one view — SwiftUI collapses the whole panel into a
/// single hosting view, so there is no region to carve the window-drag out of. The panel
/// closes this gate while the pointer is over text the user may want to select, and opens
/// it again on the way out.
///
/// A COUNT, not a flag: moving the pointer straight from one selectable line to the next can
/// deliver the second view's enter before the first view's exit, and a flag would be left
/// saying "draggable" while the pointer still sits on text. Balanced increments don't care
/// what order the events arrive in.
@MainActor
public final class WindowDragGate {
    private var suspensions = 0

    public init() {}

    public var allowsDrag: Bool { suspensions == 0 }

    public func setDraggable(_ draggable: Bool) {
        suspensions = draggable ? max(0, suspensions - 1) : suspensions + 1
    }

    /// Back to draggable however the count got where it is — for the panel closing, where
    /// exit events may never be delivered at all.
    public func reset() { suspensions = 0 }
}

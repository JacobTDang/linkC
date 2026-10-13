import AppKit
import SwiftUI

/// An AppKit drag source for a tab chip. SwiftUI's `.draggable` never says where a drag ended, so a
/// chip can't use it to tear off: here `draggingSession(_:endedAt:operation:)` reports the release
/// point, and a drag nothing accepted that ended outside the panel calls `onDraggedOut` with it.
///
/// Put it behind the chip (`.background`) with the chip's own content not hit-testing, so it gets the
/// mouse. It handles a click itself, so the chip needs no tap gesture of its own.
struct DragOutSource: NSViewRepresentable {
    /// What a drop target reads. Copied for each drag: an item belongs to one pasteboard.
    let payload: NSPasteboardItem
    /// A press and release with less than `dragThreshold` of movement.
    let onClick: () -> Void
    /// The drag was accepted by nothing and let go outside the window it started in; the point is in
    /// screen coordinates (bottom-left origin).
    let onDraggedOut: (CGPoint) -> Void

    /// How far the mouse moves, in points, before a press becomes a drag.
    static let dragThreshold: CGFloat = 3

    func makeNSView(context: Context) -> SourceView {
        let view = SourceView()
        update(view)
        return view
    }

    func updateNSView(_ view: SourceView, context: Context) { update(view) }

    private func update(_ view: SourceView) {
        view.payload = payload
        view.onClick = onClick
        view.onDraggedOut = onDraggedOut
    }

    static func isDrag(from start: CGPoint, to point: CGPoint) -> Bool {
        hypot(point.x - start.x, point.y - start.y) >= dragThreshold
    }

    /// Copying and moving are for targets in linkC; nothing outside takes the drag.
    static func sourceOperationMask(for context: NSDraggingContext) -> NSDragOperation {
        switch context {
        case .withinApplication: [.copy, .move]
        case .outsideApplication: []
        @unknown default: []
        }
    }

    /// A tear-off is a drag that nothing took and that ended outside the window it began in. Inside it,
    /// a drag no target accepted does nothing.
    static func tearsOff(endedAt point: CGPoint, operation: NSDragOperation, from windowFrame: CGRect) -> Bool {
        operation.isEmpty && !windowFrame.contains(point)
    }

    @MainActor
    final class SourceView: NSView, NSDraggingSource {
        var payload = NSPasteboardItem()
        var onClick: () -> Void = {}
        var onDraggedOut: (CGPoint) -> Void = { _ in }

        /// Where the press began (window coordinates), until it becomes a click or a drag.
        private var pressLocation: CGPoint?
        /// The frame of the window the drag began in, in screen coordinates. Taken at the start, as the
        /// chip may be gone from the window by the time the drag ends.
        private var sourceWindowFrame = CGRect.zero

        // A chip doesn't move the panel, and a press on it while the panel is behind still counts.
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            pressLocation = event.locationInWindow
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = pressLocation, DragOutSource.isDrag(from: start, to: event.locationInWindow),
                  let window else { return }
            pressLocation = nil
            sourceWindowFrame = window.frame
            let item = NSDraggingItem(pasteboardWriter: copyOfPayload())
            item.setDraggingFrame(bounds, contents: dragImage())
            beginDraggingSession(with: [item], event: event, source: self)
        }

        override func mouseUp(with event: NSEvent) {
            guard pressLocation != nil else { return }
            pressLocation = nil
            onClick()
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            DragOutSource.sourceOperationMask(for: context)
        }

        /// Outside the window nothing will take the drag, so the image stays where it was let go and the
        /// new window opens there; inside it slides back to the chip when no target takes it.
        func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
            session.animatesToStartingPositionsOnCancelOrFail = sourceWindowFrame.contains(screenPoint)
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            guard DragOutSource.tearsOff(endedAt: screenPoint, operation: operation, from: sourceWindowFrame) else { return }
            onDraggedOut(screenPoint)
        }

        private func copyOfPayload() -> NSPasteboardItem {
            let copy = NSPasteboardItem()
            for type in payload.types {
                guard let data = payload.data(forType: type) else {
                    preconditionFailure("The drag payload lists \(type.rawValue) but holds no data for it.")
                }
                copy.setData(data, forType: type)
            }
            return copy
        }

        /// The chip as it looks now. The chip is drawn by the SwiftUI view this sits in, not by this view,
        /// so its bounds are rendered from the window's content view.
        private func dragImage() -> NSImage {
            let image = NSImage(size: bounds.size)
            guard let content = window?.contentView else { return image }
            let area = content.convert(bounds, from: self)
            guard let rep = content.bitmapImageRepForCachingDisplay(in: area) else { return image }
            content.cacheDisplay(in: area, to: rep)
            image.addRepresentation(rep)
            return image
        }
    }
}

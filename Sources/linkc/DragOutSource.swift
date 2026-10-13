import AppKit
import LinkCKit
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
    /// A press and release with less than `TearOffRules.dragThreshold` of movement.
    let onClick: () -> Void
    /// The drag was accepted by nothing and let go outside the window it started in; the point is where
    /// the cursor was, in screen coordinates (bottom-left origin).
    let onDraggedOut: (CGPoint) -> Void
    /// What the pointer shows after a moment over the chip. An AppKit tooltip belongs to the view under
    /// the cursor, so SwiftUI's `.help` on the chip can't reach through this view.
    let toolTip: String?

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
        view.toolTip = toolTip
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
            // Control-click is a secondary click: it opens the chip's menu, and is neither a click nor a drag.
            if event.modifierFlags.contains(.control) {
                rightMouseDown(with: event)
                return
            }
            pressLocation = event.locationInWindow
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = pressLocation, TearOffRules.isDrag(from: start, to: event.locationInWindow),
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
            TearOffRules.sourceOperationMask(for: context)
        }

        /// Outside the window nothing will take the drag, so the image stays where it was let go and the
        /// new window opens there; inside it slides back to the chip when no target takes it.
        func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
            session.animatesToStartingPositionsOnCancelOrFail = sourceWindowFrame.contains(screenPoint)
        }

        /// `endedAt` reports where the drag image ended, which is not the cursor; the cursor decides whether
        /// the drag left the panel, and is where the new window goes. Esc ends a drag with a key event, not
        /// the mouse-up, and that is a cancel.
        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            let cursor = NSEvent.mouseLocation
            let releasedByMouse = NSApp.currentEvent?.type == .leftMouseUp
            guard TearOffRules.tearsOff(endedAt: cursor, operation: operation, from: sourceWindowFrame,
                                        releasedByMouse: releasedByMouse) else { return }
            onDraggedOut(cursor)
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
            guard let content = window?.contentView else {
                NSLog("[linkC] drag-out: the chip has no window content to draw, so the drag image is blank")
                return image
            }
            let area = content.convert(bounds, from: self)
            guard let rep = content.bitmapImageRepForCachingDisplay(in: area) else {
                NSLog("[linkC] drag-out: no bitmap for the chip's %@ area, so the drag image is blank", NSStringFromRect(area))
                return image
            }
            content.cacheDisplay(in: area, to: rep)
            image.addRepresentation(rep)
            return image
        }
    }
}

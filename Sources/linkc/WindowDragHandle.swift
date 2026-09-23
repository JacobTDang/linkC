import AppKit
import SwiftUI

/// The only places a drag moves the panel. Put it behind a top row (`.background`): where the
/// row's own controls sit, they get the click; in the empty space around them, this does, and
/// hands the drag to the window server — so the panel moves exactly as a title bar would.
struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }

        // A real title bar drags on the very first click, even while another app is frontmost.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}

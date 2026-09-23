import AppKit
import SwiftUI

/// Reports the `NSWindow` the view ends up hosted in — the one reliable way for a view to learn
/// its own window, so a local key monitor can tell it apart from a popover's or the open panel's,
/// which can also be the app's key window at any given moment.
struct WindowReader: NSViewRepresentable {
    let onChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { onChange(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onChange(nsView.window) }
    }
}

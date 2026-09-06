import AppKit
import SwiftTerm
import SwiftUI

/// SwiftUI bridge that hosts the selected session's live `LocalProcessTerminalView`.
///
/// Swapping the shown session only detaches/attaches views — it never destroys them — so
/// background terminals keep their process and scrollback fully alive while off screen.
public struct TerminalContainer: NSViewRepresentable {
    private let session: TerminalSession?

    public init(session: TerminalSession?) {
        self.session = session
    }

    public func makeNSView(context: Context) -> TerminalHostView {
        TerminalHostView(frame: .zero)
    }

    public func updateNSView(_ nsView: TerminalHostView, context: Context) {
        nsView.show(session?.terminalView)
    }
}

/// A plain container that shows at most one terminal view at a time, sized to fill it.
public final class TerminalHostView: NSView {
    private weak var shown: NSView?

    /// Only allows window dragging if no terminal view is currently attached. When a terminal
    /// is shown, mouse clicks/drags must be handled by the terminal view for text selection.
    public override var mouseDownCanMoveWindow: Bool { shown == nil }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autoresizingMask = [.width, .height]
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Show `view` (or nothing). Detaching the previously shown terminal leaves it — and its
    /// PTY — fully alive; it is only removed from the view hierarchy until reselected.
    func show(_ view: NSView?) {
        if shown === view {
            view?.frame = bounds
            return
        }
        shown?.removeFromSuperview()
        shown = view
        guard let view else { return }
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        window?.makeFirstResponder(view)
    }

    public override func layout() {
        super.layout()
        shown?.frame = bounds
    }
}

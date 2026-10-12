import AppKit
import SwiftTerm
import SwiftUI

/// SwiftUI bridge that hosts the selected session's live `LocalProcessTerminalView`.
///
/// Swapping the shown session only detaches/attaches views — it never destroys them — so
/// background terminals keep their process and scrollback fully alive while off screen.
public struct TerminalContainer: NSViewRepresentable {
    private let session: TerminalSession?
    private let takesFocus: Bool
    private let onFocus: (() -> Void)?

    /// `takesFocus`: grab the keyboard when the terminal is attached here — the single pane does,
    /// a split's cells only for the focused pane. `onFocus`: told when a click (or anything else)
    /// gives this terminal the keyboard.
    public init(session: TerminalSession?, takesFocus: Bool = true, onFocus: (() -> Void)? = nil) {
        self.session = session
        self.takesFocus = takesFocus
        self.onFocus = onFocus
    }

    public func makeNSView(context: Context) -> TerminalHostView {
        TerminalHostView(frame: .zero)
    }

    public func updateNSView(_ nsView: TerminalHostView, context: Context) {
        session?.terminalView.onFocus = onFocus
        nsView.show(session?.terminalView, takesFocus: takesFocus)
    }
}

/// A plain container that shows at most one terminal view at a time, sized to fill it.
public final class TerminalHostView: NSView {
    private weak var shown: NSView?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autoresizingMask = [.width, .height]
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Show `view` (or nothing). Detaching the previously shown terminal leaves it — and its
    /// PTY — fully alive; it is only removed from the view hierarchy until reselected. A terminal
    /// moves between hosts (its own tab, a split cell), so "shown last" is not "still here": a view
    /// another host has since taken is attached again, and one this host no longer holds is never
    /// pulled out of the host that does.
    func show(_ view: NSView?, takesFocus: Bool = true) {
        if let view, shown === view, view.superview === self {
            view.frame = bounds
            return
        }
        if let shown, shown !== view, shown.superview === self {
            shown.removeFromSuperview()
        }
        shown = view
        guard let view else { return }
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        if takesFocus { window?.makeFirstResponder(view) }
    }

    public override func layout() {
        super.layout()
        shown?.frame = bounds
    }
}

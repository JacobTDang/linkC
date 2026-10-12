import AppKit
import LinkCKit

/// The panel's look for a live terminal, shared by the single terminal and every split pane.
enum TerminalStyle {
    /// Restyle the terminal to the panel's tokens: SF Mono at 12.5 and a translucent background,
    /// so the glass reads through the terminal. The font must be set first and the layer cleared
    /// last: `setupOptions()` re-stamps an opaque layer background on font changes.
    @MainActor static func apply(to session: TerminalSession?) {
        guard let view = session?.terminalView else { return }
        view.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        view.nativeBackgroundColor = NSColor.black.withAlphaComponent(0.30)
        view.layer?.backgroundColor = NSColor.clear.cgColor
    }
}

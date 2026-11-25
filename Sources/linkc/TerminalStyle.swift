import AppKit
import LinkCKit

/// The panel's look for a live terminal, shared by the single terminal and every split pane.
enum TerminalStyle {
    /// Restyle the terminal to the panel's tokens: SF Mono at 12.5 and a translucent background,
    /// so the glass reads through the terminal. The font must be set first and the layer cleared
    /// last: `setupOptions()` re-stamps an opaque layer background on font changes.
    @MainActor static func apply(to session: TerminalSession?) {
        guard let view = session?.terminalView else { return }
        view.font = font
        view.nativeBackgroundColor = NSColor.black.withAlphaComponent(0.30)
        view.layer?.backgroundColor = NSColor.clear.cgColor
    }

    /// The terminal's grid on a screen of `backingScale` pixels per point, as SwiftTerm lays it out.
    /// The scroller is SwiftTerm's default `.overlay` one, which linkC never restyles or hides.
    @MainActor static func grid(backingScale: CGFloat) -> TerminalGrid {
        TerminalGrid(fontCellWidth: fontCellWidth, backingScale: backingScale,
                     scrollerWidth: NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay))
    }

    /// One terminal cell's width in `font` before SwiftTerm rounds it to the pixel grid: the advance of "W".
    @MainActor private static let fontCellWidth: CGFloat = font.advancement(forGlyph: font.glyph(withName: "W")).width

    /// SF Mono falling back to the installed Nerd Font, worked out once per launch: a Nerd Font
    /// installed later is picked up at the next launch.
    @MainActor private static let font: NSFont = {
        let made = TerminalFont.make(size: 12.5, sfMonoFolder: TerminalFont.sfMonoFolder,
                                     families: NSFontManager.shared.availableFontFamilies)
        if let problem = made.problem { NSLog("[linkC] terminal font: %@", problem) }
        return made.font
    }()
}

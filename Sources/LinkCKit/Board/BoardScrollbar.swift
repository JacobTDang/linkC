import Foundation

/// The Board's horizontal scroll bar, as fractions of its track. The track spans the board's
/// content, `margin` screen points wider either side, joined with what is on screen — so it always
/// covers where the view is. The thumb is the visible part.
public struct BoardScrollbar: Equatable, Sendable {
    /// The canvas x at the track's left end, and the canvas width the track spans.
    public let minX: Double
    public let span: Double
    /// The thumb as fractions of the track.
    public let thumbStart: Double
    public let thumbLength: Double

    /// Nil when there is no content, or the view already shows all of it across.
    public static func horizontal(viewport: BoardViewport, content: BoardRect?, width: Double, margin: Double = 48) -> BoardScrollbar? {
        guard let content, width > 0 else { return nil }
        let visibleWidth = width / viewport.zoom
        let pad = margin / viewport.zoom
        let minX = min(viewport.originX, Double(content.x) - pad)
        let maxX = max(viewport.originX + visibleWidth, Double(content.x + content.w) + pad)
        let span = maxX - minX
        guard span - visibleWidth > 0.5 else { return nil }
        return BoardScrollbar(minX: minX, span: span,
                              thumbStart: (viewport.originX - minX) / span, thumbLength: visibleWidth / span)
    }

    /// The view's `originX` that puts the thumb's left end at `start` along the track, kept on it.
    public func originX(thumbStart start: Double) -> Double {
        minX + min(max(start, 0), 1 - thumbLength) * span
    }

    /// The view's `originX` that centres the view on `fraction` of the track, kept on it.
    public func originX(centredOn fraction: Double) -> Double {
        originX(thumbStart: fraction - thumbLength / 2)
    }
}

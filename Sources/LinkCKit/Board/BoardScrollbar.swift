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
    public static func horizontal(viewport: BoardViewport, content: BoardRect?, width: Double, margin: Double = BoardViewport.edgeMargin) -> BoardScrollbar? {
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

    /// This track with the thumb moved to where `viewport` is now: the same `minX` and `span`, so the
    /// track holds still while a drag lasts. The thumb may lie off the track if the view strays off it.
    public func tracking(_ viewport: BoardViewport, width: Double) -> BoardScrollbar {
        BoardScrollbar(minX: minX, span: span,
                       thumbStart: (viewport.originX - minX) / span, thumbLength: width / viewport.zoom / span)
    }

    /// The thumb in points along a track `track` points long: at least `minLength` long (so it can
    /// be grabbed) and kept on the track.
    public func thumb(inTrack track: Double, minLength: Double) -> (start: Double, length: Double) {
        let length = min(track, max(minLength, track * thumbLength))
        return (min(max(track * thumbStart, 0), track - length), length)
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

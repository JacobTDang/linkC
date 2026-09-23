import CoreGraphics
import Foundation

/// Which part of the canvas is on screen. `originX`/`originY` is the canvas point at the view's
/// top-left corner; `zoom` is screen points per canvas point. Personal: kept on this Mac, never
/// in the file.
public struct BoardViewport: Equatable, Sendable, Codable {
    public var originX: Double
    public var originY: Double
    public var zoom: Double

    public static let minZoom = 0.25
    public static let maxZoom = 2.0
    public static let initial = BoardViewport(originX: -40, originY: -40, zoom: 1)

    public init(originX: Double, originY: Double, zoom: Double) {
        self.originX = originX
        self.originY = originY
        self.zoom = min(Self.maxZoom, max(Self.minZoom, zoom))
    }

    public func toCanvas(_ screen: CGPoint) -> CGPoint {
        CGPoint(x: screen.x / zoom + originX, y: screen.y / zoom + originY)
    }

    public func toScreen(_ canvas: CGPoint) -> CGPoint {
        CGPoint(x: (canvas.x - originX) * zoom, y: (canvas.y - originY) * zoom)
    }

    /// Content follows the fingers: a drag of `dx` screen points moves the canvas by `dx / zoom`.
    public func panned(byScreenDX dx: Double, dy: Double) -> BoardViewport {
        BoardViewport(originX: originX - dx / zoom, originY: originY - dy / zoom, zoom: zoom)
    }

    /// Zoom by `factor`, keeping the canvas point under `pointer` fixed.
    public func zoomed(by factor: Double, aroundScreen pointer: CGPoint) -> BoardViewport {
        let anchor = toCanvas(pointer)
        let zoom = min(Self.maxZoom, max(Self.minZoom, zoom * factor))
        return BoardViewport(originX: anchor.x - pointer.x / zoom, originY: anchor.y - pointer.y / zoom, zoom: zoom)
    }

    public func visibleRect(width: Double, height: Double) -> BoardRect {
        BoardRect(x: Int(originX.rounded(.down)), y: Int(originY.rounded(.down)),
                  w: Int((width / zoom).rounded(.up)), h: Int((height / zoom).rounded(.up)))
    }

    /// The viewport that shows all of `bounds` with `margin` screen points around it, never
    /// zoomed in past 100%.
    public static func fitting(_ bounds: BoardRect, width: Double, height: Double, margin: Double = 48) -> BoardViewport {
        let usableWidth = max(1, width - 2 * margin)
        let usableHeight = max(1, height - 2 * margin)
        let zoom = min(1.0, min(usableWidth / Double(max(1, bounds.w)), usableHeight / Double(max(1, bounds.h))))
        let clamped = min(maxZoom, max(minZoom, zoom))
        let centreX = Double(bounds.x) + Double(bounds.w) / 2
        let centreY = Double(bounds.y) + Double(bounds.h) / 2
        return BoardViewport(originX: centreX - width / (2 * clamped), originY: centreY - height / (2 * clamped), zoom: clamped)
    }
}

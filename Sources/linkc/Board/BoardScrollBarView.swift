import LinkCKit
import SwiftUI

/// The Board's horizontal scroll bar along the canvas's bottom edge: a faint thumb that brightens
/// on hover and while dragging. Drag the thumb to slide sideways; click the track to centre the view
/// there and keep dragging from it. Hidden when the view already shows everything across.
struct BoardScrollBar: View {
    @Binding var viewport: BoardViewport
    let content: BoardRect?
    /// The canvas's width in screen points.
    let canvasWidth: CGFloat

    @State private var hovering = false
    /// The bar as it was when the drag began, its thumb's start then, and where the pointer began:
    /// the track keeps that span for the whole drag, so the thumb stays under the pointer.
    @State private var drag: Drag?

    private struct Drag {
        let bar: BoardScrollbar
        let thumbStart: Double
        let startX: CGFloat
    }

    private static let inset: CGFloat = 12
    private static let height: CGFloat = 10

    var body: some View {
        if let bar = BoardScrollbar.horizontal(viewport: viewport, content: content, width: Double(canvasWidth)) {
            GeometryReader { geometry in
                let track = geometry.size.width
                let active = hovering || drag != nil
                Capsule()
                    .fill(Theme.textPrimary.opacity(active ? 0.45 : 0.2))
                    .frame(width: max(24, track * bar.thumbLength), height: active ? 6 : 4)
                    .offset(x: track * bar.thumbStart)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .animation(Theme.hoverEase, value: active)
                    .contentShape(Rectangle())
                    .onHover { hovering = $0 }
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in dragged(value, bar: bar, track: track) }
                        .onEnded { _ in drag = nil })
            }
            .frame(height: Self.height)
            .padding(.horizontal, Self.inset)
            .padding(.bottom, 1)
            .onDisappear {
                hovering = false
                drag = nil
            }
        }
    }

    private func dragged(_ value: DragGesture.Value, bar: BoardScrollbar, track: CGFloat) {
        guard track > 0 else { return }
        if let drag {
            viewport.originX = drag.bar.originX(thumbStart: drag.thumbStart + Double((value.location.x - drag.startX) / track))
            return
        }
        let fraction = Double(value.startLocation.x / track)
        let onThumb = fraction >= bar.thumbStart && fraction <= bar.thumbStart + bar.thumbLength
        if !onThumb { viewport.originX = bar.originX(centredOn: fraction) }
        guard let now = BoardScrollbar.horizontal(viewport: viewport, content: content, width: Double(canvasWidth)) else { return }
        drag = Drag(bar: now, thumbStart: now.thumbStart, startX: value.startLocation.x)
    }
}

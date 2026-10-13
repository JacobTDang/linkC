import LinkCKit
import SwiftUI

/// The Board's horizontal scroll bar along the canvas's bottom edge: a faint thumb that brightens
/// on hover and while dragging. Drag the thumb to slide sideways; click the track to centre the view
/// there and keep dragging from it. Hidden when the view already shows everything across.
struct BoardScrollBarView: View {
    @Binding var viewport: BoardViewport
    let content: BoardRect?
    /// The canvas's width in screen points.
    let canvasWidth: CGFloat

    @State private var hovering = false
    /// The press in progress. Its track is the one the press landed on, kept for the whole drag so
    /// the thumb stays under the pointer however the live track would change; nil between presses.
    @State private var drag: Drag?
    /// True while a press lasts. Unlike `drag` it also falls back when the system cancels the gesture.
    @GestureState private var pressing = false

    private struct Drag {
        let bar: BoardScrollbar
        /// How far into the drawn thumb the pointer is, in screen points.
        let grab: CGFloat
    }

    private static let inset: CGFloat = 12
    private static let height: CGFloat = 10
    private static let minThumb: CGFloat = 24

    var body: some View {
        if let bar = shownBar {
            GeometryReader { geometry in
                let track = geometry.size.width
                let thumb = drawnThumb(of: bar, track: track)
                let active = hovering || drag != nil
                Capsule()
                    .fill(Theme.textPrimary.opacity(active ? 0.45 : 0.2))
                    .frame(width: thumb.length, height: active ? 6 : 4)
                    .offset(x: thumb.start)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .animation(Theme.hoverEase, value: active)
                    .contentShape(Rectangle())
                    .onHover { hovering = $0 }
                    .gesture(DragGesture(minimumDistance: 0)
                        .updating($pressing) { _, state, _ in state = true }
                        .onChanged { value in dragged(value, bar: bar, track: track) }
                        .onEnded { _ in drag = nil })
            }
            .frame(height: Self.height)
            .padding(.horizontal, Self.inset)
            .padding(.bottom, 1)
            // `onEnded` clears a finished press; this catches one the system cancelled.
            .onChange(of: pressing) { _, isPressing in
                if !isPressing { drag = nil }
            }
            .onDisappear { hovering = false }
        }
    }

    /// What is drawn: during a drag the track it began on, followed by the view, even where a fresh
    /// track would be shorter or the content now fits; otherwise the track the board's content makes.
    private var shownBar: BoardScrollbar? {
        if let drag { return drag.bar.tracking(viewport, width: Double(canvasWidth)) }
        return BoardScrollbar.horizontal(viewport: viewport, content: content, width: Double(canvasWidth))
    }

    private func drawnThumb(of bar: BoardScrollbar, track: CGFloat) -> (start: CGFloat, length: CGFloat) {
        let thumb = bar.thumb(inTrack: Double(track), minLength: Double(Self.minThumb))
        return (CGFloat(thumb.start), CGFloat(thumb.length))
    }

    /// `bar` is the one on screen: a press freezes it as the drag's track, and the first event
    /// either lands on the thumb or moves the view so the thumb is centred on the pointer.
    private func dragged(_ value: DragGesture.Value, bar: BoardScrollbar, track: CGFloat) {
        guard track > 0 else { return }
        if let drag {
            viewport.originX = drag.bar.originX(thumbStart: Double((value.location.x - drag.grab) / track))
            return
        }
        let x = value.startLocation.x
        var placed = viewport
        var thumb = drawnThumb(of: bar, track: track)
        if x < thumb.start || x > thumb.start + thumb.length {
            placed.originX = bar.originX(centredOn: Double(x / track))
            viewport.originX = placed.originX
            thumb = drawnThumb(of: bar.tracking(placed, width: Double(canvasWidth)), track: track)
        }
        drag = Drag(bar: bar, grab: x - thumb.start)
    }
}

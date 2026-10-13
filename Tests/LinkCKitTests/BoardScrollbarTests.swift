import XCTest
@testable import LinkCKit

final class BoardScrollbarTests: XCTestCase {
    private let content = BoardRect(x: 0, y: 0, w: 2000, h: 300)

    func testNoContentOrContentThatFitsHasNoBar() {
        let viewport = BoardViewport(originX: -100, originY: 0, zoom: 1)
        XCTAssertNil(BoardScrollbar.horizontal(viewport: viewport, content: nil, width: 800))
        let small = BoardRect(x: 0, y: 0, w: 500, h: 100)
        XCTAssertNil(BoardScrollbar.horizontal(viewport: viewport, content: small, width: 800, margin: 48),
                     "the view (-100…700) already covers the content with its margin (-48…548)")
    }

    /// The track spans the content plus the margin; the thumb is the visible part.
    func testThumbIsTheVisiblePartOfTheContentSpan() throws {
        let viewport = BoardViewport(originX: 452, originY: 0, zoom: 1)
        let bar = try XCTUnwrap(BoardScrollbar.horizontal(viewport: viewport, content: content, width: 800, margin: 48))
        XCTAssertEqual(bar.minX, -48)
        XCTAssertEqual(bar.span, 2096)
        XCTAssertEqual(bar.thumbStart, 500.0 / 2096, accuracy: 1e-9)
        XCTAssertEqual(bar.thumbLength, 800.0 / 2096, accuracy: 1e-9)
    }

    /// The margin is screen points: at zoom 2 it is 24 canvas points; the visible width halves too.
    func testZoomChangesTheMarginAndTheThumb() throws {
        let viewport = BoardViewport(originX: 0, originY: 0, zoom: 2)
        let bar = try XCTUnwrap(BoardScrollbar.horizontal(viewport: viewport, content: content, width: 800, margin: 48))
        XCTAssertEqual(bar.minX, -24)
        XCTAssertEqual(bar.span, 2048)
        XCTAssertEqual(bar.thumbLength, 400.0 / 2048, accuracy: 1e-9)
    }

    /// A view panned past the content stretches the track to include it, so the thumb is always on the track.
    func testAViewBeyondTheContentStretchesTheTrack() throws {
        let viewport = BoardViewport(originX: 3000, originY: 0, zoom: 1)
        let bar = try XCTUnwrap(BoardScrollbar.horizontal(viewport: viewport, content: content, width: 800, margin: 48))
        XCTAssertEqual(bar.minX, -48)
        XCTAssertEqual(bar.span, 3848)
        XCTAssertEqual(bar.thumbStart + bar.thumbLength, 1, accuracy: 1e-9)
    }

    func testThumbStartMapsBackToTheOriginAndStaysOnTheTrack() throws {
        let viewport = BoardViewport(originX: 452, originY: 0, zoom: 1)
        let bar = try XCTUnwrap(BoardScrollbar.horizontal(viewport: viewport, content: content, width: 800, margin: 48))
        XCTAssertEqual(bar.originX(thumbStart: bar.thumbStart), 452, accuracy: 1e-9)
        XCTAssertEqual(bar.originX(thumbStart: -0.5), -48, accuracy: 1e-9, "dragged past the left end")
        XCTAssertEqual(bar.originX(thumbStart: 2), -48 + 2096 - 800, accuracy: 1e-9, "dragged past the right end")
    }

    func testCentringOnATrackSpot() throws {
        let viewport = BoardViewport(originX: -48, originY: 0, zoom: 1)
        let bar = try XCTUnwrap(BoardScrollbar.horizontal(viewport: viewport, content: content, width: 800, margin: 48))
        XCTAssertEqual(bar.originX(centredOn: 0.5), -48 + 1048 - 400, accuracy: 1e-9)
        XCTAssertEqual(bar.originX(centredOn: 0), -48, accuracy: 1e-9, "kept on the track")
    }

    /// A view left of the content starts the track at the view itself, so the thumb sits at the left end.
    func testAViewLeftOfTheContentStartsTheTrackAtTheView() throws {
        let viewport = BoardViewport(originX: -300, originY: 0, zoom: 1)
        let bar = try XCTUnwrap(BoardScrollbar.horizontal(viewport: viewport, content: content, width: 800, margin: 48))
        XCTAssertEqual(bar.minX, -300)
        XCTAssertEqual(bar.span, 2348)
        XCTAssertEqual(bar.thumbStart, 0)
    }

    /// "Fit all" leaves exactly the margin either side, so the track and the view are the same width
    /// up to float residue (the first five sizes leave about 1e-13 over): the bar's threshold, and the
    /// one shared margin, keep it hidden.
    func testAFitAllViewHasNoBar() {
        for (contentWidth, width) in [(545, 640.0), (706, 800.0), (909, 1000.0), (1210, 1280.0), (1434, 1512.0), (3400, 1000.0)] {
            let bounds = BoardRect(x: 17, y: -40, w: contentWidth, h: 10)
            let viewport = BoardViewport.fitting(bounds, width: width, height: 600)
            XCTAssertGreaterThan(viewport.zoom, BoardViewport.minZoom, "content \(contentWidth) fits within the zoom limit")
            XCTAssertLessThan(viewport.zoom, 1, "and by zooming out")
            XCTAssertNil(BoardScrollbar.horizontal(viewport: viewport, content: bounds, width: width),
                         "content \(contentWidth) fitted in \(width) pt")
        }
    }

    /// A drag keeps the track it began on: the thumb follows the view along that track even where a
    /// fresh track would be shorter.
    func testTrackingKeepsTheFrozenTrackAsTheViewMoves() throws {
        let pressed = BoardViewport(originX: 3000, originY: 0, zoom: 1)
        let frozen = try XCTUnwrap(BoardScrollbar.horizontal(viewport: pressed, content: content, width: 800, margin: 48))
        XCTAssertEqual(frozen.span, 3848)
        let dragged = BoardViewport(originX: 1000, originY: 0, zoom: 1)
        let tracking = frozen.tracking(dragged, width: 800)
        XCTAssertEqual(tracking.minX, frozen.minX)
        XCTAssertEqual(tracking.span, frozen.span)
        XCTAssertEqual(tracking.thumbStart, 1048.0 / 3848, accuracy: 1e-9)
        XCTAssertEqual(tracking.thumbLength, 800.0 / 3848, accuracy: 1e-9)
        let fresh = try XCTUnwrap(BoardScrollbar.horizontal(viewport: dragged, content: content, width: 800, margin: 48))
        XCTAssertEqual(fresh.span, 2096, "a fresh track has shrunk back to the content")
    }

    func testTrackingTheViewTheBarWasMadeFromIsTheBar() throws {
        let viewport = BoardViewport(originX: 452, originY: 0, zoom: 1)
        let bar = try XCTUnwrap(BoardScrollbar.horizontal(viewport: viewport, content: content, width: 800, margin: 48))
        XCTAssertEqual(bar.tracking(viewport, width: 800), bar)
    }

    func testTrackingScalesTheThumbByTheZoom() throws {
        let frozen = try XCTUnwrap(BoardScrollbar.horizontal(
            viewport: BoardViewport(originX: 452, originY: 0, zoom: 1), content: content, width: 800, margin: 48))
        let zoomed = frozen.tracking(BoardViewport(originX: 452, originY: 0, zoom: 2), width: 800)
        XCTAssertEqual(zoomed.thumbStart, 500.0 / 2096, accuracy: 1e-9)
        XCTAssertEqual(zoomed.thumbLength, 400.0 / 2096, accuracy: 1e-9)
    }

    /// Dragged to the left end over content that sits inside the view, a fresh bar would be nil; the
    /// frozen one still has the thumb at the left end of its track.
    func testTrackingStillHasABarWhereAFreshOneWouldBeNil() throws {
        let small = BoardRect(x: 0, y: 0, w: 500, h: 100)
        let frozen = try XCTUnwrap(BoardScrollbar.horizontal(
            viewport: BoardViewport(originX: 1000, originY: 0, zoom: 1), content: small, width: 800, margin: 48))
        let atLeftEnd = BoardViewport(originX: frozen.originX(thumbStart: 0), originY: 0, zoom: 1)
        XCTAssertNil(BoardScrollbar.horizontal(viewport: atLeftEnd, content: small, width: 800, margin: 48))
        let tracking = frozen.tracking(atLeftEnd, width: 800)
        XCTAssertEqual(tracking.thumbStart, 0, accuracy: 1e-9)
        XCTAssertEqual(tracking.thumbLength, 800.0 / frozen.span, accuracy: 1e-9)
    }

    func testDrawnThumbIsTheFractionsOfTheTrack() {
        let bar = BoardScrollbar(minX: 0, span: 1000, thumbStart: 0.25, thumbLength: 0.5)
        let thumb = bar.thumb(inTrack: 800, minLength: 24)
        XCTAssertEqual(thumb.start, 200, accuracy: 1e-9)
        XCTAssertEqual(thumb.length, 400, accuracy: 1e-9)
    }

    /// A thumb too short to grab is drawn `minLength` long, and pulled back so it still ends on the track.
    func testDrawnThumbIsNeverShorterThanTheMinimumOrPastTheTrackEnd() {
        let bar = BoardScrollbar(minX: 0, span: 1000, thumbStart: 0.99, thumbLength: 0.01)
        let thumb = bar.thumb(inTrack: 800, minLength: 24)
        XCTAssertEqual(thumb.length, 24)
        XCTAssertEqual(thumb.start, 776, accuracy: 1e-9, "track 800 − length 24")
    }

    /// A view that has strayed off the frozen track (an arrow key mid-drag) still draws on it.
    func testDrawnThumbStaysOnTheTrackWhenTheViewIsOffIt() {
        let before = BoardScrollbar(minX: 0, span: 1000, thumbStart: -0.2, thumbLength: 0.1)
        XCTAssertEqual(before.thumb(inTrack: 800, minLength: 24).start, 0)
        let after = BoardScrollbar(minX: 0, span: 1000, thumbStart: 1.2, thumbLength: 0.1)
        XCTAssertEqual(after.thumb(inTrack: 800, minLength: 24).start, 720, accuracy: 1e-9)
    }

    func testDrawnThumbFitsATrackShorterThanTheMinimum() {
        let bar = BoardScrollbar(minX: 0, span: 1000, thumbStart: 0.5, thumbLength: 0.1)
        let thumb = bar.thumb(inTrack: 20, minLength: 24)
        XCTAssertEqual(thumb.start, 0)
        XCTAssertEqual(thumb.length, 20)
    }

    /// The scroll bar view's drag, step by step: grab the thumb of a view panned past the content, drag
    /// back along the track the press landed on, and the drawn thumb stays at the same spot under
    /// the pointer. A fresh track would have shrunk to the content, and left the thumb behind.
    func testTheDrawnThumbStaysUnderThePointerWhileDraggingBackFromPastTheContent() throws {
        let track = 776.0
        var viewport = BoardViewport(originX: 3000, originY: 0, zoom: 1)
        let frozen = try XCTUnwrap(BoardScrollbar.horizontal(viewport: viewport, content: content, width: 800, margin: 48))
        let grab = 650 - frozen.thumb(inTrack: track, minLength: 24).start
        XCTAssertGreaterThan(grab, 0, "the press at 650 is on the thumb")
        for pointer in stride(from: 650.0, through: 100, by: -50) {
            viewport.originX = frozen.originX(thumbStart: (pointer - grab) / track)
            let drawn = frozen.tracking(viewport, width: 800).thumb(inTrack: track, minLength: 24)
            XCTAssertEqual(pointer - drawn.start, grab, accuracy: 1e-6, "pointer at \(pointer)")
        }
        viewport.originX = frozen.originX(thumbStart: (450 - grab) / track)
        let fresh = try XCTUnwrap(BoardScrollbar.horizontal(viewport: viewport, content: content, width: 800, margin: 48))
        XCTAssertEqual(fresh.thumb(inTrack: track, minLength: 24).start, 559, accuracy: 1, "a fresh track draws it far from the pointer at 450")
    }

    /// A thumb drawn longer than its share (the 24 pt minimum) travels the track minus its drawn
    /// length, so its drawn position is the view's place along that shorter travel.
    func testALengthenedThumbIsPlacedAlongItsOwnTravel() {
        let bar = BoardScrollbar(minX: 0, span: 100_000, thumbStart: 0.4955, thumbLength: 0.009)
        let thumb = bar.thumb(inTrack: 800, minLength: 24)
        XCTAssertEqual(thumb.length, 24)
        XCTAssertEqual(thumb.start, 0.4955 / (1 - 0.009) * (800 - 24), accuracy: 1e-6)
    }

    /// Grabbing a lengthened thumb and moving it never jumps the view: a drawn start maps back to the
    /// origin that drew it, all along the travel and at both ends.
    func testADrawnThumbStartMapsBackToTheOriginThatDrewIt() {
        let span = 100_096.0, tl = 800.0 / span, minX = -48.0
        for fraction in [0.0, 0.25, 0.5, 0.75, 1.0] {
            let origin = minX + fraction * (1 - tl) * span
            let bar = BoardScrollbar(minX: minX, span: span, thumbStart: (origin - minX) / span, thumbLength: tl)
            let drawn = bar.thumb(inTrack: 800, minLength: 24)
            XCTAssertEqual(bar.originX(drawnThumbStart: drawn.start, inTrack: 800, minLength: 24), origin,
                           accuracy: 1e-6, "at \(fraction) of the travel")
        }
    }

    /// A pointer step moves the view by the matching share of its travel, never by the jump the
    /// thumb's true length would give.
    func testOnePointOfDragMovesTheViewByOnePointOfTravel() {
        let span = 100_096.0, tl = 800.0 / span
        let bar = BoardScrollbar(minX: -48, span: span, thumbStart: 1 - tl, thumbLength: tl)
        let start = bar.thumb(inTrack: 800, minLength: 24).start
        let atEnd = bar.originX(drawnThumbStart: start, inTrack: 800, minLength: 24)
        let oneLeft = bar.originX(drawnThumbStart: start - 1, inTrack: 800, minLength: 24)
        XCTAssertEqual(atEnd - oneLeft, (1 - tl) * span / (800 - 24), accuracy: 1e-6)
    }

    /// A thumb at its natural length maps exactly as the track fraction does.
    func testANaturalLengthThumbMapsAsItsTrackFraction() {
        let bar = BoardScrollbar(minX: -48, span: 2096, thumbStart: 0.2, thumbLength: 800.0 / 2096)
        for start in [0.0, 100, 250, 400] {
            XCTAssertEqual(bar.originX(drawnThumbStart: start, inTrack: 800, minLength: 24),
                           bar.originX(thumbStart: start / 800), accuracy: 1e-9)
        }
    }

    /// Dragged past either end, the view stops at that end; a thumb that fills the track has no travel.
    func testADrawnThumbStartIsKeptOnTheTrack() {
        let span = 100_096.0, tl = 800.0 / span
        let bar = BoardScrollbar(minX: -48, span: span, thumbStart: 0.5, thumbLength: tl)
        XCTAssertEqual(bar.originX(drawnThumbStart: -50, inTrack: 800, minLength: 24), -48, accuracy: 1e-9)
        XCTAssertEqual(bar.originX(drawnThumbStart: 5000, inTrack: 800, minLength: 24), -48 + (1 - tl) * span, accuracy: 1e-6)
        XCTAssertEqual(bar.originX(drawnThumbStart: 3, inTrack: 20, minLength: 24), -48, accuracy: 1e-9)
    }
}

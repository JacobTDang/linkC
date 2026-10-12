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
}

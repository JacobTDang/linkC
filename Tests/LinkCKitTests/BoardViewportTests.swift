import XCTest
@testable import LinkCKit

final class BoardViewportTests: XCTestCase {
    func testScreenAndCanvasAreInverse() {
        let viewport = BoardViewport(originX: 100, originY: 50, zoom: 2)
        let screen = viewport.toScreen(CGPoint(x: 150, y: 80))
        XCTAssertEqual(screen, CGPoint(x: 100, y: 60))
        XCTAssertEqual(viewport.toCanvas(screen), CGPoint(x: 150, y: 80))
    }

    func testPanningMovesByScreenDistance() {
        let panned = BoardViewport(originX: 0, originY: 0, zoom: 2).panned(byScreenDX: 20, dy: -10)
        XCTAssertEqual(panned.originX, -10)
        XCTAssertEqual(panned.originY, 5)
    }

    /// Zooming keeps the canvas point under the pointer where it was.
    func testZoomingKeepsThePointUnderThePointer() {
        let viewport = BoardViewport(originX: 0, originY: 0, zoom: 1)
        let pointer = CGPoint(x: 200, y: 100)
        let before = viewport.toCanvas(pointer)
        let zoomed = viewport.zoomed(by: 1.5, aroundScreen: pointer)
        XCTAssertEqual(zoomed.zoom, 1.5)
        XCTAssertEqual(zoomed.toCanvas(pointer).x, before.x, accuracy: 0.001)
        XCTAssertEqual(zoomed.toCanvas(pointer).y, before.y, accuracy: 0.001)
    }

    func testZoomIsClamped() {
        XCTAssertEqual(BoardViewport.initial.zoomed(by: 100, aroundScreen: .zero).zoom, 2.0)
        XCTAssertEqual(BoardViewport.initial.zoomed(by: 0.001, aroundScreen: .zero).zoom, 0.25)
    }

    func testTheVisibleRectCoversTheView() {
        let rect = BoardViewport(originX: 40, originY: 80, zoom: 0.5).visibleRect(width: 400, height: 200)
        XCTAssertEqual(rect, BoardRect(x: 40, y: 80, w: 800, h: 400))
    }

    func testFittingShowsEverything() {
        let content = BoardRect(x: 0, y: 0, w: 1000, h: 500)
        let viewport = BoardViewport.fitting(content, width: 600, height: 400, margin: 50)
        let visible = viewport.visibleRect(width: 600, height: 400)
        XCTAssertTrue(visible.contains(content), "\(visible)")
        XCTAssertLessThanOrEqual(viewport.zoom, 1.0)
    }

    /// A lens is a way of looking, not a place: panning, zooming and fitting keep it.
    func testPanZoomAndFitKeepTheLens() {
        let viewport = BoardViewport(originX: 0, originY: 0, zoom: 1, lens: .control)
        XCTAssertEqual(viewport.panned(byScreenDX: 20, dy: 10).lens, .control)
        XCTAssertEqual(viewport.zoomed(by: 1.5, aroundScreen: CGPoint(x: 10, y: 10)).lens, .control)
        XCTAssertEqual(BoardViewport.fitting(BoardRect(x: 0, y: 0, w: 100, h: 100), width: 400, height: 300, lens: .data).lens, .data)
    }

    /// → shows what is further right: the origin moves right by the step in canvas points.
    func testArrowPansAStepInEachDirectionAtAnyZoom() {
        let viewport = BoardViewport(originX: 100, originY: 50, zoom: 2)
        let step = BoardViewport.arrowStep / 2
        XCTAssertEqual(viewport.panned(BoardPan(.right), width: 800, height: 400).originX, 100 + step)
        XCTAssertEqual(viewport.panned(BoardPan(.left), width: 800, height: 400).originX, 100 - step)
        XCTAssertEqual(viewport.panned(BoardPan(.down), width: 800, height: 400).originY, 50 + step)
        XCTAssertEqual(viewport.panned(BoardPan(.up), width: 800, height: 400).originY, 50 - step)
        XCTAssertEqual(viewport.panned(BoardPan(.right), width: 800, height: 400).originY, 50, "a sideways pan keeps the height")
    }

    /// ⇧ pans by most of the visible width (← →) or height (↑ ↓).
    func testShiftArrowPansAPage() {
        let viewport = BoardViewport(originX: 0, originY: 0, zoom: 2)
        XCTAssertEqual(viewport.panned(BoardPan(.right, page: true), width: 800, height: 400).originX, 0.8 * 800 / 2, accuracy: 0.001)
        XCTAssertEqual(viewport.panned(BoardPan(.up, page: true), width: 800, height: 400).originY, -0.8 * 400 / 2, accuracy: 0.001)
    }
}

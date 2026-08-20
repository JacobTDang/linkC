import XCTest
@testable import LinkCKit

/// The panel is dragged by its body, so the drag has to be suspended over text the user
/// wants to select — and resumed reliably, or the panel becomes unmovable.
@MainActor
final class WindowDragGateTests: XCTestCase {

    func testDraggableByDefault() {
        XCTAssertTrue(WindowDragGate().allowsDrag)
    }

    func testHoveringTextSuspendsTheDrag() {
        let gate = WindowDragGate()
        gate.setDraggable(false)
        XCTAssertFalse(gate.allowsDrag, "a drag here should select, not move the panel")
        gate.setDraggable(true)
        XCTAssertTrue(gate.allowsDrag)
    }

    /// The reason this is a count. Sliding from one selectable line straight onto the next
    /// can deliver the second view's enter BEFORE the first view's exit; a flag would end up
    /// saying "draggable" while the pointer is still over text.
    func testEnterBeforeExitStillLeavesTheDragSuspended() {
        let gate = WindowDragGate()
        gate.setDraggable(false)   // enter line A
        gate.setDraggable(false)   // enter line B
        gate.setDraggable(true)    // exit line A, arriving late
        XCTAssertFalse(gate.allowsDrag, "the pointer is still on line B")
        gate.setDraggable(true)    // exit line B
        XCTAssertTrue(gate.allowsDrag, "off the text, the panel drags again")
    }

    /// Stray resumes arrive for real — `onDisappear` fires for a view that was never
    /// hovered. If they drove the count below zero the panel would read as undraggable and
    /// stay that way: unmovable, with nothing on screen explaining why.
    func testStrayResumesLeaveThePanelDraggable() {
        let gate = WindowDragGate()
        gate.setDraggable(true)
        gate.setDraggable(true)
        XCTAssertTrue(gate.allowsDrag, "stray resumes must not make the panel unmovable")

        gate.setDraggable(false)
        XCTAssertFalse(gate.allowsDrag, "and the next real hover still suspends the drag")
        gate.setDraggable(true)
        XCTAssertTrue(gate.allowsDrag)
    }

    /// The panel can close while a line is hovered, and no exit is ever delivered.
    func testResetRecoversFromAMissedExit() {
        let gate = WindowDragGate()
        gate.setDraggable(false)
        gate.reset()
        XCTAssertTrue(gate.allowsDrag, "reopening must not find the panel stuck in place")
    }
}

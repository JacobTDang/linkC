import AppKit
import XCTest
@testable import LinkCKit

final class TearOffRulesTests: XCTestCase {
    // MARK: - Press or drag

    func testAMoveUnderTheThresholdIsAClick() {
        let start = CGPoint(x: 10, y: 10)
        XCTAssertFalse(TearOffRules.isDrag(from: start, to: start))
        XCTAssertFalse(TearOffRules.isDrag(from: start, to: CGPoint(x: 12, y: 10)))
        XCTAssertFalse(TearOffRules.isDrag(from: start, to: CGPoint(x: 12, y: 12)), "2.83 points is still under 3")
    }

    func testAMoveOfTheThresholdOrMoreIsADragInAnyDirection() {
        let start = CGPoint(x: 10, y: 10)
        XCTAssertTrue(TearOffRules.isDrag(from: start, to: CGPoint(x: 13, y: 10)))
        XCTAssertTrue(TearOffRules.isDrag(from: start, to: CGPoint(x: 10, y: 7)))
        XCTAssertTrue(TearOffRules.isDrag(from: start, to: CGPoint(x: 13, y: 13)))
        XCTAssertTrue(TearOffRules.isDrag(from: start, to: CGPoint(x: 100, y: 100)))
    }

    // MARK: - What a drag may do

    func testTheDragCopiesOrMovesInsideLinkCAndNothingOutside() {
        XCTAssertEqual(TearOffRules.sourceOperationMask(for: .withinApplication), [.copy, .move])
        XCTAssertEqual(TearOffRules.sourceOperationMask(for: .outsideApplication), [])
    }

    // MARK: - Where a drag ended

    private let panel = CGRect(x: 100, y: 100, width: 400, height: 600)

    func testADragNothingTookThatEndedOutsideThePanelTearsOff() {
        XCTAssertTrue(TearOffRules.tearsOff(endedAt: CGPoint(x: 600, y: 300), operation: [], from: panel, releasedByMouse: true))
        XCTAssertTrue(TearOffRules.tearsOff(endedAt: CGPoint(x: 50, y: 300), operation: [], from: panel, releasedByMouse: true))
    }

    func testADragThatEndedInsideThePanelDoesNot() {
        XCTAssertFalse(TearOffRules.tearsOff(endedAt: CGPoint(x: 300, y: 300), operation: [], from: panel, releasedByMouse: true))
        XCTAssertFalse(TearOffRules.tearsOff(endedAt: CGPoint(x: 100, y: 100), operation: [], from: panel, releasedByMouse: true),
                       "the panel's own corner is inside it")
    }

    func testADragATargetAcceptedDoesNotTearOffEvenOutsideThePanel() {
        for operation: NSDragOperation in [.copy, .move, [.copy, .move]] {
            XCTAssertFalse(TearOffRules.tearsOff(endedAt: CGPoint(x: 600, y: 300), operation: operation, from: panel, releasedByMouse: true),
                           "operation \(operation.rawValue)")
        }
    }

    func testADragThatWasCancelledOutsideThePanelDoesNotTearOff() {
        XCTAssertFalse(TearOffRules.tearsOff(endedAt: CGPoint(x: 600, y: 300), operation: [], from: panel, releasedByMouse: false),
                       "Esc ends a drag too, and that is no tear-off")
    }

    // MARK: - ⌘W

    private func isClose(_ modifiers: NSEvent.ModifierFlags, keyCode: UInt16 = 13, typed: String? = "w") -> Bool {
        TearOffRules.isClose(modifiers: modifiers, keyCode: keyCode, typed: typed)
    }

    func testCommandWClosesTheWindow() {
        XCTAssertTrue(isClose(.command))
    }

    func testCommandWClosesWithCapsLockOnWhateverCaseTheLetterComesBackIn() {
        XCTAssertTrue(isClose([.command, .capsLock], typed: "w"))
        XCTAssertTrue(isClose([.command, .capsLock], typed: "W"))
    }

    func testFnDoesNotStopTheShortcut() {
        XCTAssertTrue(isClose([.command, .function]))
    }

    func testShiftOptionOrControlWithCommandAreNotClose() {
        XCTAssertFalse(isClose([.command, .shift], typed: "W"))
        XCTAssertFalse(isClose([.command, .option]))
        XCTAssertFalse(isClose([.command, .control]))
        XCTAssertFalse(isClose([.command, .option, .control, .shift]))
    }

    func testWithoutCommandItIsNotClose() {
        XCTAssertFalse(isClose([]))
        XCTAssertFalse(isClose(.capsLock))
        XCTAssertFalse(isClose(.control))
        XCTAssertFalse(isClose(.option))
    }

    func testAnotherLatinLetterOnTheWKeyCodeIsNotClose() {
        // Dvorak types a "," on the key a QWERTY board calls W; the key code alone must not close.
        XCTAssertFalse(isClose(.command, keyCode: 13, typed: ","))
        XCTAssertFalse(isClose(.command, keyCode: 12, typed: "q"))
    }

    func testALatinWOnAnotherKeyCloses() {
        // Dvorak puts w where a QWERTY board has the comma key.
        XCTAssertTrue(isClose(.command, keyCode: 43, typed: "w"))
    }

    func testOnALayoutWithoutLatinLettersThePhysicalWKeyCloses() {
        XCTAssertTrue(isClose(.command, keyCode: 13, typed: "ц"))
        XCTAssertFalse(isClose(.command, keyCode: 12, typed: "й"), "another physical key")
    }

    func testNoTypedCharacterIsNotClose() {
        XCTAssertFalse(isClose(.command, keyCode: 13, typed: nil))
    }
}

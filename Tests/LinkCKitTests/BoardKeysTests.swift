import XCTest
@testable import LinkCKit

final class BoardKeysTests: XCTestCase {
    func testTabKeys() {
        XCTAssertEqual(TabKeyMap.command(for: KeyPress(.character("1"), command: true)), .select(digit: 1))
        XCTAssertEqual(TabKeyMap.command(for: KeyPress(.character("9"), command: true)), .select(digit: 9))
        XCTAssertNil(TabKeyMap.command(for: KeyPress(.character("0"), command: true)))
        XCTAssertNil(TabKeyMap.command(for: KeyPress(.character("1"))), "a bare digit is typing, not a tab")
        XCTAssertNil(TabKeyMap.command(for: KeyPress(.character("1"), command: true, shift: true)))
        XCTAssertEqual(TabKeyMap.command(for: KeyPress(.tab, control: true)), .next)
        XCTAssertEqual(TabKeyMap.command(for: KeyPress(.tab, control: true, shift: true)), .previous)
        XCTAssertNil(TabKeyMap.command(for: KeyPress(.tab)))
    }

    func testBoardTools() {
        let expected: [(String, BoardCommand)] = [("v", .selectTool), ("c", .componentTool), ("a", .arrowTool),
                                                   ("f", .frameTool), ("n", .noteTool), ("t", .textTool)]
        for (key, command) in expected {
            XCTAssertEqual(BoardKeyMap.command(for: KeyPress(.character(key)), isEditingText: false), command, key)
            XCTAssertEqual(BoardKeyMap.command(for: KeyPress(.character(key.uppercased())), isEditingText: false), command, key)
        }
    }

    func testBoardEditingKeys() {
        XCTAssertEqual(BoardKeyMap.command(for: KeyPress(.delete), isEditingText: false), .delete)
        XCTAssertEqual(BoardKeyMap.command(for: KeyPress(.escape), isEditingText: false), .cancel)
        XCTAssertEqual(BoardKeyMap.command(for: KeyPress(.character("z"), command: true), isEditingText: false), .undo)
        XCTAssertEqual(BoardKeyMap.command(for: KeyPress(.character("z"), command: true, shift: true), isEditingText: false), .redo)
        XCTAssertEqual(BoardKeyMap.command(for: KeyPress(.character("1"), shift: true), isEditingText: false), .fitAll)
        XCTAssertNil(BoardKeyMap.command(for: KeyPress(.character("c"), command: true), isEditingText: false), "⌘C is not the component tool")
    }

    /// While a field is being typed into, every key belongs to the field.
    func testTypingIntoAFieldIsNeverACommand() {
        for press in [KeyPress(.character("v")), KeyPress(.delete), KeyPress(.escape), KeyPress(.character("z"), command: true)] {
            XCTAssertNil(BoardKeyMap.command(for: press, isEditingText: true))
        }
    }

    func testCommandUpGoesUpOneBoard() {
        XCTAssertEqual(BoardKeyMap.command(for: KeyPress(.up, command: true), isEditingText: false), .goUp)
        XCTAssertNil(BoardKeyMap.command(for: KeyPress(.up, command: true, shift: true), isEditingText: false))
        XCTAssertNil(BoardKeyMap.command(for: KeyPress(.up, command: true), isEditingText: true))
    }

    func testArrowsPanAStepAndShiftArrowsAPage() {
        let arrows: [(KeyPress.Key, BoardPan.Direction)] = [(.left, .left), (.right, .right), (.up, .up), (.down, .down)]
        for (key, direction) in arrows {
            XCTAssertEqual(BoardKeyMap.command(for: KeyPress(key), isEditingText: false), .pan(BoardPan(direction)), "\(key)")
            XCTAssertEqual(BoardKeyMap.command(for: KeyPress(key, shift: true), isEditingText: false),
                           .pan(BoardPan(direction, page: true)), "⇧\(key)")
        }
    }

    func testCommandUpStillGoesUpAndOtherModifiedArrowsAreNotTheBoards() {
        XCTAssertEqual(BoardKeyMap.command(for: KeyPress(.up, command: true), isEditingText: false), .goUp)
        for key in [KeyPress.Key.left, .right, .up, .down] {
            XCTAssertNil(BoardKeyMap.command(for: KeyPress(key, control: true), isEditingText: false), "⌃\(key)")
            XCTAssertNil(BoardKeyMap.command(for: KeyPress(key, option: true), isEditingText: false), "⌥\(key)")
        }
        for key in [KeyPress.Key.left, .right, .down] {
            XCTAssertNil(BoardKeyMap.command(for: KeyPress(key, command: true), isEditingText: false), "⌘\(key)")
        }
    }

    func testArrowsBelongToAFieldBeingEdited() {
        for key in [KeyPress.Key.left, .right, .up, .down] {
            XCTAssertNil(BoardKeyMap.command(for: KeyPress(key), isEditingText: true), "\(key)")
        }
    }
}

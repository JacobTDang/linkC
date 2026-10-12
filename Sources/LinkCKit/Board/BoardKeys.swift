import Foundation

/// One key press, reduced to what the key maps need. `character` is the key's unshifted
/// character, lowercased by the maps — so ⇧1 is `.character("1")` with `shift`.
public struct KeyPress: Equatable, Sendable {
    public enum Key: Equatable, Sendable {
        case character(String)
        case tab
        case escape
        case delete
        case space
        case up
        case down
        case left
        case right
    }

    public let key: Key
    public let command: Bool
    public let control: Bool
    public let shift: Bool
    public let option: Bool

    public init(_ key: Key, command: Bool = false, control: Bool = false, shift: Bool = false, option: Bool = false) {
        self.key = key
        self.command = command
        self.control = control
        self.shift = shift
        self.option = option
    }
}

public enum TabCommand: Equatable, Sendable {
    case select(digit: Int)
    case next
    case previous
}

public enum TabKeyMap {
    /// ⌘1–⌘9 pick a tab; ⌃Tab and ⌃⇧Tab cycle.
    public static func command(for press: KeyPress) -> TabCommand? {
        switch press.key {
        case .character(let character):
            guard press.command, !press.control, !press.option, !press.shift,
                  let digit = Int(character), (1...9).contains(digit) else { return nil }
            return .select(digit: digit)
        case .tab:
            guard press.control, !press.command, !press.option else { return nil }
            return press.shift ? .previous : .next
        default:
            return nil
        }
    }
}

public enum BoardCommand: Equatable, Sendable {
    case selectTool, componentTool, arrowTool, frameTool, noteTool, textTool
    case delete, cancel, undo, redo, fitAll, goUp
    case pan(BoardPan)
}

/// An arrow key's pan: which way the view moves, and whether by a page (⇧) or a step.
public struct BoardPan: Equatable, Sendable {
    public enum Direction: Equatable, Sendable { case left, right, up, down }
    public let direction: Direction
    public let page: Bool

    public init(_ direction: Direction, page: Bool = false) {
        self.direction = direction
        self.page = page
    }
}

public enum BoardKeyMap {
    /// The canvas's keys. While a field is being typed into, every key belongs to the field.
    public static func command(for press: KeyPress, isEditingText: Bool) -> BoardCommand? {
        guard !isEditingText else { return nil }
        let noModifiers = !press.command && !press.control && !press.option
        switch press.key {
        case .escape where noModifiers:
            return .cancel
        case .delete where noModifiers:
            return .delete
        case .up:
            if press.command, !press.control, !press.option, !press.shift {
                return .goUp
            }
            return pan(.up, press)
        case .down: return pan(.down, press)
        case .left: return pan(.left, press)
        case .right: return pan(.right, press)
        case .character(let raw):
            let character = raw.lowercased()
            if press.command, !press.control, !press.option, character == "z" {
                return press.shift ? .redo : .undo
            }
            if press.shift, noModifiers, character == "1" { return .fitAll }
            guard noModifiers, !press.shift else { return nil }
            switch character {
            case "v": return .selectTool
            case "c": return .componentTool
            case "a": return .arrowTool
            case "f": return .frameTool
            case "n": return .noteTool
            case "t": return .textTool
            default: return nil
            }
        default:
            return nil
        }
    }

    /// An arrow pans; ⇧ makes it a page. With ⌘, ⌃ or ⌥ it is not the Board's.
    private static func pan(_ direction: BoardPan.Direction, _ press: KeyPress) -> BoardCommand? {
        guard !press.command, !press.control, !press.option else { return nil }
        return .pan(BoardPan(direction, page: press.shift))
    }
}

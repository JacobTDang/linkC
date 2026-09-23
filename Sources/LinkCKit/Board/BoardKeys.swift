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
    case delete, cancel, undo, redo, fitAll
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
}

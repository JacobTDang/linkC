import AppKit

/// The pure rules behind pulling a terminal or a grid out of the panel and closing its window: when a press
/// becomes a drag, what a drag may do, where a drag counts as a tear-off, and which key closes a window.
/// The AppKit views that use them hold no logic of their own.
public enum TearOffRules {
    /// How far the mouse moves, in points, before a press becomes a drag.
    public static let dragThreshold: CGFloat = 3

    public static func isDrag(from start: CGPoint, to point: CGPoint) -> Bool {
        hypot(point.x - start.x, point.y - start.y) >= dragThreshold
    }

    /// Copying and moving are for targets in linkC; nothing outside takes the drag.
    public static func sourceOperationMask(for context: NSDraggingContext) -> NSDragOperation {
        switch context {
        case .withinApplication: [.copy, .move]
        case .outsideApplication: []
        @unknown default: []
        }
    }

    /// A tear-off is a drag that nothing took, that the user let go of (a cancelled drag, Esc for one,
    /// is not one), and that ended outside the window it began in. `point` is where the cursor was, in
    /// screen coordinates. Inside the window, a drag no target accepted does nothing.
    public static func tearsOff(endedAt point: CGPoint, operation: NSDragOperation, from windowFrame: CGRect,
                                releasedByMouse: Bool) -> Bool {
        operation.isEmpty && releasedByMouse && !windowFrame.contains(point)
    }

    /// ⌘ and no other of the four modifiers: Caps Lock and Fn are in `.deviceIndependentFlagsMask` too, and
    /// must not stop the shortcut. The key is the letter w on a Latin layout (Dvorak included, and in
    /// either case, as Caps Lock can give a capital), and the physical W key (code 13) on a layout whose
    /// letters are not Latin.
    public static func isClose(modifiers: NSEvent.ModifierFlags, keyCode: UInt16, typed: String?) -> Bool {
        guard modifiers.intersection([.command, .shift, .option, .control]) == .command else { return false }
        if typed?.lowercased() == "w" { return true }
        let notLatin = typed?.unicodeScalars.allSatisfy { !$0.isASCII } ?? false
        return notLatin && keyCode == 13
    }
}

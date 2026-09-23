import AppKit
import LinkCKit

/// The Board's keys, scroll and pinch, through one `NSEvent` local monitor — installed when the
/// Board appears and removed when it goes, so nothing listens while it is not showing. A local
/// monitor needs no Accessibility permission.
@MainActor
final class BoardInput {
    /// A key the Board may act on. Returns whether it was handled (and so swallowed).
    var onKey: (KeyPress) -> Bool = { _ in false }
    /// Space pressed or released, for pan-by-dragging.
    var onSpace: (Bool) -> Void = { _ in }
    /// A scroll over the canvas: location in canvas-view points, deltas, whether the deltas are
    /// precise (trackpad), whether ⌘ is held.
    var onScroll: (CGPoint, CGFloat, CGFloat, Bool, Bool) -> Void = { _, _, _, _, _ in }
    /// A pinch over the canvas: location in canvas-view points, and the magnification step.
    var onMagnify: (CGPoint, CGFloat) -> Void = { _, _ in }
    /// The canvas's frame in window coordinates, top-left origin (SwiftUI's global space).
    var canvasFrame: () -> CGRect = { .zero }

    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .scrollWheel, .magnify]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Whether a text field or editor has the keyboard.
    static var isEditingText: Bool {
        NSApp.keyWindow?.firstResponder is NSText
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let window = event.window else { return false }
        switch event.type {
        case .keyDown, .keyUp:
            guard window.isKeyWindow, !Self.isEditingText else { return false }
            if event.keyCode == 49 {   // space
                onSpace(event.type == .keyDown)
                return true
            }
            guard event.type == .keyDown, let press = Self.press(from: event) else { return false }
            return onKey(press)
        case .scrollWheel, .magnify:
            let point = Self.location(of: event, in: window)
            let frame = canvasFrame()
            guard frame.contains(point) else { return false }
            let local = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
            if event.type == .magnify {
                onMagnify(local, event.magnification)
            } else {
                onScroll(local, event.scrollingDeltaX, event.scrollingDeltaY,
                         event.hasPreciseScrollingDeltas, event.modifierFlags.contains(.command))
            }
            return true
        default:
            return false
        }
    }

    /// The event's location in window coordinates with a top-left origin.
    private static func location(of event: NSEvent, in window: NSWindow) -> CGPoint {
        let height = window.contentView?.bounds.height ?? window.frame.height
        return CGPoint(x: event.locationInWindow.x, y: height - event.locationInWindow.y)
    }

    /// Digits by key code, so ⇧1 still reads as "1" whatever the layout's shifted character is.
    private static let digitKeyCodes: [UInt16: String] = [
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
    ]

    static func press(from event: NSEvent) -> KeyPress? {
        let flags = event.modifierFlags
        let key: KeyPress.Key
        switch event.keyCode {
        case 48: key = .tab
        case 53: key = .escape
        case 51, 117: key = .delete
        case 49: key = .space
        default:
            if let digit = digitKeyCodes[event.keyCode] {
                key = .character(digit)
            } else if let characters = event.charactersIgnoringModifiers?.lowercased(), !characters.isEmpty {
                key = .character(characters)
            } else {
                return nil
            }
        }
        return KeyPress(key, command: flags.contains(.command), control: flags.contains(.control),
                        shift: flags.contains(.shift), option: flags.contains(.option))
    }
}

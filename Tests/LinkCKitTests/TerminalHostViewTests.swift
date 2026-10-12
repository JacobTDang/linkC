import AppKit
import XCTest
@testable import LinkCKit

@MainActor
final class TerminalHostViewTests: XCTestCase {
    /// One terminal view, two hosts: the grid cell borrows it, then its own tab shows it again.
    func testAHostReattachesAViewAnotherHostBorrowed() {
        let a = TerminalHostView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let b = TerminalHostView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let view = NSView()
        a.show(view)
        b.show(view)
        XCTAssertTrue(view.superview === b)
        a.show(view)
        XCTAssertTrue(view.superview === a, "the host must attach the view again even though it showed it last")
    }

    func testAHostNeverDetachesAViewItNoLongerHolds() {
        let a = TerminalHostView(frame: .zero)
        let b = TerminalHostView(frame: .zero)
        let view = NSView()
        a.show(view)
        b.show(view)
        a.show(nil)
        XCTAssertTrue(view.superview === b, "clearing a host must not pull the view out of the host now holding it")
    }

    func testOnlyAHostThatTakesFocusMakesTheViewFirstResponder() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        let host = TerminalHostView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        window.contentView = host
        let quiet = FocusableView()
        host.show(quiet, takesFocus: false)
        XCTAssertFalse(window.firstResponder === quiet)
        let eager = FocusableView()
        host.show(eager, takesFocus: true)
        XCTAssertTrue(window.firstResponder === eager)
    }

    func testALayoutPassOnAHostNeverResizesAViewAnotherHostHolds() {
        let a = TerminalHostView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let b = TerminalHostView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let view = NSView()
        a.show(view)
        b.show(view)
        XCTAssertEqual(view.frame, b.bounds)
        a.layout()
        XCTAssertEqual(view.frame, b.bounds, "a host must size only the view it holds")
    }

    func testAPaneThatBecomesFocusedTakesTheKeyboardButARepeatDoesNotStealIt() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let host = TerminalHostView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let field = FocusableView(frame: NSRect(x: 200, y: 0, width: 200, height: 200))
        root.addSubview(host)
        root.addSubview(field)
        window.contentView = root
        let view = FocusableView()
        host.show(view, takesFocus: false)
        XCTAssertFalse(window.firstResponder === view)
        host.show(view, takesFocus: true)
        XCTAssertTrue(window.firstResponder === view, "a pane that becomes the focused one must take the keyboard")
        window.makeFirstResponder(field)
        host.show(view, takesFocus: true)
        XCTAssertTrue(window.firstResponder === field, "a repeated update must not take the keyboard back from another field")
    }

    /// A grid cell's first update comes before the cell is in a window: the wish for the keyboard waits for one.
    func testAFocusedPaneShownBeforeItsHostHasAWindowTakesTheKeyboardOnceItDoes() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        window.contentView = root
        let host = TerminalHostView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let view = FocusableView()
        host.show(view, takesFocus: true)
        host.show(view, takesFocus: true)
        XCTAssertFalse(window.firstResponder === view)
        root.addSubview(host)
        XCTAssertTrue(window.firstResponder === view, "a focused pane must get the keyboard when it reaches a window")
    }

    func testAnUnfocusedPaneNeverTakesTheKeyboardWhenItsHostReachesAWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        window.contentView = root
        let host = TerminalHostView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let view = FocusableView()
        host.show(view, takesFocus: false)
        root.addSubview(host)
        XCTAssertFalse(window.firstResponder === view)
    }

    /// The keyboard is given once per spell of focus: a host that moves windows later doesn't take it back.
    func testAHostThatMovesWindowsDoesNotTakeTheKeyboardBack() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let host = TerminalHostView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let field = FocusableView(frame: NSRect(x: 200, y: 0, width: 200, height: 200))
        root.addSubview(host)
        root.addSubview(field)
        window.contentView = root
        let view = FocusableView()
        host.show(view, takesFocus: true)
        XCTAssertTrue(window.firstResponder === view)
        window.makeFirstResponder(field)
        host.removeFromSuperview()
        root.addSubview(host)
        XCTAssertTrue(window.firstResponder === field)
    }

    func testATerminalViewReportsBecomingFirstResponder() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        let view = LinkCTerminalView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        window.contentView = view
        var focused = 0
        view.onFocus = { focused += 1 }
        window.makeFirstResponder(view)
        XCTAssertEqual(focused, 1)
    }

    /// A click is the user's own act, unlike the keyboard arriving by itself, so it reports apart.
    func testATerminalViewReportsAClickButNotFocusAlone() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        let view = LinkCTerminalView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        window.contentView = view
        var clicks = 0
        view.onClick = { clicks += 1 }
        window.makeFirstResponder(view)
        XCTAssertEqual(clicks, 0, "taking the keyboard is not a click")
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 10, y: 10), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        view.mouseDown(with: event)
        XCTAssertEqual(clicks, 1)
    }
}

private final class FocusableView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

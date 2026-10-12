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

    func testATerminalViewReportsBecomingFirstResponder() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        let view = LinkCTerminalView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        window.contentView = view
        var focused = 0
        view.onFocus = { focused += 1 }
        window.makeFirstResponder(view)
        XCTAssertEqual(focused, 1)
    }
}

private final class FocusableView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

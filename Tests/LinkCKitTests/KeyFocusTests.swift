import XCTest
import AppKit
import SwiftUI
import WebKit
@testable import LinkCKit

/// Where the keyboard is decides whose the tab strip's keys are: a web page in an app tab keeps ⌘K,
/// which Storybook, Linear and docs search all use; linkC's own chrome and its terminals give it to
/// the prompt bar.
@MainActor
final class KeyFocusTests: XCTestCase {
    private let commandK = KeyPress(.character("k"), command: true)

    /// A window laid out as linkC's panel is: a glass content view holding the SwiftUI hosting view,
    /// with `embedded` placed by SwiftUI as an app tab's web view or a session's terminal is.
    private func window<Content: View>(_ content: Content) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
            backing: .buffered, defer: true)
        let glass = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let hosting = NSHostingView(rootView: content.frame(width: 400, height: 300))
        hosting.frame = glass.bounds
        glass.addSubview(hosting)
        window.contentView = glass
        hosting.layoutSubtreeIfNeeded()
        return window
    }

    func testAWebPageInAnAppTabKeepsCommandK() throws {
        let web = WKWebView(frame: .zero)
        let window = window(Embedded(view: web))
        let inside = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        web.addSubview(inside)

        XCTAssertTrue(window.makeFirstResponder(web))
        XCTAssertEqual(KeyFocus.of(window.firstResponder), .embedded)
        XCTAssertNil(TabKeyMap.command(for: commandK, focus: KeyFocus.of(window.firstResponder)))
        XCTAssertEqual(KeyFocus.of(inside), .embedded, "a view inside the page is the page's")
    }

    func testATerminalGivesCommandKToTheBar() throws {
        let host = TerminalHostView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let terminal = LinkCTerminalView(frame: host.bounds)
        host.addSubview(terminal)
        let window = window(Embedded(view: host))

        XCTAssertTrue(window.makeFirstResponder(terminal))
        XCTAssertEqual(KeyFocus.of(window.firstResponder), .terminal)
        XCTAssertEqual(TabKeyMap.command(for: commandK, focus: .terminal), .focusPromptBar)
    }

    func testLinkCsOwnChromeGivesCommandKToTheBar() throws {
        let window = window(Color.clear)
        let hosting = try XCTUnwrap(window.contentView?.subviews.first)

        XCTAssertEqual(KeyFocus.of(nil), .chrome)
        XCTAssertEqual(KeyFocus.of(window), .chrome)
        XCTAssertEqual(KeyFocus.of(hosting), .chrome)
        XCTAssertEqual(TabKeyMap.command(for: commandK, focus: .chrome), .focusPromptBar)
    }

    /// A text field has every key: ⌘K, ⌘1 and ⌃Tab all stay with it.
    func testATextFieldKeepsEveryTabKey() throws {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 22))
        let window = window(Embedded(view: field))

        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertEqual(KeyFocus.of(window.firstResponder), .text)
        for press in [commandK, KeyPress(.character("1"), command: true), KeyPress(.tab, control: true)] {
            XCTAssertNil(TabKeyMap.command(for: press, focus: .text), "\(press)")
        }
    }

    /// Only ⌘K yields to a web page: ⌘1–⌘9 and ⌃Tab move between linkC's tabs from anywhere but a field.
    func testTabKeysOtherThanCommandKStillWorkOverAWebPage() {
        XCTAssertEqual(TabKeyMap.command(for: KeyPress(.character("2"), command: true), focus: .embedded), .select(digit: 2))
        XCTAssertEqual(TabKeyMap.command(for: KeyPress(.tab, control: true), focus: .embedded), .next)
    }

    /// An AppKit view placed by SwiftUI, as `AppWebView` and `TerminalContainer` place theirs.
    private struct Embedded: NSViewRepresentable {
        let view: NSView
        func makeNSView(context: Context) -> NSView { view }
        func updateNSView(_ nsView: NSView, context: Context) {}
    }
}

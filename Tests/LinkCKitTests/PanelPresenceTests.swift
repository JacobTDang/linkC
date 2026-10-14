import XCTest
@testable import LinkCKit

/// The panel counts as on screen only while its window is ordered in on the active Space and no hide is
/// fading it out. Showing and hiding through linkC are not the only ways it leaves the screen.
@MainActor
final class PanelPresenceTests: XCTestCase {
    /// The window as `PanelPresence` reads it, and what it published.
    private final class FakePanel {
        var orderedIn = false
        var onActiveSpace = true
        var published: [Bool] = []
    }

    private func make() -> (FakePanel, PanelPresence) {
        let panel = FakePanel()
        let presence = PanelPresence(
            isOrderedIn: { panel.orderedIn },
            isOnActiveSpace: { panel.onActiveSpace },
            publish: { panel.published.append($0) }
        )
        return (panel, presence)
    }

    /// Presented and ordered in on the active Space.
    private func shown() -> (FakePanel, PanelPresence) {
        let (panel, presence) = make()
        presence.willPresent()
        panel.orderedIn = true
        presence.windowStateChanged()
        return (panel, presence)
    }

    func testAPanelThatWasNeverShownIsNeverPresent() {
        // At launch the panel's window exists but was never ordered in.
        let (panel, presence) = make()
        presence.windowStateChanged()
        XCTAssertEqual(panel.published, [])
        XCTAssertFalse(presence.isPresent)
    }

    func testPresentingIsPresentBeforeTheWindowOrdersIn() {
        let (panel, presence) = make()
        presence.willPresent()
        XCTAssertEqual(panel.published, [true])
        XCTAssertTrue(presence.isPresent)
        panel.orderedIn = true
        presence.windowStateChanged()
        XCTAssertEqual(panel.published, [true], "already present, so nothing new")
    }

    func testAWindowOrderedOutWithoutAHideIsNotPresent() {
        // NSApp.hide, or an orderOut that didn't go through hide().
        let (panel, presence) = shown()
        panel.orderedIn = false
        presence.windowStateChanged()
        XCTAssertEqual(panel.published, [true, false])
        XCTAssertFalse(presence.isPresent)
    }

    func testAPanelLeftOnAnotherSpaceIsNotPresentUntilTheUserIsBack() {
        let (panel, presence) = shown()
        panel.onActiveSpace = false
        presence.windowStateChanged()
        XCTAssertEqual(panel.published, [true, false])
        panel.onActiveSpace = true
        presence.windowStateChanged()
        XCTAssertEqual(panel.published, [true, false, true])
    }

    func testAWindowOrderedInWithoutAPresentIsPresent() {
        // The app unhidden: nothing called present().
        let (panel, presence) = make()
        panel.orderedIn = true
        presence.windowStateChanged()
        XCTAssertEqual(panel.published, [true])
        XCTAssertTrue(presence.isPresent)
    }

    func testAPanelFadingOutIsNotPresent() {
        let (panel, presence) = shown()
        presence.willHide()
        XCTAssertEqual(panel.published, [true, false])
        presence.windowStateChanged()   // mid-fade: the window is still ordered in
        XCTAssertEqual(panel.published, [true, false])
        panel.orderedIn = false
        presence.didFinishHide()
        XCTAssertEqual(panel.published, [true, false])
        XCTAssertFalse(presence.isPresent)
    }

    func testPresentingDuringAHideFadeWins() {
        let (panel, presence) = shown()
        presence.willHide()
        presence.willPresent()
        presence.windowStateChanged()   // never ordered out
        XCTAssertEqual(panel.published, [true, false, true])
        XCTAssertTrue(presence.isPresent)
    }

    func testOnlyAChangeIsPublished() {
        let (panel, presence) = make()
        presence.willPresent()
        presence.willPresent()
        panel.orderedIn = true
        presence.windowStateChanged()
        presence.windowStateChanged()
        presence.willHide()
        presence.willHide()
        presence.windowStateChanged()
        XCTAssertEqual(panel.published, [true, false])
    }
}

import XCTest
@testable import LinkCKit

@MainActor
final class SidebarStateTests: XCTestCase {
    nonisolated(unsafe) private var suiteName: String!
    nonisolated(unsafe) private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "linkc-sidebar-test-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testAFreshStateIsEmptyWithEverySectionClosed() {
        let state = SidebarState(defaults: defaults)
        XCTAssertEqual(state.projectOrder, [])
        XCTAssertEqual(state.expandOverrides, [:])
        for section in SidebarState.Section.allCases {
            XCTAssertFalse(state.isOpen(section), "\(section) should start closed")
        }
    }

    func testProjectsKeepTheOrderTheyWereFirstSeenIn() {
        let state = SidebarState(defaults: defaults)
        state.noteProjects(["/a", "/b"])
        state.noteProjects(["/c", "/b", "/a"])
        XCTAssertEqual(state.projectOrder, ["/a", "/b", "/c"])
    }

    func testEverythingSurvivesARelaunch() {
        let state = SidebarState(defaults: defaults)
        state.noteProjects(["/a", "/b"])
        state.setExpanded("/a", true)
        state.toggle(.earlier)
        let reloaded = SidebarState(defaults: defaults)
        XCTAssertEqual(reloaded.projectOrder, ["/a", "/b"])
        XCTAssertEqual(reloaded.expandOverrides, ["/a": true])
        XCTAssertTrue(reloaded.isOpen(.earlier))
        XCTAssertFalse(reloaded.isOpen(.servers))
    }

    func testToggleOpensAndClosesASection() {
        let state = SidebarState(defaults: defaults)
        state.toggle(.more)
        XCTAssertTrue(state.isOpen(.more))
        state.toggle(.more)
        XCTAssertFalse(state.isOpen(.more))
    }

    func testPruneKeepsOnlyFoldersStillInUse() {
        let state = SidebarState(defaults: defaults)
        state.noteProjects(["/a", "/b", "/c"])
        state.setExpanded("/b", true)
        state.prune(keeping: ["/a", "/c"])
        XCTAssertEqual(state.projectOrder, ["/a", "/c"])
        XCTAssertEqual(state.expandOverrides, [:])
        XCTAssertEqual(SidebarState(defaults: defaults).projectOrder, ["/a", "/c"])
    }

    func testAProjectThatTurnsCoralExpandsAndAManualCollapseSticksWhileItStaysCoral() {
        let state = SidebarState(defaults: defaults)
        state.noteCoral(["/a"])
        XCTAssertEqual(state.expandOverrides["/a"], true)
        state.setExpanded("/a", false)
        state.noteCoral(["/a"])
        XCTAssertEqual(state.expandOverrides["/a"], false, "still coral: the manual collapse sticks")
        state.noteCoral([])
        state.noteCoral(["/a"])
        XCTAssertEqual(state.expandOverrides["/a"], true, "coral again: expands again")
    }

    func testMovingIntoAProjectOpensItAgain() {
        let state = SidebarState(defaults: defaults)
        state.noteSelectedProject("/a")
        state.setExpanded("/a", false)
        state.noteSelectedProject("/a")
        XCTAssertEqual(state.expandOverrides["/a"], false, "still the selected project: the collapse sticks")
        state.noteSelectedProject("/b")
        state.noteSelectedProject("/a")
        XCTAssertNil(state.expandOverrides["/a"], "moved away and back: it opens again")
    }

    func testUnreadableStoredStateStartsFresh() {
        defaults.set(Data("not json".utf8), forKey: SidebarState.key)
        let state = SidebarState(defaults: defaults)
        XCTAssertEqual(state.projectOrder, [])
        XCTAssertEqual(state.expandOverrides, [:])
    }
}

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
        XCTAssertEqual(state.expandOverrides["/a"], true, "moved away and back: it opens again")
    }

    /// Closing the agent on screen moves the selection out of its project. The project must stay
    /// open: arriving in it marked it open, rather than leaving it open only while it held the
    /// selection.
    func testAProjectStaysOpenAfterTheSelectionLeavesIt() {
        let state = SidebarState(defaults: defaults)
        state.noteSelectedProject("/a")
        state.noteSelectedProject(nil)
        XCTAssertEqual(state.expandOverrides["/a"], true)
        XCTAssertEqual(SidebarModel.projects(
            inputs: [SidebarModel.Input(
                session: Session(id: "s2", cwd: "/a", title: "a"),
                title: "t", status: SessionRowStatus(text: "", tone: .quiet), hasRunningSubagents: false)],
            order: ["/a"], expandOverrides: state.expandOverrides, selectedId: nil
        ).projects.first?.isExpanded, true)
    }

    func testUnreadableStoredStateStartsFresh() {
        defaults.set(Data("not json".utf8), forKey: SidebarState.key)
        let state = SidebarState(defaults: defaults)
        XCTAssertEqual(state.projectOrder, [])
        XCTAssertEqual(state.expandOverrides, [:])
    }

    func testABoardViewportIsRememberedPerProjectAndPruned() {
        let state = SidebarState(defaults: defaults)
        XCTAssertNil(state.boardViewport(for: "/p"))
        let viewport = BoardViewport(originX: 12, originY: -40, zoom: 1.5)
        state.setBoardViewport(viewport, for: "/p")
        XCTAssertEqual(state.boardViewport(for: "/p"), viewport)
        XCTAssertNil(state.boardViewport(for: "/other"))
        XCTAssertEqual(SidebarState(defaults: defaults).boardViewport(for: "/p"), viewport, "it survives a relaunch")
        state.prune(keeping: ["/other"])
        XCTAssertNil(state.boardViewport(for: "/p"))
    }

    func testFilingsPersistAndPrune() {
        let state = SidebarState(defaults: defaults)
        state.file(terminal: "t1", under: "/p/june")

        let reloaded = SidebarState(defaults: defaults)
        XCTAssertEqual(reloaded.terminalProjects, ["t1": "/p/june"])

        reloaded.unfile(terminal: "t1")
        XCTAssertEqual(reloaded.terminalProjects, [:])

        reloaded.file(terminal: "t1", under: "/p/june")
        reloaded.file(terminal: "t2", under: "/p/linkc")

        reloaded.pruneTerminals(keeping: ["t2"])
        XCTAssertEqual(reloaded.terminalProjects, ["t2": "/p/linkc"])
    }

    func testAFilingStandardizesItsPathLikeTheRestOfTheSidebar() {
        let state = SidebarState(defaults: defaults)
        state.file(terminal: "t1", under: "~/june/")
        XCTAssertEqual(state.terminalProjects["t1"], ("~/june" as NSString).standardizingPath)
    }

    func testAStateSavedBeforeFilingsExistedDecodesWithEmptyFilings() {
        let json = """
        {"projectOrder":["/a"],"expandOverrides":{},"openSections":[]}
        """
        defaults.set(Data(json.utf8), forKey: SidebarState.key)
        let state = SidebarState(defaults: defaults)
        XCTAssertEqual(state.projectOrder, ["/a"])
        XCTAssertEqual(state.terminalProjects, [:])
    }

    func testInUseProjectsAddsTheFiledPathsStandardized() {
        XCTAssertEqual(
            SidebarState.inUseProjects(sessionPaths: ["/p/linkc"], filed: ["t1": "/p/june/./"]),
            ["/p/linkc", "/p/june"])
    }

    func testAFiledOnlyProjectKeepsItsSlotAndCollapseThroughTheStartPrune() {
        let state = SidebarState(defaults: defaults)
        state.noteProjects(["/p/june", "/p/linkc"])
        state.setExpanded("/p/june", false)

        // june has no live session — only a filing — so a naive "sessions + Earlier" keep set
        // would drop it and its collapse; the start prune must not.
        let sessionPaths: Set<String> = ["/p/linkc"]
        let filed = ["t1": "/p/june"]
        state.prune(keeping: SidebarState.inUseProjects(sessionPaths: sessionPaths, filed: filed))

        XCTAssertEqual(state.projectOrder, ["/p/june", "/p/linkc"])
        XCTAssertEqual(state.expandOverrides["/p/june"], false)
    }

    func testOpenAppsAreRememberedPerProjectInOpenOrder() {
        let state = SidebarState(defaults: defaults)
        state.openApp(OpenApp(folder: "/p/circuit", name: "Circuit"), in: "/p/circuit")
        state.openApp(OpenApp(folder: "/tools/notes", name: "Notes"), in: "/p/circuit/")
        state.openApp(OpenApp(folder: "/p/circuit", name: "Circuit"), in: "/p/circuit")
        state.openApp(OpenApp(folder: "/tools/notes", name: "Notes"), in: "/p/june")

        let reloaded = SidebarState(defaults: defaults)
        XCTAssertEqual(reloaded.openApps(in: "/p/circuit").map(\.name), ["Circuit", "Notes"], "one entry per app, in open order")
        XCTAssertEqual(reloaded.openApps(in: "/p/june").map(\.name), ["Notes"])

        reloaded.closeApp(folder: "/p/circuit/", in: "/p/circuit")
        XCTAssertEqual(SidebarState(defaults: defaults).openApps(in: "/p/circuit").map(\.name), ["Notes"])
    }

    func testAStateSavedBeforeAppTabsHasNone() throws {
        defaults.set(Data(#"{"projectOrder": ["/p/a"], "expandOverrides": {}, "openSections": []}"#.utf8), forKey: "sidebarState")
        let state = SidebarState(defaults: defaults)
        XCTAssertEqual(state.projectOrder, ["/p/a"])
        XCTAssertEqual(state.openApps(in: "/p/a"), [])
    }

    func testSavedDataKeyedByTwoSpellingsLoadsAsOneKeyWithFirstOccurrencesOrderAndOverrides() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("linkc-sidebar-canonical-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let realFolder = tempDir.appendingPathComponent("Proj")
        try FileManager.default.createDirectory(at: realFolder, withIntermediateDirectories: true)

        let symlink = tempDir.appendingPathComponent("link_to_proj")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: realFolder)

        let path1 = symlink.path
        let path2 = realFolder.path
        let canonical = ProjectPath.canonical(realFolder.path)

        let json = """
        {
            "projectOrder": ["\(path1)", "\(path2)"],
            "expandOverrides": {"\(path1)": false, "\(path2)": true},
            "openSections": [],
            "boardViewports": {
                "\(path1)": {"originX": 10, "originY": 20, "zoom": 1.0, "lens": "all"},
                "\(path2)": {"originX": 30, "originY": 40, "zoom": 2.0, "lens": "all"}
            }
        }
        """
        defaults.set(Data(json.utf8), forKey: SidebarState.key)
        let state = SidebarState(defaults: defaults)

        XCTAssertEqual(state.projectOrder, [canonical])
        XCTAssertEqual(state.expandOverrides, [canonical: false])
        XCTAssertEqual(state.boardViewport(for: path1)?.originX, 10)
        XCTAssertEqual(state.boardViewport(for: path2)?.originX, 10)
    }
}

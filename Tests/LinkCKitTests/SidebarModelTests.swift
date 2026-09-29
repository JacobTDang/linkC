import XCTest
@testable import LinkCKit

final class SidebarModelTests: XCTestCase {
    private func input(
        _ id: String, cwd: String, agent: AgentKind = .claude,
        tone: SessionRowStatus.Tone = .quiet, subagents: Bool = false
    ) -> SidebarModel.Input {
        SidebarModel.Input(
            session: Session(id: id, cwd: cwd, title: URL(fileURLWithPath: cwd).lastPathComponent, agentKind: agent),
            title: "title-\(id)",
            status: SessionRowStatus(text: "text-\(id)", tone: tone),
            hasRunningSubagents: subagents)
    }

    private func build(
        _ inputs: [SidebarModel.Input], shells: [ShellRow] = [], filed: [String: String] = [:], order: [String] = [], overrides: [String: Bool] = [:], selected: String? = nil
    ) -> [SidebarProject] {
        SidebarModel.projects(inputs: inputs, shells: shells, filed: filed, order: order, expandOverrides: overrides, selectedId: selected).projects
    }

    func testProjectsFollowTheStoredOrderAndUnknownOnesComeLastInOpenedOrder() {
        let projects = build(
            [input("1", cwd: "/p/b"), input("2", cwd: "/p/x"), input("3", cwd: "/p/a"), input("4", cwd: "/p/y")],
            order: ["/p/a", "/p/b"])
        XCTAssertEqual(projects.map(\.path), ["/p/a", "/p/b", "/p/x", "/p/y"])
        XCTAssertEqual(projects.map(\.name), ["a", "b", "x", "y"])
    }

    func testSessionsStayInOpenedOrderWithTheirTitlesAndStatuses() {
        let projects = build([input("1", cwd: "/p/a", agent: .agy), input("2", cwd: "/p/b"), input("3", cwd: "/p/a")])
        let a = projects.first { $0.path == "/p/a" }!
        XCTAssertEqual(a.sessions.map(\.id), ["1", "3"])
        XCTAssertEqual(a.sessions[0], SidebarSessionRow(
            id: "1", agentKind: .agy, title: "title-1", status: SessionRowStatus(text: "text-1", tone: .quiet)))
    }

    func testTheDotIsCoralOverTealOverNone() {
        func dot(_ inputs: [SidebarModel.Input]) -> ProjectDot { build(inputs)[0].dot }
        XCTAssertEqual(dot([input("1", cwd: "/p", tone: .working), input("2", cwd: "/p", tone: .attention)]), .attention)
        XCTAssertEqual(dot([input("1", cwd: "/p", tone: .error)]), .attention)
        XCTAssertEqual(dot([input("1", cwd: "/p", tone: .working)]), .working)
        XCTAssertEqual(dot([input("1", cwd: "/p", subagents: true)]), .working)
        XCTAssertEqual(dot([input("1", cwd: "/p")]), .none)
    }

    func testTheSelectedSessionsProjectIsOpenUnlessTheUserCollapsedIt() {
        let held = build([input("1", cwd: "/p/a")], selected: "1")
        XCTAssertTrue(held[0].isExpanded, "no override: the project holding the open terminal is open")

        let collapsed = build([input("1", cwd: "/p/a")], overrides: ["/p/a": false], selected: "1")
        XCTAssertFalse(collapsed[0].isExpanded, "a manual collapse sticks even while it holds the terminal")
    }

    func testOtherwiseTheOverrideDecidesAndTheDefaultIsCollapsed() {
        let projects = build(
            [input("1", cwd: "/p/a"), input("2", cwd: "/p/b"), input("3", cwd: "/p/c")],
            overrides: ["/p/a": true, "/p/b": false])
        XCTAssertEqual(projects.map(\.isExpanded), [true, false, false])
    }

    func testADuplicateSessionIdShowsTwiceInsteadOfTrapping() {
        let projects = build([input("1", cwd: "/p/a"), input("1", cwd: "/p/a")])
        XCTAssertEqual(projects[0].sessions.map(\.id), ["1", "1"])
    }

    func testAnOrderEntryWithNoLiveSessionMakesNoRow() {
        let projects = build([input("1", cwd: "/p/a")], order: ["/p/gone", "/p/a"])
        XCTAssertEqual(projects.map(\.path), ["/p/a"])
    }

    func testAWorkingRowCarriesItsActionAndAnIdleOneDoesNot() {
        var working = Session(id: "w", cwd: "/p/a", title: "a", agentKind: .claude)
        working.state = .working
        var idle = Session(id: "i", cwd: "/p/a", title: "a", agentKind: .claude)
        idle.state = .finished
        let status = SessionRowStatus(text: "", tone: .quiet)
        let rows = SidebarModel.projects(
            inputs: [
                SidebarModel.Input(session: working, title: "w", status: status, hasRunningSubagents: false, activity: "$ swift test"),
                SidebarModel.Input(session: idle, title: "i", status: status, hasRunningSubagents: false, activity: "$ swift test"),
            ],
            order: [], expandOverrides: [:], selectedId: nil
        ).projects[0].sessions
        XCTAssertEqual(rows.map(\.activity?.text), ["$ swift test", nil])
    }

    func testTerminalsListUnderTheirProjectAndAFiledOnlyProjectShows() {
        let s1 = ShellRow(id: "s1", cwd: "/p/linkc", title: "s1", state: .running)
        let s2 = ShellRow(id: "s2", cwd: "/Users/j/school", title: "s2", state: .running)
        let s3 = ShellRow(id: "s3", cwd: "/tmp", title: "s3", state: .running)

        let out = SidebarModel.projects(
            inputs: [input("session1", cwd: "/p/linkc")],
            shells: [s1, s2, s3],
            filed: ["s2": "/p/june"],
            order: ["/p/linkc", "/p/june"],
            expandOverrides: [:],
            selectedId: nil
        )
        let projects = out.projects

        XCTAssertEqual(projects.count, 2)
        XCTAssertEqual(projects[0].path, "/p/linkc")
        XCTAssertEqual(projects[0].sessions.map(\.id), ["session1"])
        XCTAssertEqual(projects[0].terminals.map(\.id), ["s1"])

        XCTAssertEqual(projects[1].path, "/p/june")
        XCTAssertEqual(projects[1].name, "june") // last component
        XCTAssertEqual(projects[1].dot, .none) // quiet dot
        XCTAssertEqual(projects[1].sessions.count, 0)
        XCTAssertEqual(projects[1].terminals.map(\.id), ["s2"])

        XCTAssertEqual(out.unfiled.map(\.id), ["s3"])
    }

    func testAFilingForATerminalThatIsNotLiveMakesNoProject() {
        // s2 was filed under /p/june, then stopped: the filing survives (it's restorable), but
        // it is no longer in `shells`. Without a live terminal, /p/june must not show as a project.
        let s1 = ShellRow(id: "s1", cwd: "/p/linkc", title: "s1", state: .running)

        let out = SidebarModel.projects(
            inputs: [],
            shells: [s1],
            filed: ["s1": "/p/linkc", "s2": "/p/june"],
            order: [],
            expandOverrides: [:],
            selectedId: nil
        )

        XCTAssertEqual(out.projects.map(\.path), ["/p/linkc"])
    }

    func testFiledOnlyProjectsFollowTheirTerminalsLaunchOrderRegardlessOfDictionaryOrder() {
        // Filed-only projects are only ever reached through a `filed[id]` lookup (never by
        // iterating the `filed` dictionary), so its own nondeterministic order can never leak in.
        // The order that's left is `shells`' own — the terminals' launch order.
        let shells = ["e", "a", "c", "d", "b"].map { ShellRow(id: "t\($0)", cwd: "/tmp", title: "t\($0)", state: .running) }
        let filed = Dictionary(uniqueKeysWithValues: shells.map { ($0.id, "/p/\($0.title.dropFirst())") })

        let projects = build([], shells: shells, filed: filed, order: [])

        XCTAssertEqual(projects.map(\.path), ["/p/e", "/p/a", "/p/c", "/p/d", "/p/b"])
    }

    @MainActor
    func testATerminalThatChangesFolderFollowsTheFolderRuleUnlessFiled() {
        let store = ShellTerminalStore()
        store.add(id: "s1", cwd: "/Users/j", title: "~")
        store.add(id: "s2", cwd: "/Users/j", title: "~")
        store.updateDirectory(id: "s1", to: "/p/linkc", home: "/Users/j")
        store.updateDirectory(id: "s2", to: "/p/linkc", home: "/Users/j")

        let out = SidebarModel.projects(
            inputs: [input("session1", cwd: "/p/linkc"), input("session2", cwd: "/p/june")],
            shells: store.rows,
            filed: ["s2": "/p/june"],
            order: ["/p/linkc", "/p/june"],
            expandOverrides: [:],
            selectedId: nil
        )

        XCTAssertEqual(out.projects.map(\.path), ["/p/linkc", "/p/june"])
        XCTAssertEqual(out.projects[0].terminals.map(\.id), ["s1"])
        XCTAssertEqual(out.projects[0].terminals.map(\.title), ["linkc"])
        XCTAssertEqual(out.projects[1].terminals.map(\.id), ["s2"], "a filed terminal stays where it was filed")
        XCTAssertTrue(out.unfiled.isEmpty)
    }

    func testATerminalInASubfolderIsNotListedUnderItsParentProject() {
        let s1 = ShellRow(id: "s1", cwd: "/p/linkc/Sources", title: "s1", state: .running)

        let out = SidebarModel.projects(
            inputs: [input("session1", cwd: "/p/linkc")],
            shells: [s1],
            filed: [:],
            order: [],
            expandOverrides: [:],
            selectedId: nil
        )

        XCTAssertEqual(out.projects.map(\.path), ["/p/linkc"])
        XCTAssertTrue(out.projects[0].terminals.isEmpty)
        XCTAssertEqual(out.unfiled.map(\.id), ["s1"])
    }
}

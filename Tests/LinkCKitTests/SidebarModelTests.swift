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
        _ inputs: [SidebarModel.Input], order: [String] = [], overrides: [String: Bool] = [:], selected: String? = nil
    ) -> [SidebarProject] {
        SidebarModel.projects(inputs: inputs, order: order, expandOverrides: overrides, selectedId: selected)
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
}

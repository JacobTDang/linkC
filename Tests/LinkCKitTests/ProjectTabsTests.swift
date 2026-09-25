import XCTest
@testable import LinkCKit

final class ProjectTabsTests: XCTestCase {
    private func session(_ id: String, _ cwd: String, _ state: SessionState = .ready, agent: AgentKind = .claude) -> Session {
        var session = Session(id: id, cwd: cwd, title: "title-\(id)", state: state)
        session.agentKind = agent
        return session
    }

    private func shell(_ id: String, _ cwd: String) -> ShellRow {
        ShellRow(id: id, cwd: cwd, title: "shell-\(id)", state: .running)
    }

    func testTheBoardComesFirstThenAgentsThenTerminals() {
        let tabs = ProjectTabs.tabs(
            project: "/p/june",
            sessions: [session("a1", "/p/june"), session("x", "/p/other"), session("a2", "/p/june/", agent: .codex)],
            shells: [shell("s1", "/p/june"), shell("s2", "/p/other")],
            titles: ["a1": "audio pipeline"])
        XCTAssertEqual(tabs.map(\.id), [ProjectTabs.boardID("/p/june"), "a1", "a2", "s1"])
        XCTAssertEqual(tabs[0].kind, .board)
        XCTAssertEqual(tabs[1].title, "audio pipeline", "a live title wins")
        XCTAssertEqual(tabs[2].kind, .agent(.codex))
        XCTAssertEqual(tabs[3].kind, .terminal)
    }

    func testAProjectWithNoSessionsHasOnlyItsBoard() {
        XCTAssertEqual(ProjectTabs.tabs(project: "/p/empty", sessions: [], shells: [], titles: [:]).map(\.kind), [.board])
    }

    func testAWorkingSessionIsMarked() {
        let tabs = ProjectTabs.tabs(project: "/p", sessions: [session("a", "/p", .working), session("b", "/p", .finished)], shells: [], titles: [:])
        XCTAssertEqual(tabs.map(\.isWorking), [false, true, false])
    }

    func testDigitsPickTabsInOrder() {
        let tabs = ProjectTabs.tabs(project: "/p", sessions: [session("a", "/p")], shells: [], titles: [:])
        XCTAssertEqual(ProjectTabs.tab(forDigit: 1, in: tabs)?.kind, .board)
        XCTAssertEqual(ProjectTabs.tab(forDigit: 2, in: tabs)?.id, "a")
        XCTAssertNil(ProjectTabs.tab(forDigit: 3, in: tabs))
        XCTAssertNil(ProjectTabs.tab(forDigit: 0, in: tabs))
    }

    func testCyclingWrapsBothWays() {
        let tabs = ProjectTabs.tabs(project: "/p", sessions: [session("a", "/p"), session("b", "/p")], shells: [], titles: [:])
        XCTAssertEqual(ProjectTabs.cycle(from: "b", in: tabs, backwards: false)?.kind, .board)
        XCTAssertEqual(ProjectTabs.cycle(from: ProjectTabs.boardID("/p"), in: tabs, backwards: true)?.id, "b")
        XCTAssertEqual(ProjectTabs.cycle(from: "gone", in: tabs, backwards: false)?.id, "a", "an unknown current starts from the Board")
    }

    func testAWorkingTabCarriesItsActionAndAnIdleOneDoesNot() {
        let tabs = ProjectTabs.tabs(
            project: "/p", sessions: [session("a", "/p", .working), session("b", "/p", .ready)], shells: [],
            titles: [:], activities: ["a": "Read the panel's drag gate", "b": "$ ls"])
        XCTAssertEqual(tabs.map(\.activity?.text), [nil, "Read the panel's drag gate", nil])
    }

    func testAFiledTerminalIsATabOfItsProject() {
        let tabs = ProjectTabs.tabs(
            project: "/p/june",
            sessions: [],
            shells: [shell("s1", "/Users/j/school")],
            filed: ["s1": "/p/june"],
            titles: [:])
        XCTAssertEqual(tabs.map(\.id), [ProjectTabs.boardID("/p/june"), "s1"])
    }

    func testATerminalFiledElsewhereIsLeftOutOfItsFoldersProjectTabs() {
        // s1's folder is /p/linkc, but it's filed under /p/june: it belongs to june, so linkc's
        // strip must not show it.
        let tabs = ProjectTabs.tabs(
            project: "/p/linkc",
            sessions: [],
            shells: [shell("s1", "/p/linkc")],
            filed: ["s1": "/p/june"],
            titles: [:])
        XCTAssertEqual(tabs.map(\.id), [ProjectTabs.boardID("/p/linkc")])
    }

    func testAppTabsComeLastInOpenOrder() {
        let tabs = ProjectTabs.tabs(
            project: "/p/circuit",
            sessions: [session("a1", "/p/circuit")],
            shells: [shell("s1", "/p/circuit")],
            titles: [:],
            openApps: [OpenApp(folder: "/p/circuit", name: "Circuit MCP"), OpenApp(folder: "/tools/notes/", name: "Notes")])
        XCTAssertEqual(tabs.map(\.id), [
            ProjectTabs.boardID("/p/circuit"), "a1", "s1",
            "app:/p/circuit#/p/circuit", "app:/p/circuit#/tools/notes",
        ])
        XCTAssertEqual(tabs[3].kind, .app)
        XCTAssertEqual(tabs[3].title, "Circuit MCP")
        XCTAssertFalse(tabs[3].isWorking, "closing an app tab needs no confirmation")
    }

    func testAnAppTabIDNamesItsProjectAndFolder() {
        XCTAssertEqual(ProjectTabs.appTabID(project: "/p/x/", folder: "/tools/notes/."), "app:/p/x#/tools/notes")
    }
}

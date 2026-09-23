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
}

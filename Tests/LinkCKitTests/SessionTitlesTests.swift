import XCTest
@testable import LinkCKit

final class SessionTitlesTests: XCTestCase {
    private func session(_ id: String, _ agent: AgentKind, cwd: String = "/p/linkC") -> Session {
        Session(id: id, cwd: cwd, title: "linkC", agentKind: agent)
    }

    private func task(
        id: String = "a1b2c3d4-0000", assignee: String, state: TaskState,
        prompt: String = "Fix relay dispatch\nDetails"
    ) -> TaskRecord {
        TaskRecord(id: id, fromAgent: .claude, toAgent: .agy, assigneeSessionId: assignee, prompt: prompt, state: state)
    }

    func testTheConversationsOwnTitleWinsOverAHeldTask() {
        let s = session("s1", .claude)
        let held = task(assignee: "s1", state: .started)
        let titles = SessionTitles.resolve(
            sessions: [s], claudeTitle: { $0 == "s1" ? "Session UI redesign" : nil }, heldTask: { _ in held })
        XCTAssertEqual(titles["s1"], "Session UI redesign")
    }

    func testAHeldTaskNamesTheSessionByShortIdAndFirstPromptLine() {
        let s = session("s1", .agy)
        let held = task(assignee: "s1", state: .delivered, prompt: "\n  Fix relay dispatch  \nmore")
        let titles = SessionTitles.resolve(sessions: [s], claudeTitle: { _ in nil }, heldTask: { _ in held })
        XCTAssertEqual(titles["s1"], "Task a1b2c3d4: Fix relay dispatch")
    }

    func testATaskWithABlankPromptIsNamedByShortIdAlone() {
        XCTAssertEqual(SessionTitles.taskTitle(task(assignee: "s1", state: .started, prompt: " \n ")), "Task a1b2c3d4")
    }

    func testUntitledSessionsOfOneAgentInOneProjectAreNumberedInOpenedOrder() {
        let a = session("a", .cursor)
        let b = session("b", .cursor)
        let c = session("c", .agy)
        let d = session("d", .cursor, cwd: "/p/other")
        let titles = SessionTitles.resolve(sessions: [a, b, c, d], claudeTitle: { _ in nil }, heldTask: { _ in nil })
        XCTAssertEqual(titles["a"], "Cursor")
        XCTAssertEqual(titles["b"], "Cursor 2")
        XCTAssertEqual(titles["c"], "agy")
        XCTAssertEqual(titles["d"], "Cursor", "numbering is per project")
    }

    func testATitledSessionDoesNotTakeANumber() {
        let a = session("a", .claude)
        let b = session("b", .claude)
        let titles = SessionTitles.resolve(
            sessions: [a, b], claudeTitle: { $0 == "a" ? "Named" : nil }, heldTask: { _ in nil })
        XCTAssertEqual(titles["b"], "Claude")
    }

    func testTheHeldTaskIsTheDeliveredOrStartedTaskAssignedToTheSession() {
        let s = session("s1", .agy)
        let queued = task(id: "q", assignee: "s1", state: .queued)
        let done = task(id: "d", assignee: "s1", state: .done)
        let other = task(id: "o", assignee: "s2", state: .started)
        let held = task(id: "h", assignee: "s1", state: .started)
        XCTAssertEqual(SessionTitles.heldTask(for: s, in: [queued, done, other, held])?.id, "h")
        XCTAssertNil(SessionTitles.heldTask(for: s, in: [queued, done, other]))
    }

    func testShortNames() {
        XCTAssertEqual(AgentKind.claude.shortName, "Claude")
        XCTAssertEqual(AgentKind.agy.shortName, "agy")
        XCTAssertEqual(AgentKind.cursor.shortName, "Cursor")
        XCTAssertEqual(AgentKind.codex.shortName, "Codex")
        XCTAssertEqual(AgentKind.shell.shortName, "Terminal")
    }
}

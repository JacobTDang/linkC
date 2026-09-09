import XCTest
@testable import LinkCKit

final class ProjectDashboardSheetTests: XCTestCase {
    func testProjectDashboardDataInitialization() {
        let data = ProjectDashboardData(workspacePath: "/tmp/foo", projectTitle: "foo")
        XCTAssertEqual(data.projectTitle, "foo")
        XCTAssertEqual(data.workspacePath, "/tmp/foo")
        XCTAssertTrue(data.activityItems.isEmpty)
        XCTAssertTrue(data.dossiers.isEmpty)
        XCTAssertTrue(data.sharedNotes.isEmpty)
        XCTAssertTrue(data.collisions.isEmpty)
    }

    func testProjectDashboardDataWithPopulatedValues() {
        let activity = AgentActivityItem(
            workspacePath: "/tmp/foo",
            projectTitle: "foo",
            fromAgent: .claude,
            toAgent: .codex,
            kind: .delegatedTask,
            title: "Delegate subtask",
            body: "Check docs"
        )
        let dossier = AgentContributionDossier(
            agent: .claude,
            workspacePath: "/tmp/foo",
            completedTasksCount: 2,
            claimedFiles: ["Sources/linkc/Main.swift"]
        )
        let note = SharedNote(
            authorAgent: .claude,
            title: "Architecture Note",
            content: "Using Coordinator pattern"
        )
        let collision = CollisionWarning(
            conflictingAgent: .codex,
            pid: 1234,
            conflictingFiles: ["Sources/linkc/Main.swift"],
            goal: "Refactor main"
        )

        let data = ProjectDashboardData(
            workspacePath: "/tmp/foo",
            projectTitle: "foo",
            activityItems: [activity],
            dossiers: [dossier],
            sharedNotes: [note],
            collisions: [collision]
        )

        XCTAssertEqual(data.activityItems.count, 1)
        XCTAssertEqual(data.dossiers.count, 1)
        XCTAssertEqual(data.sharedNotes.count, 1)
        XCTAssertEqual(data.collisions.count, 1)
        XCTAssertEqual(data.collisions.first?.conflictingAgent, .codex)
    }
}

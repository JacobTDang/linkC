import XCTest
@testable import LinkCKit

final class DashboardModelsTests: XCTestCase {
    func testAgentActivityItemRoundTripJSON() throws {
        let item = AgentActivityItem(
            id: "act-1",
            timestamp: Date(timeIntervalSince1970: 1725880000),
            workspacePath: "/tmp/project",
            projectTitle: "project",
            fromAgent: .claude,
            toAgent: .cursor,
            kind: .completedTask,
            title: "Task Completed by Cursor Agent",
            body: "Created Auth.swift with 5 tests passing.",
            claimedFiles: ["Auth.swift", "AuthTests.swift"]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(item)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AgentActivityItem.self, from: data)

        XCTAssertEqual(decoded, item)
        XCTAssertEqual(decoded.kind, .completedTask)
        XCTAssertEqual(decoded.fromAgent, .claude)
        XCTAssertEqual(decoded.toAgent, .cursor)
        XCTAssertEqual(decoded.claimedFiles, ["Auth.swift", "AuthTests.swift"])
    }

    func testAgentContributionDossierProperties() {
        let dossier = AgentContributionDossier(
            agent: .cursor,
            workspacePath: "/tmp/project",
            activeSessionId: "s-1",
            status: "working",
            liveActivity: "Generating Auth.swift",
            completedTasksCount: 3,
            claimedFiles: ["Auth.swift"],
            modifiedFiles: ["Sources/Auth.swift"],
            lastDeliverable: "Generated Auth.swift successfully",
            notesAuthoredCount: 1
        )

        XCTAssertEqual(dossier.id, "/tmp/project-cursor")
        XCTAssertEqual(dossier.agent, .cursor)
        XCTAssertEqual(dossier.status, "working")
        XCTAssertEqual(dossier.liveActivity, "Generating Auth.swift")
        XCTAssertEqual(dossier.completedTasksCount, 3)
        XCTAssertEqual(dossier.claimedFiles, ["Auth.swift"])
        XCTAssertEqual(dossier.modifiedFiles, ["Sources/Auth.swift"])
        XCTAssertEqual(dossier.lastDeliverable, "Generated Auth.swift successfully")
        XCTAssertEqual(dossier.notesAuthoredCount, 1)
    }

    func testProjectDashboardDataDefaults() {
        let data = ProjectDashboardData(workspacePath: "/tmp/project", projectTitle: "project")
        XCTAssertEqual(data.workspacePath, "/tmp/project")
        XCTAssertEqual(data.projectTitle, "project")
        XCTAssertTrue(data.activityItems.isEmpty)
        XCTAssertTrue(data.dossiers.isEmpty)
        XCTAssertTrue(data.sharedNotes.isEmpty)
        XCTAssertTrue(data.collisions.isEmpty)
    }

    func testGlobalDashboardDataDefaults() {
        let data = GlobalDashboardData()
        XCTAssertTrue(data.activityItems.isEmpty)
        XCTAssertTrue(data.dossiers.isEmpty)
        XCTAssertEqual(data.activeProjectCount, 0)
    }
}

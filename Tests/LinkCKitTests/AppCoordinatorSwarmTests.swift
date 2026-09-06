import XCTest
@testable import LinkCKit

final class AppCoordinatorSwarmTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-swarm-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    func testProjectSwarmDetectedForMultipleAgentsInSameCwd() throws {
        let path = tempDir.path
        let blackboard = BlackboardStore(workspaceRoot: path)

        // Agent 1 claims FileA
        _ = try blackboard.broadcastIntent(
            agentKind: .claude,
            pid: 1001,
            goal: "Refactor A",
            files: ["Sources/FileA.swift"],
            status: "working"
        )

        // Agent 2 claims FileA and FileB
        let warnings = try blackboard.broadcastIntent(
            agentKind: .cursor,
            pid: 1002,
            goal: "Refactor A & B",
            files: ["Sources/FileA.swift", "Sources/FileB.swift"],
            status: "working"
        )

        let swarm = ProjectSwarm(
            workspacePath: path,
            activeAgents: [.claude, .cursor],
            collisions: warnings
        )

        XCTAssertEqual(swarm.workspacePath, path)
        XCTAssertEqual(swarm.activeAgents, [.claude, .cursor])
        XCTAssertEqual(swarm.collisions.count, 1)
        XCTAssertEqual(swarm.collisions.first?.conflictingFiles, ["Sources/FileA.swift"])
    }
}

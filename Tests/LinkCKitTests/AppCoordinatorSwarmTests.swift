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

    private final class NoOpNotificationSink: NotificationSink, @unchecked Sendable {
        func deliver(id: String, title: String, body: String) {}
    }

    @MainActor
    private func makeCoordinator() -> AppCoordinator {
        let settingsDir = tempDir.appendingPathComponent("settings")
        try? FileManager.default.createDirectory(at: settingsDir, withIntermediateDirectories: true)
        return AppCoordinator(
            terminals: TerminalSessionManager(),
            hookServer: HookServer(port: 0),
            notifications: NotificationManager(sink: NoOpNotificationSink(), now: { Date() }),
            claudePath: "/usr/bin/true",
            settingsDir: settingsDir,
            userSettingsURL: tempDir.appendingPathComponent("user-settings.json"),
            manifestDir: tempDir.appendingPathComponent("manifest"),
            isWatching: { _ in false }
        )
    }

    /// `sampleSwarms` now reads each candidate workspace's blackboard off the main actor
    /// (`Task.detached`) before hopping back to publish — this pins down that moving the read did
    /// not change what it actually computes.
    @MainActor
    func testSampleSwarmsStillDetectsCollisionsAfterMovingTheReadOffTheMainActor() async throws {
        let path = tempDir.path
        let norm = ProjectPath.canonical(path)
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }
        // `store.create` canonicalizes `cwd`, and `sampleSwarms` groups sessions by that
        // canonical value — the blackboard must be written under the same path or the swarm
        // computation's own `BlackboardStore(workspaceRoot:)` reads an empty board.
        coordinator.store.create(cwd: path, title: "one", agentKind: .claude)
        coordinator.store.create(cwd: path, title: "two", agentKind: .cursor)

        let blackboard = BlackboardStore(workspaceRoot: norm)
        _ = try blackboard.broadcastIntent(
            agentKind: .claude, pid: 2001, goal: "A", files: ["Sources/FileA.swift"], status: "working"
        )
        _ = try blackboard.broadcastIntent(
            agentKind: .cursor, pid: 2002, goal: "A too", files: ["Sources/FileA.swift"], status: "working"
        )

        await coordinator.sampleSwarms()

        let swarm = try XCTUnwrap(coordinator.swarms.first { $0.workspacePath == norm })
        XCTAssertEqual(Set(swarm.activeAgents), [.claude, .cursor])
        XCTAssertEqual(swarm.collisions.first?.conflictingFiles, ["Sources/FileA.swift"])
    }

    /// A workspace with only one agent is never a swarm — unaffected by the async move.
    @MainActor
    func testSampleSwarmsIgnoresAWorkspaceWithOnlyOneAgent() async throws {
        let path = tempDir.path
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }
        coordinator.store.create(cwd: path, title: "solo", agentKind: .claude)

        await coordinator.sampleSwarms()

        XCTAssertTrue(coordinator.swarms.isEmpty)
    }

    /// Sampling again with nothing changed must not disturb the published value — the fix skips
    /// the republish, but the observable result is identical either way.
    @MainActor
    func testSampleSwarmsIsStableAcrossRepeatedCallsWithNoChange() async throws {
        let path = tempDir.path
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }
        coordinator.store.create(cwd: path, title: "one", agentKind: .claude)
        coordinator.store.create(cwd: path, title: "two", agentKind: .cursor)

        await coordinator.sampleSwarms()
        let first = coordinator.swarms
        await coordinator.sampleSwarms()
        XCTAssertEqual(coordinator.swarms, first)
    }
}

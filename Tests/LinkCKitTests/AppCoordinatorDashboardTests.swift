import XCTest
@testable import LinkCKit

final class AppCoordinatorDashboardTests: XCTestCase {
    @MainActor
    func testCoordinatorFetchesProjectAndGlobalDashboard() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let coordinator = AppCoordinator()
        defer { coordinator.shutdown() }

        let projectData = coordinator.fetchProjectDashboard(workspacePath: tempDir.path)
        XCTAssertEqual(projectData.workspacePath, (tempDir.path as NSString).standardizingPath)

        let globalData = coordinator.fetchGlobalDashboard()
        XCTAssertNotNil(globalData)
    }

    func testPanelScreenActivityEnumCase() {
        XCTAssertTrue(PanelScreen.allCases.contains(.activity))
        XCTAssertEqual(PanelScreen.activity.rawValue, "activity")
        XCTAssertEqual(PanelScreen.activity.id, "activity")
    }

    @MainActor
    func testCoordinatorDashboardAggregatorProperty() {
        let coordinator = AppCoordinator()
        defer { coordinator.shutdown() }

        XCTAssertNotNil(coordinator.dashboardAggregator)
    }

    @MainActor
    func testCoordinatorFetchesProjectDashboardWithLiveSessions() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let coordinator = AppCoordinator()
        defer { coordinator.shutdown() }

        let session = coordinator.store.create(cwd: tempDir.path, title: "claude-session", agentKind: .claude)
        coordinator.store.updateState(id: session.id, to: .working)

        let projectData = coordinator.fetchProjectDashboard(workspacePath: tempDir.path)
        XCTAssertEqual(projectData.workspacePath, (tempDir.path as NSString).standardizingPath)
        XCTAssertFalse(projectData.dossiers.isEmpty)
        let claudeDossier = projectData.dossiers.first { $0.agent == .claude }
        XCTAssertNotNil(claudeDossier)
        XCTAssertEqual(claudeDossier?.status, "working")
    }

    @MainActor
    func testCoordinatorFetchesGlobalDashboardMultipleWorkspaces() throws {
        let dir1 = FileManager.default.temporaryDirectory.appendingPathComponent("ws1-\(UUID().uuidString)")
        let dir2 = FileManager.default.temporaryDirectory.appendingPathComponent("ws2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: dir1)
            try? FileManager.default.removeItem(at: dir2)
        }

        let coordinator = AppCoordinator()
        defer { coordinator.shutdown() }

        _ = coordinator.store.create(cwd: dir1.path, title: "ws1-agent", agentKind: .claude)
        _ = coordinator.store.create(cwd: dir2.path, title: "ws2-agent", agentKind: .cursor)

        let globalData = coordinator.fetchGlobalDashboard()
        XCTAssertGreaterThanOrEqual(globalData.activeProjectCount, 2)
        XCTAssertTrue(globalData.dossiers.contains { $0.agent == .claude })
        XCTAssertTrue(globalData.dossiers.contains { $0.agent == .cursor })
    }

    @MainActor
    func testCoordinatorFiltersSessionsByWorkspace() throws {
        let dir1 = FileManager.default.temporaryDirectory.appendingPathComponent("wsA-\(UUID().uuidString)")
        let dir2 = FileManager.default.temporaryDirectory.appendingPathComponent("wsB-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: dir1)
            try? FileManager.default.removeItem(at: dir2)
        }

        let coordinator = AppCoordinator()
        defer { coordinator.shutdown() }

        _ = coordinator.store.create(cwd: dir1.path, title: "agentA", agentKind: .claude)
        _ = coordinator.store.create(cwd: dir2.path, title: "agentB", agentKind: .cursor)

        let projA = coordinator.fetchProjectDashboard(workspacePath: dir1.path)
        XCTAssertTrue(projA.dossiers.contains { $0.agent == .claude })
        XCTAssertFalse(projA.dossiers.contains { $0.agent == .cursor })
    }

    @MainActor
    func testCoordinatorFetchesProjectAndGlobalDashboardAsync() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let coordinator = AppCoordinator()
        defer { coordinator.shutdown() }

        let session = coordinator.store.create(cwd: tempDir.path, title: "claude-session", agentKind: .claude)
        coordinator.store.updateState(id: session.id, to: .working)

        let projectData = await coordinator.fetchProjectDashboardAsync(workspacePath: tempDir.path)
        XCTAssertEqual(projectData.workspacePath, (tempDir.path as NSString).standardizingPath)
        XCTAssertFalse(projectData.dossiers.isEmpty)
        XCTAssertEqual(projectData.dossiers.first?.agent, .claude)

        let globalData = await coordinator.fetchGlobalDashboardAsync()
        XCTAssertEqual(globalData.activeProjectCount, 1)
        XCTAssertTrue(globalData.dossiers.contains { $0.agent == .claude })
    }

    @MainActor
    func testCoordinatorPassesTerminalRecentOutputToDashboard() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let coordinator = AppCoordinator()
        defer { coordinator.shutdown() }

        let session = coordinator.store.create(cwd: tempDir.path, title: "claude-session", agentKind: .claude)
        coordinator.store.updateState(id: session.id, to: .working)

        let termSession = coordinator.terminals.makeSession(id: session.id, cwd: tempDir.path, title: "claude-session", agentKind: .claude)
        try termSession.start(executable: "/bin/cat", args: [], env: [:])
        termSession.sendInput("Compiling project files\nAll 15 modules built successfully\n")

        // Wait brief moment for cat to echo to terminal view
        for _ in 0..<30 {
            if !termSession.recentOutput(lines: 5).isEmpty {
                break
            }
            try? await Task.sleep(for: .milliseconds(50))
        }

        let projectData = coordinator.fetchProjectDashboard(workspacePath: tempDir.path)
        let claudeDossier = projectData.dossiers.first { $0.agent == .claude }
        XCTAssertNotNil(claudeDossier)
        XCTAssertTrue(claudeDossier?.lastDeliverable?.contains("modules built successfully") ?? false)

        let liveItem = projectData.activityItems.first { $0.fromAgent == .claude && $0.title.contains("active in terminal") }
        XCTAssertNotNil(liveItem)
        XCTAssertTrue(liveItem?.body.contains("modules built successfully") ?? false)

        let globalData = await coordinator.fetchGlobalDashboardAsync()
        let globalClaudeDossier = globalData.dossiers.first { $0.agent == .claude }
        XCTAssertEqual(globalClaudeDossier?.lastDeliverable, claudeDossier?.lastDeliverable)

        termSession.terminate()
    }
}

import XCTest
@testable import LinkCKit

final class AppCoordinatorDashboardTests: XCTestCase {
    /// Polls until `predicate` holds (or times out) instead of sleeping a fixed duration.
    @MainActor
    private func waitUntil(_ predicate: @MainActor () -> Bool, iterations: Int = 100) async throws -> Bool {
        for _ in 0..<iterations {
            if predicate() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return predicate()
    }

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
        // `stty -echo` matches a real CLI's raw-mode input loop: plain `/bin/cat` leaves the pty's
        // kernel echo on, which would double this multi-line input (once from the kernel, once
        // from `cat`'s own copy-through).
        try termSession.start(executable: "/bin/sh", args: ["-c", "stty -echo; printf 'MOCK_SHELL_READY\\n'; exec cat"], env: [:])
        // Poll for the shell's own confirmation that `stty -echo` already ran, instead of
        // sleeping a fixed duration: writing before that lands would race the shell's own
        // startup and catch the pty with kernel echo still on.
        let shellReady = try await waitUntil {
            termSession.recentOutput(lines: 5).contains("MOCK_SHELL_READY")
        }
        XCTAssertTrue(shellReady, "mock shell never confirmed it disabled pty echo")
        termSession.sendInput("Compiling project files\nAll 15 modules built successfully\n")

        // Wait for cat to echo the full frame back — not just the first line — before reading it.
        for _ in 0..<30 {
            if termSession.recentOutput(lines: 5).contains("modules built successfully") {
                break
            }
            try? await Task.sleep(for: .milliseconds(50))
        }

        let projectData = coordinator.fetchProjectDashboard(workspacePath: tempDir.path)
        let claudeDossier = projectData.dossiers.first { $0.agent == .claude }
        XCTAssertNotNil(claudeDossier)
        XCTAssertTrue(claudeDossier?.lastDeliverable?.contains("modules built successfully") ?? false)

        // Presence is not a timeline event: no activity item is synthesized for the live session.
        XCTAssertNil(projectData.activityItems.first { $0.fromAgent == .claude })
        XCTAssertEqual(claudeDossier?.activeSessionId, session.id)

        let globalData = await coordinator.fetchGlobalDashboardAsync()
        let globalClaudeDossier = globalData.dossiers.first { $0.agent == .claude }
        XCTAssertEqual(globalClaudeDossier?.lastDeliverable, claudeDossier?.lastDeliverable)

        termSession.terminate()
    }
}

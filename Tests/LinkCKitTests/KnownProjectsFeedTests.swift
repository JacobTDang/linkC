import Observation
import os
import XCTest
@testable import LinkCKit

/// The known-projects list the sweep builds for `projects.json` is also published in-process, so the
/// app draws its agent cards from the list itself rather than from the file.
@MainActor
final class KnownProjectsFeedTests: XCTestCase {
    nonisolated(unsafe) private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-feed-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private final class NoOpNotificationSink: NotificationSink, @unchecked Sendable {
        func deliver(id: String, title: String, body: String) {}
    }

    private func makeCoordinator() -> AppCoordinator {
        let settingsDir = tempDir.appendingPathComponent("settings")
        try? FileManager.default.createDirectory(at: settingsDir, withIntermediateDirectories: true)
        return AppCoordinator(
            terminals: TerminalSessionManager(),
            hookServer: HookServer.forTesting(),
            notifications: NotificationManager(sink: NoOpNotificationSink(), now: { Date() }),
            claudePath: "/usr/bin/true",
            settingsDir: settingsDir,
            userSettingsURL: tempDir.appendingPathComponent("user-settings.json"),
            manifestDir: tempDir.appendingPathComponent("manifest"),
            modelLists: TestModelLists.none,
            isWatching: { _ in false }
        )
    }

    /// Set from an observation's change callback, which may run off the test's own frame.
    private final class Flag: Sendable {
        private let box = OSAllocatedUnfairLock(initialState: false)
        func set() { box.withLock { $0 = true } }
        var isSet: Bool { box.withLock { $0 } }
    }

    private func watch(_ feed: KnownProjectsFeed) -> Flag {
        let changed = Flag()
        withObservationTracking { _ = feed.projects } onChange: { changed.set() }
        return changed
    }

    /// No `projects.json` here at all: the in-process list does not depend on the file.
    func testTheSweepPublishesTheListInProcessWithoutAFile() async {
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }
        coordinator.store.create(cwd: tempDir.path, title: "idle", id: "L1", agentKind: .codex)
        coordinator.store.updateState(id: "L1", to: .ready)

        await coordinator.runSweepTickForTests()

        let sessions = coordinator.knownProjects.projects.flatMap(\.sessions)
        XCTAssertEqual(sessions.map(\.id), ["L1"])
        XCTAssertEqual(sessions.map(\.state), ["ready"])
        XCTAssertEqual(coordinator.knownProjects.projects.map(\.path), [ProjectPath.canonical(tempDir.path)])
    }

    func testObserversHearOfAChangedListAndNotOfAnUnchangedOne() async {
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }
        coordinator.store.create(cwd: tempDir.path, title: "idle", id: "L1", agentKind: .agy)
        coordinator.store.updateState(id: "L1", to: .ready)
        await coordinator.runSweepTickForTests()

        let quiet = watch(coordinator.knownProjects)
        await coordinator.runSweepTickForTests()
        XCTAssertFalse(quiet.isSet, "an equal list must not redraw the cards")

        coordinator.store.updateState(id: "L1", to: .working)
        await coordinator.runSweepTickForTests()
        XCTAssertTrue(quiet.isSet)
        XCTAssertEqual(coordinator.knownProjects.projects.flatMap(\.sessions).map(\.state), ["working"])
    }

    /// The cards beside a terminal are built from the published list, so a new list is new cards.
    func testTheColumnFollowsThePublishedList() async {
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }
        let path = ProjectPath.canonical(tempDir.path)
        let roots: [String: RepoRoots.Root] = [path: .repo(path)]
        coordinator.store.create(cwd: tempDir.path, title: "mine", id: "L1", agentKind: .agy)
        coordinator.store.updateState(id: "L1", to: .ready)
        await coordinator.runSweepTickForTests()
        let before = AgentsColumn.build(projects: coordinator.knownProjects.projects, roots: roots, selectedId: "L1")
        XCTAssertEqual(before.cards.map(\.id), ["L1"])
        XCTAssertNil(before.needsYouLabel)

        coordinator.store.create(cwd: tempDir.path, title: "asks", id: "L2", agentKind: .codex)
        coordinator.store.updateState(id: "L2", to: .waitingPermission)
        await coordinator.runSweepTickForTests()

        let after = AgentsColumn.build(projects: coordinator.knownProjects.projects, roots: roots, selectedId: "L1")
        XCTAssertEqual(after.cards.map(\.id), ["L2", "L1"])
        XCTAssertEqual(after.needsYouLabel, "1 need you")
    }
}

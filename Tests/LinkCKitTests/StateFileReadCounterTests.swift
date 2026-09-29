import XCTest
@testable import LinkCKit

/// The counter the read-cache tests measure with. It has to count real disk loads exactly, or
/// every "read once" assertion built on it is meaningless.
final class StateFileReadCounterTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-read-counter-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    func testAnAbsentInboxCountsNoDiskLoad() throws {
        let store = InboxStore(workspaceRoot: tempDir.path)

        _ = try store.load()

        XCTAssertEqual(StateFileReadCounter.shared.count(path: store.inboxURL.path), 0)
    }

    func testEachInboxLoadOfAnExistingFileCountsOnce() throws {
        let store = InboxStore(workspaceRoot: tempDir.path)
        try store.saveRaw(Inbox(workspacePath: store.workspaceRoot))
        let before = StateFileReadCounter.shared.count(path: store.inboxURL.path)

        _ = try store.load()
        _ = try store.load()

        XCTAssertEqual(StateFileReadCounter.shared.count(path: store.inboxURL.path) - before, 2)
    }

    func testEachBlackboardLoadOfAnExistingFileCountsOnce() throws {
        let store = BlackboardStore(workspaceRoot: tempDir.path)
        try store.saveRaw(Blackboard(projectPath: store.workspaceRoot))
        let before = StateFileReadCounter.shared.count(path: store.blackboardURL.path)

        _ = try store.load()
        _ = try store.load()
        _ = try store.load()

        XCTAssertEqual(StateFileReadCounter.shared.count(path: store.blackboardURL.path) - before, 3)
    }
}

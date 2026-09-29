import XCTest
import os
@testable import LinkCKit

final class InboxWatcherTests: XCTestCase {
    private var root: URL!
    private var workspace: String { root.path }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-inbox-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeWatcher(_ description: String, inverted: Bool = false) -> (InboxWatcher, XCTestExpectation) {
        let fired = expectation(description: description)
        fired.assertForOverFulfill = false
        fired.isInverted = inverted
        return (InboxWatcher { fired.fulfill() }, fired)
    }

    /// A save that really writes: a task whose brief repeats an open one is deduplicated, unwritten.
    private func saveToInbox(_ workspace: String) throws {
        _ = try InboxStore(workspaceRoot: workspace).createTask(
            from: .codex, to: .claude, prompt: "work \(UUID().uuidString)", files: [])
    }

    func testASaveToTheInboxFires() throws {
        try saveToInbox(workspace)
        let (watcher, fired) = makeWatcher("saved")
        defer { watcher.stop() }
        watcher.watch(workspaces: [workspace])

        try saveToInbox(workspace)
        wait(for: [fired], timeout: 2)
    }

    func testAWriteToAnotherFileInTheFolderStaysQuiet() throws {
        try saveToInbox(workspace)
        let (watcher, fired) = makeWatcher("quiet", inverted: true)
        defer { watcher.stop() }
        watcher.watch(workspaces: [workspace])

        try Data("{}".utf8).write(to: root.appendingPathComponent(".linkc/blackboard.json"), options: .atomic)
        try Data("notes".utf8).write(to: root.appendingPathComponent(".linkc/HANDOFF.md"))
        wait(for: [fired], timeout: 0.5)
    }

    func testTheFirstSaveIntoAWorkspaceWithoutAFolderFires() throws {
        let (watcher, fired) = makeWatcher("first save")
        defer { watcher.stop() }
        watcher.watch(workspaces: [workspace])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".linkc").path))

        try saveToInbox(workspace)
        wait(for: [fired], timeout: 2)
    }

    func testAWorkspaceAddedLaterIsWatched() throws {
        try saveToInbox(workspace)
        let (watcher, fired) = makeWatcher("added later")
        defer { watcher.stop() }
        watcher.watch(workspaces: [])
        watcher.watch(workspaces: [workspace])

        try saveToInbox(workspace)
        wait(for: [fired], timeout: 2)
    }

    func testAWorkspaceDroppedFromTheSetIsNoLongerWatched() throws {
        try saveToInbox(workspace)
        let (watcher, fired) = makeWatcher("dropped", inverted: true)
        defer { watcher.stop() }
        watcher.watch(workspaces: [workspace])
        watcher.watch(workspaces: [])

        try saveToInbox(workspace)
        wait(for: [fired], timeout: 0.5)
    }

    /// The watch follows the folder, not the first one that was there: after it is removed and made
    /// again, a later save still fires.
    func testAFolderRemovedAndMadeAgainIsStillWatched() throws {
        try saveToInbox(workspace)
        let count = OSAllocatedUnfairLock(initialState: 0)
        let watcher = InboxWatcher { count.withLock { $0 += 1 } }
        defer { watcher.stop() }
        watcher.watch(workspaces: [workspace])

        try FileManager.default.removeItem(at: root.appendingPathComponent(".linkc"))
        try saveToInbox(workspace)
        Thread.sleep(forTimeInterval: 0.3)   // the events of the removal and the new folder settle
        let before = count.withLock { $0 }

        try saveToInbox(workspace)
        let deadline = Date().addingTimeInterval(2)
        while count.withLock({ $0 }) == before, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertGreaterThan(count.withLock { $0 }, before, "a save into the recreated folder was not seen")
    }

    func testAWorkspaceThatDidNotExistYetIsPickedUpOnTheNextWatch() throws {
        let later = root.appendingPathComponent("later").path
        let (watcher, fired) = makeWatcher("appeared")
        defer { watcher.stop() }
        watcher.watch(workspaces: [later])

        try FileManager.default.createDirectory(atPath: later, withIntermediateDirectories: true)
        watcher.watch(workspaces: [later])
        try saveToInbox(later)
        wait(for: [fired], timeout: 2)
    }

    func testStopIsIdempotentAndLaterWatchesDoNothing() throws {
        try saveToInbox(workspace)
        let (watcher, fired) = makeWatcher("stopped", inverted: true)
        watcher.watch(workspaces: [workspace])
        watcher.stop()
        watcher.stop()
        watcher.watch(workspaces: [workspace])

        try saveToInbox(workspace)
        wait(for: [fired], timeout: 0.5)
    }

    func testReleasingTheWatcherWithoutStopIsSafe() throws {
        try saveToInbox(workspace)
        var watcher: InboxWatcher? = InboxWatcher {}
        watcher?.watch(workspaces: [workspace])
        watcher = nil
        XCTAssertNil(watcher)
    }
}

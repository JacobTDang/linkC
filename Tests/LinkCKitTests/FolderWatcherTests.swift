import XCTest
@testable import LinkCKit

final class FolderWatcherTests: XCTestCase {
    func testAFileWrittenIntoTheFolderIsSeen() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let seen = expectation(description: "a change is reported")
        seen.assertForOverFulfill = false
        let watcher = try FolderWatcher(directory: folder) { seen.fulfill() }
        defer { watcher.stop() }

        try Data("{}".utf8).write(to: folder.appendingPathComponent("R1.json"), options: .atomic)

        wait(for: [seen], timeout: 2)
    }

    func testAFolderThatDoesNotExistCannotBeWatched() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-missing-\(UUID().uuidString)")
        XCTAssertThrowsError(try FolderWatcher(directory: missing) {})
    }

    /// A file moved into the folder (an atomic write lands by rename) is seen, not only a file created there.
    func testAFileMovedIntoTheFolderIsSeen() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-watch-\(UUID().uuidString)")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-outside-\(UUID().uuidString).json")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: outside)
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: outside)
        }
        let seen = expectation(description: "the move is reported")
        seen.assertForOverFulfill = false
        let watcher = try FolderWatcher(directory: folder) { seen.fulfill() }
        defer { watcher.stop() }

        try FileManager.default.moveItem(at: outside, to: folder.appendingPathComponent("R1.json"))

        wait(for: [seen], timeout: 2)
    }

    func testAStoppedWatcherReportsNothing() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let silent = expectation(description: "no change is reported after stop")
        silent.isInverted = true
        let watcher = try FolderWatcher(directory: folder) { silent.fulfill() }
        watcher.stop()

        try Data("{}".utf8).write(to: folder.appendingPathComponent("R1.json"))

        wait(for: [silent], timeout: 0.5)
    }
}

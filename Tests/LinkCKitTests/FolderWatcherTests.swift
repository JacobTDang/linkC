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
}

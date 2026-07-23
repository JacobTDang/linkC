import XCTest
@testable import LinkCKit

final class RecentFoldersLogTests: XCTestCase {
    func testRecordingAddsToFront() {
        let log = RecentFoldersLog()
            .recording("/Users/x/projects/a")
            .recording("/Users/x/projects/b")
        XCTAssertEqual(log.paths, ["/Users/x/projects/b", "/Users/x/projects/a"])
    }

    func testRecordingExistingPathMovesItToFrontWithoutDuplicating() {
        let log = RecentFoldersLog()
            .recording("/a")
            .recording("/b")
            .recording("/a")
        XCTAssertEqual(log.paths, ["/a", "/b"])
    }

    func testTrailingSlashDedupes() {
        let log = RecentFoldersLog()
            .recording("/Users/x/projects/a")
            .recording("/Users/x/projects/a/")
        XCTAssertEqual(log.paths, ["/Users/x/projects/a"])
    }

    func testRecordingTheFrontPathIsANoOp() {
        let log = RecentFoldersLog().recording("/a").recording("/b")
        XCTAssertEqual(log.recording("/b"), log)
    }

    func testCapEvictsTheOldest() {
        var log = RecentFoldersLog()
        for i in 1...9 { log = log.recording("/p\(i)") }
        XCTAssertEqual(log.paths.count, RecentFoldersLog.cap)
        XCTAssertEqual(log.paths.first, "/p9")
        XCTAssertFalse(log.paths.contains("/p1"))
    }
}

@MainActor
final class RecentFoldersStoreTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-recents-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    func testRecordPersistsAcrossStores() {
        let store = RecentFoldersStore(directory: dir)
        store.record("/Users/x/projects/a")
        store.record("/Users/x/projects/b")

        let reloaded = RecentFoldersStore(directory: dir)
        XCTAssertEqual(reloaded.paths, ["/Users/x/projects/b", "/Users/x/projects/a"])
    }

    func testCorruptFileLoadsAsEmptyAndStoreStillRecords() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("recents.json"))

        let store = RecentFoldersStore(directory: dir)
        XCTAssertEqual(store.paths, [])
        store.record("/a")
        XCTAssertEqual(store.paths, ["/a"])
    }

    func testMissingDirectoryLoadsAsEmpty() {
        let store = RecentFoldersStore(directory: dir)
        XCTAssertEqual(store.paths, [])
    }
}

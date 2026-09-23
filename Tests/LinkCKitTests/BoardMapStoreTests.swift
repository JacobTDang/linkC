import XCTest
@testable import LinkCKit

final class BoardMapStoreTests: XCTestCase {
    nonisolated(unsafe) private var workspace: URL!

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-board-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: workspace)
    }

    func testTheMapLivesAtTheProjectRoot() {
        XCTAssertEqual(BoardMapStore(workspacePath: workspace.path).fileURL.lastPathComponent, "system-map.json")
        XCTAssertEqual(BoardMapStore(workspacePath: workspace.path).fileURL.deletingLastPathComponent().path,
                       (workspace.path as NSString).standardizingPath)
    }

    func testAProjectWithNoMapLoadsNothing() throws {
        XCTAssertNil(try BoardMapStore(workspacePath: workspace.path).load())
    }

    func testSavingANewMapThenLoadingItReturnsTheBytesWritten() throws {
        let store = BoardMapStore(workspacePath: workspace.path)
        var map = BoardMap.empty
        map.components = [BoardComponent(name: "api", kind: .service)]
        let written = try store.save(map, expecting: nil)
        let loaded = try XCTUnwrap(try store.load())
        XCTAssertEqual(loaded.bytes, written)
        XCTAssertEqual(loaded.map.components.map(\.name), ["api"])
    }

    /// A change linkC has not seen — a git pull, a hand edit — must never be overwritten.
    func testAWriteOverAFileThatChangedOnDiskIsRefused() throws {
        let store = BoardMapStore(workspacePath: workspace.path)
        let first = try store.save(.empty, expecting: nil)
        let theirs = Data(#"{"version": 2, "places": {"Not placed": {"theirs": {}}}}"#.utf8)
        try theirs.write(to: store.fileURL)

        var mine = BoardMap.empty
        mine.components = [BoardComponent(name: "mine", kind: .service)]
        XCTAssertThrowsError(try store.save(mine, expecting: first)) { error in
            XCTAssertEqual(error as? BoardMapStoreError, .changedOnDisk)
        }
        XCTAssertEqual(try Data(contentsOf: store.fileURL), theirs, "their change is untouched")
    }

    func testCreatingAMapWhereOneAppearedMeanwhileIsRefused() throws {
        let store = BoardMapStore(workspacePath: workspace.path)
        try Data(#"{"version": 2, "places": {}}"#.utf8).write(to: store.fileURL)
        XCTAssertThrowsError(try store.save(.empty, expecting: nil)) { error in
            XCTAssertEqual(error as? BoardMapStoreError, .changedOnDisk)
        }
    }

    func testAnUnreadableFileThrowsRatherThanReadingAsEmpty() throws {
        let store = BoardMapStore(workspacePath: workspace.path)
        try Data("{ nope".utf8).write(to: store.fileURL)
        XCTAssertThrowsError(try store.load())
    }
}

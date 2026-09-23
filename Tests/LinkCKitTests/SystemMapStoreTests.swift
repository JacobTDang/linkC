import XCTest
@testable import LinkCKit

final class SystemMapStoreTests: XCTestCase {
    nonisolated(unsafe) private var workspace: URL!

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-workbench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: workspace)
    }

    func testTheFileSitsBesideTheOtherProjectFiles() {
        let store = SystemMapStore(workspacePath: workspace.path)
        XCTAssertEqual(store.fileURL.lastPathComponent, "system.json")
        XCTAssertEqual(store.fileURL.deletingLastPathComponent().lastPathComponent, ".linkc")
    }

    func testAProjectWithNoMapLoadsNothing() throws {
        XCTAssertNil(try SystemMapStore(workspacePath: workspace.path).load())
    }

    func testSavingCreatesTheDirectoryAndLoadingReadsItBack() throws {
        let store = SystemMapStore(workspacePath: workspace.path)
        let map = SystemMap(components: [
            SystemComponent(name: "postgres", kind: .database, reachedBy: "DATABASE_URL",
                            at: GridPoint(x: 1, y: 2)),
        ])
        try store.save(map)

        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.path))
        let loaded = try XCTUnwrap(try store.load())
        XCTAssertEqual(loaded.components.map(\.name), ["postgres"])
        XCTAssertEqual(loaded.components[0].at, GridPoint(x: 1, y: 2))
    }

    /// An unreadable map must fail loud — reading it as an empty system would invite an
    /// edit that overwrites whatever the file really held.
    func testAnUnreadableFileThrowsRatherThanReadingAsEmpty() throws {
        let store = SystemMapStore(workspacePath: workspace.path)
        try FileManager.default.createDirectory(
            at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ nope".utf8).write(to: store.fileURL)

        XCTAssertThrowsError(try store.load())
    }

    func testSavingReplacesAnEarlierMap() throws {
        let store = SystemMapStore(workspacePath: workspace.path)
        try store.save(SystemMap(components: [SystemComponent(name: "a", kind: .service)]))
        try store.save(SystemMap(components: [SystemComponent(name: "b", kind: .cache)]))
        XCTAssertEqual(try store.load()?.components.map(\.name), ["b"])
    }
}

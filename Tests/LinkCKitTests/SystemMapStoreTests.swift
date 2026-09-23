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

    /// The file sits where git can actually track it. `.linkc/` is in every repo's
    /// `.gitignore`, so a map kept there would never be committed — defeating a feature whose
    /// whole point is that any agent, on any machine, can read it.
    func testTheFileSitsAtTheProjectRootWhereGitCanTrackIt() {
        let store = SystemMapStore(workspacePath: workspace.path)
        XCTAssertEqual(store.fileURL.lastPathComponent, "system-map.json")
        XCTAssertEqual(
            store.fileURL.deletingLastPathComponent().standardizedFileURL,
            workspace.standardizedFileURL)
    }

    func testAProjectWithNoMapLoadsNothing() throws {
        XCTAssertNil(try SystemMapStore(workspacePath: workspace.path).load())
    }

    func testSavingWritesToTheProjectRootAndLoadingReadsItBack() throws {
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
        try Data("{ nope".utf8).write(to: store.fileURL)

        XCTAssertThrowsError(try store.load())
    }

    /// A read that fails as I/O (not a decode problem) is this repo's `.server` case, matching
    /// the other stores that touch files in a workspace — `.parse` is reserved for content that
    /// cannot be decoded.
    func testAReadIOFailureThrowsServerNotParse() throws {
        let store = SystemMapStore(workspacePath: workspace.path)
        // A directory where the store expects a file: Data(contentsOf:) fails to read it,
        // which is an I/O failure, not a decoding one.
        try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: true)

        XCTAssertThrowsError(try store.load()) { error in
            guard case LinkCError.server(let message) = error else {
                return XCTFail("expected .server, got \(error)")
            }
            XCTAssertTrue(message.contains(store.fileURL.path))
        }
    }

    func testSavingReplacesAnEarlierMap() throws {
        let store = SystemMapStore(workspacePath: workspace.path)
        try store.save(SystemMap(components: [SystemComponent(name: "a", kind: .service)]))
        try store.save(SystemMap(components: [SystemComponent(name: "b", kind: .cache)]))
        XCTAssertEqual(try store.load()?.components.map(\.name), ["b"])
    }
}

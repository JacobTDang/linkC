import XCTest
@testable import LinkCKit

final class BoardCatalogTests: XCTestCase {
    nonisolated(unsafe) private var workspace: URL!

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-catalog-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: workspace)
    }

    func testCatalogDiscoversLinkedAndUnlinkedBoardsInOrder() throws {
        var overview = BoardMap.empty
        overview.components = [
            BoardComponent(name: "Audio engine", kind: .service, detail: "audio-engine"),
            BoardComponent(name: "API", kind: .service)
        ]
        _ = try BoardMapStore(workspacePath: workspace.path, board: nil).save(overview, expecting: nil)

        var audioEngine = BoardMap.empty
        audioEngine.components = [
            BoardComponent(name: "Mixer", kind: .service, detail: "audio-engine.mixer")
        ]
        _ = try BoardMapStore(workspacePath: workspace.path, board: "audio-engine").save(audioEngine, expecting: nil)

        let mixer = BoardMap.empty
        _ = try BoardMapStore(workspacePath: workspace.path, board: "audio-engine.mixer").save(mixer, expecting: nil)

        let oldIdea = BoardMap.empty
        _ = try BoardMapStore(workspacePath: workspace.path, board: "old-idea").save(oldIdea, expecting: nil)

        let catalog = try BoardCatalog.load(workspacePath: workspace.path, projectName: "June")
        XCTAssertEqual(catalog.entries.map(\.slug), [nil, "audio-engine", "audio-engine.mixer", "old-idea"])
        XCTAssertEqual(catalog.entries.map(\.path), [["June"], ["June", "Audio engine"], ["June", "Audio engine", "Mixer"], ["old-idea"]])
        XCTAssertEqual(catalog.entries.map(\.linked), [true, true, true, false])
    }

    func testFolderWithOnlyOverviewGivesOneEntry() throws {
        _ = try BoardMapStore(workspacePath: workspace.path, board: nil).save(.empty, expecting: nil)
        let catalog = try BoardCatalog.load(workspacePath: workspace.path, projectName: "June")
        XCTAssertEqual(catalog.entries.count, 1)
        XCTAssertEqual(catalog.entries.first?.slug, nil)
        XCTAssertEqual(catalog.entries.first?.path, ["June"])
        XCTAssertEqual(catalog.entries.first?.linked, true)
    }
}

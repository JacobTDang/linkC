import XCTest
@testable import LinkCKit

final class BoardDrillTests: XCTestCase {
    nonisolated(unsafe) private var workspace: URL!

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-drill-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: workspace)
    }

    func testDetailCreatesDetailBoardWithGhostsAndSetsLink() throws {
        var overview = BoardMap(system: "June")
        overview.components = [
            BoardComponent(name: "A", kind: .service, uses: ["Engine": ""]),
            BoardComponent(name: "B", kind: .service, uses: ["Engine": ""]),
            BoardComponent(name: "Engine", kind: .service, uses: ["C": "", "D": ""]),
            BoardComponent(name: "C", kind: .database),
            BoardComponent(name: "D", kind: .queue)
        ]
        _ = try BoardMapStore(workspacePath: workspace.path, board: nil).save(overview, expecting: nil)

        let slug = try BoardDrill.detail(of: "Engine", onBoard: nil, workspacePath: workspace.path)
        XCTAssertEqual(slug, "engine")

        // Detail file exists and has ghosts and system == "Engine"
        let detailStore = BoardMapStore(workspacePath: workspace.path, board: "engine")
        let detailLoaded = try XCTUnwrap(try detailStore.load())
        XCTAssertEqual(detailLoaded.map.system, "Engine")
        XCTAssertEqual(detailLoaded.map.components.filter { $0.outside != nil }.map(\.name).sorted(), ["A", "B", "C", "D"])

        // Overview's Engine now has detail == "engine"
        let updatedOverview = try XCTUnwrap(try BoardMapStore(workspacePath: workspace.path, board: nil).load()?.map)
        XCTAssertEqual(updatedOverview.components.first { $0.name == "Engine" }?.detail, "engine")

        // Calling it again returns the same slug and does not recreate the file
        let slugAgain = try BoardDrill.detail(of: "Engine", onBoard: nil, workspacePath: workspace.path)
        XCTAssertEqual(slugAgain, "engine")
    }

    func testNestedDetailBoard() throws {
        var overview = BoardMap(system: "June")
        overview.components = [
            BoardComponent(name: "Engine", kind: .service, detail: "engine")
        ]
        _ = try BoardMapStore(workspacePath: workspace.path, board: nil).save(overview, expecting: nil)

        var engineMap = BoardMap(system: "Engine")
        engineMap.components = [
            BoardComponent(name: "Mixer", kind: .service)
        ]
        _ = try BoardMapStore(workspacePath: workspace.path, board: "engine").save(engineMap, expecting: nil)

        let nestedSlug = try BoardDrill.detail(of: "Mixer", onBoard: "engine", workspacePath: workspace.path)
        XCTAssertEqual(nestedSlug, "engine.mixer")
    }

    func testOpenSyncsGhostsAgainstParentAndSavesWhenChanged() throws {
        var overview = BoardMap(system: "June")
        overview.components = [
            BoardComponent(name: "A", kind: .service, uses: ["Engine": ""]),
            BoardComponent(name: "B", kind: .service, uses: ["Engine": ""]),
            BoardComponent(name: "Engine", kind: .service, uses: ["C": ""]),
            BoardComponent(name: "C", kind: .database)
        ]
        _ = try BoardMapStore(workspacePath: workspace.path, board: nil).save(overview, expecting: nil)

        _ = try BoardDrill.detail(of: "Engine", onBoard: nil, workspacePath: workspace.path)

        // Modify parent: remove A -> Engine
        var updatedOverview = try XCTUnwrap(try BoardMapStore(workspacePath: workspace.path, board: nil).load()?.map)
        let aIndex = try XCTUnwrap(updatedOverview.components.firstIndex { $0.name == "A" })
        updatedOverview.components[aIndex].uses = [:]
        let parentStore = BoardMapStore(workspacePath: workspace.path, board: nil)
        let bytes = try parentStore.currentBytes()
        _ = try parentStore.save(updatedOverview, expecting: bytes)

        // Opening engine detail map should sync: A becomes stale, and detail file is updated
        let opened = try BoardDrill.open("engine", workspacePath: workspace.path)
        let ghostA = try XCTUnwrap(opened.components.first { $0.name == "A" })
        XCTAssertTrue(ghostA.stale)

        // Verify saved on disk
        let onDisk = try XCTUnwrap(try BoardMapStore(workspacePath: workspace.path, board: "engine").load()?.map)
        XCTAssertTrue(onDisk.components.first { $0.name == "A" }?.stale == true)
    }

    func testOpenNonexistentBoardThrows() {
        XCTAssertThrowsError(try BoardDrill.open("nope", workspacePath: workspace.path))
    }

    func testDetailOnAGhostThrows() throws {
        var detailMap = BoardMap(system: "Engine")
        detailMap.components = [
            BoardComponent(name: "A", kind: .service, outside: .in)
        ]
        _ = try BoardMapStore(workspacePath: workspace.path, board: "engine").save(detailMap, expecting: nil)

        XCTAssertThrowsError(try BoardDrill.detail(of: "A", onBoard: "engine", workspacePath: workspace.path)) { error in
            XCTAssertTrue("\(error)".contains("overview"))
        }
    }
}

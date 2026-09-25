import XCTest
@testable import LinkCKit

final class BoardGhostsTests: XCTestCase {
    private var parent: BoardMap!

    override func setUp() {
        super.setUp()
        parent = BoardMap(system: "System")
        parent.components = [
            BoardComponent(name: "A", kind: .service, uses: ["Engine": ""]),
            BoardComponent(name: "B", kind: .service, uses: ["Engine": ""]),
            BoardComponent(name: "Engine", kind: .service, uses: ["C": "", "D": ""]),
            BoardComponent(name: "C", kind: .database),
            BoardComponent(name: "D", kind: .queue)
        ]
    }

    func testFirstSyncAddsGhostsInColumnsAndSecondSyncReturnsNil() throws {
        let empty = BoardMap(system: "Engine")
        let synced = try XCTUnwrap(BoardGhosts.sync(detail: empty, parent: parent, part: "Engine"))

        let ghostA = try XCTUnwrap(synced.components.first { $0.name == "A" })
        let ghostB = try XCTUnwrap(synced.components.first { $0.name == "B" })
        let ghostC = try XCTUnwrap(synced.components.first { $0.name == "C" })
        let ghostD = try XCTUnwrap(synced.components.first { $0.name == "D" })

        XCTAssertEqual(ghostA.outside, .in)
        XCTAssertEqual(ghostB.outside, .in)
        XCTAssertEqual(ghostC.outside, .out)
        XCTAssertEqual(ghostD.outside, .out)

        XCTAssertEqual(ghostA.kind, .service)
        XCTAssertEqual(ghostB.kind, .service)
        XCTAssertEqual(ghostC.kind, .database)
        XCTAssertEqual(ghostD.kind, .queue)

        // Empty inner box at (0, 0, 0, 0)
        // Left column at x = 0 - 176 - 96 = -272
        // Right column at x = 0 + 96 = 96
        XCTAssertEqual(ghostA.at?.x, -272)
        XCTAssertEqual(ghostB.at?.x, -272)
        XCTAssertEqual(ghostA.at?.y, 0)
        XCTAssertEqual(ghostB.at?.y, 124)

        XCTAssertEqual(ghostC.at?.x, 96)
        XCTAssertEqual(ghostD.at?.x, 96)
        XCTAssertEqual(ghostC.at?.y, 0)
        XCTAssertEqual(ghostD.at?.y, 124)

        // Second sync with no change returns nil
        XCTAssertNil(BoardGhosts.sync(detail: synced, parent: parent, part: "Engine"))
    }

    func testRemovedNeighbourBecomesStaleAndRestoringNeighbourClearsStale() throws {
        let empty = BoardMap(system: "Engine")
        let synced = try XCTUnwrap(BoardGhosts.sync(detail: empty, parent: parent, part: "Engine"))

        // Remove B -> Engine from parent
        var modifiedParent = parent!
        let bIndex = try XCTUnwrap(modifiedParent.components.firstIndex { $0.name == "B" })
        modifiedParent.components[bIndex].uses = [:]

        let staleSync = try XCTUnwrap(BoardGhosts.sync(detail: synced, parent: modifiedParent, part: "Engine"))
        let ghostB = try XCTUnwrap(staleSync.components.first { $0.name == "B" })
        XCTAssertTrue(ghostB.stale)
        XCTAssertEqual(ghostB.outside, .in)

        // Restore B -> Engine on parent
        let restoredSync = try XCTUnwrap(BoardGhosts.sync(detail: staleSync, parent: parent, part: "Engine"))
        let restoredB = try XCTUnwrap(restoredSync.components.first { $0.name == "B" })
        XCTAssertFalse(restoredB.stale)
    }

    func testArrowFromGhostToInnerPartSurvivesSync() throws {
        let empty = BoardMap(system: "Engine")
        var synced = try XCTUnwrap(BoardGhosts.sync(detail: empty, parent: parent, part: "Engine"))

        // Wire ghost A to an inner part Decoder
        synced.components.append(BoardComponent(name: "Decoder", kind: .service))
        let aIndex = try XCTUnwrap(synced.components.firstIndex { $0.name == "A" })
        synced.components[aIndex].uses["Decoder"] = "decodes"

        // Sync again
        let resynced = BoardGhosts.sync(detail: synced, parent: parent, part: "Engine") ?? synced
        let ghostA = try XCTUnwrap(resynced.components.first { $0.name == "A" })
        XCTAssertEqual(ghostA.uses["Decoder"]?.label, "decodes")
    }

    func testNeighbourKindChangeOnParentIsCopiedToGhost() throws {
        let empty = BoardMap(system: "Engine")
        let synced = try XCTUnwrap(BoardGhosts.sync(detail: empty, parent: parent, part: "Engine"))

        var modifiedParent = parent!
        let aIndex = try XCTUnwrap(modifiedParent.components.firstIndex { $0.name == "A" })
        modifiedParent.components[aIndex].kind = .database

        let resynced = try XCTUnwrap(BoardGhosts.sync(detail: synced, parent: modifiedParent, part: "Engine"))
        let ghostA = try XCTUnwrap(resynced.components.first { $0.name == "A" })
        XCTAssertEqual(ghostA.kind, .database)
    }

    func testInnerPartStandsInForNeighbourSoNoGhostIsAdded() throws {
        var detail = BoardMap(system: "Engine")
        detail.components = [
            BoardComponent(name: "C", kind: .database) // inner part, outside is nil
        ]

        let synced = try XCTUnwrap(BoardGhosts.sync(detail: detail, parent: parent, part: "Engine"))
        let cParts = synced.components.filter { $0.name == "C" }
        XCTAssertEqual(cParts.count, 1)
        XCTAssertNil(cParts.first?.outside)
        XCTAssertEqual(synced.components.filter { $0.outside != nil }.map(\.name).sorted(), ["A", "B", "D"])
    }
}

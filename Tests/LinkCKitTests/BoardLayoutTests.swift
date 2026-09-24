import XCTest
@testable import LinkCKit

final class BoardLayoutTests: XCTestCase {
    private func linkCMap() throws -> BoardMap {
        // linkC's own architecture, as drawn on 2026-09-24.
        try BoardMap.decode(Data("""
        { "version": 2, "places": {
          "linkC app": { "panel": {"kind":"service","uses":{"coordinator":"drives","board":"shows","usage":"usage rows","oracle-cloud":"Cloud section","supabase":""}},
                         "coordinator": {"kind":"service","uses":{"terminals":"spawns sessions","inbox":"relays","app-support":"saves state","notifications":"alerts"}},
                         "terminals": {"kind":"service","uses":{"claude":"hosts","codex":"hosts","cursor":"hosts","antigravity":"hosts"}},
                         "hook-server": {"kind":"service","uses":{"coordinator":"session state"}},
                         "board": {"kind":"service","uses":{"system-map":"reads, writes, watches","tool-servers":"what's running"}},
                         "usage": {"kind":"service","uses":{"transcripts":"reads"}},
                         "tool-servers": {"kind":"service","uses":{"docker":"docker compose"}} },
          "Agents": { "claude": {"kind":"service","uses":{"linkc-mcp":"tools","hook-server":"hook events"}},
                      "codex": {"kind":"service","uses":{"linkc-mcp":"tools"}},
                      "cursor": {"kind":"service","uses":{"linkc-mcp":"tools"}},
                      "antigravity": {"kind":"service","uses":{"linkc-mcp":"tools"}},
                      "linkc-mcp": {"kind":"service","uses":{"inbox":"messages, tasks","blackboard":"heartbeats, notes","system-map":"edits the Board"}} },
          "Project folder": { "inbox": {"kind":"queue"}, "blackboard": {"kind":"storage"}, "system-map": {"kind":"storage"} },
          "This Mac": { "app-support": {"kind":"storage"}, "transcripts": {"kind":"storage"}, "notifications": {"kind":"external"}, "docker": {"kind":"host","tech":"docker"} },
          "Cloud": { "oracle-cloud": {"kind":"external"}, "supabase": {"kind":"external","tech":"supabase"} },
          "Not placed": {} },
          "notes": ["one", "two"] }
        """.utf8))
    }

    private func rect(_ m: BoardMap, _ name: String) throws -> BoardRect {
        BoardGeometry.rect(ofComponentAt: try XCTUnwrap(m.components.first { $0.name == name }?.at, name))
    }

    func testTheSameMapAlwaysGetsTheSameLayout() throws {
        let m = try linkCMap()
        XCTAssertEqual(BoardLayout.arranged(m), BoardLayout.arranged(m))
        XCTAssertEqual(BoardLayout.arranged(BoardLayout.arranged(m)), BoardLayout.arranged(m), "arranging is idempotent")
    }

    func testNoBoxesOverlapAndEveryComponentIsInsideItsFrame() throws {
        let m = BoardLayout.arranged(try linkCMap())
        let boxes = m.components.compactMap { $0.at.map(BoardGeometry.rect(ofComponentAt:)) } + m.notes.compactMap { $0.at.map(BoardGeometry.rect(ofNoteAt:)) }
        XCTAssertEqual(boxes.count, m.components.count + m.notes.count, "everything placed")
        for i in boxes.indices { for j in boxes.indices where j > i { XCTAssertFalse(boxes[i].intersects(boxes[j])) } }
        for c in m.components where c.place != BoardMap.notPlaced {
            let frame = try XCTUnwrap(m.frames.first { $0.label == c.place }?.rect)
            XCTAssertTrue(BoardGeometry.interior(of: frame).contains(try rect(m, c.name)), c.name)
        }
        let frames = m.frames.compactMap(\.rect)
        for i in frames.indices { for j in frames.indices where j > i { XCTAssertFalse(frames[i].intersects(frames[j])) } }
    }

    func testFramesFlowLeftToRightByTheirArrows() throws {
        let m = BoardLayout.arranged(try linkCMap())
        func x(_ label: String) throws -> Int { try XCTUnwrap(m.frames.first { $0.label == label }?.rect?.x) }
        XCTAssertLessThan(try x("linkC app"), try x("Agents"))
        XCTAssertLessThan(try x("Agents"), try x("Project folder"))
        XCTAssertEqual(try x("Agents"), try x("This Mac"), "same rank stacks vertically")
    }

    func testInsideAFrameComponentsFlowByTheirArrows() throws {
        let m = BoardLayout.arranged(try linkCMap())
        XCTAssertLessThan(try rect(m, "panel").x, try rect(m, "coordinator").x)
        XCTAssertLessThan(try rect(m, "coordinator").x, try rect(m, "terminals").x)
        XCTAssertLessThan(try rect(m, "claude").x, try rect(m, "linkc-mcp").x)
    }

    func testNotesGoInAColumnToTheRight() throws {
        let m = BoardLayout.arranged(try linkCMap())
        let maxX = m.frames.compactMap(\.rect).map(\.maxX).max() ?? 0
        for note in m.notes { XCTAssertGreaterThanOrEqual(try XCTUnwrap(note.at).x, maxX) }
    }

    func testCycleBreakingFollowsArrowWeightNotAlphabet() throws {
        // "Alpha Heavy" sorts first ascending / last descending. Its one component sends 4 arrows
        // into "Zulu Light"; one of Zulu Light's components sends a single arrow back. The heavy
        // side must win the cycle regardless of what a name-only tiebreak would have picked.
        var m = BoardMap()
        m.frames = [BoardFrame(label: "Alpha Heavy"), BoardFrame(label: "Zulu Light")]
        m.components = [
            BoardComponent(name: "hub", kind: .service, uses: ["z1": "", "z2": "", "z3": "", "z4": ""], place: "Alpha Heavy"),
            BoardComponent(name: "z1", kind: .service, uses: ["hub": ""], place: "Zulu Light"),
            BoardComponent(name: "z2", kind: .service, place: "Zulu Light"),
            BoardComponent(name: "z3", kind: .service, place: "Zulu Light"),
            BoardComponent(name: "z4", kind: .service, place: "Zulu Light"),
        ]
        let arranged = BoardLayout.arranged(m)
        func x(_ label: String) throws -> Int { try XCTUnwrap(arranged.frames.first { $0.label == label }?.rect?.x) }
        XCTAssertLessThan(try x("Alpha Heavy"), try x("Zulu Light"), "4 arrows out beats 1 arrow back")
    }

    func testCycleBreakingByWeightIgnoresAlphabeticalOrder() throws {
        // Mirror of the above with the heavy side renamed to sort last: "Zulu Heavy" still sends 4
        // arrows into "Alpha Light", which sends 1 back. The heavy side must still end up upstream.
        var m = BoardMap()
        m.frames = [BoardFrame(label: "Zulu Heavy"), BoardFrame(label: "Alpha Light")]
        m.components = [
            BoardComponent(name: "hub", kind: .service, uses: ["a1": "", "a2": "", "a3": "", "a4": ""], place: "Zulu Heavy"),
            BoardComponent(name: "a1", kind: .service, uses: ["hub": ""], place: "Alpha Light"),
            BoardComponent(name: "a2", kind: .service, place: "Alpha Light"),
            BoardComponent(name: "a3", kind: .service, place: "Alpha Light"),
            BoardComponent(name: "a4", kind: .service, place: "Alpha Light"),
        ]
        let arranged = BoardLayout.arranged(m)
        func x(_ label: String) throws -> Int { try XCTUnwrap(arranged.frames.first { $0.label == label }?.rect?.x) }
        XCTAssertLessThan(try x("Zulu Heavy"), try x("Alpha Light"), "the heavy side stays upstream even though its name sorts last")
    }

    func testClusterBarycentreDedupesAMutualCyclePartner() throws {
        // Base1, Base2, Base3 are three independent sources. W and V each take one real arrow from
        // a single base. Z cycles with Base1 (Base1↔Z) and also takes a real arrow from Base3 — so
        // Z's correct predecessors are {Base1, Base3}. A duplicated Base1 predecessor (the old
        // bug) skews Z's barycentre mean below W's, putting Z above W; deduplicated, W's single
        // predecessor (Base2, the middle base) still beats Z's average of the top and bottom base.
        var m = BoardMap()
        m.frames = [
            BoardFrame(label: "Base1"), BoardFrame(label: "Base2"), BoardFrame(label: "Base3"),
            BoardFrame(label: "W"), BoardFrame(label: "Z"), BoardFrame(label: "V"),
        ]
        m.components = [
            BoardComponent(name: "b1", kind: .service, uses: ["z": ""], place: "Base1"),
            BoardComponent(name: "b2", kind: .service, uses: ["w": ""], place: "Base2"),
            BoardComponent(name: "b3", kind: .service, uses: ["z": "", "v": ""], place: "Base3"),
            BoardComponent(name: "w", kind: .service, place: "W"),
            BoardComponent(name: "z", kind: .service, uses: ["b1": ""], place: "Z"),
            BoardComponent(name: "v", kind: .service, place: "V"),
        ]
        let arranged = BoardLayout.arranged(m)
        func y(_ label: String) throws -> Int { try XCTUnwrap(arranged.frames.first { $0.label == label }?.rect?.y) }
        XCTAssertLessThan(try y("W"), try y("Z"), "W's single predecessor still outranks Z's deduplicated pair")
        XCTAssertLessThan(try y("Z"), try y("V"))
    }

    func testWeightedRankingBuildsADAGWithoutDuplicateEdges() {
        // A→B carries weight 2, B→A carries weight 1 (a mutual cycle), and B→C carries weight 1.
        // The old DFS-reversal cycle break could append a cycle partner twice into the same node's
        // edge list; the weighted ordering must never do that, and must drop the back edge (B→A)
        // rather than keep both directions.
        let weights: [String?: [String?: Int]] = [
            "A": ["B": 2],
            "B": ["A": 1, "C": 1],
        ]
        let nodes: [String?] = ["A", "B", "C"]
        let sortKey: (String?) -> String = { $0?.lowercased() ?? "\u{FFFF}" }
        let order = BoardLayout.weightedOrdering(nodes: nodes, weights: weights, sortKey: sortKey)
        let (_, dag) = BoardLayout.ranksAndDAG(nodes: nodes, order: order, weights: weights)
        let edgeCount = dag.values.reduce(0) { $0 + $1.count }
        XCTAssertEqual(edgeCount, 2, "A→B and B→C survive; B→A is the back edge and drops")
        for (_, tos) in dag {
            XCTAssertEqual(tos.count, Set(tos).count, "no duplicate edge to the same neighbour")
        }
    }

    func testACycleDoesNotHangAndNotPlacedIsItsOwnCluster() throws {
        var m = BoardMap()
        m.components = [BoardComponent(name: "a", kind: .service, uses: ["b": ""]),
                        BoardComponent(name: "b", kind: .service, uses: ["a": ""])]
        let arranged = BoardLayout.arranged(m)
        XCTAssertNotNil(arranged.components.first?.at)
        XCTAssertTrue(arranged.frames.isEmpty)
    }

    func testLaidOutSeparatesOverlappingComponents() {
        var m = BoardMap()
        m.components = [BoardComponent(name: "a", kind: .service, at: BoardPoint(x: 0, y: 0)),
                        BoardComponent(name: "b", kind: .service, at: BoardPoint(x: 40, y: 16))]
        let fixed = BoardModel.laidOut(m)
        let a = BoardGeometry.rect(ofComponentAt: fixed.components[0].at!), b = BoardGeometry.rect(ofComponentAt: fixed.components[1].at!)
        XCTAssertFalse(a.intersects(b))
    }
}

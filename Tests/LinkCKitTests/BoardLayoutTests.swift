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

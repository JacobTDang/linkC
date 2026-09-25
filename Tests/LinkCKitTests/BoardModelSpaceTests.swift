import XCTest
@testable import LinkCKit

@MainActor
final class BoardModelSpaceTests: XCTestCase {
    nonisolated(unsafe) private var workspace: URL!

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-board-space-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: workspace)
    }

    private func fresh() -> BoardModel {
        let board = BoardModel(store: BoardMapStore(workspacePath: workspace.path), settle: .seconds(3600), sleep: { _ in })
        board.load()
        board.startMap()
        return board
    }

    private func overlaps(_ board: BoardModel) -> Bool {
        let rects = BoardModel.elementRects(board.map, excluding: [])
        for (i, a) in rects.enumerated() {
            for b in rects[(i + 1)...] where a.intersects(b) { return true }
        }
        return false
    }

    func testMovingABoxIntoAFrameMakesItLiveThereAndOutMakesItNotPlaced() throws {
        let board = fresh()
        let label = try XCTUnwrap(board.addFrame(BoardRect(x: 0, y: 0, w: 400, h: 200)))
        let api = try XCTUnwrap(board.addComponent(kind: .service, at: BoardPoint(x: 600, y: 0)))
        board.move([.component(api)], by: BoardPoint(x: -560, y: 40))
        XCTAssertEqual(board.map.components.first { $0.name == api }?.place, label)
        board.move([.component(api)], by: BoardPoint(x: 800, y: 0))
        XCTAssertEqual(board.map.components.first { $0.name == api }?.place, BoardMap.notPlaced)
    }

    func testABoxDroppedOnAnotherSlidesClear() throws {
        let board = fresh()
        let a = try XCTUnwrap(board.addComponent(kind: .service, at: BoardPoint(x: 0, y: 0)))
        let b = try XCTUnwrap(board.addComponent(kind: .service, at: BoardPoint(x: 400, y: 0)))
        board.move([.component(b)], by: BoardPoint(x: -400, y: 0))
        XCTAssertFalse(overlaps(board))
        XCTAssertNotEqual(board.map.components.first { $0.name == a }?.at, board.map.components.first { $0.name == b }?.at)
    }

    func testMovingAFrameCarriesItsComponents() throws {
        let board = fresh()
        let label = try XCTUnwrap(board.addFrame(BoardRect(x: 0, y: 0, w: 400, h: 200)))
        let api = try XCTUnwrap(board.addComponent(kind: .service, at: BoardPoint(x: 16, y: 16)))
        let before = try XCTUnwrap(board.map.components.first { $0.name == api }?.at)
        board.move([.frame(label)], by: BoardPoint(x: 0, y: 400))
        let after = try XCTUnwrap(board.map.components.first { $0.name == api }?.at)
        XCTAssertEqual(after.y - before.y, 400)
        XCTAssertEqual(board.map.components.first { $0.name == api }?.place, label)
    }

    func testAFrameNeverLandsOnAnotherFrame() throws {
        let board = fresh()
        let first = try XCTUnwrap(board.addFrame(BoardRect(x: 0, y: 0, w: 400, h: 200)))
        let second = try XCTUnwrap(board.addFrame(BoardRect(x: 0, y: 400, w: 400, h: 200)))
        board.move([.frame(second)], by: BoardPoint(x: 0, y: -400))
        let a = try XCTUnwrap(board.map.frames.first { $0.label == first }?.rect)
        let b = try XCTUnwrap(board.map.frames.first { $0.label == second }?.rect)
        XCTAssertFalse(a.intersects(b))
    }

    /// A frame dropped onto loose boxes it does not own lands clear of them, and those boxes —
    /// not part of the move — never move themselves.
    func testAFrameDroppedOnLooseBoxesLandsClearAndTheyDoNotMove() throws {
        let board = fresh()
        let label = try XCTUnwrap(board.addFrame(BoardRect(x: 0, y: 0, w: 200, h: 200)))
        let loose = try XCTUnwrap(board.addComponent(kind: .service, at: BoardPoint(x: 600, y: 0)))
        let before = try XCTUnwrap(board.map.components.first { $0.name == loose }?.at)
        board.move([.frame(label)], by: BoardPoint(x: 600, y: 0))
        let frameRect = try XCTUnwrap(board.map.frames.first { $0.label == label }?.rect)
        let looseRect = try XCTUnwrap(board.rect(of: .component(loose)))
        XCTAssertFalse(frameRect.intersects(looseRect))
        XCTAssertEqual(board.map.components.first { $0.name == loose }?.at, before)
    }

    /// A selection holding both a frame and one of that frame's own components moves the
    /// component once, carried by the frame — never a second time as a loose element too.
    func testMovingAFrameAndItsOwnComponentTogetherMovesTheComponentOnce() throws {
        let board = fresh()
        let label = try XCTUnwrap(board.addFrame(BoardRect(x: 0, y: 0, w: 400, h: 200)))
        let api = try XCTUnwrap(board.addComponent(kind: .service, at: BoardPoint(x: 16, y: 16)))
        let before = try XCTUnwrap(board.map.components.first { $0.name == api }?.at)
        board.move([.frame(label), .component(api)], by: BoardPoint(x: 96, y: 0))
        let after = try XCTUnwrap(board.map.components.first { $0.name == api }?.at)
        XCTAssertEqual(after.x - before.x, 96, "the frame carries its own component once, not twice")
    }

    /// R5: a frame moved together with a loose box beside it (not carried — outside the frame)
    /// must not dodge that box's *old* spot, the same rule I3 applies among loose elements —
    /// the box is moving too, in this same move.
    func testMovingAFrameWithALooseBoxBesideItDoesNotDodgeTheBoxsOldSpot() throws {
        let board = fresh()
        let label = try XCTUnwrap(board.addFrame(BoardRect(x: 0, y: 0, w: 200, h: 200)))
        let box = try XCTUnwrap(board.addComponent(kind: .service, at: BoardPoint(x: 200, y: 0)))
        board.move([.frame(label), .component(box)], by: BoardPoint(x: 200, y: 0))
        let frameRect = try XCTUnwrap(board.map.frames.first { $0.label == label }?.rect)
        XCTAssertEqual(frameRect.origin, BoardPoint(x: 200, y: 0), "the frame must not dodge the box's old spot since the box is moving too")
    }

    /// Two boxes moved together must keep their arrangement — each is checked against the
    /// other's *landing* spot, never against where it used to be before this same move.
    func testMovingTwoBoxesTogetherKeepsTheirArrangement() throws {
        let board = fresh()
        let a = try XCTUnwrap(board.addComponent(kind: .service, at: BoardPoint(x: 0, y: 0)))
        let b = try XCTUnwrap(board.addComponent(kind: .service, at: BoardPoint(x: 184, y: 0)))
        board.move([.component(a), .component(b)], by: BoardPoint(x: 160, y: 0))
        XCTAssertEqual(board.map.components.first { $0.name == a }?.at, BoardPoint(x: 160, y: 0))
        XCTAssertEqual(board.map.components.first { $0.name == b }?.at, BoardPoint(x: 344, y: 0))
    }

    func testAMoveIsOneUndoStep() throws {
        let board = fresh()
        let api = try XCTUnwrap(board.addComponent(kind: .service, at: BoardPoint(x: 0, y: 0)))
        let before = board.map.components.first { $0.name == api }?.at
        board.move([.component(api)], by: BoardPoint(x: 200, y: 0))
        board.undo()
        XCTAssertEqual(board.map.components.first { $0.name == api }?.at, before)
    }

    func testAMoveOfNothingIsNotAnEdit() throws {
        let board = fresh()
        let api = try XCTUnwrap(board.addComponent(kind: .service, at: BoardPoint(x: 0, y: 0)))
        board.move([.component(api)], by: BoardPoint(x: 0, y: 0))
        board.undo()
        XCTAssertTrue(board.map.components.isEmpty, "the zero move added no undo step, so one undo removes the component")
    }

    /// A non-zero move that collision fully blocks slides the element back to exactly where it
    /// was — and that is not an edit either: no undo step is added for it.
    func testAFullyBlockedMoveIsNotAnEdit() throws {
        let board = fresh()
        let api = try XCTUnwrap(board.addComponent(kind: .service, at: BoardPoint(x: 0, y: 0)))
        let wall = try XCTUnwrap(board.addComponent(kind: .service, at: BoardPoint(x: 152, y: 0)))
        let before = try XCTUnwrap(board.map.components.first { $0.name == api }?.at)
        board.move([.component(api)], by: BoardPoint(x: 8, y: 0))
        XCTAssertEqual(board.map.components.first { $0.name == api }?.at, before, "fully blocked, it slides back to where it was")
        board.undo()
        XCTAssertNil(board.map.components.first { $0.name == wall },
                     "one undo removed the wall's own add — the blocked move recorded no step of its own")
        XCTAssertEqual(board.map.components.first { $0.name == api }?.at, before)
    }

    func testContentBoundsCoverEverything() throws {
        let board = fresh()
        XCTAssertNil(board.contentBounds)
        _ = try XCTUnwrap(board.addFrame(BoardRect(x: 0, y: 0, w: 400, h: 200)))
        _ = try XCTUnwrap(board.addComponent(kind: .service, at: BoardPoint(x: 800, y: 600)))
        let bounds = try XCTUnwrap(board.contentBounds)
        XCTAssertLessThanOrEqual(bounds.minX, 0)
        XCTAssertGreaterThanOrEqual(bounds.maxX, 952)
        XCTAssertGreaterThanOrEqual(bounds.maxY, 656)
    }

    /// A note wholly inside a frame goes along when the frame moves.
    func testMovingAFrameCarriesANoteInsideIt() throws {
        let board = fresh()
        let label = try XCTUnwrap(board.addFrame(BoardRect(x: 0, y: 0, w: 400, h: 200)))
        let note = try XCTUnwrap(board.addNote(at: BoardPoint(x: 16, y: 16)))
        let before = try XCTUnwrap(board.map.notes.first { $0.id == note }?.at)
        board.move([.frame(label)], by: BoardPoint(x: 0, y: 400))
        let after = try XCTUnwrap(board.map.notes.first { $0.id == note }?.at)
        XCTAssertEqual(after.y - before.y, 400)
    }

    func testResizingNeverShrinksPastItsContents() throws {
        let board = fresh()
        let label = try XCTUnwrap(board.addFrame(BoardRect(x: 0, y: 0, w: 400, h: 200)))
        _ = try XCTUnwrap(board.addComponent(kind: .service, at: BoardPoint(x: 200, y: 100)))
        board.resizeFrame(label, to: BoardRect(x: 0, y: 0, w: 100, h: 100))
        let rect = try XCTUnwrap(board.map.frames.first?.rect)
        XCTAssertTrue(BoardGeometry.interior(of: rect).contains(try XCTUnwrap(board.rect(of: .component(board.map.components[0].name)))))
    }

    /// A note wholly inside a frame is protected by the shrink floor exactly like a component —
    /// a shrink can never leave it straddling the new edge.
    func testResizingNeverShrinksPastANoteInside() throws {
        let board = fresh()
        let label = try XCTUnwrap(board.addFrame(BoardRect(x: 0, y: 0, w: 400, h: 200)))
        let note = try XCTUnwrap(board.addNote(at: BoardPoint(x: 16, y: 16)))
        board.resizeFrame(label, to: BoardRect(x: 0, y: 0, w: 100, h: 100))
        let rect = try XCTUnwrap(board.map.frames.first?.rect)
        XCTAssertTrue(BoardGeometry.interior(of: rect).contains(try XCTUnwrap(board.rect(of: .note(note)))))
    }

    /// A hand-written map with no layout: every place gets a frame on the board, every
    /// component a position inside its own frame, and nothing overlaps — without writing.
    func testAMapWithNoLayoutIsLaidOut() throws {
        var map = BoardMap.empty
        map.frames = [BoardFrame(label: "Oracle box"), BoardFrame(label: "Local docker")]
        map.components = [
            BoardComponent(name: "api", kind: .service, place: "Local docker"),
            BoardComponent(name: "db", kind: .database, place: "Local docker"),
            BoardComponent(name: "audio", kind: .host, place: "Oracle box"),
            BoardComponent(name: "loose", kind: .external),
        ]
        map.notes = [BoardNote(text: "hi")]
        let laid = BoardModel.laidOut(map)

        XCTAssertTrue(laid.frames.allSatisfy { $0.rect != nil })
        XCTAssertTrue(laid.components.allSatisfy { $0.at != nil })
        XCTAssertTrue(laid.notes.allSatisfy { $0.at != nil })
        for component in laid.components {
            let rect = BoardGeometry.rect(ofComponentAt: try XCTUnwrap(component.at))
            let frame = laid.frames.first { $0.label == component.place }?.rect
            if let frame {
                XCTAssertTrue(BoardGeometry.interior(of: frame).contains(rect), component.name)
            } else {
                XCTAssertFalse(laid.frames.compactMap(\.rect).contains { $0.intersects(rect) }, component.name)
            }
        }
        let frames = laid.frames.compactMap(\.rect)
        XCTAssertFalse(frames[0].intersects(frames[1]))
        XCTAssertEqual(BoardModel.laidOut(laid), laid, "laying out a laid-out map changes nothing")
    }

    /// Frames that overlap in the file — after a git merge, say — are pulled apart on load, each
    /// carrying its own components with it, exactly as a frame move would.
    func testOverlappingFramesInTheFileAreSeparatedOnLoadCarryingTheirContents() throws {
        var map = BoardMap.empty
        map.frames = [
            BoardFrame(label: "A", rect: BoardRect(x: 0, y: 0, w: 200, h: 200)),
            BoardFrame(label: "B", rect: BoardRect(x: 100, y: 100, w: 200, h: 200)),
        ]
        map.components = [
            BoardComponent(name: "api", kind: .service, place: "A", at: BoardPoint(x: 16, y: 16)),
            BoardComponent(name: "db", kind: .database, place: "B", at: BoardPoint(x: 116, y: 116)),
        ]
        let laid = BoardModel.laidOut(map)

        let a = try XCTUnwrap(laid.frames.first { $0.label == "A" }?.rect)
        let b = try XCTUnwrap(laid.frames.first { $0.label == "B" }?.rect)
        XCTAssertFalse(a.intersects(b), "the two frames must no longer overlap")
        XCTAssertEqual(a, BoardRect(x: 0, y: 0, w: 200, h: 200), "the earlier frame in label order stays put")

        let apiRect = BoardGeometry.rect(ofComponentAt: try XCTUnwrap(laid.components.first { $0.name == "api" }?.at))
        let dbRect = BoardGeometry.rect(ofComponentAt: try XCTUnwrap(laid.components.first { $0.name == "db" }?.at))
        XCTAssertTrue(BoardGeometry.interior(of: a).contains(apiRect), "api stayed with its frame")
        XCTAssertTrue(BoardGeometry.interior(of: b).contains(dbRect), "db moved along with its frame")
        XCTAssertEqual(BoardModel.laidOut(laid), laid, "laying out an already-separated map changes nothing")
    }

    /// R6: only A and B overlap in the file; C was always clear. B's escape route from A must not
    /// run it into C — an innocent frame it never overlapped must keep its position, not get
    /// dragged into moving just because B's naive nearest-free-spot search landed on it.
    func testALaidOutFrameEscapingAnOverlapNeverLandsOnAnUninvolvedFrame() throws {
        var map = BoardMap.empty
        map.frames = [
            BoardFrame(label: "A", rect: BoardRect(x: 0, y: 0, w: 200, h: 200)),
            BoardFrame(label: "B", rect: BoardRect(x: 100, y: 100, w: 200, h: 200)),
            BoardFrame(label: "C", rect: BoardRect(x: 300, y: 100, w: 200, h: 200)),
        ]
        let laid = BoardModel.laidOut(map)

        let a = try XCTUnwrap(laid.frames.first { $0.label == "A" }?.rect)
        let b = try XCTUnwrap(laid.frames.first { $0.label == "B" }?.rect)
        let c = try XCTUnwrap(laid.frames.first { $0.label == "C" }?.rect)
        XCTAssertFalse(a.intersects(b), "A and B must no longer overlap")
        XCTAssertFalse(b.intersects(c), "B's escape route must not create a new overlap with C")
        XCTAssertEqual(a, BoardRect(x: 0, y: 0, w: 200, h: 200), "A never overlapped anything and must keep its position")
        XCTAssertEqual(c, BoardRect(x: 300, y: 100, w: 200, h: 200), "C never overlapped anything and must keep its position")
    }

    /// A box the file lists under one place but positions in another frame moves to its place —
    /// the file's places are what agents read, so they win.
    func testTheFilesPlaceWinsOverAStrayPosition() throws {
        var map = BoardMap.empty
        map.frames = [BoardFrame(label: "A", rect: BoardRect(x: 0, y: 0, w: 400, h: 200)),
                      BoardFrame(label: "B", rect: BoardRect(x: 600, y: 0, w: 400, h: 200))]
        map.components = [BoardComponent(name: "api", kind: .service, place: "B", at: BoardPoint(x: 16, y: 16))]
        let laid = BoardModel.laidOut(map)
        let rect = BoardGeometry.rect(ofComponentAt: try XCTUnwrap(laid.components[0].at))
        XCTAssertTrue(BoardGeometry.interior(of: BoardRect(x: 600, y: 0, w: 400, h: 200)).contains(rect))
    }

    /// A note already wholly inside a frame is left exactly where it is by the layout pass.
    func testLayoutLeavesANoteAlreadyInsideAFrameWhereItIs() throws {
        var map = BoardMap.empty
        map.frames = [BoardFrame(label: "A", rect: BoardRect(x: 0, y: 0, w: 400, h: 200))]
        map.notes = [BoardNote(text: "hi", at: BoardPoint(x: 16, y: 16))]
        let laid = BoardModel.laidOut(map)
        XCTAssertEqual(laid.notes.first?.at, BoardPoint(x: 16, y: 16))
    }

    /// A text that overlaps a component is moved clear of it by the layout pass — nothing is
    /// left sitting on top of anything.
    func testLayoutMovesATextThatOverlapsAComponent() throws {
        var map = BoardMap.empty
        map.components = [BoardComponent(name: "api", kind: .service, at: BoardPoint(x: 0, y: 0))]
        map.texts = [BoardText(text: "heading", style: .label, at: BoardPoint(x: 40, y: 10), width: 100)]
        let laid = BoardModel.laidOut(map)
        let componentRect = BoardGeometry.rect(ofComponentAt: try XCTUnwrap(laid.components.first?.at))
        let textRect = BoardGeometry.rect(of: try XCTUnwrap(laid.texts.first))
        XCTAssertFalse(componentRect.intersects(textRect))
    }

    /// A component whose place names a frame that does not exist is unplaced for positioning,
    /// and the layout pass clears the stale label rather than leaving it a heading for nothing.
    func testALayoutClearsAPlaceNamingNoFrame() throws {
        var map = BoardMap.empty
        map.components = [BoardComponent(name: "api", kind: .service, place: "Gone")]
        let laid = BoardModel.laidOut(map)
        XCTAssertEqual(laid.components.first?.place, BoardMap.notPlaced)
    }

    /// Regression: a board made before `componentSize` grew to 176 pt wide has frames still 176
    /// wide, with an interior of only 160 — too narrow for a component box of the current size.
    /// `laidOut` must widen such a frame to hold its members rather than demote them to "Not
    /// placed". This is the literal shape of Jacob's own file: 5 frames, each still 176 wide,
    /// placed side by side as the old engine left them, holding 23 components at their old-size
    /// positions.
    func testOldNarrowFramesWidenRatherThanEvictTheirComponents() throws {
        var map = BoardMap.empty
        map.frames = [
            BoardFrame(label: "Agents", rect: BoardRect(x: 424, y: 0, w: 176, h: 352)),
            BoardFrame(label: "Cloud", rect: BoardRect(x: 1096, y: 0, w: 176, h: 160)),
            BoardFrame(label: "linkC app", rect: BoardRect(x: 200, y: 0, w: 176, h: 416)),
            BoardFrame(label: "Project folder", rect: BoardRect(x: 648, y: 0, w: 176, h: 224)),
            BoardFrame(label: "This Mac", rect: BoardRect(x: 872, y: 0, w: 176, h: 288)),
        ]
        func c(_ name: String, _ x: Int, _ y: Int, _ place: String) -> BoardComponent {
            BoardComponent(name: name, kind: .service, place: place, at: BoardPoint(x: x, y: y))
        }
        map.components = [
            c("antigravity", 432, 176, "Agents"), c("claude", 432, 8, "Agents"), c("codex", 432, 64, "Agents"),
            c("cursor", 432, 120, "Agents"), c("linkc-mcp", 432, 232, "Agents"),
            c("oracle-cloud", 1104, 8, "Cloud"), c("supabase", 1104, 64, "Cloud"),
            c("board", 208, 232, "linkC app"), c("coordinator", 208, 64, "linkC app"), c("hook-server", 208, 176, "linkC app"),
            c("panel", 208, 8, "linkC app"), c("terminals", 208, 120, "linkC app"), c("tool-servers", 208, 344, "linkC app"),
            c("usage", 208, 288, "linkC app"),
            c("Database", -208, 136, BoardMap.notPlaced), c("new-database", 0, -24, BoardMap.notPlaced),
            c("blackboard", 656, 64, "Project folder"), c("inbox", 656, 8, "Project folder"), c("system-map", 656, 120, "Project folder"),
            c("app-support", 880, 8, "This Mac"), c("docker", 880, 176, "This Mac"), c("notifications", 880, 120, "This Mac"),
            c("transcripts", 880, 64, "This Mac"),
        ]
        XCTAssertEqual(map.components.count, 23)

        let laid = BoardModel.laidOut(map)

        for before in map.components {
            let after = try XCTUnwrap(laid.components.first { $0.name == before.name })
            XCTAssertEqual(after.place, before.place, "\(before.name) must keep its place")
        }
        for component in laid.components where component.place != BoardMap.notPlaced {
            let rect = BoardGeometry.rect(ofComponentAt: try XCTUnwrap(component.at, component.name))
            let frame = try XCTUnwrap(laid.frames.first { $0.label == component.place }?.rect, component.name)
            XCTAssertTrue(BoardGeometry.interior(of: frame).contains(rect), component.name)
        }
        let boxes = laid.components.compactMap { $0.at.map(BoardGeometry.rect(ofComponentAt:)) }
        for i in boxes.indices { for j in boxes.indices where j > i {
            XCTAssertFalse(boxes[i].intersects(boxes[j]), "\(map.components[i].name) overlaps \(map.components[j].name)")
        } }
        let frames = laid.frames.compactMap(\.rect)
        for i in frames.indices { for j in frames.indices where j > i {
            XCTAssertFalse(frames[i].intersects(frames[j]))
        } }

        // The next agent edit (or Tidy up) must not write the evicted map either.
        let applied = try BoardEdit.apply([.system("still here")], to: map).map
        for before in map.components {
            let after = try XCTUnwrap(applied.components.first { $0.name == before.name })
            XCTAssertEqual(after.place, before.place, "\(before.name) must keep its place through BoardEdit.apply")
        }
    }

    func testLoadingLaysOutWithoutWriting() throws {
        let store = BoardMapStore(workspacePath: workspace.path)
        let bytes = Data(#"{"version": 2, "places": {"Not placed": {"a": {}, "b": {}}}}"#.utf8)
        try bytes.write(to: store.fileURL)
        let board = BoardModel(store: store, settle: .seconds(3600), sleep: { _ in })
        board.load()
        XCTAssertTrue(board.map.components.allSatisfy { $0.at != nil })
        XCTAssertFalse(overlaps(board))
        board.saveNow()
        XCTAssertEqual(try Data(contentsOf: store.fileURL), bytes)
    }

    // MARK: - Marquee pick

    private func marqueeMap() -> BoardMap {
        var m = BoardMap()
        m.components = [
            BoardComponent(name: "shown", kind: .service, at: BoardPoint(x: 0, y: 0)),
            BoardComponent(name: "hidden", kind: .service, at: BoardPoint(x: 400, y: 0)),
        ]
        m.notes = [BoardNote(text: "n", at: BoardPoint(x: 800, y: 0))]
        return m
    }

    func testMarqueePickCoversEveryComponentAndNoteWhenNothingIsFocused() {
        let map = marqueeMap()
        let area = BoardRect(x: -50, y: -50, w: 1100, h: 300)
        let picked = BoardModel.marqueePick(in: area, map: map, visibleParts: nil)
        XCTAssertEqual(picked, [.component("shown"), .component("hidden"), .note(map.notes[0].id)])
    }

    /// While Focus is on, a marquee drawn over what looks like empty space must never pick a part
    /// Focus is hiding — but a note or text, which Focus never hides, still comes through.
    func testMarqueePickSkipsAComponentFocusHidesButStillPicksNotes() {
        let map = marqueeMap()
        let area = BoardRect(x: -50, y: -50, w: 1100, h: 300)
        let picked = BoardModel.marqueePick(in: area, map: map, visibleParts: ["shown"])
        XCTAssertEqual(picked, [.component("shown"), .note(map.notes[0].id)])
    }
}

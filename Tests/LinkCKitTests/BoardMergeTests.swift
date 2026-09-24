import XCTest
@testable import LinkCKit

final class BoardMergeTests: XCTestCase {
    private func map(_ components: [BoardComponent], frames: [BoardFrame] = [], notes: [String] = [], system: String? = nil) -> BoardMap {
        var m = BoardMap(system: system)
        m.components = components
        m.frames = frames
        m.notes = notes.enumerated().map { BoardNote(text: $0.element, at: BoardPoint(x: 0, y: $0.offset * 200)) }
        return m
    }
    private func c(_ name: String, does: String? = nil, at: BoardPoint? = BoardPoint(x: 0, y: 0), uses: [String: BoardArrow] = [:]) -> BoardComponent {
        BoardComponent(name: name, kind: .service, does: does, uses: uses, at: at)
    }
    private func n(_ text: String, at: BoardPoint) -> BoardNote { BoardNote(text: text, at: at) }
    private func noteMap(_ notes: [BoardNote]) -> BoardMap {
        var m = BoardMap()
        m.notes = notes
        return m
    }
    private func t(_ text: String, style: BoardTextStyle = .label, at: BoardPoint, width: Int = 100) -> BoardText {
        BoardText(text: text, style: style, at: at, width: width)
    }
    private func textMap(_ texts: [BoardText]) -> BoardMap {
        var m = BoardMap()
        m.texts = texts
        return m
    }

    func testOnlyTheirsChanged() {
        let base = map([c("api")]), mine = base, theirs = map([c("api", does: "http"), c("redis")])
        XCTAssertEqual(BoardMerge.merge(base: base, mine: mine, theirs: theirs).components.map(\.name), ["api", "redis"])
        XCTAssertEqual(BoardMerge.merge(base: base, mine: mine, theirs: theirs).components.first?.does, "http")
    }

    func testOnlyMineChanged() {
        let base = map([c("api")]), mine = map([c("api", at: BoardPoint(x: 400, y: 0))]), theirs = base
        XCTAssertEqual(BoardMerge.merge(base: base, mine: mine, theirs: theirs).components.first?.at, BoardPoint(x: 400, y: 0))
    }

    func testDifferentElementsBothSurvive() {
        let base = map([c("api"), c("db")])
        let mine = map([c("api", at: BoardPoint(x: 400, y: 0)), c("db")])
        let theirs = map([c("api"), c("db", does: "postgres"), c("redis")])
        let merged = BoardMerge.merge(base: base, mine: mine, theirs: theirs)
        XCTAssertEqual(merged.components.first { $0.name == "api" }?.at, BoardPoint(x: 400, y: 0))
        XCTAssertEqual(merged.components.first { $0.name == "db" }?.does, "postgres")
        XCTAssertNotNil(merged.components.first { $0.name == "redis" })
    }

    func testTheSameElementFieldByFieldMineWinsATie() {
        let base = map([c("api", does: "a")])
        let mine = map([c("api", does: "mine", at: BoardPoint(x: 400, y: 0))])
        let theirs = map([c("api", does: "theirs", uses: ["db": "reads"])])
        let api = BoardMerge.merge(base: base, mine: mine, theirs: theirs).components.first
        XCTAssertEqual(api?.does, "mine")
        XCTAssertEqual(api?.at, BoardPoint(x: 400, y: 0))
        XCTAssertEqual(api?.uses, ["db": "reads"], "an arrow only theirs added survives, even to something that is not a component")
    }

    func testDeletionsCountAsChanges() {
        let base = map([c("api"), c("db")])
        XCTAssertNil(BoardMerge.merge(base: base, mine: map([c("api")]), theirs: map([c("api"), c("db", does: "x")]))
            .components.first { $0.name == "db" }, "mine deleted, theirs edited: mine wins")
        XCTAssertEqual(BoardMerge.merge(base: base, mine: map([c("api"), c("db", does: "x")]), theirs: map([c("api")]))
            .components.first { $0.name == "db" }?.does, "x", "theirs deleted, mine edited: mine wins")
        XCTAssertNil(BoardMerge.merge(base: base, mine: base, theirs: map([c("api")])).components.first { $0.name == "db" })
    }

    func testNotesMatchByText() {
        let base = map([], notes: ["a", "b"])
        let mine = map([], notes: ["a", "b", "mine"])
        let theirs = map([], notes: ["a", "theirs"])
        XCTAssertEqual(Set(BoardMerge.merge(base: base, mine: mine, theirs: theirs).notes.map(\.text)), ["a", "theirs", "mine"])
    }

    func testFramesAndSystem() {
        let frame = BoardFrame(label: "Local docker", rect: BoardRect(x: 0, y: 0, w: 320, h: 200))
        let base = map([], frames: [frame], system: "old")
        var moved = frame; moved.rect = BoardRect(x: 400, y: 0, w: 320, h: 200)
        let mine = map([], frames: [moved], system: "old")
        let theirs = map([], frames: [frame, BoardFrame(label: "Oracle", rect: BoardRect(x: 0, y: 400, w: 320, h: 200))], system: "new")
        let merged = BoardMerge.merge(base: base, mine: mine, theirs: theirs)
        XCTAssertEqual(merged.frames.first { $0.label == "Local docker" }?.rect?.x, 400)
        XCTAssertNotNil(merged.frames.first { $0.label == "Oracle" })
        XCTAssertEqual(merged.system, "new")
    }

    // MARK: - Duplicate-text notes and texts pair by position, not by index (review finding 1)

    func testDuplicateTextNotesPairByExactPositionThenOrder() {
        let base = noteMap([n("dup", at: BoardPoint(x: 0, y: 0)), n("dup", at: BoardPoint(x: 0, y: 200))])
        let mine = noteMap([n("dup", at: BoardPoint(x: 0, y: 200))])
        let theirs = noteMap([n("dup", at: BoardPoint(x: 0, y: 0)), n("dup", at: BoardPoint(x: 0, y: 400))])
        let merged = BoardMerge.merge(base: base, mine: mine, theirs: theirs)
        XCTAssertEqual(merged.notes.map(\.at), [BoardPoint(x: 0, y: 400)], "the deleted-by-mine note stays gone; the surviving one takes theirs' move")
    }

    func testDuplicateTextTextsPairByExactPositionThenOrder() {
        let base = textMap([t("dup", at: BoardPoint(x: 0, y: 0)), t("dup", at: BoardPoint(x: 0, y: 200))])
        let mine = textMap([t("dup", at: BoardPoint(x: 0, y: 200))])
        let theirs = textMap([t("dup", at: BoardPoint(x: 0, y: 0)), t("dup", at: BoardPoint(x: 0, y: 400))])
        let merged = BoardMerge.merge(base: base, mine: mine, theirs: theirs)
        XCTAssertEqual(merged.texts.map(\.at), [BoardPoint(x: 0, y: 400)])
    }

    // MARK: - A note (or text) mine changed but theirs removed by identity is kept, and theirs' addition arrives too (review finding 2)

    func testNoteMineChangedTheirsRemovedKeepsBoth() {
        let base = noteMap([n("TODO: fix", at: BoardPoint(x: 0, y: 0))])
        let mine = noteMap([n("TODO: fix", at: BoardPoint(x: 400, y: 0))])
        let theirs = noteMap([n("TODO: fix this", at: BoardPoint(x: 0, y: 0))])
        let merged = BoardMerge.merge(base: base, mine: mine, theirs: theirs)
        XCTAssertEqual(merged.notes.count, 2)
        XCTAssertEqual(merged.notes.first { $0.text == "TODO: fix" }?.at, BoardPoint(x: 400, y: 0), "mine's edit to the old note wins over theirs' deletion of it")
        XCTAssertEqual(merged.notes.first { $0.text == "TODO: fix this" }?.at, BoardPoint(x: 0, y: 0), "theirs' new note still arrives")
    }

    func testTextMineChangedTheirsRemovedKeepsBoth() {
        let base = textMap([t("TODO: fix", at: BoardPoint(x: 0, y: 0))])
        let mine = textMap([t("TODO: fix", at: BoardPoint(x: 400, y: 0))])
        let theirs = textMap([t("TODO: fix this", at: BoardPoint(x: 0, y: 0))])
        let merged = BoardMerge.merge(base: base, mine: mine, theirs: theirs)
        XCTAssertEqual(merged.texts.count, 2)
        XCTAssertEqual(merged.texts.first { $0.text == "TODO: fix" }?.at, BoardPoint(x: 400, y: 0))
        XCTAssertEqual(merged.texts.first { $0.text == "TODO: fix this" }?.at, BoardPoint(x: 0, y: 0))
    }

    // MARK: - `uses` keys merge case-insensitively (review finding 3)

    func testUsesKeyMergesCaseInsensitively() {
        let base = map([c("api", uses: ["postgres": ""])])
        let mine = map([c("api", uses: ["postgres": "reads"])])
        let theirs = map([c("api", uses: ["Postgres": ""])])
        let merged = BoardMerge.merge(base: base, mine: mine, theirs: theirs)
        XCTAssertEqual(merged.components.first?.uses, ["postgres": "reads"], "the hand-recased key is no real change, and never mints a second arrow")
    }

    func testUsesKeyTakesTargetComponentsRealMergedName() {
        // "api" itself must be a real field-merge (both sides touch it), not a short-circuit to
        // one side's whole component — that is the only path that runs mergedUses.
        let basePostgres = c("postgres")
        let base = map([c("api", does: "does", uses: ["postgres": ""]), basePostgres])
        let mine = map([c("api", does: "mine", uses: ["postgres": "reads"]), basePostgres])
        let theirs = map([c("api", does: "theirs", uses: ["postgres": ""]), c("Postgres")])
        let merged = BoardMerge.merge(base: base, mine: mine, theirs: theirs)
        XCTAssertEqual(merged.components.first { $0.name.lowercased() == "postgres" }?.name, "Postgres", "theirs recased the component itself, and mine never touched it")
        XCTAssertEqual(merged.components.first { $0.name == "api" }?.uses, ["Postgres": "reads"], "the arrow's key follows the target's real merged name")
    }

    // MARK: - Missing coverage (review finding 4)

    func testTextsAddedRemovedAndMovedOnEitherSide() {
        let base = textMap([
            t("Frontend", style: .title, at: BoardPoint(x: 0, y: 0)),
            t("gone-mine", at: BoardPoint(x: 0, y: 200)),
            t("gone-theirs", at: BoardPoint(x: 0, y: 400)),
        ])
        let mine = textMap([
            t("Frontend", style: .title, at: BoardPoint(x: 400, y: 0)),
            t("gone-theirs", at: BoardPoint(x: 0, y: 400)),
            t("added-by-mine", at: BoardPoint(x: 0, y: 600)),
        ])
        let theirs = textMap([
            t("Frontend", style: .title, at: BoardPoint(x: 0, y: 0)),
            t("gone-mine", at: BoardPoint(x: 0, y: 200)),
            t("added-by-theirs", at: BoardPoint(x: 0, y: 800)),
        ])
        let merged = BoardMerge.merge(base: base, mine: mine, theirs: theirs)
        XCTAssertEqual(merged.texts.first { $0.text == "Frontend" }?.at, BoardPoint(x: 400, y: 0), "moved by mine, untouched by theirs")
        XCTAssertNil(merged.texts.first { $0.text == "gone-mine" }, "mine deleted it, theirs left it alone")
        XCTAssertNil(merged.texts.first { $0.text == "gone-theirs" }, "theirs deleted it, mine left it alone")
        XCTAssertNotNil(merged.texts.first { $0.text == "added-by-mine" })
        XCTAssertNotNil(merged.texts.first { $0.text == "added-by-theirs" })
    }

    func testBothSidesAddSameNewComponentMineWins() {
        let base = map([])
        let mine = map([c("cache", does: "mine")])
        let theirs = map([c("cache", does: "theirs")])
        let merged = BoardMerge.merge(base: base, mine: mine, theirs: theirs)
        XCTAssertEqual(merged.components.count, 1)
        XCTAssertEqual(merged.components.first { $0.name == "cache" }?.does, "mine")
    }

    func testUsesKeyBothSidesRelabelledDifferentlyMineWins() {
        let base = map([c("api", uses: ["db": ""])])
        let mine = map([c("api", uses: ["db": "reads"])])
        let theirs = map([c("api", uses: ["db": "writes"])])
        let merged = BoardMerge.merge(base: base, mine: mine, theirs: theirs)
        XCTAssertEqual(merged.components.first?.uses, ["db": "reads"])
    }

    func testExtrasAndLayoutExtrasComeFromTheirs() throws {
        let baseJSON = """
        {"version":2,"system":"sys","places":{"Not placed":{}},"notes":[],
         "layout":{"components":{},"frames":{},"notes":[],"texts":[]}}
        """
        let theirsJSON = """
        {"version":2,"system":"sys","places":{"Not placed":{}},"notes":[],
         "layout":{"components":{},"frames":{},"notes":[],"texts":[],"unknown_layout_key":"layoutvalue"},
         "unknown_root_key":"rootvalue"}
        """
        let base = try BoardMap.decode(Data(baseJSON.utf8))
        let mine = base
        let theirs = try BoardMap.decode(Data(theirsJSON.utf8))
        let merged = BoardMerge.merge(base: base, mine: mine, theirs: theirs)
        XCTAssertNil(base.extras)
        XCTAssertNotNil(theirs.extras)
        XCTAssertEqual(merged.extras, theirs.extras)
        XCTAssertEqual(merged.layoutExtras, theirs.layoutExtras)
    }

    /// Mine deletes a component while theirs, at the same moment, points a new arrow at it —
    /// mine's deletion wins the component (a deletion counts as a change), but the arrow theirs
    /// added lives in the *other* component's `uses` and survives untouched, since mine never
    /// touched that other component. Left alone, that arrow would name nothing: invisible on the
    /// canvas, since nothing routes to a component that isn't there.
    func testMineDeletesWhatTheirsConnectsToDropsTheDanglingArrow() {
        let base = map([c("x"), c("y")])
        let mine = map([c("y")])
        let theirs = map([c("x"), c("y", uses: ["x": ""])])
        let merged = BoardMerge.merge(base: base, mine: mine, theirs: theirs)
        XCTAssertNil(merged.components.first { $0.name == "x" }, "mine's deletion wins")
        XCTAssertEqual(merged.components.first { $0.name == "y" }?.uses, [:], "no arrow may name a component that isn't on the merged map")
    }

    /// The file format allows `uses` to name something that is not a component at all — a
    /// hand-written `"api": {"uses": {"stripe": "payments"}}`. `droppingDanglingUses` must only
    /// drop a `uses` key when the merge actually removed its target — a target that was never a
    /// component anywhere (base, mine or theirs) is left alone, whatever else the merge touches.
    func testAnArrowToSomethingThatIsNotAComponentSurvivesAMergeThatTouchesSomethingElse() {
        let base = map([c("api", uses: ["stripe": "payments"])])
        let mine = map([c("api", does: "http", uses: ["stripe": "payments"])])
        let theirs = base
        let merged = BoardMerge.merge(base: base, mine: mine, theirs: theirs)
        XCTAssertEqual(merged.components.first { $0.name == "api" }?.uses, ["stripe": "payments"],
                       "an arrow to something that was never a component must survive untouched")
    }

    func testTechMergesLikeAnyField() {
        let base = map([BoardComponent(name: "db", kind: .database)])
        var mine = base; mine.components[0].tech = "postgres"
        XCTAssertEqual(BoardMerge.merge(base: base, mine: mine, theirs: base).components.first?.tech, "postgres")
    }

    func testBothSidesDeleteSameComponentIsGone() {
        let base = map([c("api"), c("db")])
        let mine = map([c("api")])
        let theirs = map([c("api")])
        let merged = BoardMerge.merge(base: base, mine: mine, theirs: theirs)
        XCTAssertNil(merged.components.first { $0.name == "db" })
    }

    func testAnArrowsStyleMergesAsOneValue() {
        let base = map([BoardComponent(name: "r", kind: .router, uses: ["x": "go"]), BoardComponent(name: "x", kind: .end)])
        var mine = base; mine.components[0].uses["x"] = BoardArrow(label: "go", style: .conditional)
        XCTAssertEqual(BoardMerge.merge(base: base, mine: mine, theirs: base).components[0].uses["x"]?.style, .conditional)
    }
}

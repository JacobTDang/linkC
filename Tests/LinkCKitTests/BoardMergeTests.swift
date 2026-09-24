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
    private func c(_ name: String, does: String? = nil, at: BoardPoint? = BoardPoint(x: 0, y: 0), uses: [String: String] = [:]) -> BoardComponent {
        BoardComponent(name: name, kind: .service, does: does, uses: uses, at: at)
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
        XCTAssertEqual(api?.uses, ["db": "reads"], "an arrow only theirs added survives")
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
}

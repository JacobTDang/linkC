import XCTest
@testable import LinkCKit

final class TornOffTests: XCTestCase {
    private let frame = TornOffFrame(x: 10, y: 20, w: 720, h: 460)

    func testAddingKeepsOrderAndNeverDuplicates() {
        let other = TornOffFrame(x: 0, y: 0, w: 1, h: 1)
        let torn = TornOff().adding(.terminal("A"), frame: frame).adding(.split("/p"), frame: frame)
            .adding(.terminal("A"), frame: other)
        XCTAssertEqual(torn.windows.map(\.item), [.terminal("A"), .split("/p")])
        XCTAssertEqual(torn.frame(of: .terminal("A")), frame, "an item already open keeps its frame")
    }

    func testRemovingAndFraming() {
        let moved = TornOffFrame(x: 5, y: 5, w: 800, h: 500)
        let torn = TornOff().adding(.terminal("A"), frame: frame).adding(.terminal("B"), frame: frame)
        XCTAssertEqual(torn.removing(.terminal("A")).windows.map(\.item), [.terminal("B")])
        XCTAssertEqual(torn.framing(.terminal("B"), to: moved).frame(of: .terminal("B")), moved)
        XCTAssertEqual(torn.framing(.terminal("Z"), to: moved), torn, "framing an item that isn't open changes nothing")
        XCTAssertTrue(TornOff().isEmpty)
    }

    /// A terminal window wins over a split window holding the same terminal; an inactive split holds
    /// nothing; anything else lives in the panel (nil).
    func testTheHostRule() {
        let splits = ["/p": ProjectSplit(members: ["A", "B", "C"]), "/q": ProjectSplit(members: ["X", "Y"])]
        let live: [String: Set<String>] = ["/p": ["A", "B", "C"], "/q": ["X"]]
        let torn = TornOff().adding(.split("/p"), frame: frame).adding(.terminal("B"), frame: frame)
            .adding(.split("/q"), frame: frame)
        let host = { (id: String) in torn.host(of: id, splits: splits) { live[$0] ?? [] } }
        XCTAssertEqual(host("A"), .split("/p"))
        XCTAssertEqual(host("B"), .terminal("B"), "its own window wins over the grid's")
        XCTAssertNil(host("X"), "a split with one live pane is not active: X stays in the panel")
        XCTAssertNil(host("Z"))
    }

    func testAMemberThatIsNotLiveHasNoGridHost() {
        let splits = ["/p": ProjectSplit(members: ["A", "B", "C"])]
        let torn = TornOff().adding(.split("/p"), frame: frame)
        XCTAssertNil(torn.host(of: "C", splits: splits) { _ in ["A", "B"] })
    }

    func testPruningClosesWhatIsGone() {
        let torn = TornOff().adding(.terminal("A"), frame: frame).adding(.terminal("GONE"), frame: frame)
            .adding(.split("/p"), frame: frame).adding(.split("/dead"), frame: frame)
        let result = torn.pruned(liveTerminals: ["A"], activeSplits: ["/p"])
        XCTAssertEqual(result.kept.windows.map(\.item), [.terminal("A"), .split("/p")])
        XCTAssertEqual(result.closed, [.terminal("GONE"), .split("/dead")])
    }

    func testItemsRoundTripThroughJSON() throws {
        let torn = TornOff().adding(.terminal("A"), frame: frame).adding(.split("/p q"), frame: frame)
        let data = try JSONEncoder().encode(torn.windows)
        XCTAssertEqual(try JSONDecoder().decode([TornOffWindow].self, from: data), torn.windows)
    }
}

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

    /// A live terminal of the project that isn't one of the split's panes stays in the panel.
    func testALiveNonMemberHasNoGridHost() {
        let splits = ["/p": ProjectSplit(members: ["A", "B", "C"])]
        let torn = TornOff().adding(.split("/p"), frame: frame)
        XCTAssertNil(torn.host(of: "D", splits: splits) { _ in ["A", "B", "C", "D"] })
    }

    func testAMemberThatIsNotLiveHasNoGridHost() {
        let splits = ["/p": ProjectSplit(members: ["A", "B", "C"])]
        let torn = TornOff().adding(.split("/p"), frame: frame)
        XCTAssertNil(torn.host(of: "C", splits: splits) { _ in ["A", "B"] })
    }

    /// Asked for every sidebar row, so the splits (a filesystem call per key) are built only when a
    /// split window could hold the terminal.
    func testTheSplitsAreReadOnlyWhenASplitWindowIsOpen() {
        var reads = 0
        func splits() -> [String: ProjectSplit] {
            reads += 1
            return ["/p": ProjectSplit(members: ["A", "B"])]
        }
        let terminals = TornOff().adding(.terminal("A"), frame: frame)
        XCTAssertEqual(terminals.host(of: "A", splits: splits()) { _ in ["A", "B"] }, .terminal("A"))
        XCTAssertNil(terminals.host(of: "B", splits: splits()) { _ in ["A", "B"] })
        XCTAssertEqual(reads, 0, "only terminal windows are open: the splits are never built")

        let withSplit = terminals.adding(.split("/p"), frame: frame)
        XCTAssertEqual(withSplit.host(of: "B", splits: splits()) { _ in ["A", "B"] }, .split("/p"))
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(withSplit.host(of: "A", splits: splits()) { _ in ["A", "B"] }, .terminal("A"),
                       "its own window answers before the splits are read")
        XCTAssertEqual(reads, 1)
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

    // MARK: Placing a new window

    private let screen = CGRect(x: 0, y: 0, width: 1600, height: 900)

    func testADefaultSizeForEachKindOfItem() {
        XCTAssertEqual(TornOffItem.terminal("A").defaultSize, CGSize(width: 720, height: 460))
        XCTAssertEqual(TornOffItem.split("/p").defaultSize, CGSize(width: 960, height: 600))
    }

    func testAWindowIsCentredOnThePoint() {
        let placed = TornOffFrame.placed(size: CGSize(width: 720, height: 460), centredOn: CGPoint(x: 800, y: 450), within: screen)
        XCTAssertEqual(placed, TornOffFrame(x: 440, y: 220, w: 720, h: 460))
    }

    func testAWindowDroppedNearAnEdgeIsPulledBackOntoTheScreen() {
        let size = CGSize(width: 720, height: 460)
        XCTAssertEqual(TornOffFrame.placed(size: size, centredOn: CGPoint(x: 1590, y: 450), within: screen),
                       TornOffFrame(x: 880, y: 220, w: 720, h: 460), "right edge")
        XCTAssertEqual(TornOffFrame.placed(size: size, centredOn: CGPoint(x: 5, y: 5), within: screen),
                       TornOffFrame(x: 0, y: 0, w: 720, h: 460), "bottom left corner")
        XCTAssertEqual(TornOffFrame.placed(size: size, centredOn: CGPoint(x: 800, y: 899), within: screen),
                       TornOffFrame(x: 440, y: 440, w: 720, h: 460), "top edge")
    }

    /// The visible frame of a second screen can start at any offset, negative ones included.
    func testPlacingWithinAScreenThatDoesNotStartAtTheOrigin() {
        let left = CGRect(x: -1440, y: 100, width: 1440, height: 800)
        let placed = TornOffFrame.placed(size: CGSize(width: 960, height: 600), centredOn: CGPoint(x: -20, y: 150), within: left)
        XCTAssertEqual(placed, TornOffFrame(x: -960, y: 100, w: 960, h: 600))
    }

    func testAWindowLargerThanTheScreenShrinksToIt() {
        let small = CGRect(x: 0, y: 0, width: 800, height: 500)
        let placed = TornOffFrame.placed(size: CGSize(width: 960, height: 600), centredOn: CGPoint(x: 400, y: 250), within: small)
        XCTAssertEqual(placed, TornOffFrame(x: 0, y: 0, w: 800, h: 500))
    }

    func testAWindowOpensBesideThePanelWithAGap() {
        let panel = CGRect(x: 100, y: 300, width: 500, height: 520)
        let placed = TornOffFrame.placed(size: CGSize(width: 720, height: 460), beside: panel, within: screen)
        XCTAssertEqual(placed, TornOffFrame(x: 624, y: 360, w: 720, h: 460), "24 pt right of the panel, top edges level")
    }

    func testAWindowGoesLeftOfAPanelThatLeavesNoRoomOnTheRight() {
        let panel = CGRect(x: 1100, y: 300, width: 480, height: 580)
        let placed = TornOffFrame.placed(size: CGSize(width: 720, height: 460), beside: panel, within: screen)
        XCTAssertEqual(placed, TornOffFrame(x: 356, y: 420, w: 720, h: 460))
    }

    func testAWindowWithRoomOnNeitherSideOfThePanelIsClampedOnScreen() {
        let panel = CGRect(x: 300, y: 100, width: 1000, height: 700)
        let placed = TornOffFrame.placed(size: CGSize(width: 720, height: 460), beside: panel, within: screen)
        XCTAssertEqual(placed, TornOffFrame(x: 880, y: 340, w: 720, h: 460))
    }
}

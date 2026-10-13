import XCTest
@testable import LinkCKit

final class ProjectSplitTests: XCTestCase {
    func testDroppingOnASingleTerminalMakesASplitOfBothFocusedOnTheDroppedOne() throws {
        let split = try ProjectSplit(members: ["A"]).adding("B", onto: "A", edge: .right)
        XCTAssertEqual(split.members, ["A", "B"])
        XCTAssertEqual(split.focused, "B")
    }

    func testTheEdgeDecidesThePosition() throws {
        let split = try ProjectSplit(members: ["A", "B"]).adding("C", onto: "B", edge: .left)
        XCTAssertEqual(split.members, ["A", "C", "B"])
    }

    func testDroppingAMemberMovesIt() throws {
        let split = try ProjectSplit(members: ["A", "B", "C"]).adding("A", onto: "C", edge: .right)
        XCTAssertEqual(split.members, ["B", "C", "A"])
    }

    func testDroppingATerminalOnItselfChangesNothing() throws {
        let split = ProjectSplit(members: ["A", "B"], focused: "A")
        XCTAssertEqual(try split.adding("B", onto: "B", edge: .left), split)
    }

    func testANinthTerminalIsRefusedButAMoveAtEightIsNot() throws {
        let full = ProjectSplit(members: (1...8).map { "T\($0)" })
        XCTAssertThrowsError(try full.adding("T9", onto: "T1", edge: .left)) {
            XCTAssertEqual($0 as? ProjectSplit.Refusal, .full)
        }
        XCTAssertEqual(try full.adding("T8", onto: "T1", edge: .left).members.first, "T8")
    }

    func testATargetOutsideTheSplitIsRefused() {
        XCTAssertThrowsError(try ProjectSplit(members: ["A", "B"]).adding("C", onto: "Z", edge: .left)) {
            XCTAssertEqual($0 as? ProjectSplit.Refusal, .targetNotInSplit)
        }
    }

    // MARK: - The drop rule

    private let project: Set<String> = ["A", "B", "C", "D"]

    func testDroppingOnATerminalWithNoSplitStartsOneFromTheTarget() throws {
        let split = try ProjectSplit.dropping("B", onto: "A", edge: .left, into: nil, splittable: project)
        XCTAssertEqual(split.members, ["B", "A"])
        XCTAssertEqual(split.focused, "B")
    }

    func testDroppingOnAMemberJoinsTheExistingSplit() throws {
        let existing = ProjectSplit(members: ["A", "B"], focused: "A")
        let split = try ProjectSplit.dropping("C", onto: "B", edge: .right, into: existing, splittable: project)
        XCTAssertEqual(split.members, ["A", "B", "C"])
        XCTAssertEqual(split.focused, "C")
    }

    func testDroppingOnATerminalOutsideAShowingSplitIsRefused() {
        let existing = ProjectSplit(members: ["A", "B"], focused: "A")
        XCTAssertThrowsError(try ProjectSplit.dropping("D", onto: "C", edge: .right, into: existing, splittable: project)) {
            XCTAssertEqual($0 as? ProjectSplit.Refusal, .splitAlreadyShowing)
        }
    }

    /// A split with fewer than two live members isn't showing, so a drop elsewhere may replace it.
    func testDroppingOnATerminalOutsideASplitThatIsNotShowingReplacesIt() throws {
        for existing in [ProjectSplit(members: ["A", "GONE"], focused: "A"), ProjectSplit(members: ["A"], focused: "A"), ProjectSplit()] {
            let split = try ProjectSplit.dropping("D", onto: "C", edge: .right, into: existing, splittable: project)
            XCTAssertEqual(split.members, ["C", "D"])
            XCTAssertEqual(split.focused, "D")
        }
    }

    /// The split the user sees is its live members: members that are gone count for nothing.
    func testMembersThatAreNotLiveDoNotCountTowardsTheCap() throws {
        let live = (1...6).map { "T\($0)" }
        let existing = ProjectSplit(members: ["GONE1", "GONE2"] + live, focused: "T1")
        let splittable = Set(live + ["T7", "T8"])
        var split = try ProjectSplit.dropping("T7", onto: "T1", edge: .left, into: existing, splittable: splittable)
        split = try ProjectSplit.dropping("T8", onto: "T1", edge: .left, into: split, splittable: splittable)
        XCTAssertEqual(split.members.count, 8)
        XCTAssertFalse(split.members.contains { $0.hasPrefix("GONE") })
    }

    func testMembersThatAreNotLiveDoNotShiftWhereADropLands() throws {
        let existing = ProjectSplit(members: ["GONE", "A", "B"], focused: "A")
        let split = try ProjectSplit.dropping("C", onto: "A", edge: .left, into: existing, splittable: project)
        XCTAssertEqual(split.members, ["C", "A", "B"])
    }

    func testMovingAMemberIgnoresMembersThatAreNotLive() throws {
        let existing = ProjectSplit(members: ["GONE", "A", "B", "C"], focused: "A")
        let split = try ProjectSplit.dropping("A", onto: "C", edge: .right, into: existing, splittable: project)
        XCTAssertEqual(split.members, ["B", "C", "A"])
    }

    func testDroppingAMemberOnAnotherMovesIt() throws {
        let existing = ProjectSplit(members: ["A", "B", "C"], focused: "A")
        let split = try ProjectSplit.dropping("A", onto: "C", edge: .right, into: existing, splittable: project)
        XCTAssertEqual(split.members, ["B", "C", "A"])
    }

    func testDroppingATerminalOnItselfIsRefusedWithOrWithoutASplit() {
        let existing = ProjectSplit(members: ["A", "B"], focused: "A")
        for split in [existing, nil] {
            XCTAssertThrowsError(try ProjectSplit.dropping("A", onto: "A", edge: .left, into: split, splittable: project)) {
                XCTAssertEqual($0 as? ProjectSplit.Refusal, .onItself)
            }
        }
    }

    func testATerminalOfAnotherProjectIsRefused() {
        XCTAssertThrowsError(try ProjectSplit.dropping("X", onto: "A", edge: .left, into: nil, splittable: project)) {
            XCTAssertEqual($0 as? ProjectSplit.Refusal, .notSplittable)
        }
    }

    func testATargetOfAnotherProjectIsRefused() {
        let existing = ProjectSplit(members: ["A", "B"])
        XCTAssertThrowsError(try ProjectSplit.dropping("A", onto: "X", edge: .left, into: existing, splittable: project)) {
            XCTAssertEqual($0 as? ProjectSplit.Refusal, .notSplittable)
        }
    }

    func testANinthTerminalIsRefusedWhateverTheProject() {
        let members = (1...8).map { "T\($0)" }
        let full = ProjectSplit(members: members)
        let splittable = Set(members + ["T9"])
        XCTAssertThrowsError(try ProjectSplit.dropping("T9", onto: "T1", edge: .left, into: full, splittable: splittable)) {
            XCTAssertEqual($0 as? ProjectSplit.Refusal, .full)
        }
        XCTAssertEqual(try ProjectSplit.dropping("T8", onto: "T1", edge: .left, into: full, splittable: splittable).members.first, "T8")
    }

    func testRemovingTheFocusedMemberFocusesItsNeighbour() {
        let split = ProjectSplit(members: ["A", "B", "C"], focused: "B").removing("B")
        XCTAssertEqual(split.members, ["A", "C"])
        XCTAssertEqual(split.focused, "C")
        XCTAssertEqual(ProjectSplit(members: ["A", "B"], focused: "B").removing("B").focused, "A")
    }

    func testPruningKeepsOnlyKnownIDsAndRepairsFocus() {
        let split = ProjectSplit(members: ["A", "B", "C"], focused: "B").pruned(keeping: ["A", "C"])
        XCTAssertEqual(split.members, ["A", "C"])
        XCTAssertEqual(split.focused, "A")
    }

    func testOnlyLiveMembersCountTowardsAnActiveSplit() {
        let split = ProjectSplit(members: ["A", "B", "C"], focused: "C")
        XCTAssertEqual(split.liveMembers(in: ["A", "C"]), ["A", "C"])
        XCTAssertTrue(split.isActive(liveIDs: ["A", "C"]))
        XCTAssertFalse(split.isActive(liveIDs: ["A"]))
        XCTAssertEqual(split.focusedLive(in: ["A"]), "A", "a focused member that isn't live gives way to the first live one")
        XCTAssertEqual(split.focusedLive(in: ["A", "C"]), "C")
    }

    func testFocusingOnlyAcceptsMembers() {
        let split = ProjectSplit(members: ["A", "B"], focused: "A")
        XCTAssertEqual(split.focusing("B").focused, "B")
        XCTAssertEqual(split.focusing("Z").focused, "A")
    }

    func testMidListForwardMove() throws {
        let split = try ProjectSplit(members: ["A", "B", "C", "D"]).adding("A", onto: "C", edge: .right)
        XCTAssertEqual(split.members, ["B", "C", "A", "D"])
        XCTAssertEqual(split.focused, "A")
    }

    func testFocusAfterMove() throws {
        let split = try ProjectSplit(members: ["A", "B", "C"], focused: "B").adding("A", onto: "C", edge: .right)
        XCTAssertEqual(split.focused, "A", "the moved terminal takes the focus from the one that had it")
    }

    func testRemovingUnfocusedMemberKeepsFocus() {
        let split = ProjectSplit(members: ["A", "B", "C"], focused: "A").removing("B")
        XCTAssertEqual(split.members, ["A", "C"])
        XCTAssertEqual(split.focused, "A")
    }

    func testRemovingFirstMemberKeepsFocusIfNotRemoved() {
        let split = ProjectSplit(members: ["A", "B", "C"], focused: "B").removing("A")
        XCTAssertEqual(split.members, ["B", "C"])
        XCTAssertEqual(split.focused, "B")
    }

    func testRemovingOnlyMemberClearsFocus() {
        let split = ProjectSplit(members: ["A"], focused: "A").removing("A")
        XCTAssertEqual(split.members, [])
        XCTAssertEqual(split.focused, nil)
    }

    func testRemovingNonMemberNoChange() {
        let split = ProjectSplit(members: ["A", "B"], focused: "A")
        XCTAssertEqual(split.removing("Z"), split)
    }

    func testPruningKeepsSurvivingFocus() {
        let split = ProjectSplit(members: ["A", "B", "C"], focused: "B").pruned(keeping: ["A", "B", "C"])
        XCTAssertEqual(split.focused, "B")
    }

    func testPruningNilFocusBecomesFirstKept() {
        let split = ProjectSplit(members: ["A", "B", "C"], focused: nil).pruned(keeping: ["A", "B"])
        XCTAssertEqual(split.focused, "A")
    }

    func testSevenToEightJoinSucceeds() throws {
        let partial = ProjectSplit(members: (1...7).map { "T\($0)" })
        let full = try partial.adding("T8", onto: "T1", edge: .left)
        XCTAssertEqual(full.members.count, 8)
    }

    func testAtEightMoveKeepsCountAtEight() throws {
        let full = ProjectSplit(members: (1...8).map { "T\($0)" })
        let moved = try full.adding("T1", onto: "T8", edge: .right)
        XCTAssertEqual(moved.members.count, 8)
    }

    func testCodableRoundTrip() throws {
        let split = ProjectSplit(members: ["A", "B", "C"], focused: "B")
        let encoded = try JSONEncoder().encode(split)
        let decoded = try JSONDecoder().decode(ProjectSplit.self, from: encoded)
        XCTAssertEqual(decoded, split)
    }

    func testCodableRoundTripWithNilFocus() throws {
        let split = ProjectSplit(members: ["A", "B", "C"], focused: nil)
        let encoded = try JSONEncoder().encode(split)
        let decoded = try JSONDecoder().decode(ProjectSplit.self, from: encoded)
        XCTAssertEqual(decoded, split)
    }

    // MARK: - Decoding a stored split

    private func decode(_ json: String) throws -> ProjectSplit {
        try JSONDecoder().decode(ProjectSplit.self, from: Data(json.utf8))
    }

    func testADecodedSplitKeepsOnlyTheFirstOfADuplicateMember() throws {
        let split = try decode(#"{"members":["A","B","A","C","B"],"focused":"C"}"#)
        XCTAssertEqual(split.members, ["A", "B", "C"])
        XCTAssertEqual(split.focused, "C")
    }

    /// A JSON array of `count` members, T1 to T`count`.
    private func members(_ count: Int) -> String {
        "[" + (1...count).map { "\"T\($0)\"" }.joined(separator: ",") + "]"
    }

    func testADecodedSplitHoldsAtMostTheMostPanes() throws {
        let split = try decode(#"{"members":\#(members(10)),"focused":"T2"}"#)
        XCTAssertEqual(split.members, (1...SplitLayout.maxPanes).map { "T\($0)" })
        XCTAssertEqual(split.focused, "T2")
    }

    func testADecodedFocusThatIsNoLongerAMemberMovesToTheFirstMember() throws {
        XCTAssertEqual(try decode(#"{"members":["A","B"],"focused":"Z"}"#).focused, "A")
        XCTAssertEqual(try decode(#"{"members":\#(members(10)),"focused":"T9"}"#).focused, "T1", "cut off by the cap")
    }

    func testADecodedSplitWithNoFocusKeepsNone() throws {
        XCTAssertNil(try decode(#"{"members":["A","B"]}"#).focused)
    }

    /// Opening a terminal from outside its tab strip (a sidebar row, a notification) shows the
    /// split that holds it, when that split is showing two or more live panes.
    func testOpeningATerminalFindsTheActiveSplitHoldingIt() {
        let splits = ["/a": ProjectSplit(members: ["A1", "A2"]), "/b": ProjectSplit(members: ["B1", "B2", "B3"])]
        let live: [String: Set<String>] = ["/a": ["A1", "A2"], "/b": ["B1", "B3"]]
        let find = { (id: String) in ProjectSplit.project(opening: id, in: splits) { live[$0] ?? [] } }
        XCTAssertEqual(find("A2"), "/a")
        XCTAssertEqual(find("B3"), "/b")
        XCTAssertNil(find("B2"), "a member that isn't live has no pane to open")
        XCTAssertNil(find("C1"), "not in any split")
    }

    func testASplitWithFewerThanTwoLivePanesIsNotOpened() {
        let splits = ["/a": ProjectSplit(members: ["A1", "A2"])]
        XCTAssertNil(ProjectSplit.project(opening: "A1", in: splits) { _ in ["A1"] })
    }

    func testALiveTerminalThatIsNotAMemberOpensNoSplit() {
        let splits = ["/a": ProjectSplit(members: ["A1", "A2"])]
        XCTAssertNil(ProjectSplit.project(opening: "A3", in: splits) { _ in ["A1", "A2", "A3"] })
    }

    /// Which split shows once `selected` is selected, `opened` being what the user opened (nil when
    /// the selection moved by itself).
    func testWhichSplitShowsAfterASelection() {
        let splits = ["/a": ProjectSplit(members: ["A1", "A2"]), "/b": ProjectSplit(members: ["B1", "B2"])]
        let live: [String: Set<String>] = ["/a": ["A1", "A2", "A3"], "/b": ["B1", "B2"]]
        let showing = { (selected: String?, opened: String?, current: String?, fullSize: Bool) in
            ProjectSplit.showing(selected: selected, opened: opened, current: current, fullSize: fullSize,
                                 splits: splits) { live[$0] ?? [] }
        }
        XCTAssertEqual(showing("A1", "A1", nil, false), "/a", "a member opened from the sidebar or a notification shows its split")
        XCTAssertNil(showing("A1", "A1", nil, true), "its own tab chip asked for it full-size")
        XCTAssertEqual(showing("A2", "A2", "/a", false), "/a", "a member of the showing split keeps it")
        XCTAssertEqual(showing("A2", "A2", "/a", true), "/a", "a member of the showing split keeps it")
        XCTAssertEqual(showing("B1", "B1", "/a", false), "/b", "a member of another project's split shows that split")
        XCTAssertNil(showing("A3", "A3", "/a", false), "a non-member leaves the split")
        XCTAssertNil(showing("A1", "GONE", nil, false), "opening something that selected nothing opens no split")
        XCTAssertNil(showing("A1", nil, nil, false), "a selection that moved by itself opens no split")
        XCTAssertNil(showing(nil, "A1", "/a", false))
    }
}

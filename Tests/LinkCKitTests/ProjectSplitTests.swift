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

    func testDroppingOnATerminalOutsideTheSplitReplacesTheSplitWithOneFromThatTerminal() throws {
        let existing = ProjectSplit(members: ["A", "B"], focused: "A")
        let split = try ProjectSplit.dropping("D", onto: "C", edge: .right, into: existing, splittable: project)
        XCTAssertEqual(split.members, ["C", "D"])
        XCTAssertEqual(split.focused, "D")
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
}

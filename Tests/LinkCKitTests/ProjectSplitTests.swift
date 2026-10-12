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
}

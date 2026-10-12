import XCTest
@testable import LinkCKit

final class SplitRepairTests: XCTestCase {
    func testRemovingTheFocusedPaneOfTwoShowsTheOtherOneAlone() {
        let removed = ProjectSplit(members: ["A", "B"], focused: "A").removing("A")
        let repair = removed.repair(selected: "A", liveIDs: ["A", "B"])
        XCTAssertFalse(repair.keepsGrid)
        XCTAssertEqual(repair.select, "B", "the removed pane is still selected and still live; the one left must take over")
    }

    func testRemovingTheFocusedPaneOfThreeMovesTheSelectionToItsNeighbour() {
        let removed = ProjectSplit(members: ["A", "B", "C"], focused: "B").removing("B")
        let repair = removed.repair(selected: "B", liveIDs: ["A", "B", "C"])
        XCTAssertTrue(repair.keepsGrid)
        XCTAssertEqual(repair.select, "C")
    }

    func testRemovingAnUnfocusedPaneLeavesTheSelectionAlone() {
        let removed = ProjectSplit(members: ["A", "B", "C"], focused: "A").removing("C")
        let repair = removed.repair(selected: "A", liveIDs: ["A", "B", "C"])
        XCTAssertTrue(repair.keepsGrid)
        XCTAssertNil(repair.select)
    }

    func testAMemberEndingUnderTheSelectionHandsItToALiveMember() {
        let split = ProjectSplit(members: ["A", "B", "C"], focused: "A")
        let repair = split.repair(selected: "elsewhere", liveIDs: ["B", "C", "elsewhere"])
        XCTAssertTrue(repair.keepsGrid)
        XCTAssertEqual(repair.select, "B", "the manager's fallback terminal is not a pane; a live member is selected instead")
    }

    func testASelectionOnALiveMemberStays() {
        let split = ProjectSplit(members: ["A", "B", "C"], focused: "A")
        let repair = split.repair(selected: "C", liveIDs: ["A", "B", "C"])
        XCTAssertTrue(repair.keepsGrid)
        XCTAssertNil(repair.select)
    }

    func testAMemberThatIsNoLongerLiveIsNotASelectionToKeep() {
        let split = ProjectSplit(members: ["A", "B", "C"], focused: "A")
        XCTAssertEqual(split.repair(selected: "A", liveIDs: ["B", "C"]).select, "B")
    }

    func testNothingSelectedSelectsTheFocusedLiveMember() {
        let split = ProjectSplit(members: ["A", "B"], focused: "B")
        XCTAssertEqual(split.repair(selected: nil, liveIDs: ["A", "B"]).select, "B")
    }

    func testOneLiveAndOneRestorableMemberLeavesTheGridButSelectsTheLiveOne() {
        let split = ProjectSplit(members: ["A", "B"], focused: "A")
        let selectedLive = split.repair(selected: "A", liveIDs: ["A"])
        XCTAssertFalse(selectedLive.keepsGrid)
        XCTAssertNil(selectedLive.select)
        let selectedElsewhere = split.repair(selected: "X", liveIDs: ["A", "X"])
        XCTAssertFalse(selectedElsewhere.keepsGrid)
        XCTAssertEqual(selectedElsewhere.select, "A")
    }

    func testNoLiveMemberLeavesTheGridWithNothingToSelect() {
        let repair = ProjectSplit(members: ["A", "B"], focused: "A").repair(selected: "X", liveIDs: ["X"])
        XCTAssertFalse(repair.keepsGrid)
        XCTAssertNil(repair.select)
    }

    func testASplitIsViableWithTwoMembersLiveOrNot() {
        XCTAssertTrue(ProjectSplit(members: ["A", "B"]).isViable)
        XCTAssertFalse(ProjectSplit(members: ["A"]).isViable)
        XCTAssertFalse(ProjectSplit().isViable)
    }
}

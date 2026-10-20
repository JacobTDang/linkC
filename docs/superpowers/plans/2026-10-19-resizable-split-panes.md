# Resizable Split Panes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The gaps between a Split tab's panes become handles: drag one to resize the panes either side of it (or the two rows), double-click it to even them out, and the split keeps its sizes until a terminal joins or leaves.

**Architecture:**
- **LinkCKit (pure, tested):**
  - `SplitSizes` (new): the shares, the clamped resize operations, and validated decoding.
  - `ProjectSplit` carries `sizes: SplitSizes?`. It clears them when membership changes, keeps them on a move or a focus change, and persists them through `SidebarState`, which already encodes the split.
- **App target:**
  - `AppModel.resizeSplit(_:in:)` stores sizes once, when a drag ends.
  - `splitPaneState(in:)` hands the grid its sizes.
  - `SplitPane` lays the grid out from the shares, with a `ResizeHandle` in every gap.

**Tech Stack:** Swift 6, SwiftUI + AppKit, macOS 14, XCTest (`swift test`).

## Global Constraints
- **Spec.** `docs/superpowers/specs/2026-10-19-resizable-split-panes-design.md` governs.
- **Minimum pane size.** 120 pt wide and 80 pt tall (`SplitSizes.minPaneWidth`, `SplitSizes.minPaneHeight`).
  - When a drag would push a pane below its minimum, the boundary stops there.
  - When the space is too small for both minimums, the boundary does not move.
- **Gaps.** The gap between panes, and between the rows, stays 6 pt. Each gap is a handle.
- **Shares.** Each share list holds positive fractions that add up to 1. Stored lists may be off by up to 0.001. A stored list of the wrong length, with a share that is not positive, or off by more decodes as nil (an even grid), and the repair is logged.
- **Membership.**
  - A terminal joining clears the sizes, and so do `removing`, a `pruned(keeping:)` that removes a member, and a decode repair that changes `members`.
  - A member moving keeps them, and so does `focusing`.
  - A new split from a drop has none.
- **When sizes apply.** Only when `sizes.fits(paneCount:)` matches the number of live panes. Otherwise the grid renders even, and the stored sizes are kept.
- **Writes.** The split is written once, when a drag ends, never on every mouse movement.
- **Code rules.**
  - No side effects in SwiftUI view bodies.
  - Fail loud: no swallowed errors or silent fallbacks. A logged repair is not silent.
  - Swift 6 strict concurrency.
  - `swift build --build-tests` with 0 warnings.
  - No new dependencies.
- **Commits.** No trailers of any kind. Never mention Claude, Anthropic or AI. `./scripts/check-commits.sh origin/main..HEAD` must be clean.
- **Never launch the built app.** The user's running linkC owns the hook server and restores sessions; a second instance would interfere. App-target behaviour is checked by build, the full suite, and reading.

---

### Task 1: `SplitSizes` (LinkCKit)

**Files:**
- Create: `Sources/LinkCKit/Terminal/SplitSizes.swift`
- Test: `Tests/LinkCKitTests/SplitSizesTests.swift` (new)

**Interfaces:**
- Consumes: `SplitLayout.rows(for:)` and `SplitLayout.maxPanes` from `Sources/LinkCKit/Terminal/SplitLayout.swift`. Neither changes.
- Produces (Tasks 2 and 3 rely on these exact names):
  - `public struct SplitSizes: Codable, Equatable, Sendable`
  - `static let minPaneWidth: Double` and `static let minPaneHeight: Double`
  - `let paneCount: Int`, `private(set) var rows: [Double]`, `private(set) var columns: [[Double]]`
  - `static func even(for paneCount: Int) -> SplitSizes`
  - `func fits(paneCount: Int) -> Bool`
  - `func resizingColumns(inRow row: Int, divider: Int, by distance: Double, rowWidth: Double, minWidth: Double = SplitSizes.minPaneWidth) -> SplitSizes`
  - `func resizingRows(by distance: Double, gridHeight: Double, minHeight: Double = SplitSizes.minPaneHeight) -> SplitSizes`
  - `func evenedRow(_ row: Int) -> SplitSizes` and `func evenedRows() -> SplitSizes`
  - `static func paneSpace(_ length: Double, count: Int, gap: Double) -> Double`

- [ ] **Step 1: Write the failing tests.** Create `Tests/LinkCKitTests/SplitSizesTests.swift`:

```swift
import XCTest
@testable import LinkCKit

final class SplitSizesTests: XCTestCase {
    private let accuracy = 1e-9

    func testAnEvenGridSharesEachRowAndTheRowsEqually() {
        for count in 2...SplitLayout.maxPanes {
            let sizes = SplitSizes.even(for: count)
            let layout = SplitLayout.rows(for: count)
            XCTAssertEqual(sizes.paneCount, count)
            XCTAssertEqual(sizes.rows, Array(repeating: 1 / Double(layout.count), count: layout.count), "\(count) panes")
            XCTAssertEqual(sizes.columns, layout.map { Array(repeating: 1 / Double($0), count: $0) }, "\(count) panes")
        }
    }

    /// Six panes are two rows of three; a 900 pt row gives each pane 300 pt.
    func testAColumnDragMovesOnlyItsTwoPanes() {
        let sizes = SplitSizes.even(for: 6)
        let wider = sizes.resizingColumns(inRow: 0, divider: 0, by: 90, rowWidth: 900)
        XCTAssertEqual(wider.columns[0][0] * 900, 390, accuracy: accuracy)
        XCTAssertEqual(wider.columns[0][1] * 900, 210, accuracy: accuracy)
        XCTAssertEqual(wider.columns[0][2], sizes.columns[0][2])
        XCTAssertEqual(wider.columns[1], sizes.columns[1])
        XCTAssertEqual(wider.rows, sizes.rows)
        XCTAssertEqual(wider.columns[0].reduce(0, +), 1, accuracy: accuracy)

        let narrower = sizes.resizingColumns(inRow: 1, divider: 1, by: -60, rowWidth: 900)
        XCTAssertEqual(narrower.columns[1][1] * 900, 240, accuracy: accuracy)
        XCTAssertEqual(narrower.columns[1][2] * 900, 360, accuracy: accuracy)
        XCTAssertEqual(narrower.columns[1][0], sizes.columns[1][0])
        XCTAssertEqual(narrower.columns[0], sizes.columns[0])
    }

    func testAColumnDragStopsAtTheMinimumWidth() {
        let sizes = SplitSizes.even(for: 2)
        let left = sizes.resizingColumns(inRow: 0, divider: 0, by: -500, rowWidth: 600)
        XCTAssertEqual(left.columns[0][0] * 600, SplitSizes.minPaneWidth, accuracy: accuracy)
        XCTAssertEqual(left.columns[0][1] * 600, 600 - SplitSizes.minPaneWidth, accuracy: accuracy)
        let right = sizes.resizingColumns(inRow: 0, divider: 0, by: 500, rowWidth: 600)
        XCTAssertEqual(right.columns[0][1] * 600, SplitSizes.minPaneWidth, accuracy: accuracy)
    }

    func testNothingMovesWhenTheRowIsTooNarrowForTwoMinimums() {
        let sizes = SplitSizes.even(for: 2)
        XCTAssertEqual(sizes.resizingColumns(inRow: 0, divider: 0, by: 40, rowWidth: 2 * SplitSizes.minPaneWidth - 1), sizes)
    }

    func testARowDragMovesTheBoundaryBetweenTheRows() {
        let sizes = SplitSizes.even(for: 4)
        let taller = sizes.resizingRows(by: 100, gridHeight: 600)
        XCTAssertEqual(taller.rows[0] * 600, 400, accuracy: accuracy)
        XCTAssertEqual(taller.rows[1] * 600, 200, accuracy: accuracy)
        XCTAssertEqual(taller.columns, sizes.columns)
    }

    func testARowDragStopsAtTheMinimumHeight() {
        let sizes = SplitSizes.even(for: 4)
        XCTAssertEqual(sizes.resizingRows(by: 1000, gridHeight: 600).rows[1] * 600, SplitSizes.minPaneHeight, accuracy: accuracy)
        XCTAssertEqual(sizes.resizingRows(by: -1000, gridHeight: 600).rows[0] * 600, SplitSizes.minPaneHeight, accuracy: accuracy)
        XCTAssertEqual(sizes.resizingRows(by: 10, gridHeight: 2 * SplitSizes.minPaneHeight - 1), sizes)
    }

    func testAOneRowGridHasNoRowsToResize() {
        let sizes = SplitSizes.even(for: 2)
        XCTAssertEqual(sizes.resizingRows(by: 100, gridHeight: 600), sizes)
    }

    /// Five panes are a row of three over a row of two.
    func testEveningARowLeavesTheOtherRowAndTheHeights() {
        let resized = SplitSizes.even(for: 5)
            .resizingColumns(inRow: 0, divider: 1, by: 50, rowWidth: 900)
            .resizingColumns(inRow: 1, divider: 0, by: 50, rowWidth: 900)
            .resizingRows(by: 50, gridHeight: 600)
        let evened = resized.evenedRow(0)
        XCTAssertEqual(evened.columns[0], SplitSizes.even(for: 5).columns[0])
        XCTAssertEqual(evened.columns[1], resized.columns[1])
        XCTAssertEqual(evened.rows, resized.rows)
    }

    func testEveningTheRowsLeavesTheColumns() {
        let resized = SplitSizes.even(for: 4)
            .resizingColumns(inRow: 1, divider: 0, by: 50, rowWidth: 900)
            .resizingRows(by: 50, gridHeight: 600)
        let evened = resized.evenedRows()
        XCTAssertEqual(evened.rows, SplitSizes.even(for: 4).rows)
        XCTAssertEqual(evened.columns, resized.columns)
    }

    func testSizesFitOnlyTheirOwnPaneCount() {
        let sizes = SplitSizes.even(for: 5)
        XCTAssertTrue(sizes.fits(paneCount: 5))
        XCTAssertFalse(sizes.fits(paneCount: 4))
        XCTAssertFalse(sizes.fits(paneCount: 6))
    }

    func testPaneSpaceIsTheLengthLessTheGaps() {
        XCTAssertEqual(SplitSizes.paneSpace(906, count: 3, gap: 6), 894)
        XCTAssertEqual(SplitSizes.paneSpace(300, count: 1, gap: 6), 300)
        XCTAssertEqual(SplitSizes.paneSpace(4, count: 3, gap: 6), 0, "never negative")
    }

    // MARK: - Stored sizes

    func testSizesRoundTrip() throws {
        let sizes = SplitSizes.even(for: 5)
            .resizingColumns(inRow: 0, divider: 0, by: 40, rowWidth: 900)
            .resizingRows(by: -30, gridHeight: 600)
        XCTAssertEqual(try JSONDecoder().decode(SplitSizes.self, from: JSONEncoder().encode(sizes)), sizes)
    }

    private func decode(_ json: String) throws -> SplitSizes {
        try JSONDecoder().decode(SplitSizes.self, from: Data(json.utf8))
    }

    func testStoredSizesThatDoNotDescribeTheirGridAreRefused() {
        let bad = [
            #"{"paneCount":3,"rows":[1],"columns":[[0.5,0.5]]}"#,                      // one row where three panes make two
            #"{"paneCount":3,"rows":[0.5,0.5],"columns":[[0.5,0.5],[0.5,0.5]]}"#,      // the second row holds one pane, not two
            #"{"paneCount":2,"rows":[1],"columns":[[1.2,-0.2]]}"#,                      // a share that is not positive
            #"{"paneCount":2,"rows":[1],"columns":[[0,1]]}"#,                           // a share of nothing
            #"{"paneCount":2,"rows":[1],"columns":[[0.6,0.6]]}"#,                       // shares adding up to 1.2
            #"{"paneCount":1,"rows":[],"columns":[]}"#,                                 // no grid
            #"{"paneCount":9,"rows":[0.5,0.5],"columns":[[0.25,0.25,0.25,0.25],[0.25,0.25,0.25,0.25]]}"#,  // more than the most panes
        ]
        for json in bad {
            XCTAssertThrowsError(try decode(json), json)
        }
    }

    func testStoredSharesWithinTheToleranceAreRead() throws {
        let sizes = try decode(#"{"paneCount":3,"rows":[0.4,0.6005],"columns":[[0.3335,0.667],[1]]}"#)
        XCTAssertEqual(sizes.paneCount, 3)
        XCTAssertEqual(sizes.rows, [0.4, 0.6005])
        XCTAssertEqual(sizes.columns, [[0.3335, 0.667], [1]])
    }
}
```

- [ ] **Step 2: Run them to see them fail.**

Run: `swift test --filter SplitSizesTests`
Expected: a compile failure: `cannot find 'SplitSizes' in scope`.

- [ ] **Step 3: Write `SplitSizes`.** Create `Sources/LinkCKit/Terminal/SplitSizes.swift`:

```swift
import Foundation

/// How a split's grid divides its space once the user has resized its panes: each row's share of the
/// grid's height, and each pane's share of its row's width. The rows follow `SplitLayout.rows`, and the
/// sizes belong to positions, not terminals. Every share list holds positive fractions that add up to 1.
/// Pure value type.
public struct SplitSizes: Codable, Equatable, Sendable {
    /// The narrowest a pane gets, in points: the smallest a terminal stays usable at.
    public static let minPaneWidth: Double = 120
    /// The shortest a pane gets, in points.
    public static let minPaneHeight: Double = 80
    /// How far a stored share list may add up away from 1 and still be read.
    static let tolerance = 0.001

    /// The number of panes these sizes were made for.
    public let paneCount: Int
    /// Each row's share of the grid's height, top to bottom.
    public private(set) var rows: [Double]
    /// Per row, each pane's share of the row's width, left to right.
    public private(set) var columns: [[Double]]

    private init(paneCount: Int, rows: [Double], columns: [[Double]]) {
        self.paneCount = paneCount
        self.rows = rows
        self.columns = columns
    }

    /// The even grid of `paneCount` panes: every row the same height, every pane in a row the same width.
    public static func even(for paneCount: Int) -> SplitSizes {
        let layout = SplitLayout.rows(for: paneCount)
        return SplitSizes(paneCount: paneCount, rows: evenShares(layout.count), columns: layout.map(evenShares))
    }

    /// Whether these sizes describe a grid of `paneCount` panes.
    public func fits(paneCount: Int) -> Bool { self.paneCount == paneCount }

    /// The boundary between pane `divider` and pane `divider + 1` of `row` moved `distance` points
    /// (positive is right) in a row whose panes take `rowWidth` points between them. Only those two
    /// panes change. The boundary stops where either would fall below `minWidth`, and does not move
    /// when the two together are narrower than two minimums.
    public func resizingColumns(inRow row: Int, divider: Int, by distance: Double, rowWidth: Double,
                                minWidth: Double = SplitSizes.minPaneWidth) -> SplitSizes {
        precondition(columns.indices.contains(row) && divider >= 0 && divider + 1 < columns[row].count,
                     "no divider \(divider) in row \(row) of a \(paneCount)-pane grid")
        guard let shares = Self.moving(columns[row], boundary: divider, by: distance, length: rowWidth,
                                       minimum: minWidth) else { return self }
        var next = self
        next.columns[row] = shares
        return next
    }

    /// The boundary between the two rows moved `distance` points (positive is down) in a grid whose
    /// rows take `gridHeight` points between them, clamped as `resizingColumns` clamps. A one-row grid
    /// has nothing to resize.
    public func resizingRows(by distance: Double, gridHeight: Double,
                             minHeight: Double = SplitSizes.minPaneHeight) -> SplitSizes {
        guard rows.count == 2,
              let shares = Self.moving(rows, boundary: 0, by: distance, length: gridHeight, minimum: minHeight)
        else { return self }
        var next = self
        next.rows = shares
        return next
    }

    /// `row`'s panes back to the same width.
    public func evenedRow(_ row: Int) -> SplitSizes {
        precondition(columns.indices.contains(row), "no row \(row) in a \(paneCount)-pane grid")
        var next = self
        next.columns[row] = Self.evenShares(columns[row].count)
        return next
    }

    /// The rows back to the same height.
    public func evenedRows() -> SplitSizes {
        var next = self
        next.rows = Self.evenShares(rows.count)
        return next
    }

    /// The points `length` leaves for `count` panes once the `gap` between each two is taken out.
    /// Never negative.
    public static func paneSpace(_ length: Double, count: Int, gap: Double) -> Double {
        max(0, length - gap * Double(max(0, count - 1)))
    }

    private static func evenShares(_ count: Int) -> [Double] {
        Array(repeating: 1 / Double(count), count: count)
    }

    /// `shares` with the boundary after share `boundary` moved `distance` points along `length`, so that
    /// neither neighbour falls below `minimum`. nil when the two together hold less than two minimums.
    private static func moving(_ shares: [Double], boundary: Int, by distance: Double, length: Double,
                               minimum: Double) -> [Double]? {
        let pair = (shares[boundary] + shares[boundary + 1]) * length
        guard length > 0, pair >= 2 * minimum else { return nil }
        let first = min(max(shares[boundary] * length + distance, minimum), pair - minimum)
        var next = shares
        next[boundary] = first / length
        next[boundary + 1] = (pair - first) / length
        return next
    }

    private enum CodingKeys: String, CodingKey { case paneCount, rows, columns }

    /// Stored sizes are read only when they describe a grid: a pane count `SplitLayout` lays out, share
    /// lists of the lengths its rows give, and positive shares that add up to 1 within `tolerance`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let paneCount = try container.decode(Int.self, forKey: .paneCount)
        let rows = try container.decode([Double].self, forKey: .rows)
        let columns = try container.decode([[Double]].self, forKey: .columns)
        let layout = SplitLayout.rows(for: paneCount)
        guard (2...SplitLayout.maxPanes).contains(paneCount), rows.count == layout.count,
              columns.map(\.count) == layout, ([rows] + columns).allSatisfy(Self.isShareList) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "rows \(rows) and columns \(columns) don't describe a grid of \(paneCount) panes"))
        }
        self.init(paneCount: paneCount, rows: rows, columns: columns)
    }

    /// Positive fractions that add up to 1, within `tolerance`.
    private static func isShareList(_ shares: [Double]) -> Bool {
        shares.allSatisfy { $0 > 0 && $0.isFinite } && abs(shares.reduce(0, +) - 1) <= tolerance
    }
}
```

- [ ] **Step 4: Run the tests to see them pass.**

Run: `swift test --filter SplitSizesTests`
Expected: all 14 tests pass.

Then run: `swift build --build-tests 2>&1 | grep -cE "warning:|error:"`
Expected: `0`.

- [ ] **Step 5: Commit.**

```bash
git add Sources/LinkCKit/Terminal/SplitSizes.swift Tests/LinkCKitTests/SplitSizesTests.swift
git commit -m "feat(split): pane sizes for a split's grid, clamped to a usable minimum"
```

---

### Task 2: `ProjectSplit` carries its sizes (LinkCKit)

**Files:**
- Modify: `Sources/LinkCKit/Terminal/ProjectSplit.swift`
- Test: `Tests/LinkCKitTests/ProjectSplitTests.swift`, `Tests/LinkCKitTests/SidebarStateTests.swift`

**Interfaces:**
- Consumes: `SplitSizes` from Task 1. That covers `even(for:)`, `fits(paneCount:)`, `resizingColumns(inRow:divider:by:rowWidth:)`, `columns` and `Codable`.
- Produces (Task 3 relies on these):
  - `public private(set) var sizes: SplitSizes?` on `ProjectSplit`; nil means even.
  - `public init(members: [String] = [], focused: String? = nil, sizes: SplitSizes? = nil)`
  - `public func resized(_ sizes: SplitSizes) -> ProjectSplit`
  - `public func gridSizes(paneCount: Int) -> SplitSizes`: the stored sizes when they fit `paneCount`, else `SplitSizes.even(for: paneCount)`.

- [ ] **Step 1: Write the failing tests.** Append this section inside `final class ProjectSplitTests` in `Tests/LinkCKitTests/ProjectSplitTests.swift`, before its closing brace. The class already has `private let project: Set<String> = ["A", "B", "C", "D"]` and `private func decode(_ json: String) throws -> ProjectSplit`. Use them; don't redeclare them.

```swift
    // MARK: - Pane sizes

    /// `members` with sizes made for them: the first boundary dragged 60 pt to the right.
    private func sized(_ members: [String], focused: String? = nil) -> ProjectSplit {
        let sizes = SplitSizes.even(for: members.count).resizingColumns(inRow: 0, divider: 0, by: 60, rowWidth: 600)
        return ProjectSplit(members: members, focused: focused).resized(sizes)
    }

    func testResizingSetsTheSizesAndNothingElse() {
        let sizes = SplitSizes.even(for: 2).resizingColumns(inRow: 0, divider: 0, by: 60, rowWidth: 600)
        let split = ProjectSplit(members: ["A", "B"], focused: "A").resized(sizes)
        XCTAssertEqual(split.sizes, sizes)
        XCTAssertEqual(split.members, ["A", "B"])
        XCTAssertEqual(split.focused, "A")
    }

    func testANewSplitIsEven() {
        XCTAssertNil(ProjectSplit(members: ["A", "B"]).sizes)
    }

    func testATerminalJoiningClearsTheSizes() throws {
        XCTAssertNil(try sized(["A", "B"]).adding("C", onto: "B", edge: .right).sizes)
    }

    func testAMemberMovingKeepsTheSizes() throws {
        let split = sized(["A", "B", "C"])
        XCTAssertEqual(try split.adding("A", onto: "C", edge: .right).sizes, split.sizes)
    }

    func testAMemberDroppedOnItselfKeepsTheSplit() throws {
        let split = sized(["A", "B"])
        XCTAssertEqual(try split.adding("B", onto: "B", edge: .left), split)
    }

    func testANewSplitFromADropHasNoSizes() throws {
        XCTAssertNil(try ProjectSplit.dropping("B", onto: "A", edge: .left, into: nil, splittable: project).sizes)
    }

    func testRemovingAMemberClearsTheSizes() {
        XCTAssertNil(sized(["A", "B", "C"]).removing("B").sizes)
    }

    func testRemovingANonMemberChangesNothing() {
        let split = sized(["A", "B"])
        XCTAssertEqual(split.removing("Z"), split)
    }

    func testPruningThatRemovesAMemberClearsTheSizes() {
        XCTAssertNil(sized(["A", "B", "C"]).pruned(keeping: ["A", "B"]).sizes)
    }

    func testPruningThatKeepsEveryMemberKeepsTheSizes() {
        let split = sized(["A", "B", "C"])
        XCTAssertEqual(split.pruned(keeping: ["A", "B", "C", "D"]).sizes, split.sizes)
    }

    func testFocusingKeepsTheSizes() {
        let split = sized(["A", "B"], focused: "A")
        XCTAssertEqual(split.focusing("B").sizes, split.sizes)
    }

    /// Sizes made for three panes don't fit a grid showing two, a member still relaunching for example:
    /// that grid is even, and the stored sizes stay for when the member is back.
    func testTheGridShowsStoredSizesOnlyForTheirPaneCount() {
        let split = sized(["A", "B", "C"])
        XCTAssertEqual(split.gridSizes(paneCount: 3), split.sizes)
        XCTAssertEqual(split.gridSizes(paneCount: 2), SplitSizes.even(for: 2))
        XCTAssertEqual(ProjectSplit(members: ["A", "B"]).gridSizes(paneCount: 2), SplitSizes.even(for: 2))
    }

    func testSizesRoundTripWithTheSplit() throws {
        let split = sized(["A", "B", "C"], focused: "B")
        XCTAssertEqual(try JSONDecoder().decode(ProjectSplit.self, from: JSONEncoder().encode(split)), split)
    }

    /// A split with no sizes is stored without the key, so an older build reads the file as before.
    func testASplitWithoutSizesStoresNoSizesKey() throws {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ProjectSplit(members: ["A", "B"])))
        XCTAssertNil((object as? [String: Any])?["sizes"])
    }

    func testASplitStoredBeforeSizesDecodesEven() throws {
        XCTAssertNil(try decode(#"{"members":["A","B"],"focused":"A"}"#).sizes)
    }

    func testStoredSizesDecode() throws {
        let split = try decode(#"{"members":["A","B"],"sizes":{"paneCount":2,"rows":[1],"columns":[[0.4,0.6]]}}"#)
        XCTAssertEqual(split.sizes?.columns, [[0.4, 0.6]])
    }

    func testUnreadableSizesDecodeEvenAndKeepTheSplit() throws {
        let split = try decode(#"{"members":["A","B"],"focused":"A","sizes":{"paneCount":2,"rows":[1],"columns":[[0.6,0.6]]}}"#)
        XCTAssertEqual(split.members, ["A", "B"])
        XCTAssertEqual(split.focused, "A")
        XCTAssertNil(split.sizes)
    }

    func testRepairingTheMembersClearsTheSizes() throws {
        let split = try decode(#"{"members":["A","B","A"],"sizes":{"paneCount":3,"rows":[0.5,0.5],"columns":[[0.5,0.5],[1]]}}"#)
        XCTAssertEqual(split.members, ["A", "B"])
        XCTAssertNil(split.sizes)
    }
```

Then, in `Tests/LinkCKitTests/SidebarStateTests.swift`, add this test directly after `testASplitSurvivesARelaunch()`:

```swift
    func testASplitsSizesSurviveARelaunch() {
        let sizes = SplitSizes.even(for: 2).resizingColumns(inRow: 0, divider: 0, by: 60, rowWidth: 600)
        SidebarState(defaults: defaults).setSplit(ProjectSplit(members: ["A", "B"], focused: "B").resized(sizes), for: "/tmp")
        XCTAssertEqual(SidebarState(defaults: defaults).split(for: "/tmp")?.sizes, sizes)
    }
```

- [ ] **Step 2: Run them to see them fail.**

Run: `swift test --filter "ProjectSplitTests|SidebarStateTests"`
Expected: compile failures, because `resized`, `sizes` and `gridSizes` don't exist on `ProjectSplit` yet.

- [ ] **Step 3: Give `ProjectSplit` its sizes.** In `Sources/LinkCKit/Terminal/ProjectSplit.swift`:

3a. Replace the type's doc comment and the stored properties, the memberwise init and `CodingKeys`. The current text runs from `/// A project's split: the terminals shown together` through `private enum CodingKeys: String, CodingKey { case members, focused }`. Keep the `Refusal` enum as it is. The result reads:

```swift
/// A project's split: the terminals shown together in its Split tab, in grid order, which one has the
/// keyboard, and the sizes of its panes once the user has resized them. Members are linkC terminal ids
/// (session ids or shell terminal ids) and are the project's live terminals: one that ends drops out. A
/// session linkC relaunches at start-up keeps its id and so rejoins; one restored later from Earlier is a
/// new session, not in the split. The sizes belong to positions: a member moving keeps them, and a
/// terminal joining or leaving evens the grid out. Pure value type.
public struct ProjectSplit: Codable, Equatable, Sendable {
```

followed by the unchanged `Refusal` enum, then:

```swift
    public private(set) var members: [String]
    public private(set) var focused: String?
    /// How the grid divides its space; nil is even.
    public private(set) var sizes: SplitSizes?

    public init(members: [String] = [], focused: String? = nil, sizes: SplitSizes? = nil) {
        self.members = members
        self.focused = focused
        self.sizes = sizes
    }

    private enum CodingKeys: String, CodingKey { case members, focused, sizes }
```

3b. Replace the whole `public init(from decoder: Decoder) throws` with its doc comment:

```swift
    /// A stored split is repaired as it is read: duplicate members would put one terminal in two
    /// cells, more than `SplitLayout.maxPanes` would not fit the grid, and a focus that names no member
    /// would leave no pane with the keyboard. Sizes that don't describe a grid, or that were made for
    /// members the repair changed, are dropped and the grid evens out. Anything repaired is logged.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let stored = try container.decode([String].self, forKey: .members)
        let storedFocus = try container.decodeIfPresent(String.self, forKey: .focused)
        var seen: Set<String> = []
        let members = Array(stored.filter { seen.insert($0).inserted }.prefix(SplitLayout.maxPanes))
        var focused = storedFocus
        if let current = focused, !members.contains(current) { focused = members.first }
        if members != stored || focused != storedFocus {
            NSLog("[linkC] a stored split had duplicate or surplus members, or a focus outside them — repaired from %@ (focused %@) to %@ (focused %@)",
                  stored.joined(separator: ","), storedFocus ?? "none", members.joined(separator: ","), focused ?? "none")
        }
        var sizes: SplitSizes?
        do {
            sizes = try container.decodeIfPresent(SplitSizes.self, forKey: .sizes)
        } catch {
            NSLog("[linkC] a stored split's pane sizes were unreadable, so its grid evens out: %@", "\(error)")
        }
        if sizes != nil, members != stored {
            NSLog("[linkC] a stored split's members were repaired, so its pane sizes are dropped and its grid evens out")
            sizes = nil
        }
        self.members = members
        self.focused = focused
        self.sizes = sizes
    }
```

3c. In `adding(_:onto:edge:)`, replace its last line, `return ProjectSplit(members: next, focused: id)`, with:

```swift
        // Sizes belong to positions: a member moving keeps them; one joining reshapes the grid and evens it.
        return ProjectSplit(members: next, focused: id, sizes: source == nil ? nil : sizes)
```

3d. Replace `removing(_:)`, `focusing(_:)` and `pruned(keeping:)`, with their doc comments, by:

```swift
    /// `id` taken out. A focused member hands the focus to the one that takes its place, or to the
    /// one before it when it was last. The grid reshapes, so it evens out.
    public func removing(_ id: String) -> ProjectSplit {
        guard let index = members.firstIndex(of: id) else { return self }
        var next = members
        next.remove(at: index)
        var focus = focused
        if focused == id { focus = next.isEmpty ? nil : next[min(index, next.count - 1)] }
        return ProjectSplit(members: next, focused: focus, sizes: nil)
    }

    public func focusing(_ id: String) -> ProjectSplit {
        guard members.contains(id) else { return self }
        return ProjectSplit(members: members, focused: id, sizes: sizes)
    }

    /// Only the members in `ids` — the project's live terminals. The sizes stay only when every member does.
    public func pruned(keeping ids: Set<String>) -> ProjectSplit {
        let kept = members.filter { ids.contains($0) }
        let focus = focused.flatMap { kept.contains($0) ? $0 : nil } ?? kept.first
        return ProjectSplit(members: kept, focused: focus, sizes: kept == members ? sizes : nil)
    }

    /// The split with its panes sized by `sizes`, until a terminal joins or leaves it.
    public func resized(_ sizes: SplitSizes) -> ProjectSplit {
        ProjectSplit(members: members, focused: focused, sizes: sizes)
    }

    /// The sizes a grid of `paneCount` live panes shows: the stored ones when they were made for that
    /// many panes, else even. Sizes that don't fit stay stored for when the missing member is back.
    public func gridSizes(paneCount: Int) -> SplitSizes {
        if let sizes, sizes.fits(paneCount: paneCount) { return sizes }
        return .even(for: paneCount)
    }
```

`dropping(_:onto:edge:into:splittable:)` needs no change. Its new split from `target` is built with no sizes, and its other paths go through `pruned` and `adding`.

- [ ] **Step 4: Run the tests to see them pass.**

Run: `swift test --filter "ProjectSplitTests|SidebarStateTests|SplitSizesTests|TornOffTests"`
Expected: all pass, the existing split and torn-off tests included.

Then run: `swift build --build-tests 2>&1 | grep -cE "warning:|error:"`
Expected: `0`.

- [ ] **Step 5: Commit.**

```bash
git add Sources/LinkCKit/Terminal/ProjectSplit.swift Tests/LinkCKitTests/ProjectSplitTests.swift Tests/LinkCKitTests/SidebarStateTests.swift
git commit -m "feat(split): a split keeps its pane sizes until a terminal joins or leaves"
```

---

### Task 3: Resize handles in the Split tab (app target)

**Files:**
- Modify: `Sources/linkc/LinkCApp.swift` (`splitPaneState(in:)` near line 863; a new `resizeSplit(_:in:)` beside `removeFromSplit(_:in:)` near line 958)
- Modify: `Sources/linkc/SplitPane.swift`

**Interfaces:**
- Consumes:
  - From Task 2: `ProjectSplit.resized(_:)`, `ProjectSplit.gridSizes(paneCount:)`, `ProjectSplit.liveMembers(in:)`.
  - From Task 1: `SplitSizes.fits(paneCount:)`, `paneCount`, `rows`, `columns`, `resizingColumns(inRow:divider:by:rowWidth:)`, `resizingRows(by:gridHeight:)`, `evenedRow(_:)`, `evenedRows()`, `paneSpace(_:count:gap:)`.
  - Existing: `SplitLayout.rowRanges(for:)`.
- Produces:
  - `AppModel.resizeSplit(_ sizes: SplitSizes, in project: String)`.
  - `AppModel.splitPaneState(in:)` now also returns `sizes: SplitSizes`.

The app target has no unit tests. The logic lives in Tasks 1 and 2 and is tested there. This task is checked by a build with no warnings, the full suite, and reading the code. Never launch the app.

- [ ] **Step 1: The model hands the grid its sizes and stores new ones.** In `Sources/linkc/LinkCApp.swift`, replace `splitPaneState(in:)` and its doc comment with:

```swift
    /// What the Split tab renders: the live members in grid order, the one with the keyboard, the live
    /// titles, and the sizes the grid shows (even unless the stored ones fit the live panes). One tab-list
    /// build and one title resolve, however many panes there are.
    func splitPaneState(in project: String)
        -> (members: [String], focused: String?, titles: [String: String], sizes: SplitSizes) {
        guard let split = sidebarState.split(for: project) else { return ([], nil, [:], SplitSizes.even(for: 0)) }
        let live = splittableIDs(in: project)
        let members = split.liveMembers(in: live)
        return (members, split.focusedLive(in: live), sessionTitles, split.gridSizes(paneCount: members.count))
    }
```

Then add this method directly above `removeFromSplit(_:in:)`, with its doc comment:

```swift
    /// The user let go of a resize handle in `project`'s grid: the split keeps `sizes` until a terminal
    /// joins or leaves it. Sizes made for a grid that changed during the drag (a pane ended) fit no grid
    /// on screen; they are not stored, and that is logged.
    func resizeSplit(_ sizes: SplitSizes, in project: String) {
        let key = ProjectTabs.standardized(project)
        guard let split = sidebarState.split(for: key) else { return }
        let panes = split.liveMembers(in: splittableIDs(in: key)).count
        guard sizes.fits(paneCount: panes) else {
            NSLog("[linkC] pane sizes for %ld panes not stored: %@'s split shows %ld now", sizes.paneCount, key, panes)
            return
        }
        sidebarState.setSplit(split.resized(sizes), for: key)
    }
```

- [ ] **Step 2: The grid lays out from the sizes, with handles in the gaps.** In `Sources/linkc/SplitPane.swift`:

2a. Replace everything from the first line (`import LinkCKit`) through the closing brace of `struct SplitPane` with the code below. `SplitPaneItem` and `SplitCell` stay exactly as they are.

```swift
import AppKit
import LinkCKit
import SwiftUI

/// A project's Split tab: its live split members in a grid (see `SplitLayout`), each a full live
/// terminal. A click inside a pane, or on its title row, gives it the keyboard and the focus outline;
/// the title row's × takes it out of the split (its session keeps running).
///
/// The gaps between panes are handles. Dragging one resizes the panes either side of it, or the two
/// rows; a double-click evens them out again. The split keeps its sizes until a terminal joins or leaves
/// it, and sizes made for another number of panes show an even grid (`ProjectSplit.gridSizes`).
///
/// A pane that ends leaves the tab up to a second before the model's repair ends the grid, so fewer
/// than two live members still render: one fills the pane, none shows a placeholder.
///
/// `host` is the torn-off window this grid is drawn in, nil for the panel. A terminal's live view
/// lives in one host only, so a pane whose terminal is hosted elsewhere (its own window, or another
/// window's grid) shows a note in place of the terminal and never takes the view.
struct SplitPane: View {
    let model: AppModel
    let project: String
    let host: TornOffItem?
    /// The sizes a handle drag is making: shown live, and stored in the split once, when the drag ends.
    @State private var dragged: SplitSizes?
    /// The sizes the drag started from. Each step applies the drag's whole translation to these, so the
    /// boundary stays under the pointer.
    @State private var dragStart: SplitSizes?

    /// The space between two panes, and between the rows. Each one is a resize handle.
    fileprivate static let gap: CGFloat = 6
    /// The grid's coordinate space: drags are measured in it, so a handle moving under the pointer
    /// doesn't move the ruler.
    private static let space = "splitGrid"

    var body: some View {
        // Titles and dots read inputs that are not observable (inbox files, terminal screens). They
        // are resolved here, where the signal is read, and handed to the cells as values: a cell's
        // own inputs do not change when the signal publishes, so it would skip its body.
        let _ = model.sidebarSignal.signal
        let state = model.splitPaneState(in: project)
        let hosts = model.hosts(of: state.members)
        let panes = state.members.map {
            SplitPaneItem(id: $0, title: model.splitPaneTitle($0, titles: state.titles), dot: model.splitPaneDot($0),
                          hostedIn: hosts[$0])
        }
        let focused = state.focused
        // A drag that outlived its grid (a pane ended mid-drag) fits no grid on screen and is not shown.
        let live = dragged.flatMap { $0.fits(paneCount: panes.count) ? $0 : nil }
        Group {
            switch panes.count {
            case 0:
                Text("Select a session")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case 1:
                SplitCell(model: model, project: project, grid: host, pane: panes[0], isFocused: true)
            default:
                grid(panes, focused: focused, sizes: live ?? state.sizes)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    /// The panes in their rows, each pane and row as large as `sizes` makes it, with a handle in every gap.
    /// Rows are keyed by position, not by their first member, so a row that widens keeps its cells; a
    /// cell is rebuilt only when its member moves to another row.
    private func grid(_ panes: [SplitPaneItem], focused: String?, sizes: SplitSizes) -> some View {
        GeometryReader { proxy in
            let ranges = SplitLayout.rowRanges(for: panes.count)
            let gridHeight = SplitSizes.paneSpace(Double(proxy.size.height), count: ranges.count, gap: Double(Self.gap))
            VStack(spacing: 0) {
                ForEach(Array(ranges.enumerated()), id: \.offset) { row, range in
                    if row > 0 {
                        ResizeHandle(axis: .vertical, space: Self.space,
                                     onDrag: { distance in
                                         dragStep(from: sizes) { $0.resizingRows(by: distance, gridHeight: gridHeight) }
                                     },
                                     onEnd: endDrag,
                                     onDoubleClick: { model.resizeSplit(sizes.evenedRows(), in: project) })
                    }
                    let rowWidth = SplitSizes.paneSpace(Double(proxy.size.width), count: range.count, gap: Double(Self.gap))
                    HStack(spacing: 0) {
                        ForEach(Array(panes[range].enumerated()), id: \.element.id) { column, pane in
                            if column > 0 {
                                ResizeHandle(axis: .horizontal, space: Self.space,
                                             onDrag: { distance in
                                                 dragStep(from: sizes) {
                                                     $0.resizingColumns(inRow: row, divider: column - 1, by: distance, rowWidth: rowWidth)
                                                 }
                                             },
                                             onEnd: endDrag,
                                             onDoubleClick: { model.resizeSplit(sizes.evenedRow(row), in: project) })
                            }
                            SplitCell(model: model, project: project, grid: host, pane: pane, isFocused: pane.id == focused)
                                .frame(width: CGFloat(sizes.columns[row][column] * rowWidth))
                        }
                    }
                    .frame(height: CGFloat(sizes.rows[row] * gridHeight))
                }
            }
            .coordinateSpace(.named(Self.space))
        }
    }

    /// One step of a handle drag: `resize` applied to the sizes the drag started from (`shown` on its first step).
    private func dragStep(from shown: SplitSizes, _ resize: (SplitSizes) -> SplitSizes) {
        let start = dragStart ?? shown
        dragStart = start
        dragged = resize(start)
    }

    /// The drag ended: the split keeps the sizes it made, written once rather than on every step.
    private func endDrag() {
        if let made = dragged { model.resizeSplit(made, in: project) }
        dragged = nil
        dragStart = nil
    }
}
```

2b. Append this type at the end of `Sources/linkc/SplitPane.swift`:

```swift
/// A gap between panes that resizes them. Dragged, it reports its translation along `axis` in the
/// grid's coordinate space `space`; double-clicked, it asks for the even sizes back. The pointer shows the
/// resize cursor over it and for the whole drag, even once the pointer has run ahead of a boundary that
/// stopped at a minimum.
private struct ResizeHandle: View {
    /// `.horizontal` sits between two panes of a row and moves left and right; `.vertical` sits between
    /// the rows and moves up and down.
    let axis: Axis
    let space: String
    let onDrag: (Double) -> Void
    let onEnd: () -> Void
    let onDoubleClick: () -> Void
    @State private var hovering = false
    @State private var dragging = false
    /// Whether this handle pushed the resize cursor, so it pops only its own.
    @State private var pushedCursor = false

    var body: some View {
        Color.clear
            .frame(width: axis == .horizontal ? SplitPane.gap : nil, height: axis == .vertical ? SplitPane.gap : nil)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named(space))
                    .onChanged { value in
                        dragging = true
                        onDrag(Double(axis == .horizontal ? value.translation.width : value.translation.height))
                    }
                    .onEnded { _ in
                        dragging = false
                        onEnd()
                    })
            .onTapGesture(count: 2, perform: onDoubleClick)
            .onChange(of: hovering || dragging) { _, wanted in showCursor(wanted) }
            .onDisappear { showCursor(false) }
    }

    private func showCursor(_ show: Bool) {
        guard show != pushedCursor else { return }
        if show {
            (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
        } else {
            NSCursor.pop()
        }
        pushedCursor = show
    }
}
```

- [ ] **Step 3: Build with no warnings.**

Run: `swift build --build-tests 2>&1 | grep -E "warning:|error:"`
Expected: no output.

If the compiler reports that an expression is too complex to type-check in `grid(_:focused:sizes:)`, move the row's `HStack` into a `private func row(_ panes: ArraySlice<SplitPaneItem>, row: Int, rowWidth: Double, sizes: SplitSizes, focused: String?) -> some View` holding the same code. Change nothing else.

- [ ] **Step 4: Run the full suite.**

Run: `swift test 2>&1 | tail -5`
Expected: `Executed N tests, with 0 failures`.

- [ ] **Step 5: Read it through.** Before committing, check each of these against the code:
  - The split is written only from `endDrag()` and the double-click closures, never from `dragStep`.
  - `body` has no side effects. Cursor changes happen only in `onChange` and `onDisappear`.
  - Every index into `sizes.rows` and `sizes.columns` comes from `SplitLayout.rowRanges(for: panes.count)`, and `sizes` always fits `panes.count`: `state.sizes` comes from `gridSizes(paneCount:)`, and `dragged` passes the `fits` filter.

- [ ] **Step 6: Commit.**

```bash
git add Sources/linkc/LinkCApp.swift Sources/linkc/SplitPane.swift
git commit -m "feat(split): drag the gaps between split panes to resize them, double-click to even out"
```

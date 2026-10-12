# Split Terminals Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show up to 8 of a project's terminals at once in an even grid, as a "Split" tab, built by dragging terminals onto each other.

**Architecture:** The grid math, the split's membership rules, its persistence and its tab are pure LinkCKit types with unit tests. The app target adds a `SplitPane` view that lays out today's `TerminalContainer` hosts, a drop delegate that turns a dragged `LinkCTerminalDrag` plus the edge it lands on into a split change, and model state (`splitProject`) next to the existing `boardProject` and `appTab`. Each session keeps its single live `LinkCTerminalView`, which moves between its own tab's host and its grid cell.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI + AppKit (macOS 14), SwiftTerm, XCTest. Build and test with `swift build --build-tests` and `swift test`.

**Spec:** `docs/superpowers/specs/2026-10-12-split-terminals-design.md`. Read it first.

## Global Constraints

- At most 8 panes (`SplitLayout.maxPanes = 8`). One split per project.
- Panes per row: 2 → [2], 3 → [2, 1], 4 → [2, 2], 5 → [3, 2], 6 → [3, 3], 7 → [4, 3], 8 → [4, 4].
- The Split tab sits right after Board. Its id is `"split:" + canonicalPath` and its title is `"Split"`. It shows only while the split has 2 or more live members. Its `isWorking` is always false.
- Only the project's own terminals can join its split: its sessions and the shell terminals filed under it, which are what its tab strip lists.
- Removing a pane never stops its session.
- The panel never resizes itself.
- Persistence is additive. `SidebarState.Stored.splits` is optional and decoded entry by entry, so a bad entry is dropped with a log line naming the project.
- Keep repo rules:
  - Swift 6 strict concurrency, and `swift build --build-tests` with 0 warnings.
  - No new dependencies, and no side effects in SwiftUI view bodies.
  - Tests go through seams. `SidebarState` tests use `InMemoryUserDefaults()`.
  - Fail loud.
  - Match the surrounding style: 4-space indentation and the existing comment density.
- Commits are small conventional commits, with no trailers of any kind and no mention of Claude, Anthropic or AI. `./scripts/check-commits.sh origin/main..HEAD` must stay clean.

## File Structure

- Create `Sources/LinkCKit/Terminal/SplitLayout.swift`: `SplitEdge`, `SplitLayout` (rows, row ranges, insertion index, edge from a point).
- Create `Sources/LinkCKit/Terminal/ProjectSplit.swift`: `ProjectSplit` (members, focus, add/move/remove/prune) and `ProjectSplit.Refusal`.
- Modify `Sources/LinkCKit/Preferences/SidebarState.swift`: store and expose splits.
- Modify `Sources/LinkCKit/Board/ProjectTabs.swift`: `.split` kind, `splitID`, and the Split tab in `tabs(...)`.
- Modify `Sources/LinkCKit/Terminal/TerminalContainer.swift`:
  - `TerminalHostView.show` re-attaches a moved view and never detaches one it no longer holds;
  - an opt-in focus grab;
  - an `onFocus` pass-through.
- Modify `Sources/LinkCKit/Terminal/TerminalSession.swift`: `LinkCTerminalView.onFocus`, called when it becomes first responder.
- Modify `Sources/linkc/LinkCApp.swift`: `splitProject`, `showSplit`, `focusInSplit`, `removeFromSplit`, `dropTerminal`, `dissolveSplit`, plus selection rule changes.
- Modify `Sources/linkc/AppModel+Sidebar.swift`: prune splits in `sampleSidebar()`.
- Create `Sources/linkc/SplitPane.swift`: the grid view and its cells.
- Create `Sources/linkc/TerminalDropTarget.swift`: the drop delegate and the edge highlight overlay.
- Modify `Sources/linkc/PanelView.swift`: route the Split tab to `SplitPane`, attach the drop target to the single terminal, share terminal styling.
- Modify `Sources/linkc/Board/ProjectTabStrip.swift`:
  - the `.split` icon;
  - draggable session and terminal chips;
  - a strip drop that removes a pane;
  - close-help text.
- Tests: create `SplitLayoutTests.swift`, `ProjectSplitTests.swift` and `TerminalHostViewTests.swift`; extend `SidebarStateTests.swift` and `ProjectTabsTests.swift`. All are in `Tests/LinkCKitTests/`.

---

### Task 1: SplitLayout

**Files:**
- Create: `Sources/LinkCKit/Terminal/SplitLayout.swift`
- Test: `Tests/LinkCKitTests/SplitLayoutTests.swift`

**Interfaces:**
- Produces:
  - `public enum SplitEdge: String, Codable, Sendable, CaseIterable { case left, right, top, bottom }`
  - `SplitLayout.maxPanes`
  - `SplitLayout.rows(for:) -> [Int]`
  - `SplitLayout.rowRanges(for:) -> [Range<Int>]`
  - `SplitLayout.insertionIndex(droppingOn:edge:movingFrom:) -> Int`
  - `SplitLayout.edge(at:in:) -> SplitEdge`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import LinkCKit

final class SplitLayoutTests: XCTestCase {
    func testRowsForEachPaneCount() {
        XCTAssertEqual(SplitLayout.rows(for: 0), [])
        XCTAssertEqual(SplitLayout.rows(for: 1), [])
        XCTAssertEqual(SplitLayout.rows(for: 2), [2])
        XCTAssertEqual(SplitLayout.rows(for: 3), [2, 1])
        XCTAssertEqual(SplitLayout.rows(for: 4), [2, 2])
        XCTAssertEqual(SplitLayout.rows(for: 5), [3, 2])
        XCTAssertEqual(SplitLayout.rows(for: 6), [3, 3])
        XCTAssertEqual(SplitLayout.rows(for: 7), [4, 3])
        XCTAssertEqual(SplitLayout.rows(for: 8), [4, 4])
        XCTAssertEqual(SplitLayout.rows(for: 12), [4, 4], "never more than the cap")
    }

    func testRowRangesCoverEveryPaneInOrder() {
        XCTAssertEqual(SplitLayout.rowRanges(for: 5), [0..<3, 3..<5])
        XCTAssertEqual(SplitLayout.rowRanges(for: 2), [0..<2])
        XCTAssertEqual(SplitLayout.rowRanges(for: 1), [])
    }

    func testAJoiningTerminalGoesBeforeOnLeftOrTopAndAfterOnRightOrBottom() {
        XCTAssertEqual(SplitLayout.insertionIndex(droppingOn: 1, edge: .left, movingFrom: nil), 1)
        XCTAssertEqual(SplitLayout.insertionIndex(droppingOn: 1, edge: .top, movingFrom: nil), 1)
        XCTAssertEqual(SplitLayout.insertionIndex(droppingOn: 1, edge: .right, movingFrom: nil), 2)
        XCTAssertEqual(SplitLayout.insertionIndex(droppingOn: 1, edge: .bottom, movingFrom: nil), 2)
    }

    /// A member being moved leaves the list first, so a target after it shifts down by one.
    func testAMovedMemberCountsAsRemovedFirst() {
        XCTAssertEqual(SplitLayout.insertionIndex(droppingOn: 3, edge: .right, movingFrom: 0), 3)
        XCTAssertEqual(SplitLayout.insertionIndex(droppingOn: 3, edge: .left, movingFrom: 0), 2)
        XCTAssertEqual(SplitLayout.insertionIndex(droppingOn: 0, edge: .left, movingFrom: 3), 0)
    }

    /// The edge nearest the pointer, relative to the pane's size; y grows downward.
    func testTheNearestEdgeWins() {
        let size = CGSize(width: 400, height: 200)
        XCTAssertEqual(SplitLayout.edge(at: CGPoint(x: 10, y: 100), in: size), .left)
        XCTAssertEqual(SplitLayout.edge(at: CGPoint(x: 390, y: 100), in: size), .right)
        XCTAssertEqual(SplitLayout.edge(at: CGPoint(x: 200, y: 5), in: size), .top)
        XCTAssertEqual(SplitLayout.edge(at: CGPoint(x: 200, y: 195), in: size), .bottom)
        XCTAssertEqual(SplitLayout.edge(at: CGPoint(x: 100, y: 100), in: size), .left, "a quarter across is nearer the side than the middle row is to top or bottom")
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter SplitLayoutTests`
Expected: the build fails with `cannot find 'SplitLayout' in scope`.

- [ ] **Step 3: Implement**

```swift
import CoreGraphics

/// Which edge of a pane a terminal was dropped on.
public enum SplitEdge: String, Codable, Sendable, CaseIterable {
    case left, right, top, bottom
}

/// The even grid a project's split forms, and where a dropped terminal lands in it. Pure.
public enum SplitLayout {
    /// The most panes a split holds.
    public static let maxPanes = 8

    /// Panes per row, top to bottom: 2 → [2], 3 → [2, 1], 4 → [2, 2] … 8 → [4, 4]. Empty below two
    /// panes, which is no grid at all.
    public static func rows(for count: Int) -> [Int] {
        let clamped = min(count, maxPanes)
        guard clamped >= 2 else { return [] }
        guard clamped > 2 else { return [2] }
        let top = (clamped + 1) / 2
        return [top, clamped - top]
    }

    /// The member indexes each row holds, top to bottom.
    public static func rowRanges(for count: Int) -> [Range<Int>] {
        var start = 0
        return rows(for: count).map { width in
            defer { start += width }
            return start..<(start + width)
        }
    }

    /// Where a terminal dropped on `edge` of the pane at `target` goes, as an index into the members
    /// once the dragged terminal is out of the list. Left and top go before the target, right and
    /// bottom after it; the grid reflows, so top and bottom only mean before and after. `source` is
    /// the dragged terminal's own index when it is already a member (a move), nil when it is joining.
    public static func insertionIndex(droppingOn target: Int, edge: SplitEdge, movingFrom source: Int?) -> Int {
        var index = (edge == .left || edge == .top) ? target : target + 1
        if let source, source < index { index -= 1 }
        return index
    }

    /// The edge of a `size` pane nearest `point` (origin top-left), measured as a fraction of the
    /// pane's width or height so a wide pane doesn't favour top and bottom.
    public static func edge(at point: CGPoint, in size: CGSize) -> SplitEdge {
        let x = size.width > 0 ? point.x / size.width : 0.5
        let y = size.height > 0 ? point.y / size.height : 0.5
        let distances: [(SplitEdge, CGFloat)] = [(.left, x), (.right, 1 - x), (.top, y), (.bottom, 1 - y)]
        return distances.min { $0.1 < $1.1 }!.0
    }
}
```

- [ ] **Step 4: Run them to verify they pass**

Run: `swift test --filter SplitLayoutTests`
Expected: 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/LinkCKit/Terminal/SplitLayout.swift Tests/LinkCKitTests/SplitLayoutTests.swift
git commit -m "feat(split): grid rows, insertion index and drop edge for split terminals"
```

---

### Task 2: ProjectSplit

**Files:**
- Create: `Sources/LinkCKit/Terminal/ProjectSplit.swift`
- Test: `Tests/LinkCKitTests/ProjectSplitTests.swift`

**Interfaces:**
- Consumes: `SplitEdge`, `SplitLayout.maxPanes`, `SplitLayout.insertionIndex` (Task 1).
- Produces: `public struct ProjectSplit: Codable, Equatable, Sendable` with:
  - `members: [String]` and `focused: String?`;
  - `init(members:focused:)`;
  - `adding(_:onto:edge:) throws -> ProjectSplit`;
  - `removing(_:) -> ProjectSplit`;
  - `focusing(_:) -> ProjectSplit`;
  - `pruned(keeping:) -> ProjectSplit`;
  - `liveMembers(in:) -> [String]`;
  - `focusedLive(in:) -> String?`;
  - `isActive(liveIDs:) -> Bool`;
  - `public enum Refusal: Error, Equatable { case full, targetNotInSplit }`.

- [ ] **Step 1: Write the failing tests**

```swift
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
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter ProjectSplitTests`
Expected: the build fails with `cannot find 'ProjectSplit' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// A project's split: the terminals shown together in its Split tab, in grid order, and which one
/// has the keyboard. Members are linkC terminal ids (session ids or shell terminal ids); a session
/// restored after a relaunch keeps its id and so rejoins. Pure value type.
public struct ProjectSplit: Codable, Equatable, Sendable {
    public enum Refusal: Error, Equatable {
        /// The split already holds `SplitLayout.maxPanes` terminals.
        case full
        /// The terminal dropped on is not in this split.
        case targetNotInSplit
    }

    public private(set) var members: [String]
    public private(set) var focused: String?

    public init(members: [String] = [], focused: String? = nil) {
        self.members = members
        self.focused = focused
    }

    /// `id` dropped on `edge` of the member `target`. A member already in the split moves; a new one
    /// joins, unless the split is full. The dropped terminal gets the focus.
    public func adding(_ id: String, onto target: String, edge: SplitEdge) throws -> ProjectSplit {
        guard let targetIndex = members.firstIndex(of: target) else { throw Refusal.targetNotInSplit }
        guard id != target else { return self }
        let source = members.firstIndex(of: id)
        if source == nil, members.count >= SplitLayout.maxPanes { throw Refusal.full }
        var next = members
        if let source { next.remove(at: source) }
        let index = SplitLayout.insertionIndex(droppingOn: targetIndex, edge: edge, movingFrom: source)
        next.insert(id, at: min(index, next.count))
        return ProjectSplit(members: next, focused: id)
    }

    /// `id` taken out. A focused member hands the focus to the one that takes its place, or to the
    /// one before it when it was last.
    public func removing(_ id: String) -> ProjectSplit {
        guard let index = members.firstIndex(of: id) else { return self }
        var next = members
        next.remove(at: index)
        var focus = focused
        if focused == id { focus = next.isEmpty ? nil : next[min(index, next.count - 1)] }
        return ProjectSplit(members: next, focused: focus)
    }

    public func focusing(_ id: String) -> ProjectSplit {
        guard members.contains(id) else { return self }
        return ProjectSplit(members: members, focused: id)
    }

    /// Only the members in `ids` — the terminals that are live or can still be restored.
    public func pruned(keeping ids: Set<String>) -> ProjectSplit {
        let kept = members.filter { ids.contains($0) }
        let focus = focused.flatMap { kept.contains($0) ? $0 : nil } ?? kept.first
        return ProjectSplit(members: kept, focused: focus)
    }

    public func liveMembers(in liveIDs: Set<String>) -> [String] {
        members.filter { liveIDs.contains($0) }
    }

    /// The live member with the keyboard: the focused one if it is live, else the first live one.
    public func focusedLive(in liveIDs: Set<String>) -> String? {
        if let focused, liveIDs.contains(focused) { return focused }
        return liveMembers(in: liveIDs).first
    }

    /// Whether there is a grid to show: two or more live members.
    public func isActive(liveIDs: Set<String>) -> Bool {
        liveMembers(in: liveIDs).count >= 2
    }
}
```

- [ ] **Step 4: Run them to verify they pass**

Run: `swift test --filter ProjectSplitTests`
Expected: 10 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/LinkCKit/Terminal/ProjectSplit.swift Tests/LinkCKitTests/ProjectSplitTests.swift
git commit -m "feat(split): a project's split members, focus and drop rules"
```

---

### Task 3: Persist splits in SidebarState

**Files:**
- Modify: `Sources/LinkCKit/Preferences/SidebarState.swift`:
  - the `Stored` struct (~line 14);
  - the stored properties (~line 35);
  - `init(defaults:)` (~line 71–142);
  - `save()` (~line 251);
  - the new accessors at the end.
- Test: `Tests/LinkCKitTests/SidebarStateTests.swift`

**Interfaces:**
- Consumes: `ProjectSplit` (Task 2).
- Produces:
  - `split(for project: String) -> ProjectSplit?`
  - `setSplit(_ split: ProjectSplit, for project: String)`
  - `clearSplit(for project: String)`
  - `projectsWithSplits: [String]` (canonical paths)

- [ ] **Step 1: Write the failing tests** (add to `SidebarStateTests`; the class already sets `defaults = InMemoryUserDefaults()`)

```swift
    func testASplitSurvivesARelaunch() {
        let state = SidebarState(defaults: defaults)
        state.setSplit(ProjectSplit(members: ["A", "B"], focused: "B"), for: "/tmp")
        let reloaded = SidebarState(defaults: defaults)
        XCTAssertEqual(reloaded.split(for: "/tmp"), ProjectSplit(members: ["A", "B"], focused: "B"))
        XCTAssertEqual(reloaded.projectsWithSplits, [ProjectPath.canonical("/tmp")])
    }

    func testClearingASplitForgetsIt() {
        let state = SidebarState(defaults: defaults)
        state.setSplit(ProjectSplit(members: ["A", "B"]), for: "/tmp")
        state.clearSplit(for: "/tmp")
        XCTAssertNil(SidebarState(defaults: defaults).split(for: "/tmp"))
    }

    /// A file written before splits existed has no `splits` key at all.
    func testAFileWithoutSplitsLoadsWithNone() throws {
        defaults.set(Data(#"{"projectOrder":["/a"],"expandOverrides":{},"openSections":[]}"#.utf8), forKey: SidebarState.key)
        let state = SidebarState(defaults: defaults)
        XCTAssertEqual(state.projectOrder, ["/a"])
        XCTAssertTrue(state.projectsWithSplits.isEmpty)
    }

    /// One unreadable split entry is dropped; the rest of the sidebar state, other splits included, loads.
    func testABadSplitEntryIsDroppedAndTheRestLoads() throws {
        let json = #"{"projectOrder":["/a"],"expandOverrides":{},"openSections":[],"splits":{"/a":{"members":["A","B"]},"/b":{"members":42}}}"#
        defaults.set(Data(json.utf8), forKey: SidebarState.key)
        let state = SidebarState(defaults: defaults)
        XCTAssertEqual(state.projectOrder, ["/a"])
        XCTAssertEqual(state.split(for: "/a")?.members, ["A", "B"])
        XCTAssertNil(state.split(for: "/b"))
    }
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter SidebarStateTests`
Expected: the build fails with `value of type 'SidebarState' has no member 'setSplit'`.

- [ ] **Step 3: Implement**

In `Stored`, add the field and the lenient entry type:

```swift        var openApps: [String: [OpenApp]]?
        var splits: [String: SplitEntry]?
    }

    /// One project's stored split. An entry that doesn't decode becomes an empty one rather than
    /// failing the whole `Stored` decode, so one bad split can't take the rest of the sidebar with it.
    private struct SplitEntry: Codable {
        let split: ProjectSplit?
        init(_ split: ProjectSplit) { self.split = split }
        init(from decoder: Decoder) throws { split = try? ProjectSplit(from: decoder) }
        func encode(to encoder: Encoder) throws { try split?.encode(to: encoder) }
    }
```

Add the property next to `openAppsByProject`:

```swift    private var splitsByProject: [String: ProjectSplit] = [:]
```

In `init`, after `openAppsByProject = …`:

```swift
        var readableSplits: [String: ProjectSplit] = [:]
        for (project, entry) in stored.splits ?? [:] {
            if let split = entry.split {
                readableSplits[project] = split
            } else {
                NSLog("[linkC] the stored split for %@ is unreadable — dropped", project)
            }
        }
        splitsByProject = Self.mergeCanonical(readableSplits, canonicalize: ProjectPath.canonical)
```

Extend `changed` with `|| Set((stored.splits ?? [:]).keys) != Set(splitsByProject.keys)`, so a canonicalized key or a dropped unreadable entry rewrites the file once.

In `save()`, pass `splits: splitsByProject.isEmpty ? nil : splitsByProject.mapValues(SplitEntry.init)` to the `Stored` initializer.

Add accessors at the end of the class:

```swift
    /// The project's split, if it has one.
    public func split(for project: String) -> ProjectSplit? {
        splitsByProject[ProjectPath.canonical(project)]
    }

    public func setSplit(_ split: ProjectSplit, for project: String) {
        let key = ProjectPath.canonical(project)
        guard splitsByProject[key] != split else { return }
        splitsByProject[key] = split
        save()
    }

    public func clearSplit(for project: String) {
        guard splitsByProject.removeValue(forKey: ProjectPath.canonical(project)) != nil else { return }
        save()
    }

    /// The canonical paths of every project with a stored split.
    public var projectsWithSplits: [String] { splitsByProject.keys.sorted() }
```

`SidebarState.key` is `static let key` and is used by the tests above. If it isn't visible to the test target, the class is already `@testable import`ed, so `static let` is enough.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter SidebarStateTests`
Expected: all tests pass, including the 4 new ones.

- [ ] **Step 5: Commit**

```bash
git add Sources/LinkCKit/Preferences/SidebarState.swift Tests/LinkCKitTests/SidebarStateTests.swift
git commit -m "feat(split): remember each project's split, dropping an unreadable entry"
```

---

### Task 4: TerminalHostView re-attach, opt-in focus, and focus reporting

**Files:**
- Modify: `Sources/LinkCKit/Terminal/TerminalContainer.swift` (the whole file is about 55 lines)
- Modify: `Sources/LinkCKit/Terminal/TerminalSession.swift`: `LinkCTerminalView` (`grep -n "class LinkCTerminalView"`)
- Test: `Tests/LinkCKitTests/TerminalHostViewTests.swift`

**Interfaces:**
- Produces:
  - `TerminalContainer(session: TerminalSession?, takesFocus: Bool = true, onFocus: (() -> Void)? = nil)`;
  - `TerminalHostView.show(_ view: NSView?, takesFocus: Bool = true)`;
  - `LinkCTerminalView.onFocus: (() -> Void)?`, called when the view becomes first responder.

Why: a split shows several hosts at once.
- A host must re-attach a view that another host borrowed, which today it skips because it still remembers the view.
- A host must not detach a view it no longer holds.
- Only the focused cell should grab the keyboard when it attaches.
- A click inside a pane must tell the model which pane has focus. The click goes to the terminal NSView, not to SwiftUI.

- [ ] **Step 1: Write the failing tests**

```swift
import AppKit
import XCTest
@testable import LinkCKit

@MainActor
final class TerminalHostViewTests: XCTestCase {
    /// One terminal view, two hosts: the grid cell borrows it, then its own tab shows it again.
    func testAHostReattachesAViewAnotherHostBorrowed() {
        let a = TerminalHostView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let b = TerminalHostView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let view = NSView()
        a.show(view)
        b.show(view)
        XCTAssertTrue(view.superview === b)
        a.show(view)
        XCTAssertTrue(view.superview === a, "the host must attach the view again even though it showed it last")
    }

    func testAHostNeverDetachesAViewItNoLongerHolds() {
        let a = TerminalHostView(frame: .zero)
        let b = TerminalHostView(frame: .zero)
        let view = NSView()
        a.show(view)
        b.show(view)
        a.show(nil)
        XCTAssertTrue(view.superview === b, "clearing a host must not pull the view out of the host now holding it")
    }

    func testOnlyAHostThatTakesFocusMakesTheViewFirstResponder() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        let host = TerminalHostView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        window.contentView = host
        let quiet = FocusableView()
        host.show(quiet, takesFocus: false)
        XCTAssertFalse(window.firstResponder === quiet)
        let eager = FocusableView()
        host.show(eager, takesFocus: true)
        XCTAssertTrue(window.firstResponder === eager)
    }

    func testATerminalViewReportsBecomingFirstResponder() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        let view = LinkCTerminalView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        window.contentView = view
        var focused = 0
        view.onFocus = { focused += 1 }
        window.makeFirstResponder(view)
        XCTAssertEqual(focused, 1)
    }
}

private final class FocusableView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter TerminalHostViewTests`
Expected: the build fails with `extra argument 'takesFocus'`. Once that compiles, the reattach and detach tests fail.

- [ ] **Step 3: Implement**

In `TerminalContainer.swift`:

```swift
public struct TerminalContainer: NSViewRepresentable {
    private let session: TerminalSession?
    private let takesFocus: Bool
    private let onFocus: (() -> Void)?

    /// `takesFocus`: grab the keyboard when the terminal is attached here — the single pane does,
    /// a split's cells only for the focused pane. `onFocus`: told when a click (or anything else)
    /// gives this terminal the keyboard.
    public init(session: TerminalSession?, takesFocus: Bool = true, onFocus: (() -> Void)? = nil) {
        self.session = session
        self.takesFocus = takesFocus
        self.onFocus = onFocus
    }

    public func makeNSView(context: Context) -> TerminalHostView {
        TerminalHostView(frame: .zero)
    }

    public func updateNSView(_ nsView: TerminalHostView, context: Context) {
        session?.terminalView.onFocus = onFocus
        nsView.show(session?.terminalView, takesFocus: takesFocus)
    }
}
```

Replace `TerminalHostView.show`:

```swift
    /// Show `view` (or nothing). Detaching the previously shown terminal leaves it — and its
    /// PTY — fully alive; it is only removed from the view hierarchy until reselected. A terminal
    /// moves between hosts (its own tab, a split cell), so "shown last" is not "still here": a view
    /// another host has since taken is attached again, and one this host no longer holds is never
    /// pulled out of the host that does.
    func show(_ view: NSView?, takesFocus: Bool = true) {
        if let view, shown === view, view.superview === self {
            view.frame = bounds
            return
        }
        if let shown, shown !== view, shown.superview === self {
            shown.removeFromSuperview()
        }
        shown = view
        guard let view else { return }
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        if takesFocus { window?.makeFirstResponder(view) }
    }
```

In `LinkCTerminalView` (TerminalSession.swift), add:

```swift
    /// Told whenever this terminal gets the keyboard — a split uses it to follow which pane has focus.
    public var onFocus: (() -> Void)?

    public override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocus?() }
        return became
    }
```

If `LinkCTerminalView` is not `public` or `open` enough for `override`, keep it at its current access level. Only `onFocus` needs to be visible to `TerminalContainer`, which is in the same module.

- [ ] **Step 4: Run the tests to verify they pass, then the terminal suites**

Run: `swift test --filter 'TerminalHostViewTests|TerminalSessionTests'`
Expected: all pass. The existing single-pane behavior is unchanged, because `takesFocus` defaults to true.

- [ ] **Step 5: Commit**

```bash
git add Sources/LinkCKit/Terminal/TerminalContainer.swift Sources/LinkCKit/Terminal/TerminalSession.swift Tests/LinkCKitTests/TerminalHostViewTests.swift
git commit -m "fix(terminal): a host re-attaches a terminal another host borrowed, and focus is opt-in and reported"
```

---

### Task 5: The Split tab and the model's split state

**Files:**
- Modify: `Sources/LinkCKit/Board/ProjectTabs.swift`
- Test: `Tests/LinkCKitTests/ProjectTabsTests.swift`
- Modify (app target):
  - `Sources/linkc/LinkCApp.swift`;
  - `Sources/linkc/AppModel+Sidebar.swift`;
  - `Sources/linkc/Board/ProjectTabStrip.swift`: the `TabChip` icon switch, and the `requestClose` path if it switches on `kind`.

**Interfaces:**
- Consumes: `ProjectSplit` and `SidebarState.split(for:)` / `setSplit` / `clearSplit` / `projectsWithSplits` (Tasks 2–3).
- Produces:
  - In LinkCKit:
    - `ProjectTab.Kind.split`;
    - `ProjectTabs.splitID(canonical:) -> String`;
    - `ProjectTabs.tabs(..., split: ProjectSplit? = nil)`.
  - On `AppModel`:
    - `splitProject: String?`;
    - `splittableIDs(in:) -> Set<String>`;
    - `showSplit(_:)`, `focusInSplit(_:)`, `removeFromSplit(_:)`, `dissolveSplit(_:)`;
    - `liveSplitMembers(in:) -> [String]`, `focusedSplitMember(in:) -> String?`;
    - `terminalSession(_:) -> TerminalSession?`.

- [ ] **Step 1: Write the failing ProjectTabs tests** (add to `ProjectTabsTests`; follow the file's existing helpers for building `Session` / `ShellRow` values, as its current tests do)

```swift
    func testAnActiveSplitIsTheTabAfterTheBoard() {
        let project = ProjectPath.canonical(NSTemporaryDirectory())
        let a = Session(id: "A", cwd: project, title: "a")
        let b = Session(id: "B", cwd: project, title: "b")
        let tabs = ProjectTabs.tabs(project: project, sessions: [a, b], shells: [], titles: [:],
                                    split: ProjectSplit(members: ["A", "B"], focused: "A"))
        XCTAssertEqual(tabs.map(\.id), [ProjectTabs.boardID(canonical: project), ProjectTabs.splitID(canonical: project), "A", "B"])
        XCTAssertEqual(tabs[1].kind, .split)
        XCTAssertEqual(tabs[1].title, "Split")
        XCTAssertFalse(tabs[1].isWorking, "closing a split stops nothing, so it never asks first")
    }

    func testASplitWithFewerThanTwoLiveMembersHasNoTab() {
        let project = ProjectPath.canonical(NSTemporaryDirectory())
        let a = Session(id: "A", cwd: project, title: "a")
        let tabs = ProjectTabs.tabs(project: project, sessions: [a], shells: [], titles: [:],
                                    split: ProjectSplit(members: ["A", "GONE"]))
        XCTAssertFalse(tabs.contains { $0.kind == .split })
    }
```

If `Session`'s initializer needs more arguments, use the same construction the existing `ProjectTabsTests` use.

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter ProjectTabsTests`
Expected: the build fails with `extra argument 'split'`.

- [ ] **Step 3: Implement the ProjectTabs part**

Add `case split` to `ProjectTab.Kind`. Add:

```swift
    /// The Split tab's id for a canonical project path.
    public static func splitID(canonical path: String) -> String {
        "split:" + path
    }
```

Give `tabs(...)` a trailing `split: ProjectSplit? = nil` parameter. Build the other tabs as today, then insert the Split tab at index 1 when it is active:

```swift
        if let split {
            let liveIDs = Set(tabs.lazy.filter { tab in
                switch tab.kind {
                case .agent, .terminal: return true
                default: return false
                }
            }.map(\.id))
            if split.isActive(liveIDs: liveIDs) {
                tabs.insert(ProjectTab(id: splitID(canonical: folder), kind: .split, title: "Split", isWorking: false), at: 1)
            }
        }
        return tabs
```

Update the doc comment on `tabs(...)` to mention the Split tab after the Board.

- [ ] **Step 4: Run them to verify they pass**

Run: `swift test --filter ProjectTabsTests`
Expected: all pass.

- [ ] **Step 5: Model state and selection rules (app target)**

The app target has no unit tests, so this step is verified by the build and by the manual checks in Task 7. Everything goes in `LinkCApp.swift` (the `AppModel` class) unless noted.

1. State, next to `boardProject` and `appTab`:

```swift
    /// The project whose Split tab is showing, or nil. Written only by `showSplit`, `showSelection`,
    /// `showBoard`, `showApp`, `select(_:)`, `dissolveSplit` and `goBack` — never by a view.
    private(set) var splitProject: String?
```

2. Helpers:

```swift
    /// The terminals that may sit in `project`'s split: its sessions and the shell terminals filed
    /// under it — exactly what its tab strip lists.
    func splittableIDs(in project: String) -> Set<String> {
        let tabs = ProjectTabs.tabs(project: project, sessions: sessions, shells: shellRows,
                                    filed: sidebarState.terminalProjects, titles: [:])
        return Set(tabs.lazy.filter { tab in
            switch tab.kind {
            case .agent, .terminal: return true
            default: return false
            }
        }.map(\.id))
    }

    func liveSplitMembers(in project: String) -> [String] {
        sidebarState.split(for: project)?.liveMembers(in: splittableIDs(in: project)) ?? []
    }

    func focusedSplitMember(in project: String) -> String? {
        sidebarState.split(for: project)?.focusedLive(in: splittableIDs(in: project))
    }

    func terminalSession(_ id: String) -> TerminalSession? {
        coordinator?.terminals.session(id: id)
    }
```

3. Showing and leaving the split:

```swift
    /// Shows `project`'s Split tab, its focused live member selected. Does nothing when the project
    /// has no active split.
    func showSplit(_ project: String) {
        let key = ProjectTabs.standardized(project)
        guard let target = focusedSplitMember(in: key), liveSplitMembers(in: key).count >= 2 else { return }
        splitProject = key   // first, so the selection callback below keeps it
        focus(target)
        boardProject = nil
        appTab = nil
        activeScreen = nil
    }

    /// A pane in the showing split got the keyboard (a click inside it): remember it as the
    /// split's focus and select it, keeping the grid on screen.
    func focusInSplit(_ id: String) {
        guard let project = splitProject, let split = sidebarState.split(for: project), split.members.contains(id) else { return }
        sidebarState.setSplit(split.focusing(id), for: project)
        if selectedId != id { focus(id) }
    }

    /// Takes `id` out of the current project's split; the session keeps running. Fewer than two
    /// panes left dissolves the split.
    func removeFromSplit(_ id: String) {
        guard let project = currentProject, let split = sidebarState.split(for: project) else { return }
        let next = split.removing(id)
        if next.liveMembers(in: splittableIDs(in: project)).count < 2 {
            dissolveSplit(project)
        } else {
            sidebarState.setSplit(next, for: project)
            if splitProject != nil, let focus = next.focusedLive(in: splittableIDs(in: project)), selectedId != focus {
                self.focus(focus)
            }
        }
    }

    /// Forgets `project`'s split. The terminal that had the focus stays selected, shown on its own.
    func dissolveSplit(_ project: String) {
        let key = ProjectTabs.standardized(project)
        let focusID = focusedSplitMember(in: key)
        sidebarState.clearSplit(for: key)
        if splitProject == key {
            splitProject = nil
            if let focusID, selectedId != focusID { focus(focusID) }
        }
    }
```

4. Selection rules:
   - `showSelection()` keeps the split only when the newly selected terminal is one of its members. Insert this at the top:

```swift
        if let splitProject {
            let isMember = selectedId.map { sidebarState.split(for: splitProject)?.members.contains($0) ?? false } ?? false
            if !isMember { self.splitProject = nil }
        }
```

   - In `showBoard(_:)` and `showApp(_:)`, add `splitProject = nil`.
   - In `goBack()`, add a branch after the `appTab` one:

```swift
        } else if splitProject != nil {
            splitProject = nil
            coordinator?.terminals.deselect()
```

   - In `selectedTabID`, after the `boardProject` line, add `if let splitProject { return ProjectTabs.splitID(canonical: splitProject) }`.
   - In `currentProject`, after the `boardProject` line, add `if let splitProject { return splitProject }`.
   - In `select(_:)`, add `case .split: if let project = currentProject { showSplit(project) }`, and make `case .agent, .terminal:` set `splitProject = nil` before `focus(tab.id)`. A member's own tab then shows it full-size.
   - In `close(_:)`, add `case .split: if let project = currentProject { dissolveSplit(project) }`.
   - In `projectTabs`, pass `split: sidebarState.split(for: project)` to `ProjectTabs.tabs`.

5. Pruning, in `AppModel+Sidebar.swift` `sampleSidebar()`, after the attention and seen lines:

```swift
        // A split keeps the terminals that are live or can still be restored; fewer than two left
        // is no split.
        let known = Set(sessions.map(\.id)).union(shellRows.map(\.id)).union(restorables.map(\.linkcId))
        for project in sidebarState.projectsWithSplits {
            guard let split = sidebarState.split(for: project) else { continue }
            let pruned = split.pruned(keeping: known)
            if pruned.members.count < 2 {
                dissolveSplit(project)
            } else if pruned != split {
                sidebarState.setSplit(pruned, for: project)
            }
        }
        if let splitProject, liveSplitMembers(in: splitProject).count < 2 { dissolveSplit(splitProject) }
```

6. In `ProjectTabStrip.swift` `TabChip`, add a `case .split:` that shows `Image(systemName: "square.split.2x2").font(.system(size: 10))`. Wherever the strip asks before closing a working tab, `.split` never asks, because its `isWorking` is false. The close button's `.help` reads "Close the split" for `.split`, and stays "Stop this session" otherwise.

- [ ] **Step 6: Build and run the full suite**

Run: `swift build --build-tests 2>&1 | grep -cE "warning:|error:"` (expect 0), then `swift test`.
Expected: 0 warnings and all tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/LinkCKit/Board/ProjectTabs.swift Tests/LinkCKitTests/ProjectTabsTests.swift Sources/linkc/LinkCApp.swift Sources/linkc/AppModel+Sidebar.swift Sources/linkc/Board/ProjectTabStrip.swift
git commit -m "feat(split): the Split tab and the panel's split state"
```

---

### Task 6: SplitPane

**Files:**
- Create: `Sources/linkc/SplitPane.swift`
- Modify: `Sources/linkc/PanelView.swift`:
  - `Pane` (~line 63): add `case split(String)`;
  - `RightPane` (~line 95): route to `SplitPane` before the board/app branches;
  - the terminal styling in `TerminalPane`.

**Interfaces:**
- Consumes:
  - `SplitLayout.rowRanges(for:)`;
  - `AppModel.liveSplitMembers(in:)`, `focusedSplitMember(in:)`, `terminalSession(_:)`, `focusInSplit(_:)`, `removeFromSplit(_:)`;
  - `TerminalContainer(session:takesFocus:onFocus:)`;
  - the sidebar's existing status-dot drawing.
- Produces: `struct SplitPane: View { init(model: AppModel, project: String) }`, and a shared `TerminalStyle.apply(to: TerminalSession?)`.

- [ ] **Step 1: Share the terminal styling.** Move `TerminalPane.styleTerminal(_:)`'s body into a small app-target helper, `enum TerminalStyle { @MainActor static func apply(to session: TerminalSession?) }`, with the same font, background and layer clearing. Have `TerminalPane` call it where it called `styleTerminal`.

- [ ] **Step 2: Write `SplitPane.swift`**

```swift
import LinkCKit
import SwiftUI

/// A project's Split tab: its live split members in an even grid (see `SplitLayout`), each a full
/// live terminal. A click inside a pane gives it the keyboard and the focus outline; the title row's
/// × takes it out of the split (its session keeps running).
struct SplitPane: View {
    let model: AppModel
    let project: String

    var body: some View {
        let ids = model.liveSplitMembers(in: project)
        let focused = model.focusedSplitMember(in: project)
        VStack(spacing: 6) {
            ForEach(SplitLayout.rowRanges(for: ids.count), id: \.lowerBound) { range in
                HStack(spacing: 6) {
                    ForEach(ids[range], id: \.self) { id in
                        SplitCell(model: model, id: id, isFocused: id == focused)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }
}

private struct SplitCell: View {
    let model: AppModel
    let id: String
    let isFocused: Bool
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                // Reuse the sidebar's status dot for sessions; shell terminals show none.
                Text(model.splitPaneTitle(id))
                    .font(.system(size: 11))
                    .foregroundStyle(isFocused ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button { model.removeFromSplit(id) } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .opacity(hovering ? 1 : 0)
                .help("Take out of the split (keeps it running)")
            }
            .padding(.horizontal, 4)
            .draggable(LinkCTerminalDrag(id: id))
            TerminalContainer(session: model.terminalSession(id), takesFocus: isFocused,
                              onFocus: { model.focusInSplit(id) })
                .clipShape(RoundedRectangle(cornerRadius: Theme.terminalRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.terminalRadius, style: .continuous)
                        .stroke(Theme.accent.opacity(isFocused ? 0.55 : 0), lineWidth: 1)
                }
        }
        .onHover { hovering = $0 }
        .onAppear { TerminalStyle.apply(to: model.terminalSession(id)) }
    }
}
```

Add `func splitPaneTitle(_ id: String) -> String` to `AppModel`. It returns `sessionTitles[id] ?? sessions.first { $0.id == id }?.title ?? shellRows.first { $0.id == id }?.title ?? id`; use whatever the model already names its live-title map. Add the session's status dot to the title row the same way the sidebar draws it (`Sidebar.swift` ~395–400). If that view is `private`, lift it into a small shared view rather than copying it.

- [ ] **Step 3: Route the Split tab.** In `PanelView.swift`:
  - In `Pane.init`, add `else if let split = model.splitProject { self = .split(split) }` before the `appTab` line.
  - In `RightPane`, inside the `currentProject != nil` branch, add `if let split = model.splitProject { SplitPane(model: model, project: split).id(split) } else if let board = …`, keeping the existing board/app/terminal branches.

- [ ] **Step 4: Build and run the suite**

Run: `swift build --build-tests 2>&1 | grep -cE "warning:|error:"` (expect 0), then `swift test`.
Expected: 0 warnings and all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/linkc/SplitPane.swift Sources/linkc/PanelView.swift Sources/linkc/LinkCApp.swift
git commit -m "feat(split): show a project's split as an even grid of live terminals"
```

---

### Task 7: Drag to split

**Files:**
- Create: `Sources/linkc/TerminalDropTarget.swift`
- Modify:
  - `Sources/linkc/LinkCApp.swift`: `dropTerminal(_:onto:edge:)`;
  - `Sources/linkc/PanelView.swift`: the drop target on the single terminal;
  - `Sources/linkc/SplitPane.swift`: the drop target on each cell;
  - `Sources/linkc/Board/ProjectTabStrip.swift`: draggable chips and a strip drop that removes.

**Interfaces:**
- Consumes:
  - `SplitLayout.edge(at:in:)`;
  - `ProjectSplit.adding(_:onto:edge:)` and `ProjectSplit.Refusal`;
  - `AppModel.splittableIDs(in:)`, `showSplit(_:)`, `removeFromSplit(_:)`;
  - `LinkCTerminalDrag` and `UTType.linkcTerminal` (`Sidebar.swift`).
- Produces:
  - `AppModel.dropTerminal(_ id: String, onto target: String, edge: SplitEdge)`;
  - `View.terminalDropTarget(model:target:)`.

- [ ] **Step 1: The model's drop rule** (in `LinkCApp.swift`)

```swift
    /// `id` dragged onto `edge` of the terminal `target` in the current project: makes the project's
    /// split if `target` isn't in one yet, or adds/moves within it, then shows the split. A terminal
    /// from another project, or a ninth pane, is refused and the error bar says why.
    func dropTerminal(_ id: String, onto target: String, edge: SplitEdge) {
        guard id != target, let project = currentProject else { return }
        let allowed = splittableIDs(in: project)
        guard allowed.contains(id), allowed.contains(target) else {
            lastError = "That terminal belongs to another project — a split only holds this project's terminals."
            return
        }
        let current = sidebarState.split(for: project).map { $0.members.contains(target) ? $0 : nil } ?? nil
        let base = current ?? ProjectSplit(members: [target], focused: target)
        do {
            let next = try base.adding(id, onto: target, edge: edge)
            lastError = nil
            sidebarState.setSplit(next, for: project)
            showSplit(project)
        } catch ProjectSplit.Refusal.full {
            lastError = "This split already shows \(SplitLayout.maxPanes) terminals."
        } catch {
            lastError = "Couldn't split: \(error)"
        }
    }
```

There is at most one split per project. If `target` isn't in the existing split (the user dropped onto a single terminal's tab view while a split exists), the new split replaces it, starting from `[target]`. That is the simple, predictable rule: dropping onto a terminal always splits with that terminal.

- [ ] **Step 2: The drop target** (`TerminalDropTarget.swift`)

```swift
import LinkCKit
import SwiftUI
import UniformTypeIdentifiers

extension View {
    /// Lets a linkC terminal be dropped on this terminal's edges to split with it. While a drag
    /// hovers, the edge it would land on is highlighted.
    func terminalDropTarget(model: AppModel, target: String?) -> some View {
        modifier(TerminalDropTargetModifier(model: model, target: target))
    }
}

private struct TerminalDropTargetModifier: ViewModifier {
    let model: AppModel
    let target: String?
    @State private var hovered: SplitEdge?

    func body(content: Content) -> some View {
        GeometryReader { geometry in
            content
                .overlay(alignment: .topLeading) { EdgeHighlight(edge: hovered, size: geometry.size) }
                .onDrop(of: [.linkcTerminal], delegate: TerminalDropDelegate(
                    model: model, target: target, size: geometry.size, hovered: $hovered))
        }
    }
}

private struct EdgeHighlight: View {
    let edge: SplitEdge?
    let size: CGSize

    var body: some View {
        if let edge {
            let half = CGSize(
                width: edge == .left || edge == .right ? size.width / 2 : size.width,
                height: edge == .top || edge == .bottom ? size.height / 2 : size.height)
            RoundedRectangle(cornerRadius: Theme.terminalRadius, style: .continuous)
                .fill(Theme.accent.opacity(0.12))
                .overlay(RoundedRectangle(cornerRadius: Theme.terminalRadius, style: .continuous)
                    .stroke(Theme.accent.opacity(0.5), lineWidth: 1))
                .frame(width: half.width, height: half.height)
                .offset(x: edge == .right ? size.width / 2 : 0, y: edge == .bottom ? size.height / 2 : 0)
                .allowsHitTesting(false)
        }
    }
}

@MainActor
private struct TerminalDropDelegate: DropDelegate {
    let model: AppModel
    let target: String?
    let size: CGSize
    @Binding var hovered: SplitEdge?

    func validateDrop(info: DropInfo) -> Bool {
        target != nil && info.hasItemsConforming(to: [.linkcTerminal])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        hovered = SplitLayout.edge(at: info.location, in: size)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { hovered = nil }

    func performDrop(info: DropInfo) -> Bool {
        let edge = SplitLayout.edge(at: info.location, in: size)
        hovered = nil
        guard let target, let provider = info.itemProviders(for: [.linkcTerminal]).first else { return false }
        _ = provider.loadTransferable(type: LinkCTerminalDrag.self) { result in
            Task { @MainActor in
                switch result {
                case .success(let drag): model.dropTerminal(drag.id, onto: target, edge: edge)
                case .failure(let error): model.lastError = "Couldn't read the dragged terminal: \(error.localizedDescription)"
                }
            }
        }
        return true
    }
}
```

`model.lastError` must be settable from this file. If its setter is `private`, add a narrow `func reportDropFailure(_ message: String)` on `AppModel` instead.

- [ ] **Step 3: Attach the targets and drag sources**
  - `PanelView.swift` `TerminalPane.terminal`: add `.terminalDropTarget(model: model, target: model.selectedId)` to the `TerminalContainer`'s `ZStack`.
  - `SplitPane.swift` `SplitCell`: add `.terminalDropTarget(model: model, target: id)` to the `TerminalContainer`.
  - `ProjectTabStrip.swift` `TabChip`: for `.agent` and `.terminal` tabs, add `.draggable(LinkCTerminalDrag(id: tab.id))`, keeping the tap-to-select.
  - `ProjectTabStrip.swift`: on the session tabs' scroll content, add a drop that removes a split member:

```swift
                        .dropDestination(for: LinkCTerminalDrag.self) { items, _ in
                            guard model.splitProject != nil, let id = items.first?.id,
                                  model.liveSplitMembers(in: model.splitProject!).contains(id) else { return false }
                            model.removeFromSplit(id)
                            return true
                        }
```

  The sidebar's existing drop targets already ignore anything that isn't a shell terminal (`droppedTerminalID`), so draggable session chips can't be filed by mistake.

- [ ] **Step 4: Build and run the suite**

Run: `swift build --build-tests 2>&1 | grep -cE "warning:|error:"` (expect 0), then `swift test`. Also run `./scripts/tsan.sh --filter 'TerminalHostView|SidebarState|ProjectTabs|ProjectSplit|SplitLayout'`.
Expected: 0 warnings, all tests pass, and TSan is clean.

- [ ] **Step 5: Manual checks (the app target has no UI test harness)**

Build the app with `./build-app.sh` and install it through the update strip, or have the controller do it. Then confirm each of these:
1. Dragging a tab chip onto the right edge of the shown terminal creates a Split tab after Board, holding both.
2. Dragging more chips onto cells grows it to 8. A ninth drop shows the error bar.
3. Dropping a pane's title row onto another cell moves it.
4. A pane's × removes it. At one pane left, the Split tab disappears and the remaining terminal shows alone.
5. Dragging a pane's title row onto the tab strip removes it.
6. Clicking inside a pane moves the focus outline there, and typing goes to it.
7. A member's own tab shows it full-size, and the Split tab shows the grid again.
8. Stopping a member's session reflows the grid.
9. Quitting and relaunching, then restoring the sessions, brings the split back.

- [ ] **Step 6: Commit**

```bash
git add Sources/linkc/TerminalDropTarget.swift Sources/linkc/LinkCApp.swift Sources/linkc/PanelView.swift Sources/linkc/SplitPane.swift Sources/linkc/Board/ProjectTabStrip.swift
git commit -m "feat(split): drag a terminal onto another's edge to split, onto the tab strip to take it out"
```

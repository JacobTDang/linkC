# Project Board Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the workbench band with a whiteboard in its own Chrome-style tab above the terminal — an empty canvas of components, arrows, frames, notes and text — saved as an architecture-first `system-map.json` that agents read.

**Architecture:** Pure, tested types in `Sources/LinkCKit/Board/` carry every rule: the version-2 file model and its upgrade from version 1, the store with its changed-on-disk check, the reconciler, the MCP report, canvas geometry (collisions, containment, arrow routing, culling, viewport maths), the main-actor board model (edits, undo, write rules), and the tab and key mappings. The app target draws them: a tab strip in the right pane, a Board row in the sidebar, and a canvas whose grid, frames and arrows are one `Canvas` pass with lightweight element views on a single transformed layer. Keys, scroll and pinch reach the board through `NSEvent` local monitors installed only while it is showing.

**Tech Stack:** Swift 6 (strict concurrency), SwiftPM, macOS 14, SwiftUI + AppKit, XCTest. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-09-23-project-board-design.md`

## Global Constraints

- No new dependencies or packages. SwiftUI and AppKit only. `NSEvent` *local* monitors are allowed (they need no Accessibility permission); global monitors are not.
- Test-driven: write the failing test first, run it and see it fail, then implement. Mock data only in tests.
- Fail loud: no swallowed errors, no silent fallbacks. A file that cannot be read locks the board and says why; a failed write stays retryable and says so.
- The map is `system-map.json` at the project root, version 2, exactly the shape in the spec: `version`, `system`, `places` (every frame label plus the reserved `"Not placed"`, always written), `notes`, `layout` (`components` → `[x, y]`, `frames` → `[x, y, w, h]`, `notes` → `[x, y]` or `null` by index, `texts` → `{text, style, at: [x, y], w}`). Pretty-printed, sorted keys, every coordinate snapped to 8.
- A component's known keys in version 2: `kind`, `does`, `reached_by`, `runs`, `status` (only ever `"planned"`), `uses` (target name → label, `""` when unlabelled), `used_by` (version-1 names that were not components, kept verbatim). Everything else in a component, in `layout`, and at the top level is preserved unchanged.
- Component names are unique across the file, compared case-insensitively. Frame labels are unique, compared case-insensitively, and none may equal `"Not placed"` in any case.
- Sizes on the canvas: component 152 × 56; note 176 × 120; text height 32 for `title`, 20 for `label`, width stored per text.
- Collision rules (spec §2 "Collisions"): components, notes and texts never overlap; frames never overlap; an element is wholly inside a frame or wholly outside it, decided by its centre; nearest free spot is the smallest move on the 8-point grid, ties broken right, down, left, up; a frame move carries its components; arrows leave from facing sides and bend above or below a blocking component or note, else go direct.
- Never write without an edit. Opening, panning, zooming, selecting and reconciling never write. The first edit on a project with no map creates the file. A version-1 file is written as version 2 on its first edit, never on open.
- Before any write, the file must still hold exactly the bytes linkC last read (or still be absent). Otherwise the write is refused and the board says the map changed on disk.
- Power: nothing runs while the Board is not showing (no timers, no polling, no monitors); the board starts no process; redraw only on change; one `Canvas` pass for grid, frames and arrows; elements outside the viewport are not built; a drag moves one element and routing and collision run on release; one write per burst of edits.
- Commits: author is the repo's configured git user. Commit messages must NOT contain the word "claude" in any case (including inside a path like `.claude/`), and must carry no trailers of any kind — no `Co-Authored-By`, `Claude-Session`, or `Generated with`. After each commit run `git log -1 --format=%B | grep -ic claude` and confirm it prints `0`.
- Before committing, run `git diff --cached --stat` and confirm only the intended files are staged. Never `git add -A`.
- Tests: `swift test --filter <TestClass>`; full suite `swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1`. Baseline on `main`: 1097 tests, 5 skipped, 0 failures.

---

### Task 1: Remove the band the board replaces

**Files:**
- Delete: `Sources/linkc/WorkbenchBand.swift`
- Delete: `Sources/LinkCKit/Workbench/WorkbenchModel.swift`
- Delete: `Sources/LinkCKit/Workbench/WorkbenchLayout.swift`
- Delete: `Tests/LinkCKitTests/WorkbenchModelTests.swift`
- Delete: `Tests/LinkCKitTests/WorkbenchLayoutTests.swift`
- Modify: `Sources/linkc/ProjectDashboardSheet.swift` (remove the band's mount; restore the sheet's size)
- Modify: `Sources/LinkCKit/Preferences/SidebarState.swift` and `Tests/LinkCKitTests/SidebarStateTests.swift` (remove the band's open/closed preference)

**Interfaces:**
- Consumes: nothing.
- Produces: a build with no band. `SystemMap`, `SystemMapStore`, `SystemReconciler`, `SystemMapReport`, `DiscoveredThing` and `AppModel.discoveredThings(in:)` stay untouched — Task 3 replaces them.

- [ ] **Step 1: Delete the band and its model**

```bash
git rm Sources/linkc/WorkbenchBand.swift \
  Sources/LinkCKit/Workbench/WorkbenchModel.swift \
  Sources/LinkCKit/Workbench/WorkbenchLayout.swift \
  Tests/LinkCKitTests/WorkbenchModelTests.swift \
  Tests/LinkCKitTests/WorkbenchLayoutTests.swift
```

- [ ] **Step 2: Unmount it from the dashboard sheet**

In `Sources/linkc/ProjectDashboardSheet.swift`, delete the line `WorkbenchBand(workspacePath: workspacePath, model: model)` (and nothing else around it), and change `.frame(width: 720, height: 620)` back to:

```swift
        .frame(width: 600, height: 520)
```

- [ ] **Step 3: Remove the band's preference**

In `Sources/LinkCKit/Preferences/SidebarState.swift`:
- delete `var workbenchClosed: [String: Bool]?` from the private `Stored` struct;
- delete the `private var workbenchClosed` stored property, its line in `init` that reads `stored.workbenchClosed`, the `isWorkbenchOpen(_:)` and `setWorkbenchOpen(_:_:)` methods, and the `workbenchClosed` filtering inside `prune(keeping:)`;
- in `save()`, construct `Stored` without `workbenchClosed:`.

An older saved blob that still holds a `workbenchClosed` key keeps decoding: `JSONDecoder` ignores keys the struct does not declare.

In `Tests/LinkCKitTests/SidebarStateTests.swift`, delete the tests that exercise `isWorkbenchOpen` / `setWorkbenchOpen` and the prune-of-closed-boards test (grep for `Workbench`).

- [ ] **Step 4: Build and test**

Run: `grep -rn "WorkbenchBand\|WorkbenchModel\|WorkbenchLayout\|isWorkbenchOpen\|setWorkbenchOpen\|workbenchClosed" Sources Tests`
Expected: no output.

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`

Run: `swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1`
Expected: 0 failures (the count drops by the deleted tests).

- [ ] **Step 5: Commit**

```bash
git add -A Sources/linkc/WorkbenchBand.swift Sources/LinkCKit/Workbench Tests/LinkCKitTests/WorkbenchModelTests.swift Tests/LinkCKitTests/WorkbenchLayoutTests.swift
git add Sources/linkc/ProjectDashboardSheet.swift Sources/LinkCKit/Preferences/SidebarState.swift Tests/LinkCKitTests/SidebarStateTests.swift
git diff --cached --stat
git commit -m "refactor(workbench): remove the band the board replaces"
git log -1 --format=%B | grep -ic claude   # must print 0
```

---

### Task 2: The version-2 map

**Files:**
- Create: `Sources/LinkCKit/Board/ComponentKind.swift` (moved out of `Sources/LinkCKit/Workbench/SystemMap.swift`)
- Modify: `Sources/LinkCKit/Workbench/SystemMap.swift` (delete its `ComponentKind` declaration — it now lives in its own file)
- Create: `Sources/LinkCKit/Board/BoardMap.swift`
- Test: `Tests/LinkCKitTests/BoardMapTests.swift`

**Interfaces:**
- Consumes: `LinkCError.parse(String)` (existing).
- Produces:
  - `struct BoardPoint: Hashable, Sendable` — `x: Int`, `y: Int`, `init(x:y:)`, `static let grid = 8`, `var snapped: BoardPoint`
  - `struct BoardRect: Hashable, Sendable` — `x, y, w, h: Int`, `init(x:y:w:h:)`, `minX/minY/maxX/maxY`, `center: BoardPoint`, `origin: BoardPoint`, `intersects(_:)`, `contains(_ point:)`, `contains(_ rect:)`, `offsetBy(dx:dy:)`, `snapped`
  - `struct ComponentKind` — unchanged from today (`raw`, the seven statics, `known`, `isKnown`)
  - `struct BoardComponent: Equatable, Sendable, Identifiable` — `name`, `kind`, `does: String?`, `reachedBy: String?`, `runs: String?`, `planned: Bool`, `uses: [String: String]`, `legacyUsedBy: [String]`, `place: String`, `at: BoardPoint?`; internal `extras: Data?`
  - `struct BoardFrame: Equatable, Sendable, Identifiable` — `label`, `rect: BoardRect?`
  - `enum BoardTextStyle: String, Sendable { case title, label }`
  - `struct BoardNote: Equatable, Sendable, Identifiable` — `id: UUID`, `text`, `at: BoardPoint?`
  - `struct BoardText: Equatable, Sendable, Identifiable` — `id: UUID`, `text`, `style`, `at: BoardPoint`, `width: Int`
  - `struct BoardMap: Equatable, Sendable` — `static let notPlaced = "Not placed"`, `system: String?`, `components`, `frames`, `notes`, `texts`, `sourceVersion: Int` (1 for an upgraded file), internal `extras: Data?`, `layoutExtras: Data?`, `static let empty`, `static func decode(_ data: Data) throws -> BoardMap`, `func encoded() throws -> Data`

`BoardMap` coexists with the old `SystemMap` until Task 3 removes it. Do not touch any other file under `Sources/LinkCKit/Workbench/` beyond moving `ComponentKind` out.

- [ ] **Step 1: Move `ComponentKind`**

Create `Sources/LinkCKit/Board/ComponentKind.swift` with the `ComponentKind` struct copied verbatim from `Sources/LinkCKit/Workbench/SystemMap.swift` (its doc comment, `raw`, `init`, the seven statics, `known`, `isKnown`), then delete that declaration from `SystemMap.swift`. Run `swift build 2>&1 | tail -3` — expected `Build complete!` (same module, so nothing else changes).

- [ ] **Step 2: Write the failing tests**

Create `Tests/LinkCKitTests/BoardMapTests.swift`:

```swift
import XCTest
@testable import LinkCKit

final class BoardMapTests: XCTestCase {
    private let june = Data("""
    {
      "version": 2,
      "system": "June — audio journaling",
      "places": {
        "Local docker": {
          "api": { "kind": "service", "does": "HTTP api", "reached_by": "API_URL", "runs": "docker compose (api)",
                   "uses": { "postgres": "reads and writes entries", "redis": "" } },
          "postgres": { "kind": "database", "reached_by": "DATABASE_URL" },
          "redis": { "kind": "cache", "status": "planned" }
        },
        "Oracle box": { "june-audio": { "kind": "host", "does": "serves mp3s" } },
        "Not placed": {}
      },
      "notes": ["Redis is for the session cache.", "Stream uploads."],
      "layout": {
        "components": { "api": [64, 128], "postgres": [232, 128] },
        "frames": { "Local docker": [40, 96, 344, 200], "Oracle box": [408, 96, 192, 112] },
        "notes": [[640, 112], null],
        "texts": [{ "text": "June", "style": "title", "at": [32, 32], "w": 64 }]
      }
    }
    """.utf8)

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testAVersionTwoFileDecodes() throws {
        let map = try BoardMap.decode(june)
        XCTAssertEqual(map.sourceVersion, 2)
        XCTAssertEqual(map.system, "June — audio journaling")
        XCTAssertEqual(map.frames.map(\.label), ["Local docker", "Oracle box"])
        XCTAssertEqual(map.frames.first?.rect, BoardRect(x: 40, y: 96, w: 344, h: 200))

        let api = try XCTUnwrap(map.components.first { $0.name == "api" })
        XCTAssertEqual(api.place, "Local docker")
        XCTAssertEqual(api.kind, .service)
        XCTAssertEqual(api.does, "HTTP api")
        XCTAssertEqual(api.runs, "docker compose (api)")
        XCTAssertEqual(api.uses, ["postgres": "reads and writes entries", "redis": ""])
        XCTAssertEqual(api.at, BoardPoint(x: 64, y: 128))
        XCTAssertFalse(api.planned)

        let redis = try XCTUnwrap(map.components.first { $0.name == "redis" })
        XCTAssertTrue(redis.planned)
        XCTAssertNil(redis.at, "a component with no layout entry has no position yet")
        XCTAssertEqual(map.components.first { $0.name == "june-audio" }?.place, "Oracle box")

        XCTAssertEqual(map.notes.map(\.text), ["Redis is for the session cache.", "Stream uploads."])
        XCTAssertEqual(map.notes.map(\.at), [BoardPoint(x: 640, y: 112), nil])
        XCTAssertEqual(map.texts.map(\.text), ["June"])
        XCTAssertEqual(map.texts.first?.style, .title)
        XCTAssertEqual(map.texts.first?.width, 64)
    }

    /// Read top to bottom the file is the architecture; the layout sits in one block of its own.
    func testEncodingWritesTheArchitectureFirstShape() throws {
        let root = try object(try BoardMap.decode(june).encoded())
        XCTAssertEqual(root["version"] as? Int, 2)
        let places = try XCTUnwrap(root["places"] as? [String: Any])
        XCTAssertEqual(Set(places.keys), ["Local docker", "Oracle box", "Not placed"])
        let docker = try XCTUnwrap(places["Local docker"] as? [String: Any])
        let redis = try XCTUnwrap(docker["redis"] as? [String: Any])
        XCTAssertEqual(redis["status"] as? String, "planned")
        XCTAssertNil(redis["intended"])
        let api = try XCTUnwrap(docker["api"] as? [String: Any])
        XCTAssertNil(api["name"], "a component's name is its key, never a field")
        XCTAssertNil(api["at"], "positions live only in the layout block")
        XCTAssertEqual(api["uses"] as? [String: String], ["postgres": "reads and writes entries", "redis": ""])
        let layout = try XCTUnwrap(root["layout"] as? [String: Any])
        XCTAssertEqual((layout["components"] as? [String: [Int]])?["api"], [64, 128])
        XCTAssertEqual((layout["frames"] as? [String: [Int]])?["Oracle box"], [408, 96, 192, 112])
    }

    /// "Not placed" is reserved and always written, even when empty, so an agent never
    /// wonders where the rest went.
    func testAnEmptyMapStillWritesNotPlaced() throws {
        let root = try object(try BoardMap.empty.encoded())
        XCTAssertEqual(root["version"] as? Int, 2)
        XCTAssertEqual((root["places"] as? [String: Any]).map { Set($0.keys) }, ["Not placed"])
        XCTAssertEqual(root["notes"] as? [String], [])
        XCTAssertNil(root["system"])
    }

    func testKeysLinkCDoesNotKnowSurviveEveryLevel() throws {
        let data = Data("""
        { "version": 2, "owner": "jacob",
          "places": { "Not placed": { "api": { "kind": "service", "team": "core" } } },
          "notes": [],
          "layout": { "zoom_hint": 1.5 } }
        """.utf8)
        var map = try BoardMap.decode(data)
        map.components[0].does = "HTTP api"
        let root = try object(try map.encoded())
        XCTAssertEqual(root["owner"] as? String, "jacob")
        let api = try XCTUnwrap(((root["places"] as? [String: Any])?["Not placed"] as? [String: Any])?["api"] as? [String: Any])
        XCTAssertEqual(api["team"] as? String, "core")
        XCTAssertEqual(api["does"] as? String, "HTTP api", "the edit still lands")
        XCTAssertEqual((root["layout"] as? [String: Any])?["zoom_hint"] as? Double, 1.5)
    }

    /// Encoding is stable: a decode of what was written writes the same bytes again.
    func testARoundTripIsByteStable() throws {
        let once = try BoardMap.decode(june).encoded()
        let twice = try BoardMap.decode(once).encoded()
        XCTAssertEqual(once, twice)
    }

    func testCoordinatesAreSnappedToEight() throws {
        var map = BoardMap.empty
        map.components = [BoardComponent(name: "api", kind: .service, at: BoardPoint(x: 13, y: 21))]
        let layout = try XCTUnwrap(try object(try map.encoded())["layout"] as? [String: Any])
        XCTAssertEqual((layout["components"] as? [String: [Int]])?["api"], [16, 24])
    }

    func testAVersionOneFileUpgrades() throws {
        let v1 = Data("""
        { "version": 1, "note": "kept",
          "components": [
            { "name": "postgres", "kind": "database", "used_by": ["api", "ios app"], "at": { "x": 1, "y": 2 } },
            { "name": "api", "kind": "service", "intended": true, "owner": "jacob" }
          ] }
        """.utf8)
        let map = try BoardMap.decode(v1)
        XCTAssertEqual(map.sourceVersion, 1)
        XCTAssertTrue(map.components.allSatisfy { $0.place == BoardMap.notPlaced })
        let postgres = try XCTUnwrap(map.components.first { $0.name == "postgres" })
        XCTAssertEqual(postgres.at, BoardPoint(x: 160, y: 128), "cells become points: x × 160, y × 64")
        XCTAssertEqual(postgres.legacyUsedBy, ["ios app"], "a user that is not a component is kept")
        let api = try XCTUnwrap(map.components.first { $0.name == "api" })
        XCTAssertTrue(api.planned)
        XCTAssertEqual(api.uses, ["postgres": ""], "used_by becomes uses on the user")

        let root = try object(try map.encoded())
        XCTAssertEqual(root["version"] as? Int, 2)
        XCTAssertNil(root["components"], "the version-1 list is gone once written")
        XCTAssertEqual(root["note"] as? String, "kept")
        let apiOut = try XCTUnwrap(((root["places"] as? [String: Any])?["Not placed"] as? [String: Any])?["api"] as? [String: Any])
        XCTAssertEqual(apiOut["owner"] as? String, "jacob")
        XCTAssertNil(apiOut["intended"])
        XCTAssertNil(apiOut["name"])
    }

    func testAFileThatCannotBeTrustedIsRefusedWithAReason() {
        let cases: [(String, String)] = [
            ("not json", "JSON"),
            ("[1, 2]", "object"),
            (#"{"version": 2}"#, "places"),
            (#"{"notes": []}"#, "neither"),
            (#"{"version": 3, "places": {}}"#, "newer"),
            (#"{"version": 2, "places": {"A": {"api": {}}, "B": {"API": {}}}}"#, "twice"),
            (#"{"version": 2, "places": {"Docker": {}, "docker": {}}}"#, "twice"),
            (#"{"version": 2, "places": {"Not placed": {"api": {"kind": 4}}}}"#, "kind"),
            (#"{"version": 2, "places": {"Not placed": {"api": {"uses": ["db"]}}}}"#, "uses"),
            (#"{"version": 2, "places": {"Not placed": {"api": {"status": "done"}}}}"#, "status"),
            (#"{"version": 2, "places": {"Not placed": {}}, "notes": [3]}"#, "notes"),
            (#"{"version": 2, "places": {"Not placed": {}}, "layout": {"frames": {"A": [1, 2]}}}"#, "frames"),
            (#"{"version": 2, "places": {"Not placed": {}}, "layout": {"components": {"api": [1]}}}"#, "components"),
        ]
        for (json, hint) in cases {
            XCTAssertThrowsError(try BoardMap.decode(Data(json.utf8)), json) { error in
                XCTAssertTrue("\(error)".contains(hint), "\(json): \(error) should mention \(hint)")
            }
        }
    }

    func testAPlaceNamedLikeNotPlacedInAnotherCaseIsTheSameBucket() throws {
        let map = try BoardMap.decode(Data(#"{"version": 2, "places": {"not placed": {"api": {}}}}"#.utf8))
        XCTAssertEqual(map.components.first?.place, BoardMap.notPlaced)
        XCTAssertTrue(map.frames.isEmpty)
    }

    func testRectGeometry() {
        let a = BoardRect(x: 0, y: 0, w: 100, h: 50)
        XCTAssertTrue(a.intersects(BoardRect(x: 99, y: 49, w: 10, h: 10)))
        XCTAssertFalse(a.intersects(BoardRect(x: 100, y: 0, w: 10, h: 10)), "touching edges do not overlap")
        XCTAssertTrue(a.contains(BoardRect(x: 10, y: 10, w: 20, h: 20)))
        XCTAssertFalse(a.contains(BoardRect(x: 90, y: 10, w: 20, h: 20)))
        XCTAssertEqual(a.center, BoardPoint(x: 50, y: 25))
        XCTAssertEqual(BoardRect(x: 5, y: 11, w: 150, h: 57).snapped, BoardRect(x: 8, y: 8, w: 152, h: 56))
    }
}
```

- [ ] **Step 3: Run the tests and see them fail**

Run: `swift test --filter BoardMapTests`
Expected: build failure — `cannot find 'BoardMap' in scope`.

- [ ] **Step 4: Implement**

Create `Sources/LinkCKit/Board/BoardMap.swift`:

```swift
import Foundation

/// A point on the board, in canvas points. Stored snapped to 8, so moving a box changes one line.
public struct BoardPoint: Hashable, Sendable {
    public var x: Int
    public var y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }

    /// The step every stored coordinate lands on.
    public static let grid = 8

    public var snapped: BoardPoint { BoardPoint(x: Self.snap(x), y: Self.snap(y)) }

    static func snap(_ value: Int) -> Int {
        Int((Double(value) / Double(grid)).rounded()) * grid
    }
}

/// A rectangle on the board. Edges that only touch do not overlap.
public struct BoardRect: Hashable, Sendable {
    public var x: Int
    public var y: Int
    public var w: Int
    public var h: Int

    public init(x: Int, y: Int, w: Int, h: Int) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    public var minX: Int { x }
    public var minY: Int { y }
    public var maxX: Int { x + w }
    public var maxY: Int { y + h }
    public var origin: BoardPoint { BoardPoint(x: x, y: y) }
    public var center: BoardPoint { BoardPoint(x: x + w / 2, y: y + h / 2) }

    public func intersects(_ other: BoardRect) -> Bool {
        x < other.maxX && other.x < maxX && y < other.maxY && other.y < maxY
    }

    public func contains(_ point: BoardPoint) -> Bool {
        point.x >= x && point.x < maxX && point.y >= y && point.y < maxY
    }

    public func contains(_ rect: BoardRect) -> Bool {
        rect.x >= x && rect.y >= y && rect.maxX <= maxX && rect.maxY <= maxY
    }

    public func offsetBy(dx: Int, dy: Int) -> BoardRect {
        BoardRect(x: x + dx, y: y + dy, w: w, h: h)
    }

    /// Origin and size on the 8-point grid; a size never snaps below one step.
    public var snapped: BoardRect {
        BoardRect(
            x: BoardPoint.snap(x), y: BoardPoint.snap(y),
            w: max(BoardPoint.grid, BoardPoint.snap(w)), h: max(BoardPoint.grid, BoardPoint.snap(h)))
    }
}

/// One part of the system: a box on the board, and an entry under its place in the file.
public struct BoardComponent: Equatable, Sendable, Identifiable {
    public var id: String { name }
    /// Identity: unique across the whole file, and what running things are matched against.
    public var name: String
    public var kind: ComponentKind
    /// One line saying what it is for.
    public var does: String?
    /// How code reaches it: an env var name, a URL, a host.
    public var reachedBy: String?
    /// Where it runs, free text; naming a compose service in brackets is what matches it.
    public var runs: String?
    /// True while it does not exist yet.
    public var planned: Bool
    /// What it uses: each component's name, mapped to the arrow's label (`""` when unlabelled).
    public var uses: [String: String]
    /// Version-1 `used_by` names that were not components, kept verbatim.
    public var legacyUsedBy: [String]
    /// The label of the frame it sits in, or `BoardMap.notPlaced`.
    public var place: String
    /// Its box's top-left corner; nil until the board places it.
    public var at: BoardPoint?
    /// Keys linkC does not know, kept so an edit never drops them.
    var extras: Data?

    public init(
        name: String, kind: ComponentKind, does: String? = nil, reachedBy: String? = nil, runs: String? = nil,
        planned: Bool = false, uses: [String: String] = [:], legacyUsedBy: [String] = [],
        place: String = BoardMap.notPlaced, at: BoardPoint? = nil
    ) {
        self.name = name
        self.kind = kind
        self.does = does
        self.reachedBy = reachedBy
        self.runs = runs
        self.planned = planned
        self.uses = uses
        self.legacyUsedBy = legacyUsedBy
        self.place = place
        self.at = at
        self.extras = nil
    }
}

/// A labelled region; its label is a place in the file.
public struct BoardFrame: Equatable, Sendable, Identifiable {
    public var id: String { label }
    public var label: String
    /// nil until the board lays it out — a place written by hand has no geometry yet.
    public var rect: BoardRect?

    public init(label: String, rect: BoardRect? = nil) {
        self.label = label
        self.rect = rect
    }
}

public enum BoardTextStyle: String, Sendable {
    case title
    case label
}

/// A sticky note. Its id lives only in memory; the file keeps notes in order.
public struct BoardNote: Equatable, Sendable, Identifiable {
    public let id: UUID
    public var text: String
    public var at: BoardPoint?

    public init(id: UUID = UUID(), text: String, at: BoardPoint? = nil) {
        self.id = id
        self.text = text
        self.at = at
    }
}

/// A heading or label on the canvas. Visual only: agents never read it.
public struct BoardText: Equatable, Sendable, Identifiable {
    public let id: UUID
    public var text: String
    public var style: BoardTextStyle
    public var at: BoardPoint
    /// The width the board measured for it, so collisions never depend on laying out text.
    public var width: Int

    public init(id: UUID = UUID(), text: String, style: BoardTextStyle, at: BoardPoint, width: Int) {
        self.id = id
        self.text = text
        self.style = style
        self.at = at
        self.width = width
    }
}

/// The whole of `system-map.json`, version 2: the architecture first, the board's layout last.
public struct BoardMap: Equatable, Sendable {
    /// The reserved place for components outside every frame. Always written.
    public static let notPlaced = "Not placed"

    public var system: String?
    public var components: [BoardComponent] = []
    public var frames: [BoardFrame] = []
    public var notes: [BoardNote] = []
    public var texts: [BoardText] = []
    /// 1 when this map was upgraded from a version-1 file, else 2. Written as 2 either way.
    public internal(set) var sourceVersion: Int = 2
    /// Top-level keys linkC does not know.
    var extras: Data?
    /// Keys inside `layout` linkC does not know.
    var layoutExtras: Data?

    public init(system: String? = nil) {
        self.system = system
    }

    public static let empty = BoardMap()

    private static let rootKeys: Set<String> = ["version", "system", "places", "notes", "layout"]
    private static let componentKeys: Set<String> = ["kind", "does", "reached_by", "runs", "status", "uses", "used_by"]
    private static let layoutKeys: Set<String> = ["components", "frames", "notes", "texts"]
    private static let versionOneComponentKeys: Set<String> = ["name", "kind", "reached_by", "runs", "used_by", "intended", "at"]

    // MARK: - Decoding

    /// Decodes versions 1 and 2, failing loud: an unreadable file must never read as an empty system.
    public static func decode(_ data: Data) throws -> BoardMap {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw LinkCError.parse("system-map.json is not JSON: \(error.localizedDescription)")
        }
        guard let root = object as? [String: Any] else {
            throw LinkCError.parse("system-map.json is not a JSON object")
        }
        let version = try int(root, "version", context: "system-map.json")
        if let version, version > 2 {
            throw LinkCError.parse("system-map.json is version \(version), written by a newer linkC")
        }
        if root["places"] != nil || version == 2 { return try decodeVersionTwo(root) }
        if root["components"] != nil { return try decodeVersionOne(root) }
        throw LinkCError.parse("system-map.json has neither places nor components")
    }

    private static func decodeVersionTwo(_ root: [String: Any]) throws -> BoardMap {
        guard let rawPlaces = root["places"] as? [String: Any] else {
            throw LinkCError.parse("system-map.json has no places")
        }
        let layoutContext = "the layout in system-map.json"
        let layout = try dictionary(root, "layout", context: "system-map.json") ?? [:]
        let positions = try pointMap(layout, "components", context: layoutContext) ?? [:]
        let frameRects = try rectMap(layout, "frames", context: layoutContext) ?? [:]

        var map = BoardMap(system: try string(root, "system", context: "system-map.json"))
        var seenPlaces: Set<String> = []
        var seenNames: Set<String> = []
        for placeName in rawPlaces.keys.sorted() {
            guard !placeName.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw LinkCError.parse("a place in system-map.json has no name")
            }
            guard seenPlaces.insert(placeName.lowercased()).inserted else {
                throw LinkCError.parse("system-map.json names the place \"\(placeName)\" twice")
            }
            guard let members = rawPlaces[placeName] as? [String: Any] else {
                throw LinkCError.parse("the place \"\(placeName)\" in system-map.json is not an object of components")
            }
            let isUnplaced = placeName.lowercased() == notPlaced.lowercased()
            let place = isUnplaced ? notPlaced : placeName
            if !isUnplaced { map.frames.append(BoardFrame(label: placeName, rect: frameRects[placeName])) }

            for name in members.keys.sorted() {
                guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw LinkCError.parse("a component under \"\(placeName)\" in system-map.json has no name")
                }
                guard seenNames.insert(name.lowercased()).inserted else {
                    throw LinkCError.parse("system-map.json names \"\(name)\" twice")
                }
                guard let raw = members[name] as? [String: Any] else {
                    throw LinkCError.parse("component \"\(name)\" in system-map.json is not an object")
                }
                let context = "component \"\(name)\" in system-map.json"
                let status = try string(raw, "status", context: context)
                if let status, status != "planned" {
                    throw LinkCError.parse("\(context) has status \"\(status)\"; the only status is \"planned\"")
                }
                var component = BoardComponent(
                    name: name,
                    kind: ComponentKind(try string(raw, "kind", context: context) ?? ComponentKind.service.raw),
                    does: try string(raw, "does", context: context),
                    reachedBy: try string(raw, "reached_by", context: context),
                    runs: try string(raw, "runs", context: context),
                    planned: status == "planned",
                    uses: try stringMap(raw, "uses", context: context) ?? [:],
                    legacyUsedBy: try stringArray(raw, "used_by", context: context) ?? [],
                    place: place,
                    at: positions[name])
                component.extras = try extras(of: raw, excluding: componentKeys, context: context)
                map.components.append(component)
            }
        }

        let noteTexts = try stringArray(root, "notes", context: "system-map.json") ?? []
        let notePositions = try optionalPointList(layout, "notes", context: layoutContext) ?? []
        map.notes = noteTexts.enumerated().map { index, text in
            BoardNote(text: text, at: index < notePositions.count ? notePositions[index] : nil)
        }
        map.texts = try texts(layout, context: layoutContext)
        map.extras = try extras(of: root, excluding: rootKeys, context: "system-map.json")
        map.layoutExtras = try extras(of: layout, excluding: layoutKeys, context: layoutContext)
        return map
    }

    private static func decodeVersionOne(_ root: [String: Any]) throws -> BoardMap {
        guard let rawComponents = root["components"] as? [[String: Any]] else {
            throw LinkCError.parse("system-map.json has no components list")
        }
        var components: [BoardComponent] = []
        var usedBy: [[String]] = []
        var seen: Set<String> = []
        for raw in rawComponents {
            guard let name = raw["name"] as? String, !name.isEmpty else {
                throw LinkCError.parse("a component in system-map.json has no name")
            }
            guard seen.insert(name.lowercased()).inserted else {
                throw LinkCError.parse("system-map.json names \"\(name)\" twice")
            }
            let context = "component \"\(name)\" in system-map.json"
            var at: BoardPoint?
            if let value = raw["at"] {
                guard let cell = value as? [String: Any], let x = cell["x"] as? Int, let y = cell["y"] as? Int else {
                    throw LinkCError.parse("\(context) has \"at\" but it needs whole-number x and y")
                }
                at = BoardPoint(x: x * 160, y: y * 64)
            }
            var component = BoardComponent(
                name: name,
                kind: ComponentKind(try string(raw, "kind", context: context) ?? ComponentKind.service.raw),
                reachedBy: try string(raw, "reached_by", context: context),
                runs: try string(raw, "runs", context: context),
                planned: try bool(raw, "intended", context: context) ?? false,
                at: at)
            component.extras = try extras(of: raw, excluding: versionOneComponentKeys, context: context)
            components.append(component)
            usedBy.append(try stringArray(raw, "used_by", context: context) ?? [])
        }

        // Version 1 said who uses a component; version 2 says what a component uses.
        let indexByName = Dictionary(uniqueKeysWithValues: components.enumerated().map { ($0.element.name.lowercased(), $0.offset) })
        for (index, users) in usedBy.enumerated() {
            for user in users {
                if let userIndex = indexByName[user.lowercased()] {
                    components[userIndex].uses[components[index].name] = ""
                } else {
                    components[index].legacyUsedBy.append(user)
                }
            }
        }

        var map = BoardMap()
        map.components = components
        map.sourceVersion = 1
        map.extras = try extras(of: root, excluding: ["version", "components"], context: "system-map.json")
        return map
    }

    // MARK: - Encoding

    /// The file's bytes: version 2, architecture first, layout last, sorted and snapped.
    public func encoded() throws -> Data {
        var root = try Self.object(from: extras, context: "the system map's own extras")
        root["version"] = 2
        Self.set(&root, "system", system)

        var places: [String: [String: Any]] = [Self.notPlaced: [:]]
        for frame in frames { places[frame.label] = places[frame.label] ?? [:] }
        for component in components {
            var object = try Self.object(from: component.extras, context: "component \"\(component.name)\"'s extras")
            object["kind"] = component.kind.raw
            Self.set(&object, "does", component.does)
            Self.set(&object, "reached_by", component.reachedBy)
            Self.set(&object, "runs", component.runs)
            if component.planned { object["status"] = "planned" } else { object.removeValue(forKey: "status") }
            if component.uses.isEmpty { object.removeValue(forKey: "uses") } else { object["uses"] = component.uses }
            if component.legacyUsedBy.isEmpty { object.removeValue(forKey: "used_by") } else { object["used_by"] = component.legacyUsedBy }
            places[component.place, default: [:]][component.name] = object
        }
        root["places"] = places
        root["notes"] = notes.map(\.text)

        var layout = try Self.object(from: layoutExtras, context: "the layout's extras")
        var positions: [String: [Int]] = [:]
        for component in components {
            if let at = component.at?.snapped { positions[component.name] = [at.x, at.y] }
        }
        var rects: [String: [Int]] = [:]
        for frame in frames {
            if let rect = frame.rect?.snapped { rects[frame.label] = [rect.x, rect.y, rect.w, rect.h] }
        }
        layout["components"] = positions
        layout["frames"] = rects
        layout["notes"] = notes.map { note -> Any in
            guard let at = note.at?.snapped else { return NSNull() }
            return [at.x, at.y]
        }
        layout["texts"] = texts.map { text -> [String: Any] in
            let at = text.at.snapped
            return ["text": text.text, "style": text.style.rawValue, "at": [at.x, at.y], "w": text.width]
        }
        root["layout"] = layout

        guard JSONSerialization.isValidJSONObject(root) else {
            throw LinkCError.parse("the system map could not be represented as JSON")
        }
        do {
            return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        } catch {
            throw LinkCError.parse("failed to write the system map: \(error.localizedDescription)")
        }
    }

    // MARK: - Field readers: a known key present with the wrong type refuses the whole file

    private static func string(_ raw: [String: Any], _ key: String, context: String) throws -> String? {
        guard let value = raw[key] else { return nil }
        guard let string = value as? String else { throw LinkCError.parse("\(context) has \"\(key)\" but it is not text") }
        return string
    }

    private static func bool(_ raw: [String: Any], _ key: String, context: String) throws -> Bool? {
        guard let value = raw[key] else { return nil }
        guard let bool = value as? Bool else { throw LinkCError.parse("\(context) has \"\(key)\" but it is not true or false") }
        return bool
    }

    private static func int(_ raw: [String: Any], _ key: String, context: String) throws -> Int? {
        guard let value = raw[key] else { return nil }
        guard let int = value as? Int else { throw LinkCError.parse("\(context) has \"\(key)\" but it is not a whole number") }
        return int
    }

    private static func stringArray(_ raw: [String: Any], _ key: String, context: String) throws -> [String]? {
        guard let value = raw[key] else { return nil }
        guard let array = value as? [String] else { throw LinkCError.parse("\(context) has \"\(key)\" but it is not a list of text") }
        return array
    }

    private static func stringMap(_ raw: [String: Any], _ key: String, context: String) throws -> [String: String]? {
        guard let value = raw[key] else { return nil }
        guard let map = value as? [String: String] else {
            throw LinkCError.parse("\(context) has \"\(key)\" but it is not an object of text")
        }
        return map
    }

    private static func dictionary(_ raw: [String: Any], _ key: String, context: String) throws -> [String: Any]? {
        guard let value = raw[key] else { return nil }
        guard let object = value as? [String: Any] else { throw LinkCError.parse("\(context) has \"\(key)\" but it is not an object") }
        return object
    }

    private static func point(_ value: Any) -> BoardPoint? {
        guard let pair = value as? [Int], pair.count == 2 else { return nil }
        return BoardPoint(x: pair[0], y: pair[1])
    }

    private static func pointMap(_ raw: [String: Any], _ key: String, context: String) throws -> [String: BoardPoint]? {
        guard let value = raw[key] else { return nil }
        guard let entries = value as? [String: Any] else { throw LinkCError.parse("\(context) has \"\(key)\" but it is not an object") }
        var result: [String: BoardPoint] = [:]
        for (name, entry) in entries {
            guard let point = point(entry) else {
                throw LinkCError.parse("\(context) has \"\(key)\" → \"\(name)\" but it is not [x, y]")
            }
            result[name] = point
        }
        return result
    }

    private static func rectMap(_ raw: [String: Any], _ key: String, context: String) throws -> [String: BoardRect]? {
        guard let value = raw[key] else { return nil }
        guard let entries = value as? [String: Any] else { throw LinkCError.parse("\(context) has \"\(key)\" but it is not an object") }
        var result: [String: BoardRect] = [:]
        for (label, entry) in entries {
            guard let four = entry as? [Int], four.count == 4, four[2] > 0, four[3] > 0 else {
                throw LinkCError.parse("\(context) has \"\(key)\" → \"\(label)\" but it is not [x, y, w, h]")
            }
            result[label] = BoardRect(x: four[0], y: four[1], w: four[2], h: four[3])
        }
        return result
    }

    private static func optionalPointList(_ raw: [String: Any], _ key: String, context: String) throws -> [BoardPoint?]? {
        guard let value = raw[key] else { return nil }
        guard let entries = value as? [Any] else { throw LinkCError.parse("\(context) has \"\(key)\" but it is not a list") }
        return try entries.enumerated().map { index, entry in
            if entry is NSNull { return nil }
            guard let point = point(entry) else {
                throw LinkCError.parse("\(context) has \"\(key)\" item \(index + 1) but it is not [x, y] or null")
            }
            return point
        }
    }

    private static func texts(_ layout: [String: Any], context: String) throws -> [BoardText] {
        guard let value = layout["texts"] else { return [] }
        guard let entries = value as? [[String: Any]] else { throw LinkCError.parse("\(context) has \"texts\" but it is not a list of objects") }
        return try entries.enumerated().map { index, entry in
            let itemContext = "\(context), text \(index + 1)"
            guard let text = entry["text"] as? String else { throw LinkCError.parse("\(itemContext) has no text") }
            guard let at = entry["at"].flatMap(point) else { throw LinkCError.parse("\(itemContext) has no [x, y] at") }
            let styleName = try string(entry, "style", context: itemContext) ?? BoardTextStyle.label.rawValue
            guard let style = BoardTextStyle(rawValue: styleName) else {
                throw LinkCError.parse("\(itemContext) has style \"\(styleName)\"; styles are title and label")
            }
            let width = try int(entry, "w", context: itemContext) ?? 0
            return BoardText(text: text, style: style, at: at, width: width)
        }
    }

    /// The keys of `raw` outside `known`, recorded verbatim; nil when there are none.
    private static func extras(of raw: [String: Any], excluding known: Set<String>, context: String) throws -> Data? {
        let unknown = raw.filter { !known.contains($0.key) }
        guard !unknown.isEmpty else { return nil }
        do {
            return try JSONSerialization.data(withJSONObject: unknown, options: [.sortedKeys])
        } catch {
            throw LinkCError.parse("\(context) could not be recorded verbatim: \(error.localizedDescription)")
        }
    }

    /// Reads a recorded `extras` blob back. Unknown keys surviving an edit is a guarantee, so a
    /// blob that will not read back fails the write rather than quietly dropping them.
    private static func object(from data: Data?, context: String) throws -> [String: Any] {
        guard let data else { return [:] }
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw LinkCError.parse("\(context) did not decode back into an object")
            }
            return object
        } catch let error as LinkCError {
            throw error
        } catch {
            throw LinkCError.parse("\(context) could not be read back: \(error.localizedDescription)")
        }
    }

    /// Writes trimmed text, or removes the key when it is nil or blank — never `null`, never `""`.
    private static func set(_ object: inout [String: Any], _ key: String, _ value: String?) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty { object.removeValue(forKey: key) } else { object[key] = trimmed }
    }
}
```

- [ ] **Step 5: Run the tests and see them pass**

Run: `swift test --filter BoardMapTests`
Expected: `Executed 10 tests, with 0 failures`. Then `swift test --filter SystemMap` — the old tests must still pass (the old type is untouched apart from `ComponentKind` moving).

- [ ] **Step 6: Commit**

```bash
git add Sources/LinkCKit/Board/ComponentKind.swift Sources/LinkCKit/Board/BoardMap.swift Sources/LinkCKit/Workbench/SystemMap.swift Tests/LinkCKitTests/BoardMapTests.swift
git diff --cached --stat
git commit -m "feat(board): the version-2 map, architecture first, with its upgrade from version 1"
git log -1 --format=%B | grep -ic claude   # must print 0
```

---

### Task 3: Store, reconciler, report and MCP on the new map

**Files:**
- Create: `Sources/LinkCKit/Board/BoardMapStore.swift`
- Create: `Sources/LinkCKit/Board/BoardReconciler.swift` (from `Sources/LinkCKit/Workbench/SystemReconciler.swift`)
- Create: `Sources/LinkCKit/Board/BoardReport.swift` (from `Sources/LinkCKit/Workbench/SystemMapReport.swift`)
- Modify: `Sources/LinkCKit/MCP/MCPServer.swift` (the `linkc_get_project_context` case)
- Delete: `Sources/LinkCKit/Workbench/` (all four remaining files) and `Tests/LinkCKitTests/{SystemMapTests,SystemMapStoreTests,SystemMapReportTests,SystemReconcilerTests}.swift`
- Test: `Tests/LinkCKitTests/BoardMapStoreTests.swift`, `Tests/LinkCKitTests/BoardReconcilerTests.swift`, `Tests/LinkCKitTests/BoardReportTests.swift`; update the MCP project-context tests (grep `Tests/` for `system-map.json`)

**Interfaces:**
- Consumes: `BoardMap`, `BoardComponent`, `ComponentKind` (Task 2).
- Produces:
  - `struct BoardMapStore: Sendable` — `init(workspacePath:)`, `fileURL`, `struct Loaded: Sendable { map: BoardMap; bytes: Data }`, `func load() throws -> Loaded?`, `func save(_ map: BoardMap, expecting expected: Data?) throws -> Data` (returns the bytes written)
  - `enum BoardMapStoreError: Error, Equatable { case changedOnDisk }`
  - `DiscoveredThing`, `ComponentStatus`, `MapSuggestion` — moved unchanged
  - `enum BoardReconciler` — `struct Reconciliation { statuses; suggestions }`, `static func reconcile(map: BoardMap, discovered: [DiscoveredThing]) -> Reconciliation`, `static func kind(forImage:) -> ComponentKind`
  - `enum BoardReport` — `static func markdown(for map: BoardMap) -> String`

- [ ] **Step 1: Write the failing tests**

Create `Tests/LinkCKitTests/BoardMapStoreTests.swift`:

```swift
import XCTest
@testable import LinkCKit

final class BoardMapStoreTests: XCTestCase {
    nonisolated(unsafe) private var workspace: URL!

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-board-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: workspace)
    }

    func testTheMapLivesAtTheProjectRoot() {
        XCTAssertEqual(BoardMapStore(workspacePath: workspace.path).fileURL.lastPathComponent, "system-map.json")
        XCTAssertEqual(BoardMapStore(workspacePath: workspace.path).fileURL.deletingLastPathComponent().path,
                       (workspace.path as NSString).standardizingPath)
    }

    func testAProjectWithNoMapLoadsNothing() throws {
        XCTAssertNil(try BoardMapStore(workspacePath: workspace.path).load())
    }

    func testSavingANewMapThenLoadingItReturnsTheBytesWritten() throws {
        let store = BoardMapStore(workspacePath: workspace.path)
        var map = BoardMap.empty
        map.components = [BoardComponent(name: "api", kind: .service)]
        let written = try store.save(map, expecting: nil)
        let loaded = try XCTUnwrap(try store.load())
        XCTAssertEqual(loaded.bytes, written)
        XCTAssertEqual(loaded.map.components.map(\.name), ["api"])
    }

    /// A change linkC has not seen — a git pull, a hand edit — must never be overwritten.
    func testAWriteOverAFileThatChangedOnDiskIsRefused() throws {
        let store = BoardMapStore(workspacePath: workspace.path)
        let first = try store.save(.empty, expecting: nil)
        let theirs = Data(#"{"version": 2, "places": {"Not placed": {"theirs": {}}}}"#.utf8)
        try theirs.write(to: store.fileURL)

        var mine = BoardMap.empty
        mine.components = [BoardComponent(name: "mine", kind: .service)]
        XCTAssertThrowsError(try store.save(mine, expecting: first)) { error in
            XCTAssertEqual(error as? BoardMapStoreError, .changedOnDisk)
        }
        XCTAssertEqual(try Data(contentsOf: store.fileURL), theirs, "their change is untouched")
    }

    func testCreatingAMapWhereOneAppearedMeanwhileIsRefused() throws {
        let store = BoardMapStore(workspacePath: workspace.path)
        try Data(#"{"version": 2, "places": {}}"#.utf8).write(to: store.fileURL)
        XCTAssertThrowsError(try store.save(.empty, expecting: nil)) { error in
            XCTAssertEqual(error as? BoardMapStoreError, .changedOnDisk)
        }
    }

    func testAnUnreadableFileThrowsRatherThanReadingAsEmpty() throws {
        let store = BoardMapStore(workspacePath: workspace.path)
        try Data("{ nope".utf8).write(to: store.fileURL)
        XCTAssertThrowsError(try store.load())
    }
}
```

Create `Tests/LinkCKitTests/BoardReconcilerTests.swift` by porting every test in `Tests/LinkCKitTests/SystemReconcilerTests.swift` to the new types — `SystemMap(components: [...])` becomes a `BoardMap` whose `components` are set, `SystemComponent(... intended: true)` becomes `BoardComponent(... planned: true)`, `SystemReconciler` becomes `BoardReconciler` — keeping each test's name and assertions. Then add:

```swift
    /// A component linkC was told lives in a docker frame is checkable even with no `runs`.
    func testAPlaceNamingDockerMakesItsComponentsCheckable() {
        var map = BoardMap.empty
        map.frames = [BoardFrame(label: "Local docker")]
        map.components = [
            BoardComponent(name: "redis", kind: .cache, place: "Local docker"),
            BoardComponent(name: "june-audio", kind: .host, place: "Oracle box"),
        ]
        let result = BoardReconciler.reconcile(map: map, discovered: [])
        XCTAssertEqual(result.statuses["redis"], .missing)
        XCTAssertEqual(result.statuses["june-audio"], .unchecked)
    }
```

Create `Tests/LinkCKitTests/BoardReportTests.swift`:

```swift
import XCTest
@testable import LinkCKit

final class BoardReportTests: XCTestCase {
    private var june: BoardMap {
        var map = BoardMap(system: "June — audio journaling")
        map.frames = [BoardFrame(label: "Local docker", rect: BoardRect(x: 4040, y: 96, w: 344, h: 200)),
                      BoardFrame(label: "Oracle box")]
        map.components = [
            BoardComponent(name: "api", kind: .service, does: "HTTP api", reachedBy: "API_URL",
                           uses: ["postgres": "reads and writes entries", "june-audio": ""],
                           place: "Local docker", at: BoardPoint(x: 8080, y: 128)),
            BoardComponent(name: "postgres", kind: .database, reachedBy: "DATABASE_URL", place: "Local docker"),
            BoardComponent(name: "redis", kind: .cache, planned: true, place: "Local docker"),
            BoardComponent(name: "june-audio", kind: .host, does: "serves mp3s", place: "Oracle box"),
        ]
        map.notes = [BoardNote(text: "Redis is for the session cache.")]
        return map
    }

    private func line(_ text: String, _ needle: String) throws -> String {
        String(try XCTUnwrap(text.split(separator: "\n").first { $0.contains(needle) }))
    }

    func testTheSectionOpensWithTheSystemAndTheNoLiveStatusLine() throws {
        let text = BoardReport.markdown(for: june)
        XCTAssertTrue(text.hasPrefix("## System\n"))
        XCTAssertTrue(text.contains("not checked"), "an agent must not read silence as 'not running'")
        XCTAssertTrue(text.contains("June — audio journaling"))
    }

    func testComponentsAreGroupedUnderTheirPlace() throws {
        let text = BoardReport.markdown(for: june)
        let docker = try XCTUnwrap(text.range(of: "### Local docker"))
        let oracle = try XCTUnwrap(text.range(of: "### Oracle box"))
        let api = try XCTUnwrap(text.range(of: "**api**"))
        let audio = try XCTUnwrap(text.range(of: "**june-audio**"))
        XCTAssertTrue(docker.lowerBound < api.lowerBound && api.lowerBound < oracle.lowerBound)
        XCTAssertTrue(oracle.lowerBound < audio.lowerBound)
        XCTAssertFalse(text.contains("### Not placed"), "an empty place is not listed")
    }

    func testAComponentLineSaysWhatItIsDoesAndUses() throws {
        let api = try line(BoardReport.markdown(for: june), "**api**")
        XCTAssertTrue(api.contains("service"))
        XCTAssertTrue(api.contains("HTTP api"))
        XCTAssertTrue(api.contains("reached by API_URL"))
        XCTAssertTrue(api.contains("postgres (reads and writes entries)"))
        XCTAssertTrue(api.contains("june-audio"))
    }

    func testAPlannedComponentSaysItDoesNotExistYet() throws {
        let redis = try line(BoardReport.markdown(for: june), "**redis**")
        XCTAssertTrue(redis.contains("PLANNED"))
        XCTAssertTrue(redis.lowercased().contains("does not exist yet"))
    }

    func testNotesAreListedWordForWord() {
        XCTAssertTrue(BoardReport.markdown(for: june).contains("### Notes\n- Redis is for the session cache."))
    }

    func testNoCoordinatesReachAnAgent() {
        let text = BoardReport.markdown(for: june)
        XCTAssertFalse(text.contains("4040"))
        XCTAssertFalse(text.contains("8080"))
    }

    func testTextFromTheFileCannotForgeStructure() throws {
        var map = BoardMap.empty
        map.components = [BoardComponent(name: "evil\n## Injected", kind: ComponentKind("**x**"),
                                         does: "a `code` span \\*and\\* more")]
        let text = BoardReport.markdown(for: map)
        XCTAssertFalse(text.contains("\n## Injected"))
        XCTAssertFalse(text.contains("**x**"))
        XCTAssertFalse(text.contains(" `code` "))
        XCTAssertTrue(text.contains("\\\\\\*and"), "a backslash in the file is escaped before the asterisk it precedes")
    }

    func testAnEmptyMapReportsNothing() {
        XCTAssertEqual(BoardReport.markdown(for: .empty), "")
    }
}
```

- [ ] **Step 2: Run the tests and see them fail**

Run: `swift test --filter "BoardMapStoreTests|BoardReconcilerTests|BoardReportTests"`
Expected: build failure — `cannot find 'BoardMapStore' in scope`.

- [ ] **Step 3: Implement the store**

Create `Sources/LinkCKit/Board/BoardMapStore.swift`:

```swift
import Foundation

public enum BoardMapStoreError: Error, Equatable {
    /// The file no longer holds what linkC last read — something else changed it.
    case changedOnDisk
}

/// Reads and writes a project's `system-map.json` at its root. It remembers nothing: the caller
/// keeps the bytes it read and hands them back, so a change made underneath it is never overwritten.
public struct BoardMapStore: Sendable {
    public let fileURL: URL

    public struct Loaded: Sendable {
        public let map: BoardMap
        /// Exactly what was on disk — what the next save must still find there.
        public let bytes: Data
    }

    public init(workspacePath: String) {
        let workspace = URL(fileURLWithPath: (workspacePath as NSString).standardizingPath, isDirectory: true)
        fileURL = workspace.appendingPathComponent("system-map.json")
    }

    /// The project's map, or nil when it has none. Throws when a file exists but cannot be read.
    public func load() throws -> Loaded? {
        guard let bytes = try currentBytes() else { return nil }
        return Loaded(map: try BoardMap.decode(bytes), bytes: bytes)
    }

    /// Writes `map` only if the file still holds `expected` — or is still absent when `expected`
    /// is nil. Returns the bytes written, which become the next save's `expected`.
    public func save(_ map: BoardMap, expecting expected: Data?) throws -> Data {
        guard try currentBytes() == expected else { throw BoardMapStoreError.changedOnDisk }
        let data = try map.encoded()
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw LinkCError.server("could not write \(fileURL.path): \(error.localizedDescription)")
        }
        return data
    }

    private func currentBytes() throws -> Data? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            return try Data(contentsOf: fileURL)
        } catch {
            throw LinkCError.server("could not read \(fileURL.path): \(error.localizedDescription)")
        }
    }
}
```

- [ ] **Step 4: Move and adapt the reconciler**

`git mv Sources/LinkCKit/Workbench/SystemReconciler.swift Sources/LinkCKit/Board/BoardReconciler.swift`, then in that file:
- rename `enum SystemReconciler` to `enum BoardReconciler`;
- change `reconcile(map: SystemMap, …)` to `reconcile(map: BoardMap, …)`;
- replace `component.intended` with `component.planned`;
- replace `isCheckable(_ component: SystemComponent)` with the version that also reads the place:

```swift
    /// linkC may only report something missing when the map says it runs where linkC looks —
    /// in its own `runs` text, or in the label of the frame it lives in.
    private static func isCheckable(_ component: BoardComponent) -> Bool {
        let evidence = "\(component.runs ?? "") \(component.place)".lowercased()
        return evidence.contains("docker") || evidence.contains("compose")
    }
```

Keep `DiscoveredThing`, `ComponentStatus`, `MapSuggestion`, `kind(forImage:)`, `namesInRuns` and the claiming rules exactly as they are.

- [ ] **Step 5: Write the report**

Create `Sources/LinkCKit/Board/BoardReport.swift`. Copy `maxFieldLength` and `sanitized(_:)` verbatim from `Sources/LinkCKit/Workbench/SystemMapReport.swift` into it, then add:

```swift
import Foundation

/// The map as an agent reads it from `linkc_get_project_context`: the system, each place with
/// its components, then the notes. No coordinates — they mean nothing to an agent.
public enum BoardReport {
    /// "" when the map says nothing — an empty section is noise in a tool result.
    public static func markdown(for map: BoardMap) -> String {
        let system = map.system?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !map.components.isEmpty || !map.notes.isEmpty || !system.isEmpty else { return "" }

        var text = "## System\n"
        text += "_Status here is not checked — this is only what the file says. linkC's board is what shows what is actually running._\n"
        if !system.isEmpty { text += "\(sanitized(system))\n" }

        // Every place a component names, even one with no frame, so nothing is ever dropped.
        let labels = Set(map.frames.map(\.label)).union(map.components.map(\.place)).subtracting([BoardMap.notPlaced])
        let order = labels.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending } + [BoardMap.notPlaced]
        for place in order {
            let members = map.components
                .filter { $0.place == place }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            guard !members.isEmpty else { continue }
            text += "\n### \(sanitized(place))\n"
            for component in members { text += line(for: component) }
        }

        if !map.notes.isEmpty {
            text += "\n### Notes\n"
            for note in map.notes { text += "- \(sanitized(note.text))\n" }
        }
        return text + "\n"
    }

    private static func line(for component: BoardComponent) -> String {
        var head = "- **\(sanitized(component.name))** (\(sanitized(component.kind.raw))"
        if component.planned { head += ", PLANNED — does not exist yet" }
        head += ")"

        var parts: [String] = []
        if let does = nonEmpty(component.does) { parts.append(sanitized(does)) }
        if let reachedBy = nonEmpty(component.reachedBy) { parts.append("reached by \(sanitized(reachedBy))") }
        if let runs = nonEmpty(component.runs) { parts.append("runs \(sanitized(runs))") }
        if !component.uses.isEmpty {
            let uses = component.uses.keys.sorted().map { target -> String in
                let label = component.uses[target] ?? ""
                return label.isEmpty ? sanitized(target) : "\(sanitized(target)) (\(sanitized(label)))"
            }
            parts.append("uses \(uses.joined(separator: ", "))")
        }
        if !component.legacyUsedBy.isEmpty {
            parts.append("used by \(component.legacyUsedBy.map(sanitized).joined(separator: ", "))")
        }
        return parts.isEmpty ? "\(head)\n" : "\(head) — \(parts.joined(separator: "; "))\n"
    }

    private static func nonEmpty(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    // maxFieldLength and sanitized(_:), copied verbatim from SystemMapReport.swift, go here.
}
```

(The last comment marks where the two copied declarations go; the file must contain them, not the comment.)

- [ ] **Step 6: Switch the MCP tool**

In `Sources/LinkCKit/MCP/MCPServer.swift`, replace the block that loads the map in `case "linkc_get_project_context":` with:

```swift
            do {
                if let loaded = try BoardMapStore(workspacePath: board.projectPath).load() {
                    text += BoardReport.markdown(for: loaded.map)
                }
            } catch {
                text += "## System\n_The system map could not be read: \(error.localizedDescription)_\n\n"
            }
```

- [ ] **Step 7: Delete what the new types replace**

```bash
git rm Sources/LinkCKit/Workbench/SystemMap.swift Sources/LinkCKit/Workbench/SystemMapStore.swift \
  Sources/LinkCKit/Workbench/SystemMapReport.swift \
  Tests/LinkCKitTests/SystemMapTests.swift Tests/LinkCKitTests/SystemMapStoreTests.swift \
  Tests/LinkCKitTests/SystemMapReportTests.swift Tests/LinkCKitTests/SystemReconcilerTests.swift
```

Then `grep -rn "SystemMap\b\|SystemComponent\|SystemMapStore\|SystemMapReport\|SystemReconciler\|GridPoint" Sources Tests` — every remaining hit must be updated to the new types. The MCP project-context tests that write `system-map.json` still use a version-1 file: keep those files as they are (version 1 is still read) and update only assertions on wording that changed — `INTENDED` is now `PLANNED`, and the report now groups under `### Not placed`.

- [ ] **Step 8: Run the tests and see them pass**

Run: `swift test --filter "BoardMapTests|BoardMapStoreTests|BoardReconcilerTests|BoardReportTests|MCPServer"`
Expected: every test passes.
Run: `swift build 2>&1 | tail -3` — expected `Build complete!` (the app target still calls `discoveredThings(in:)`, which returns `DiscoveredThing` values, unchanged).

- [ ] **Step 9: Commit**

```bash
git add Sources/LinkCKit/Board Sources/LinkCKit/MCP/MCPServer.swift Tests/LinkCKitTests
git add -A Sources/LinkCKit/Workbench
git diff --cached --stat
git commit -m "feat(board): store, reconcile and report the new map, and serve it to agents"
git log -1 --format=%B | grep -ic claude   # must print 0
```

---
### Task 4: Board geometry and the viewport

**Files:**
- Create: `Sources/LinkCKit/Board/BoardGeometry.swift`
- Create: `Sources/LinkCKit/Board/BoardViewport.swift`
- Test: `Tests/LinkCKitTests/BoardGeometryTests.swift`, `Tests/LinkCKitTests/BoardViewportTests.swift`

**Interfaces:**
- Consumes: `BoardPoint`, `BoardRect`, `BoardFrame`, `BoardText`, `BoardTextStyle` (Task 2).
- Produces:
  - `enum BoardGeometry` —
    - sizes: `componentSize = BoardPoint(x: 152, y: 56)`, `noteSize = BoardPoint(x: 176, y: 120)`, `frameMinSize = BoardPoint(x: 176, y: 96)`, `frameInset = 8`, `func textHeight(_ style: BoardTextStyle) -> Int`
    - `rect(ofComponentAt:)`, `rect(ofNoteAt:)`, `rect(of text: BoardText)`
    - `frame(containing rect: BoardRect, frames: [BoardFrame]) -> BoardFrame?`
    - `interior(of frame: BoardRect) -> BoardRect`
    - `nearestFreeSpot(for:avoiding:inside:outside:maxRadius:) -> BoardRect?`
    - `elementDrop(_:otherElements:frames:) -> BoardRect`
    - `frameDrop(_:otherFrames:foreignElements:) -> BoardRect`
    - `frameResize(_:original:members:otherFrames:foreignElements:) -> BoardRect`
    - `grow(_ frame: BoardRect, toFit size: BoardPoint, members:otherFrames:foreignElements:) -> BoardRect?`
    - `route(from:to:obstacles:) -> [BoardPoint]`
    - `segmentIntersects(_:_:_:) -> Bool`
    - `visibleIndices(of:in:) -> [Int]`
  - `struct BoardViewport: Equatable, Sendable, Codable` — `originX`, `originY`, `zoom` (Double), `minZoom = 0.25`, `maxZoom = 2.0`, `initial`, `toCanvas(_:)`, `toScreen(_:)`, `panned(byScreenDX:dy:)`, `zoomed(by:aroundScreen:)`, `visibleRect(width:height:)`, `static func fitting(_:width:height:margin:)`

- [ ] **Step 1: Write the failing tests**

Create `Tests/LinkCKitTests/BoardGeometryTests.swift`:

```swift
import XCTest
@testable import LinkCKit

final class BoardGeometryTests: XCTestCase {
    private func box(_ x: Int, _ y: Int, _ w: Int = 16, _ h: Int = 16) -> BoardRect { BoardRect(x: x, y: y, w: w, h: h) }

    func testElementSizes() {
        XCTAssertEqual(BoardGeometry.rect(ofComponentAt: BoardPoint(x: 8, y: 16)), BoardRect(x: 8, y: 16, w: 152, h: 56))
        XCTAssertEqual(BoardGeometry.rect(ofNoteAt: BoardPoint(x: 0, y: 0)), BoardRect(x: 0, y: 0, w: 176, h: 120))
        let title = BoardText(text: "June", style: .title, at: BoardPoint(x: 0, y: 0), width: 64)
        XCTAssertEqual(BoardGeometry.rect(of: title), BoardRect(x: 0, y: 0, w: 64, h: 32))
    }

    func testAFrameHoldsWhatItsCentreIsIn() {
        let frames = [BoardFrame(label: "Docker", rect: box(0, 0, 400, 200)), BoardFrame(label: "Oracle", rect: box(500, 0, 200, 200))]
        XCTAssertEqual(BoardGeometry.frame(containing: box(380, 90, 152, 56), frames: frames)?.label, nil,
                       "centre at x 456 is outside both")
        XCTAssertEqual(BoardGeometry.frame(containing: box(300, 90, 152, 56), frames: frames)?.label, "Docker")
        XCTAssertNil(BoardGeometry.frame(containing: box(0, 0), frames: [BoardFrame(label: "No rect")]))
    }

    func testAFreeSpotIsLeftAlone() {
        XCTAssertEqual(BoardGeometry.nearestFreeSpot(for: box(40, 40), avoiding: [box(0, 0)]), box(40, 40))
    }

    /// On a tie the order is right, then down, then left, then up — the same answer every time.
    func testTiesBreakRightDownLeftUp() {
        let obstacle = box(0, 0)
        XCTAssertEqual(BoardGeometry.nearestFreeSpot(for: box(0, 0), avoiding: [obstacle]), box(16, 0))
        XCTAssertEqual(BoardGeometry.nearestFreeSpot(for: box(0, 0), avoiding: [obstacle, box(16, 0)]), box(0, 16))
        XCTAssertEqual(BoardGeometry.nearestFreeSpot(for: box(0, 0), avoiding: [obstacle, box(16, 0), box(0, 16)]), box(-16, 0))
        XCTAssertEqual(BoardGeometry.nearestFreeSpot(for: box(0, 0), avoiding: [obstacle, box(16, 0), box(0, 16), box(-16, 0)]), box(0, -16))
    }

    func testTheSmallestMoveWinsOverDirection() {
        // Moving down 56 beats moving right 152.
        let component = BoardRect(x: 0, y: 0, w: 152, h: 56)
        XCTAssertEqual(BoardGeometry.nearestFreeSpot(for: component, avoiding: [component]), BoardRect(x: 0, y: 56, w: 152, h: 56))
    }

    func testAnElementDroppedInAFrameStaysWhollyInside() throws {
        let frame = box(0, 0, 320, 160)
        let dropped = BoardRect(x: 200, y: 20, w: 152, h: 56)   // centre (276, 48) is inside; right edge sticks out
        let placed = BoardGeometry.elementDrop(dropped, otherElements: [], frames: [frame])
        XCTAssertTrue(BoardGeometry.interior(of: frame).contains(placed), "\(placed)")
    }

    func testAnElementDroppedAcrossAnEdgeWithItsCentreOutsideGoesWhollyOutside() {
        let frame = box(0, 0, 320, 160)
        let dropped = BoardRect(x: 300, y: 20, w: 152, h: 56)   // centre (376, 48) is outside
        let placed = BoardGeometry.elementDrop(dropped, otherElements: [], frames: [frame])
        XCTAssertFalse(placed.intersects(frame), "\(placed)")
    }

    func testAFullFrameSendsTheElementOutside() {
        let frame = box(0, 0, 168, 72)      // interior fits exactly one component
        let resident = BoardRect(x: 8, y: 8, w: 152, h: 56)
        let placed = BoardGeometry.elementDrop(BoardRect(x: 8, y: 8, w: 152, h: 56), otherElements: [resident], frames: [frame])
        XCTAssertFalse(placed.intersects(frame))
        XCTAssertFalse(placed.intersects(resident))
    }

    func testAFrameNeverLandsOnAnotherFrameOrSomethingNotItsOwn() {
        let other = box(0, 0, 200, 200)
        let stranger = box(260, 0, 152, 56)
        let placed = BoardGeometry.frameDrop(box(100, 0, 200, 200), otherFrames: [other], foreignElements: [stranger])
        XCTAssertFalse(placed.intersects(other))
        XCTAssertFalse(placed.intersects(stranger))
    }

    func testAResizeNeverShrinksPastItsMembersOrGrowsOverAnything() {
        let original = box(0, 0, 400, 200)
        let member = BoardRect(x: 200, y: 100, w: 152, h: 56)
        let shrunk = BoardGeometry.frameResize(box(0, 0, 100, 100), original: original, members: [member], otherFrames: [], foreignElements: [])
        XCTAssertTrue(BoardGeometry.interior(of: shrunk).contains(member), "\(shrunk)")

        let neighbour = box(480, 0, 100, 100)
        let grown = BoardGeometry.frameResize(box(0, 0, 600, 200), original: original, members: [], otherFrames: [neighbour], foreignElements: [])
        XCTAssertFalse(grown.intersects(neighbour), "\(grown)")
        XCTAssertGreaterThanOrEqual(grown.w, 400, "it grows up to the neighbour")
    }

    func testAFrameGrowsDownToFitOneMore() throws {
        let frame = box(0, 0, 168, 72)
        let resident = BoardRect(x: 8, y: 8, w: 152, h: 56)
        let grown = try XCTUnwrap(BoardGeometry.grow(frame, toFit: BoardGeometry.componentSize, members: [resident], otherFrames: [], foreignElements: []))
        XCTAssertEqual(grown.x, 0)
        XCTAssertEqual(grown.w, 168)
        XCTAssertGreaterThan(grown.h, 72)
        XCTAssertNil(BoardGeometry.grow(frame, toFit: BoardGeometry.componentSize, members: [resident], otherFrames: [box(0, 72, 168, 400)], foreignElements: []),
                     "a frame hemmed in below cannot grow")
    }

    func testAnArrowLeavesFromTheFacingSides() {
        let api = BoardRect(x: 0, y: 0, w: 152, h: 56)
        let db = BoardRect(x: 400, y: 0, w: 152, h: 56)
        XCTAssertEqual(BoardGeometry.route(from: api, to: db, obstacles: []), [BoardPoint(x: 152, y: 28), BoardPoint(x: 400, y: 28)])
        let below = BoardRect(x: 0, y: 300, w: 152, h: 56)
        XCTAssertEqual(BoardGeometry.route(from: api, to: below, obstacles: []), [BoardPoint(x: 76, y: 56), BoardPoint(x: 76, y: 300)])
    }

    func testAnArrowBendsAroundABoxInItsWay() {
        let api = BoardRect(x: 0, y: 100, w: 152, h: 56)
        let blocker = BoardRect(x: 220, y: 100, w: 152, h: 56)
        let db = BoardRect(x: 440, y: 100, w: 152, h: 56)
        let route = BoardGeometry.route(from: api, to: db, obstacles: [blocker])
        XCTAssertGreaterThan(route.count, 2, "it bends")
        for (a, b) in zip(route, route.dropFirst()) {
            XCTAssertFalse(BoardGeometry.segmentIntersects(a, b, blocker), "\(a) → \(b) crosses the blocker")
        }
        XCTAssertEqual(route.first, BoardPoint(x: 152, y: 128))
        XCTAssertEqual(route.last, BoardPoint(x: 440, y: 128))
    }

    func testWithNoSimpleRouteTheArrowGoesDirect() {
        let api = BoardRect(x: 0, y: 100, w: 152, h: 56)
        let wall = BoardRect(x: 200, y: -5000, w: 20, h: 10000)
        let db = BoardRect(x: 440, y: 100, w: 152, h: 56)
        XCTAssertEqual(BoardGeometry.route(from: api, to: db, obstacles: [wall]).count, 2)
    }

    func testOnlyWhatIsOnScreenIsKept() {
        let rects = [box(0, 0), box(900, 900), box(100, 100)]
        XCTAssertEqual(BoardGeometry.visibleIndices(of: rects, in: box(0, 0, 200, 200)), [0, 2])
    }

    /// The budget: 200 drops and 200 routes on a 200-component board, well under a second even
    /// in a debug build.
    func testTwoHundredComponentsStayFast() {
        var placed: [BoardRect] = []
        for index in 0..<200 {
            placed.append(BoardRect(x: (index % 20) * 168, y: (index / 20) * 72, w: 152, h: 56))
        }
        let start = Date()
        for index in 0..<200 {
            _ = BoardGeometry.elementDrop(placed[index].offsetBy(dx: 40, dy: 40),
                                          otherElements: placed.enumerated().filter { $0.offset != index }.map(\.element),
                                          frames: [])
        }
        for index in 0..<199 {
            _ = BoardGeometry.route(from: placed[index], to: placed[index + 1], obstacles: placed)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }
}
```

Create `Tests/LinkCKitTests/BoardViewportTests.swift`:

```swift
import XCTest
@testable import LinkCKit

final class BoardViewportTests: XCTestCase {
    func testScreenAndCanvasAreInverse() {
        let viewport = BoardViewport(originX: 100, originY: 50, zoom: 2)
        let screen = viewport.toScreen(CGPoint(x: 150, y: 80))
        XCTAssertEqual(screen, CGPoint(x: 100, y: 60))
        XCTAssertEqual(viewport.toCanvas(screen), CGPoint(x: 150, y: 80))
    }

    func testPanningMovesByScreenDistance() {
        let panned = BoardViewport(originX: 0, originY: 0, zoom: 2).panned(byScreenDX: 20, dy: -10)
        XCTAssertEqual(panned.originX, -10)
        XCTAssertEqual(panned.originY, 5)
    }

    /// Zooming keeps the canvas point under the pointer where it was.
    func testZoomingKeepsThePointUnderThePointer() {
        let viewport = BoardViewport(originX: 0, originY: 0, zoom: 1)
        let pointer = CGPoint(x: 200, y: 100)
        let before = viewport.toCanvas(pointer)
        let zoomed = viewport.zoomed(by: 1.5, aroundScreen: pointer)
        XCTAssertEqual(zoomed.zoom, 1.5)
        XCTAssertEqual(zoomed.toCanvas(pointer).x, before.x, accuracy: 0.001)
        XCTAssertEqual(zoomed.toCanvas(pointer).y, before.y, accuracy: 0.001)
    }

    func testZoomIsClamped() {
        XCTAssertEqual(BoardViewport.initial.zoomed(by: 100, aroundScreen: .zero).zoom, 2.0)
        XCTAssertEqual(BoardViewport.initial.zoomed(by: 0.001, aroundScreen: .zero).zoom, 0.25)
    }

    func testTheVisibleRectCoversTheView() {
        let rect = BoardViewport(originX: 40, originY: 80, zoom: 0.5).visibleRect(width: 400, height: 200)
        XCTAssertEqual(rect, BoardRect(x: 40, y: 80, w: 800, h: 400))
    }

    func testFittingShowsEverything() {
        let content = BoardRect(x: 0, y: 0, w: 1000, h: 500)
        let viewport = BoardViewport.fitting(content, width: 600, height: 400, margin: 50)
        let visible = viewport.visibleRect(width: 600, height: 400)
        XCTAssertTrue(visible.contains(content), "\(visible)")
        XCTAssertLessThanOrEqual(viewport.zoom, 1.0)
    }
}
```

- [ ] **Step 2: Run the tests and see them fail**

Run: `swift test --filter "BoardGeometryTests|BoardViewportTests"`
Expected: build failure — `cannot find 'BoardGeometry' in scope`.

- [ ] **Step 3: Implement the geometry**

Create `Sources/LinkCKit/Board/BoardGeometry.swift`:

```swift
import Foundation

/// The board's plain maths: sizes, containment, collisions, arrow routes and what is on screen.
/// No UI, no state — every rule the canvas follows is here and tested here.
public enum BoardGeometry {
    public static let componentSize = BoardPoint(x: 152, y: 56)
    public static let noteSize = BoardPoint(x: 176, y: 120)
    public static let frameMinSize = BoardPoint(x: 176, y: 96)
    /// The margin kept between a frame's border and anything inside it.
    public static let frameInset = 8
    /// How far an arrow's elbow keeps clear of the box it bends around.
    static let clearance = 16
    /// The furthest an elbow may swing from the straight line; beyond it there is no simple route.
    static let maxDetour = 480

    public static func textHeight(_ style: BoardTextStyle) -> Int {
        style == .title ? 32 : 20
    }

    public static func rect(ofComponentAt point: BoardPoint) -> BoardRect {
        BoardRect(x: point.x, y: point.y, w: componentSize.x, h: componentSize.y)
    }

    public static func rect(ofNoteAt point: BoardPoint) -> BoardRect {
        BoardRect(x: point.x, y: point.y, w: noteSize.x, h: noteSize.y)
    }

    public static func rect(of text: BoardText) -> BoardRect {
        BoardRect(x: text.at.x, y: text.at.y, w: max(text.width, BoardPoint.grid), h: textHeight(text.style))
    }

    /// The frame whose rect holds the rect's centre; nil means the rect is not placed.
    public static func frame(containing rect: BoardRect, frames: [BoardFrame]) -> BoardFrame? {
        frames.first { $0.rect?.contains(rect.center) == true }
    }

    public static func interior(of frame: BoardRect) -> BoardRect {
        BoardRect(x: frame.x + frameInset, y: frame.y + frameInset,
                  w: max(0, frame.w - 2 * frameInset), h: max(0, frame.h - 2 * frameInset))
    }

    /// The nearest spot for `rect` that overlaps none of `obstacles`, lies wholly inside `container`
    /// when one is given, and touches none of `excluded`. The smallest move on the 8-point grid
    /// wins; ties go right, then down, then left, then up. nil when nothing within `maxRadius` fits.
    public static func nearestFreeSpot(
        for rect: BoardRect, avoiding obstacles: [BoardRect], inside container: BoardRect? = nil,
        outside excluded: [BoardRect] = [], maxRadius: Int = 4096
    ) -> BoardRect? {
        func fits(_ candidate: BoardRect) -> Bool {
            if let container, !container.contains(candidate) { return false }
            if obstacles.contains(where: { $0.intersects(candidate) }) { return false }
            if excluded.contains(where: { $0.intersects(candidate) }) { return false }
            return true
        }
        if fits(rect) { return rect }

        let step = BoardPoint.grid
        let maxSteps = maxRadius / step
        // Inside a container nothing further than its own size can fit, so the search stops there.
        let limit = container.map { min(maxSteps, max($0.w, $0.h) / step + 1) } ?? maxSteps
        var best: (distance: Int, rank: Int, j: Int, i: Int)?
        for ring in 1...max(1, limit) {
            // Nothing on this ring can be nearer than `ring` steps.
            if let best, ring * ring * step * step > best.distance { break }
            for i in -ring...ring {
                for j in -ring...ring where max(abs(i), abs(j)) == ring {
                    let candidate = rect.offsetBy(dx: i * step, dy: j * step)
                    guard fits(candidate) else { continue }
                    let key = (distance: (i * i + j * j) * step * step, rank: directionRank(i, j), j: j, i: i)
                    if let current = best {
                        if (key.distance, key.rank, key.j, key.i) < (current.distance, current.rank, current.j, current.i) { best = key }
                    } else {
                        best = key
                    }
                }
            }
        }
        guard let best else { return nil }
        return rect.offsetBy(dx: best.i * step, dy: best.j * step)
    }

    /// Right, down, left, up, then every other direction.
    private static func directionRank(_ i: Int, _ j: Int) -> Int {
        switch (i.signum(), j.signum()) {
        case (1, 0): return 0
        case (0, 1): return 1
        case (-1, 0): return 2
        case (0, -1): return 3
        default: return 4
        }
    }

    /// Where a component, note or text dropped at `rect` lands: overlapping nothing, and wholly
    /// inside the frame holding its centre — or wholly outside every frame when its centre is in
    /// none, or when that frame has no room.
    public static func elementDrop(_ rect: BoardRect, otherElements: [BoardRect], frames: [BoardRect]) -> BoardRect {
        if let container = frames.first(where: { $0.contains(rect.center) }),
           let inside = nearestFreeSpot(for: rect, avoiding: otherElements, inside: interior(of: container)) {
            return inside
        }
        return nearestFreeSpot(for: rect, avoiding: otherElements, outside: frames) ?? rect
    }

    /// Where a moved frame lands: overlapping no other frame and nothing that is not its own.
    public static func frameDrop(_ rect: BoardRect, otherFrames: [BoardRect], foreignElements: [BoardRect]) -> BoardRect {
        nearestFreeSpot(for: rect, avoiding: otherFrames + foreignElements) ?? rect
    }

    /// A frame resized from its bottom-right corner: never smaller than its minimum or than what
    /// it holds, and stopped at the first thing it would grow over.
    public static func frameResize(
        _ proposed: BoardRect, original: BoardRect, members: [BoardRect], otherFrames: [BoardRect], foreignElements: [BoardRect]
    ) -> BoardRect {
        var result = BoardRect(x: original.x, y: original.y, w: proposed.w, h: proposed.h)
        let membersRight = members.map(\.maxX).max().map { $0 + frameInset } ?? original.x
        let membersBottom = members.map(\.maxY).max().map { $0 + frameInset } ?? original.y
        result.w = max(result.w, frameMinSize.x, membersRight - original.x)
        result.h = max(result.h, frameMinSize.y, membersBottom - original.y)

        for obstacle in otherFrames + foreignElements where obstacle.intersects(result) {
            if obstacle.minX >= original.maxX {
                result.w = obstacle.minX - original.x
            } else if obstacle.minY >= original.maxY {
                result.h = obstacle.minY - original.y
            } else {
                return original
            }
        }
        let floor = BoardRect(x: original.x, y: original.y,
                              w: max(frameMinSize.x, membersRight - original.x), h: max(frameMinSize.y, membersBottom - original.y))
        guard result.w >= floor.w, result.h >= floor.h else { return original }
        return result
    }

    /// The frame grown downward, a row at a time, until an element of `size` fits inside —
    /// nil when growing would reach another frame or something not its own.
    public static func grow(
        _ frame: BoardRect, toFit size: BoardPoint, members: [BoardRect], otherFrames: [BoardRect], foreignElements: [BoardRect]
    ) -> BoardRect? {
        var candidate = frame
        for _ in 0..<32 {
            let seed = BoardRect(x: candidate.x + frameInset, y: candidate.y + frameInset, w: size.x, h: size.y)
            if nearestFreeSpot(for: seed, avoiding: members, inside: interior(of: candidate)) != nil { return candidate }
            candidate.h += size.y + frameInset
            if (otherFrames + foreignElements).contains(where: { $0.intersects(candidate) }) { return nil }
        }
        return nil
    }

    /// An arrow's path: from the side of `source` facing `target` to the side of `target` facing
    /// `source`. Straight when clear; otherwise an elbow around the boxes in the way, on whichever
    /// side is shorter; direct again when neither elbow is clear.
    public static func route(from source: BoardRect, to target: BoardRect, obstacles: [BoardRect]) -> [BoardPoint] {
        let blockers = obstacles.filter { $0 != source && $0 != target }
        let dx = target.center.x - source.center.x
        let dy = target.center.y - source.center.y
        let horizontal = abs(dx) >= abs(dy)

        let start: BoardPoint
        let end: BoardPoint
        if horizontal {
            start = BoardPoint(x: dx >= 0 ? source.maxX : source.minX, y: source.center.y)
            end = BoardPoint(x: dx >= 0 ? target.minX : target.maxX, y: target.center.y)
        } else {
            start = BoardPoint(x: source.center.x, y: dy >= 0 ? source.maxY : source.minY)
            end = BoardPoint(x: target.center.x, y: dy >= 0 ? target.minY : target.maxY)
        }

        let direct = [start, end]
        let inTheWay = blockers.filter { segmentIntersects(start, end, $0) }
        guard !inTheWay.isEmpty else { return direct }

        var options: [[BoardPoint]] = []
        if horizontal {
            let lead = dx >= 0 ? clearance : -clearance
            let above = (inTheWay.map(\.minY).min() ?? start.y) - clearance
            let below = (inTheWay.map(\.maxY).max() ?? start.y) + clearance
            for detour in [above, below] where abs(detour - start.y) <= maxDetour {
                options.append([start, BoardPoint(x: start.x + lead, y: start.y), BoardPoint(x: start.x + lead, y: detour),
                                BoardPoint(x: end.x - lead, y: detour), BoardPoint(x: end.x - lead, y: end.y), end])
            }
        } else {
            let lead = dy >= 0 ? clearance : -clearance
            let left = (inTheWay.map(\.minX).min() ?? start.x) - clearance
            let right = (inTheWay.map(\.maxX).max() ?? start.x) + clearance
            for detour in [left, right] where abs(detour - start.x) <= maxDetour {
                options.append([start, BoardPoint(x: start.x, y: start.y + lead), BoardPoint(x: detour, y: start.y + lead),
                                BoardPoint(x: detour, y: end.y - lead), BoardPoint(x: end.x, y: end.y - lead), end])
            }
        }

        let clear = options.filter { path in
            zip(path, path.dropFirst()).allSatisfy { a, b in !blockers.contains { segmentIntersects(a, b, $0) } }
        }
        return clear.min { length($0) < length($1) } ?? direct
    }

    private static func length(_ path: [BoardPoint]) -> Int {
        zip(path, path.dropFirst()).reduce(0) { total, pair in total + abs(pair.1.x - pair.0.x) + abs(pair.1.y - pair.0.y) }
    }

    /// Whether the segment from `a` to `b` passes through the inside of `rect` (touching an edge
    /// does not count). Liang–Barsky clipping.
    public static func segmentIntersects(_ a: BoardPoint, _ b: BoardPoint, _ rect: BoardRect) -> Bool {
        let x0 = Double(a.x), y0 = Double(a.y)
        let dx = Double(b.x - a.x), dy = Double(b.y - a.y)
        var t0 = 0.0, t1 = 1.0
        let edges: [(Double, Double)] = [
            (-dx, x0 - Double(rect.minX)), (dx, Double(rect.maxX) - x0),
            (-dy, y0 - Double(rect.minY)), (dy, Double(rect.maxY) - y0),
        ]
        for (p, q) in edges {
            if p == 0 {
                if q <= 0 { return false }
            } else {
                let r = q / p
                if p < 0 { t0 = max(t0, r) } else { t1 = min(t1, r) }
                if t0 >= t1 { return false }
            }
        }
        return true
    }

    /// The indices of the rects that intersect `viewport`, in order.
    public static func visibleIndices(of rects: [BoardRect], in viewport: BoardRect) -> [Int] {
        rects.indices.filter { rects[$0].intersects(viewport) }
    }
}
```

- [ ] **Step 4: Implement the viewport**

Create `Sources/LinkCKit/Board/BoardViewport.swift`:

```swift
import CoreGraphics
import Foundation

/// Which part of the canvas is on screen. `originX`/`originY` is the canvas point at the view's
/// top-left corner; `zoom` is screen points per canvas point. Personal: kept on this Mac, never
/// in the file.
public struct BoardViewport: Equatable, Sendable, Codable {
    public var originX: Double
    public var originY: Double
    public var zoom: Double

    public static let minZoom = 0.25
    public static let maxZoom = 2.0
    public static let initial = BoardViewport(originX: -40, originY: -40, zoom: 1)

    public init(originX: Double, originY: Double, zoom: Double) {
        self.originX = originX
        self.originY = originY
        self.zoom = min(Self.maxZoom, max(Self.minZoom, zoom))
    }

    public func toCanvas(_ screen: CGPoint) -> CGPoint {
        CGPoint(x: screen.x / zoom + originX, y: screen.y / zoom + originY)
    }

    public func toScreen(_ canvas: CGPoint) -> CGPoint {
        CGPoint(x: (canvas.x - originX) * zoom, y: (canvas.y - originY) * zoom)
    }

    /// Content follows the fingers: a drag of `dx` screen points moves the canvas by `dx / zoom`.
    public func panned(byScreenDX dx: Double, dy: Double) -> BoardViewport {
        BoardViewport(originX: originX - dx / zoom, originY: originY - dy / zoom, zoom: zoom)
    }

    /// Zoom by `factor`, keeping the canvas point under `pointer` fixed.
    public func zoomed(by factor: Double, aroundScreen pointer: CGPoint) -> BoardViewport {
        let anchor = toCanvas(pointer)
        let zoom = min(Self.maxZoom, max(Self.minZoom, zoom * factor))
        return BoardViewport(originX: anchor.x - pointer.x / zoom, originY: anchor.y - pointer.y / zoom, zoom: zoom)
    }

    public func visibleRect(width: Double, height: Double) -> BoardRect {
        BoardRect(x: Int(originX.rounded(.down)), y: Int(originY.rounded(.down)),
                  w: Int((width / zoom).rounded(.up)), h: Int((height / zoom).rounded(.up)))
    }

    /// The viewport that shows all of `bounds` with `margin` screen points around it, never
    /// zoomed in past 100%.
    public static func fitting(_ bounds: BoardRect, width: Double, height: Double, margin: Double = 48) -> BoardViewport {
        let usableWidth = max(1, width - 2 * margin)
        let usableHeight = max(1, height - 2 * margin)
        let zoom = min(1.0, min(usableWidth / Double(max(1, bounds.w)), usableHeight / Double(max(1, bounds.h))))
        let clamped = min(maxZoom, max(minZoom, zoom))
        let centreX = Double(bounds.x) + Double(bounds.w) / 2
        let centreY = Double(bounds.y) + Double(bounds.h) / 2
        return BoardViewport(originX: centreX - width / (2 * clamped), originY: centreY - height / (2 * clamped), zoom: clamped)
    }
}
```

- [ ] **Step 5: Run the tests and see them pass**

Run: `swift test --filter "BoardGeometryTests|BoardViewportTests"`
Expected: all pass (16 + 6). If `testTwoHundredComponentsStayFast` is over budget, profile `nearestFreeSpot` before touching the budget — the budget is a spec requirement.

- [ ] **Step 6: Commit**

```bash
git add Sources/LinkCKit/Board/BoardGeometry.swift Sources/LinkCKit/Board/BoardViewport.swift Tests/LinkCKitTests/BoardGeometryTests.swift Tests/LinkCKitTests/BoardViewportTests.swift
git diff --cached --stat
git commit -m "feat(board): collisions, containment, arrow routes and the viewport, as plain maths"
git log -1 --format=%B | grep -ic claude   # must print 0
```

---

### Task 5: The board model — loading, writing, undo and content edits

**Files:**
- Create: `Sources/LinkCKit/Board/BoardModel.swift`
- Test: `Tests/LinkCKitTests/BoardModelTests.swift`

**Interfaces:**
- Consumes: `BoardMap` and its element types (Task 2); `BoardMapStore`, `BoardMapStoreError`, `BoardReconciler`, `DiscoveredThing`, `ComponentStatus`, `MapSuggestion` (Task 3); `BoardGeometry` (Task 4).
- Produces: `@MainActor @Observable public final class BoardModel` with
  - `enum State: Equatable, Sendable { case empty, loaded, failed(String) }`
  - `enum Tool: Equatable, Sendable { case select, component(ComponentKind), arrow, frame, note, text }`
  - `struct ArrowKey: Hashable, Sendable { from: String; to: String }`
  - `enum Element: Hashable, Sendable { case component(String), frame(String), note(UUID), text(UUID), arrow(ArrowKey) }`
  - read-only: `state`, `map`, `statuses`, `suggestions`, `routes: [ArrowKey: [BoardPoint]]`, `refusal: String?`, `writeFailure: String?`, `changedOnDisk: Bool`, `canUndo`, `canRedo`, `isEmpty`; settable: `selection: Set<Element>`, `tool: Tool`; `static let undoLimit = 100`
  - `init(store:settle:sleep:)`, `load()`, `reload()`, `startMap()`, `reconcile(with:)`, `saveNow()`, `undo()`, `redo()`
  - `setSystem(_:)`, `addComponent(kind:at:) -> String?`, `addNote(at:) -> UUID?`, `addText(at:style:text:width:) -> UUID?`, `addFrame(_:) -> String?`, `updateComponent(_:to:) -> Bool`, `renameFrame(_:to:) -> Bool`, `setNoteText(_:to:)`, `setText(_:to:width:)`, `addArrow(from:to:) -> Bool`, `setArrowLabel(_:to:)`, `delete(_:)`, `addSuggestion(_:)`, `addAllRunning()`
  - internal hooks Task 6 extends: `func edit(_ change: (inout BoardMap) -> Bool)`, `func refuse(_ message: String) -> Bool`, `func afterMapChange()`, `static func elementRects(_ map: BoardMap, excluding: Set<Element>) -> [BoardRect]`, `static func frameRects(_ map: BoardMap, excluding: Set<String>) -> [BoardRect]`

Write rules, exactly as the spec's §3 "Rules": never write without an edit; a read failure locks the board (no edits, no writes); a write failure is surfaced in `writeFailure`, stays editable and retries on the next edit or `saveNow()`; a changed-on-disk refusal sets `changedOnDisk`, locks edits, and only `reload()` clears it. Debounce: copy the pattern of `Sources/LinkCKit/App/FlashMessage.swift` — injected `sleep`, a generation counter, a `Task { @MainActor [weak self] }`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/LinkCKitTests/BoardModelTests.swift`:

```swift
import XCTest
@testable import LinkCKit

/// A clock the test releases by hand: each `sleep` waits until `release()` is called.
private actor Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { await withCheckedContinuation { waiters.append($0) } }
    func release() { if !waiters.isEmpty { waiters.removeFirst().resume() } }
    var waiting: Int { waiters.count }
}

@MainActor
final class BoardModelTests: XCTestCase {
    nonisolated(unsafe) private var workspace: URL!

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-board-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: workspace)
    }

    private var store: BoardMapStore { BoardMapStore(workspacePath: workspace.path) }

    private func model(_ gate: Gate = Gate()) -> BoardModel {
        BoardModel(store: store, settle: .milliseconds(600), sleep: { _ in await gate.wait() })
    }

    private func fresh() -> BoardModel {
        let board = model()
        board.load()
        board.startMap()
        return board
    }

    private func settle(_ gate: Gate, waiting count: Int) async {
        for _ in 0..<400 where await gate.waiting < count { await Task.yield() }
    }

    private func settleUntil(_ condition: () -> Bool) async {
        for _ in 0..<400 where !condition() { await Task.yield() }
    }

    // MARK: Loading and writing

    func testOpeningAProjectWithNoMapWritesNothing() {
        let board = model()
        board.load()
        board.reconcile(with: [DiscoveredThing(name: "db", image: "postgres", detail: "container db")])
        board.startMap()
        board.saveNow()
        XCTAssertEqual(board.state, .loaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    func testAMapNobodyEditedIsNeverRewritten() throws {
        let bytes = Data(#"{"version": 2, "places": {"Not placed": {"api": {"kind": "service", "zz": 1}}}}"#.utf8)
        try bytes.write(to: store.fileURL)
        let board = model()
        board.load()
        board.reconcile(with: [])
        board.selection = [.component("api")]
        board.saveNow()
        XCTAssertEqual(try Data(contentsOf: store.fileURL), bytes)
    }

    func testAVersionOneFileIsWrittenAsVersionTwoOnlyOnItsFirstEdit() throws {
        let v1 = Data(#"{"version": 1, "components": [{"name": "api", "kind": "service"}]}"#.utf8)
        try v1.write(to: store.fileURL)
        let board = model()
        board.load()
        board.saveNow()
        XCTAssertEqual(try Data(contentsOf: store.fileURL), v1, "opening never upgrades the file")
        board.setSystem("June")
        board.saveNow()
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
        XCTAssertEqual(root["version"] as? Int, 2)
    }

    func testAnUnreadableMapLocksTheBoard() throws {
        let bytes = Data("{ nope".utf8)
        try bytes.write(to: store.fileURL)
        let board = model()
        board.load()
        guard case .failed(let reason) = board.state else { return XCTFail("\(board.state)") }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertNil(board.addComponent(kind: .cache, at: BoardPoint(x: 0, y: 0)))
        board.saveNow()
        XCTAssertEqual(try Data(contentsOf: store.fileURL), bytes)
    }

    func testEditsAreWrittenOncePerBurst() async throws {
        let gate = Gate()
        let board = model(gate)
        board.load()
        board.startMap()
        board.setSystem("June")
        _ = board.addComponent(kind: .database, at: BoardPoint(x: 0, y: 0))
        await settle(gate, waiting: 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))

        await gate.release()   // the first edit's clock — stale, writes nothing
        for _ in 0..<50 { await Task.yield() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path), "a stale timer must not write")

        await gate.release()   // the second edit's clock — writes both edits
        await settleUntil { FileManager.default.fileExists(atPath: self.store.fileURL.path) }
        let loaded = try XCTUnwrap(try store.load())
        XCTAssertEqual(loaded.map.system, "June")
        XCTAssertEqual(loaded.map.components.count, 1)
    }

    /// A change made underneath the board — a git pull, a hand edit — is never overwritten.
    func testAChangeOnDiskRefusesTheWriteAndLocksUntilReload() throws {
        let board = fresh()
        board.setSystem("mine")
        board.saveNow()
        let theirs = Data(#"{"version": 2, "system": "theirs", "places": {"Not placed": {}}}"#.utf8)
        try theirs.write(to: store.fileURL)

        board.setSystem("mine again")
        board.saveNow()
        XCTAssertTrue(board.changedOnDisk)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), theirs)
        XCTAssertNil(board.addComponent(kind: .cache, at: BoardPoint(x: 0, y: 0)), "no edits while the disk disagrees")

        board.reload()
        XCTAssertFalse(board.changedOnDisk)
        XCTAssertEqual(board.map.system, "theirs")
    }

    func testAFailedWriteStaysEditableAndRetries() throws {
        let board = fresh()
        try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: true)  // a folder where the file must go
        board.setSystem("June")
        board.saveNow()
        XCTAssertNotNil(board.writeFailure)
        XCTAssertEqual(board.state, .loaded)

        try FileManager.default.removeItem(at: store.fileURL)
        board.setSystem("June, again")
        board.saveNow()
        XCTAssertNil(board.writeFailure)
        XCTAssertEqual(try store.load()?.map.system, "June, again")
    }

    // MARK: Undo

    func testUndoAndRedoWalkTheEdits() {
        let board = fresh()
        board.setSystem("one")
        board.setSystem("two")
        XCTAssertTrue(board.canUndo)
        board.undo()
        XCTAssertEqual(board.map.system, "one")
        board.redo()
        XCTAssertEqual(board.map.system, "two")
        board.undo()
        board.setSystem("three")
        XCTAssertFalse(board.canRedo, "a new edit clears the redo stack")
    }

    func testUndoKeepsAtMostAHundredSteps() {
        let board = fresh()
        for index in 0...150 { board.setSystem("\(index)") }
        var steps = 0
        while board.canUndo { board.undo(); steps += 1 }
        XCTAssertEqual(steps, BoardModel.undoLimit)
    }

    // MARK: Content

    func testANewComponentGetsAUniqueNameIsPlannedAndIsSelected() throws {
        let board = fresh()
        let first = try XCTUnwrap(board.addComponent(kind: .database, at: BoardPoint(x: 0, y: 0)))
        let second = try XCTUnwrap(board.addComponent(kind: .database, at: BoardPoint(x: 0, y: 0)))
        XCTAssertEqual(first, "new-database")
        XCTAssertEqual(second, "new-database-2")
        XCTAssertTrue(board.map.components.allSatisfy(\.planned))
        XCTAssertEqual(board.selection, [.component("new-database-2")])
        let rects = board.map.components.compactMap { $0.at.map(BoardGeometry.rect(ofComponentAt:)) }
        XCTAssertFalse(rects[0].intersects(rects[1]), "the second slid off the first")
    }

    func testAComponentAddedInsideAFrameLivesThere() throws {
        let board = fresh()
        let frame = try XCTUnwrap(board.addFrame(BoardRect(x: 0, y: 0, w: 400, h: 200)))
        let name = try XCTUnwrap(board.addComponent(kind: .cache, at: BoardPoint(x: 40, y: 40)))
        XCTAssertEqual(board.map.components.first { $0.name == name }?.place, frame)
    }

    func testAFrameAdoptsWhatItIsDrawnAroundAndRefusesToCutThroughThings() throws {
        let board = fresh()
        let name = try XCTUnwrap(board.addComponent(kind: .service, at: BoardPoint(x: 40, y: 40)))
        let label = try XCTUnwrap(board.addFrame(BoardRect(x: 0, y: 0, w: 400, h: 200)))
        XCTAssertEqual(board.map.components.first { $0.name == name }?.place, label)

        XCTAssertNil(board.addFrame(BoardRect(x: 100, y: 0, w: 400, h: 200)), "it would cross the first frame")
        XCTAssertNotNil(board.refusal)
    }

    func testRenamingAComponentCarriesItsArrowsAndSelection() throws {
        let board = fresh()
        let api = try XCTUnwrap(board.addComponent(kind: .service, at: BoardPoint(x: 0, y: 0)))
        let db = try XCTUnwrap(board.addComponent(kind: .database, at: BoardPoint(x: 400, y: 0)))
        XCTAssertTrue(board.addArrow(from: api, to: db))
        var renamed = try XCTUnwrap(board.map.components.first { $0.name == db })
        renamed.name = "postgres"
        renamed.does = "entries"
        board.selection = [.component(db)]
        XCTAssertTrue(board.updateComponent(db, to: renamed))
        XCTAssertEqual(board.map.components.first { $0.name == api }?.uses, ["postgres": ""])
        XCTAssertEqual(board.map.components.first { $0.name == "postgres" }?.does, "entries")
        XCTAssertEqual(board.selection, [.component("postgres")])
    }

    func testANameInUseIsRefusedAndNothingChanges() throws {
        let board = fresh()
        let a = try XCTUnwrap(board.addComponent(kind: .service, at: BoardPoint(x: 0, y: 0)))
        let b = try XCTUnwrap(board.addComponent(kind: .service, at: BoardPoint(x: 400, y: 0)))
        var clash = try XCTUnwrap(board.map.components.first { $0.name == b })
        clash.name = a.uppercased()
        XCTAssertFalse(board.updateComponent(b, to: clash))
        XCTAssertNotNil(board.refusal)
        XCTAssertEqual(Set(board.map.components.map(\.name)), [a, b])
        _ = board.addNote(at: BoardPoint(x: 0, y: 400))
        XCTAssertNil(board.refusal, "the next edit that lands clears it")
    }

    func testArrowRules() throws {
        let board = fresh()
        let api = try XCTUnwrap(board.addComponent(kind: .service, at: BoardPoint(x: 0, y: 0)))
        let db = try XCTUnwrap(board.addComponent(kind: .database, at: BoardPoint(x: 400, y: 0)))
        XCTAssertFalse(board.addArrow(from: api, to: api), "no arrow to itself")
        XCTAssertTrue(board.addArrow(from: api, to: db))
        XCTAssertFalse(board.addArrow(from: api, to: db), "no second arrow the same way")
        XCTAssertNotNil(board.routes[BoardModel.ArrowKey(from: api, to: db)])
        board.setArrowLabel(BoardModel.ArrowKey(from: api, to: db), to: "reads entries")
        XCTAssertEqual(board.map.components.first { $0.name == api }?.uses[db], "reads entries")
    }

    func testDeletingAComponentTakesItsArrowsAndDeletingAFrameKeepsItsContents() throws {
        let board = fresh()
        let label = try XCTUnwrap(board.addFrame(BoardRect(x: 0, y: 0, w: 400, h: 200)))
        let api = try XCTUnwrap(board.addComponent(kind: .service, at: BoardPoint(x: 16, y: 16)))
        let db = try XCTUnwrap(board.addComponent(kind: .database, at: BoardPoint(x: 600, y: 0)))
        XCTAssertTrue(board.addArrow(from: api, to: db))

        board.delete([.component(db)])
        XCTAssertEqual(board.map.components.first { $0.name == api }?.uses, [:])
        XCTAssertTrue(board.routes.isEmpty)

        board.delete([.frame(label)])
        XCTAssertTrue(board.map.frames.isEmpty)
        XCTAssertEqual(board.map.components.first { $0.name == api }?.place, BoardMap.notPlaced)
    }

    func testANoteAndAText() throws {
        let board = fresh()
        let note = try XCTUnwrap(board.addNote(at: BoardPoint(x: 0, y: 0)))
        board.setNoteText(note, to: "Redis is for sessions")
        XCTAssertEqual(board.map.notes.first?.text, "Redis is for sessions")
        let text = try XCTUnwrap(board.addText(at: BoardPoint(x: 0, y: 300), style: .title, text: "June", width: 64))
        board.setText(text, to: "", width: 0)
        XCTAssertTrue(board.map.texts.isEmpty, "a text emptied of words goes away")
    }

    func testRenamingAFrameMovesItsComponentsToTheNewPlace() throws {
        let board = fresh()
        let label = try XCTUnwrap(board.addFrame(BoardRect(x: 0, y: 0, w: 400, h: 200)))
        let api = try XCTUnwrap(board.addComponent(kind: .service, at: BoardPoint(x: 16, y: 16)))
        XCTAssertTrue(board.renameFrame(label, to: "Local docker"))
        XCTAssertEqual(board.map.components.first { $0.name == api }?.place, "Local docker")
        XCTAssertFalse(board.renameFrame("Local docker", to: "not PLACED"), "the reserved name is refused")
    }

    // MARK: What's running

    func testReconcilingNeverWritesAndReportsWhatIsNotOnTheMap() {
        let board = fresh()
        board.reconcile(with: [DiscoveredThing(name: "minio", image: "minio/minio", detail: "container minio")])
        XCTAssertEqual(board.suggestions.map(\.name), ["minio"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    func testAddingWhatIsRunningPutsItAllInALocalDockerFrame() throws {
        let board = model()
        board.load()
        board.reconcile(with: [
            DiscoveredThing(name: "api", image: "june-api", detail: "container api"),
            DiscoveredThing(name: "db", image: "postgres:16", detail: "container db"),
        ])
        board.addAllRunning()
        XCTAssertEqual(board.map.frames.map(\.label), ["Local docker"])
        XCTAssertEqual(Set(board.map.components.map(\.name)), ["api", "db"])
        XCTAssertTrue(board.map.components.allSatisfy { $0.place == "Local docker" && !$0.planned })
        XCTAssertEqual(board.map.components.first { $0.name == "db" }?.kind, .database)
        XCTAssertEqual(board.statuses["db"], .present)
        XCTAssertTrue(board.suggestions.isEmpty)
        board.undo()
        XCTAssertTrue(board.map.components.isEmpty, "it was one step")
    }
}
```

- [ ] **Step 2: Run the tests and see them fail**

Run: `swift test --filter BoardModelTests`
Expected: build failure — `cannot find 'BoardModel' in scope`.

- [ ] **Step 3: Implement**

Create `Sources/LinkCKit/Board/BoardModel.swift`:

```swift
import Foundation

/// Everything the board does, minus the drawing: the map, what linkC found running, the
/// selection and tool, undo, and the one pending write. The canvas holds no rules of its own.
@MainActor
@Observable
public final class BoardModel {
    public enum State: Equatable, Sendable {
        /// The project has no map, and nobody has started one.
        case empty
        case loaded
        /// The file could not be read. Nothing is edited or written while this holds.
        case failed(String)
    }

    public enum Tool: Equatable, Sendable {
        case select
        case component(ComponentKind)
        case arrow
        case frame
        case note
        case text
    }

    public struct ArrowKey: Hashable, Sendable {
        public let from: String
        public let to: String

        public init(from: String, to: String) {
            self.from = from
            self.to = to
        }
    }

    public enum Element: Hashable, Sendable {
        case component(String)
        case frame(String)
        case note(UUID)
        case text(UUID)
        case arrow(ArrowKey)
    }

    public static let undoLimit = 100
    public static let localDocker = "Local docker"

    public private(set) var state: State = .empty
    public internal(set) var map: BoardMap = .empty
    public private(set) var statuses: [String: ComponentStatus] = [:]
    public private(set) var suggestions: [MapSuggestion] = []
    public private(set) var routes: [ArrowKey: [BoardPoint]] = [:]
    public var selection: Set<Element> = []
    public var tool: Tool = .select
    /// The last edit linkC would not make, and why. Cleared by the next edit that lands.
    public private(set) var refusal: String?
    /// A save that did not stick. The board stays editable; the next edit or `saveNow` retries.
    public private(set) var writeFailure: String?
    /// The file changed underneath the board. Edits are locked until `reload()`.
    public private(set) var changedOnDisk = false

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var isEmpty: Bool {
        map.components.isEmpty && map.frames.isEmpty && map.notes.isEmpty && map.texts.isEmpty
    }

    @ObservationIgnored private let store: BoardMapStore
    @ObservationIgnored private let settle: Duration
    @ObservationIgnored private let sleep: @Sendable (Duration) async -> Void
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var hasUnwrittenEdits = false
    /// Exactly what the file held when last read or written — what a save must still find.
    @ObservationIgnored private var diskBytes: Data?
    @ObservationIgnored private var undoStack: [BoardMap] = []
    @ObservationIgnored private var redoStack: [BoardMap] = []
    @ObservationIgnored private var lastDiscovered: [DiscoveredThing] = []

    public init(
        store: BoardMapStore,
        settle: Duration = .milliseconds(600),
        sleep: @escaping @Sendable (Duration) async -> Void = { duration in try? await Task.sleep(for: duration) }
    ) {
        self.store = store
        self.settle = settle
        self.sleep = sleep
    }

    // MARK: - Lifecycle

    /// Reads the file. Refuses to replace a map with edits not yet written, so a reload can never
    /// silently discard work — `reload()` is the deliberate way to do that.
    public func load() {
        guard !hasUnwrittenEdits else { return }
        do {
            if let loaded = try store.load() {
                map = loaded.map
                diskBytes = loaded.bytes
                state = .loaded
            } else {
                map = .empty
                diskBytes = nil
                state = .empty
            }
        } catch {
            map = .empty
            state = .failed(message(for: error))
        }
        changedOnDisk = false
        undoStack.removeAll()
        redoStack.removeAll()
        selection = []
        mapLoaded()
    }

    /// Drops any unwritten edits and reads the file again — the way out of `changedOnDisk`.
    public func reload() {
        generation += 1
        hasUnwrittenEdits = false
        load()
    }

    /// Starts a map on a project with none. Writes nothing: the first edit creates the file.
    public func startMap() {
        guard state == .empty else { return }
        state = .loaded
    }

    /// Compares the map with what linkC found running. Never writes.
    public func reconcile(with discovered: [DiscoveredThing]) {
        lastDiscovered = discovered
        let result = BoardReconciler.reconcile(map: map, discovered: discovered)
        statuses = result.statuses
        suggestions = result.suggestions
    }

    /// Writes now rather than after the settle — for the board closing. Still writes only when
    /// something changed.
    public func saveNow() {
        generation += 1
        write()
    }

    // MARK: - Undo

    public func undo() {
        guard canEdit, let previous = undoStack.popLast() else { return }
        redoStack.append(map)
        map = previous
        afterMapChange()
    }

    public func redo() {
        guard canEdit, let next = redoStack.popLast() else { return }
        undoStack.append(map)
        map = next
        afterMapChange()
    }

    // MARK: - Content edits

    public func setSystem(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        edit { map in
            guard (map.system ?? "") != trimmed else { return false }
            map.system = trimmed.isEmpty ? nil : trimmed
            return true
        }
    }

    /// A new component, planned, centred where it was placed and slid clear of anything there.
    @discardableResult
    public func addComponent(kind: ComponentKind, at point: BoardPoint) -> String? {
        var added: String?
        edit { map in
            let name = Self.uniqueName("new-\(kind.raw)", taken: Set(map.components.map { $0.name.lowercased() }))
            let rect = BoardGeometry.elementDrop(
                BoardGeometry.rect(ofComponentAt: point).snapped,
                otherElements: Self.elementRects(map, excluding: []), frames: Self.frameRects(map, excluding: []))
            let place = BoardGeometry.frame(containing: rect, frames: map.frames)?.label ?? BoardMap.notPlaced
            map.components.append(BoardComponent(name: name, kind: kind, planned: true, place: place, at: rect.origin))
            added = name
            return true
        }
        if let added { selection = [.component(added)] }
        return added
    }

    @discardableResult
    public func addNote(at point: BoardPoint) -> UUID? {
        var added: UUID?
        edit { map in
            let rect = BoardGeometry.elementDrop(
                BoardGeometry.rect(ofNoteAt: point).snapped,
                otherElements: Self.elementRects(map, excluding: []), frames: Self.frameRects(map, excluding: []))
            let note = BoardNote(text: "", at: rect.origin)
            map.notes.append(note)
            added = note.id
            return true
        }
        if let added { selection = [.note(added)] }
        return added
    }

    @discardableResult
    public func addText(at point: BoardPoint, style: BoardTextStyle, text: String, width: Int) -> UUID? {
        var added: UUID?
        edit { map in
            let probe = BoardText(text: text, style: style, at: point, width: width)
            let rect = BoardGeometry.elementDrop(
                BoardGeometry.rect(of: probe).snapped,
                otherElements: Self.elementRects(map, excluding: []), frames: Self.frameRects(map, excluding: []))
            let placed = BoardText(text: text, style: style, at: rect.origin, width: width)
            map.texts.append(placed)
            added = placed.id
            return true
        }
        if let added { selection = [.text(added)] }
        return added
    }

    /// A new frame where it was drawn. Anything wholly inside becomes its own; a frame that would
    /// cross another frame or cut through anything is refused.
    @discardableResult
    public func addFrame(_ drawn: BoardRect) -> String? {
        var added: String?
        edit { map in
            var rect = drawn.snapped
            rect.w = max(rect.w, BoardGeometry.frameMinSize.x)
            rect.h = max(rect.h, BoardGeometry.frameMinSize.y)
            if Self.frameRects(map, excluding: []).contains(where: { $0.intersects(rect) }) {
                return refuse("A frame can't overlap another frame — draw it in empty space.")
            }
            let interior = BoardGeometry.interior(of: rect)
            if Self.elementRects(map, excluding: []).contains(where: { $0.intersects(rect) && !interior.contains($0) }) {
                return refuse("A frame can't cut through things — draw it around them, or in empty space.")
            }
            let label = Self.uniqueName("Frame", taken: Set(map.frames.map { $0.label.lowercased() }).union([BoardMap.notPlaced.lowercased()]), separator: " ")
            map.frames.append(BoardFrame(label: label, rect: rect))
            for index in map.components.indices {
                if let at = map.components[index].at, interior.contains(BoardGeometry.rect(ofComponentAt: at)) {
                    map.components[index].place = label
                }
            }
            added = label
            return true
        }
        if let added { selection = [.frame(added)] }
        return added
    }

    /// Takes the editable fields from `updated`: name, kind, what it does, how it is reached, where
    /// it runs, whether it is planned. Its place, position and arrows are the drawing's. Returns
    /// false only when the edit was refused — the inspector stays open on false.
    @discardableResult
    public func updateComponent(_ name: String, to updated: BoardComponent) -> Bool {
        var refused = false
        var landed = false
        let newName = updated.name.trimmingCharacters(in: .whitespacesAndNewlines)
        edit { map in
            guard let index = Self.index(of: name, in: map) else { return false }
            guard !newName.isEmpty else {
                refused = true
                return refuse("A component needs a name.")
            }
            if newName.lowercased() != name.lowercased(),
               map.components.contains(where: { $0.name.lowercased() == newName.lowercased() }) {
                refused = true
                return refuse("This map already has a component named \"\(newName)\".")
            }
            let old = map.components[index]
            var next = old
            next.name = newName
            next.kind = updated.kind
            next.does = updated.does
            next.reachedBy = updated.reachedBy
            next.runs = updated.runs
            next.planned = updated.planned
            guard next != old else { return false }
            map.components[index] = next
            if newName != name {
                for other in map.components.indices {
                    if let label = map.components[other].uses.removeValue(forKey: name) {
                        map.components[other].uses[newName] = label
                    }
                }
            }
            landed = true
            return true
        }
        if landed, newName != name {
            selection = Set(selection.map { $0 == .component(name) ? .component(newName) : $0 })
        }
        return !refused
    }

    /// Relabels a frame and moves its components to the new place. Returns false only when refused.
    @discardableResult
    public func renameFrame(_ label: String, to newLabel: String) -> Bool {
        var refused = false
        var landed = false
        let trimmed = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        edit { map in
            guard let index = map.frames.firstIndex(where: { $0.label == label }) else { return false }
            guard !trimmed.isEmpty else {
                refused = true
                return refuse("A frame needs a label.")
            }
            guard trimmed.lowercased() != BoardMap.notPlaced.lowercased() else {
                refused = true
                return refuse("\"\(BoardMap.notPlaced)\" is reserved for things outside every frame.")
            }
            if trimmed.lowercased() != label.lowercased(),
               map.frames.contains(where: { $0.label.lowercased() == trimmed.lowercased() }) {
                refused = true
                return refuse("This map already has a frame labelled \"\(trimmed)\".")
            }
            guard trimmed != label else { return false }
            map.frames[index].label = trimmed
            for other in map.components.indices where map.components[other].place == label {
                map.components[other].place = trimmed
            }
            landed = true
            return true
        }
        if landed { selection = Set(selection.map { $0 == .frame(label) ? .frame(trimmed) : $0 }) }
        return !refused
    }

    public func setNoteText(_ id: UUID, to text: String) {
        edit { map in
            guard let index = map.notes.firstIndex(where: { $0.id == id }), map.notes[index].text != text else { return false }
            map.notes[index].text = text
            return true
        }
    }

    /// New words for a text. Emptied of words, the text goes away.
    public func setText(_ id: UUID, to text: String, width: Int) {
        edit { map in
            guard let index = map.texts.firstIndex(where: { $0.id == id }) else { return false }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                map.texts.remove(at: index)
                return true
            }
            guard map.texts[index].text != text || map.texts[index].width != width else { return false }
            map.texts[index].text = text
            map.texts[index].width = width
            return true
        }
    }

    @discardableResult
    public func addArrow(from source: String, to target: String) -> Bool {
        var landed = false
        edit { map in
            guard let sourceIndex = Self.index(of: source, in: map), Self.index(of: target, in: map) != nil else { return false }
            guard source.lowercased() != target.lowercased() else { return refuse("An arrow needs two different components.") }
            guard map.components[sourceIndex].uses[target] == nil else {
                return refuse("\(source) already uses \(target) — double-click that arrow to change its label.")
            }
            map.components[sourceIndex].uses[target] = ""
            landed = true
            return true
        }
        return landed
    }

    public func setArrowLabel(_ arrow: ArrowKey, to label: String) {
        edit { map in
            guard let index = Self.index(of: arrow.from, in: map), map.components[index].uses[arrow.to] != nil else { return false }
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard map.components[index].uses[arrow.to] != trimmed else { return false }
            map.components[index].uses[arrow.to] = trimmed
            return true
        }
    }

    /// Deleting a component takes its arrows with it. Deleting a frame keeps its components; they
    /// become not placed.
    public func delete(_ elements: Set<Element>) {
        guard !elements.isEmpty else { return }
        edit { map in
            var changed = false
            for element in elements {
                switch element {
                case .component(let name):
                    guard let index = Self.index(of: name, in: map) else { continue }
                    map.components.remove(at: index)
                    for other in map.components.indices { map.components[other].uses.removeValue(forKey: name) }
                    changed = true
                case .frame(let label):
                    guard let index = map.frames.firstIndex(where: { $0.label == label }) else { continue }
                    map.frames.remove(at: index)
                    for other in map.components.indices where map.components[other].place == label {
                        map.components[other].place = BoardMap.notPlaced
                    }
                    changed = true
                case .note(let id):
                    if let index = map.notes.firstIndex(where: { $0.id == id }) { map.notes.remove(at: index); changed = true }
                case .text(let id):
                    if let index = map.texts.firstIndex(where: { $0.id == id }) { map.texts.remove(at: index); changed = true }
                case .arrow(let arrow):
                    if let index = Self.index(of: arrow.from, in: map), map.components[index].uses.removeValue(forKey: arrow.to) != nil {
                        changed = true
                    }
                }
            }
            return changed
        }
        selection.subtract(elements)
    }

    /// One running thing onto the map, inside the "Local docker" frame — created, or grown by a
    /// row, when there is no room.
    public func addSuggestion(_ suggestion: MapSuggestion) {
        edit { map in
            Self.place([suggestion], into: &map)
            return true
        }
    }

    /// Everything running onto the map at once, in one "Local docker" frame, as one undo step.
    public func addAllRunning() {
        let all = suggestions
        guard !all.isEmpty else { return }
        edit { map in
            Self.place(all, into: &map)
            return true
        }
    }

    // MARK: - Hooks the spatial edits share

    var canEdit: Bool {
        if case .failed = state { return false }
        return !changedOnDisk
    }

    /// Every edit: refused outright while the board is locked; otherwise applied to a copy, and —
    /// when it changed something — recorded for undo and followed by one scheduled write.
    func edit(_ change: (inout BoardMap) -> Bool) {
        guard canEdit else { return }
        var next = map
        guard change(&next) else { return }
        undoStack.append(map)
        if undoStack.count > Self.undoLimit { undoStack.removeFirst(undoStack.count - Self.undoLimit) }
        redoStack.removeAll()
        map = next
        refusal = nil
        afterMapChange()
    }

    /// Records why an edit was refused; returns false so the edit changes nothing.
    func refuse(_ message: String) -> Bool {
        refusal = message
        return false
    }

    func afterMapChange() {
        if state == .empty { state = .loaded }
        hasUnwrittenEdits = true
        selection = selection.filter(exists)
        recomputeRoutes()
        reconcile(with: lastDiscovered)
        scheduleWrite()
    }

    /// Called after every load. Task 6 lays out whatever the file left without a place on the board.
    func mapLoaded() {
        recomputeRoutes()
        reconcile(with: lastDiscovered)
    }

    func recomputeRoutes() {
        var rects: [String: BoardRect] = [:]
        for component in map.components {
            if let at = component.at { rects[component.name] = BoardGeometry.rect(ofComponentAt: at) }
        }
        let obstacles = Array(rects.values) + map.notes.compactMap { $0.at.map(BoardGeometry.rect(ofNoteAt:)) }
        var next: [ArrowKey: [BoardPoint]] = [:]
        for component in map.components {
            guard let source = rects[component.name] else { continue }
            for target in component.uses.keys {
                guard let destination = rects[target] else { continue }
                next[ArrowKey(from: component.name, to: target)] = BoardGeometry.route(from: source, to: destination, obstacles: obstacles)
            }
        }
        routes = next
    }

    static func elementRects(_ map: BoardMap, excluding excluded: Set<Element>) -> [BoardRect] {
        var rects: [BoardRect] = []
        for component in map.components where !excluded.contains(.component(component.name)) {
            if let at = component.at { rects.append(BoardGeometry.rect(ofComponentAt: at)) }
        }
        for note in map.notes where !excluded.contains(.note(note.id)) {
            if let at = note.at { rects.append(BoardGeometry.rect(ofNoteAt: at)) }
        }
        for text in map.texts where !excluded.contains(.text(text.id)) {
            rects.append(BoardGeometry.rect(of: text))
        }
        return rects
    }

    static func frameRects(_ map: BoardMap, excluding excluded: Set<String>) -> [BoardRect] {
        map.frames.filter { !excluded.contains($0.label) }.compactMap(\.rect)
    }

    static func index(of name: String, in map: BoardMap) -> Int? {
        map.components.firstIndex { $0.name.lowercased() == name.lowercased() }
    }

    static func uniqueName(_ base: String, taken: Set<String>, separator: String = "-") -> String {
        var name = base
        var suffix = 2
        while taken.contains(name.lowercased()) {
            name = "\(base)\(separator)\(suffix)"
            suffix += 1
        }
        return name
    }

    // MARK: - Internals

    private func exists(_ element: Element) -> Bool {
        switch element {
        case .component(let name): return Self.index(of: name, in: map) != nil
        case .frame(let label): return map.frames.contains { $0.label == label }
        case .note(let id): return map.notes.contains { $0.id == id }
        case .text(let id): return map.texts.contains { $0.id == id }
        case .arrow(let arrow):
            guard let index = Self.index(of: arrow.from, in: map) else { return false }
            return map.components[index].uses[arrow.to] != nil
        }
    }

    /// Puts running things on the map inside the "Local docker" frame, laid out four to a row.
    private static func place(_ suggestions: [MapSuggestion], into map: inout BoardMap) {
        let fresh = suggestions.filter { suggestion in !map.components.contains { $0.name.lowercased() == suggestion.name.lowercased() } }
        guard !fresh.isEmpty else { return }
        let size = BoardGeometry.componentSize
        let gap = 16

        if !map.frames.contains(where: { $0.label == localDocker }) {
            let columns = min(4, fresh.count)
            let rows = (fresh.count + columns - 1) / columns
            let wanted = BoardRect(x: 0, y: 0,
                                   w: max(BoardGeometry.frameMinSize.x, columns * (size.x + gap) + gap),
                                   h: max(BoardGeometry.frameMinSize.y, rows * (size.y + gap) + gap)).snapped
            let content = elementRects(map, excluding: []) + frameRects(map, excluding: [])
            let seedX = (content.map(\.maxX).max() ?? 0) + (content.isEmpty ? 0 : 48)
            let rect = BoardGeometry.frameDrop(wanted.offsetBy(dx: seedX, dy: 0).snapped, otherFrames: [], foreignElements: content)
            map.frames.append(BoardFrame(label: localDocker, rect: rect))
        }

        for suggestion in fresh {
            guard let frameIndex = map.frames.firstIndex(where: { $0.label == localDocker }), var frame = map.frames[frameIndex].rect else { break }
            let members = map.components.filter { $0.place == localDocker }.compactMap { $0.at.map(BoardGeometry.rect(ofComponentAt:)) }
            let foreign = elementRects(map, excluding: Set(map.components.filter { $0.place == localDocker }.map { .component($0.name) }))
                .filter { !frame.contains($0) }
            let others = frameRects(map, excluding: [localDocker])
            let seed = BoardRect(x: frame.x + BoardGeometry.frameInset, y: frame.y + BoardGeometry.frameInset, w: size.x, h: size.y)
            var spot = BoardGeometry.nearestFreeSpot(for: seed, avoiding: members, inside: BoardGeometry.interior(of: frame))
            if spot == nil, let grown = BoardGeometry.grow(frame, toFit: size, members: members, otherFrames: others, foreignElements: foreign) {
                frame = grown
                map.frames[frameIndex].rect = grown
                spot = BoardGeometry.nearestFreeSpot(for: seed, avoiding: members, inside: BoardGeometry.interior(of: grown))
            }
            let placed = spot ?? BoardGeometry.elementDrop(seed.offsetBy(dx: frame.w + 48, dy: 0),
                                                         otherElements: elementRects(map, excluding: []), frames: frameRects(map, excluding: []))
            let place = spot == nil ? BoardMap.notPlaced : localDocker
            map.components.append(BoardComponent(name: suggestion.name, kind: suggestion.kind, place: place, at: placed.origin))
        }
    }

    private func scheduleWrite() {
        generation += 1
        let scheduled = generation
        let sleep = self.sleep
        let settle = self.settle
        Task { @MainActor [weak self] in
            await sleep(settle)
            guard let self, self.generation == scheduled else { return }
            self.write()
        }
    }

    private func write() {
        guard canEdit, hasUnwrittenEdits else { return }
        do {
            diskBytes = try store.save(map, expecting: diskBytes)
            hasUnwrittenEdits = false
            writeFailure = nil
        } catch BoardMapStoreError.changedOnDisk {
            changedOnDisk = true
        } catch {
            writeFailure = message(for: error)
        }
    }

    private func message(for error: Error) -> String {
        if let error = error as? LinkCError { return error.localizedDescription }
        return String(describing: error)
    }
}
```

Two notes for the implementer:
- `updateComponent` returns `true` when the edit landed *or* when nothing needed changing, and `false` only when it was refused — the inspector closes on `true` and stays open on `false`.
- `testANewComponentGetsAUniqueNameIsPlannedAndIsSelected` asserts the second component slid clear of the first: `addComponent` places by *top-left* corner at `at`, snapped.

- [ ] **Step 4: Run the tests and see them pass**

Run: `swift test --filter BoardModelTests`
Expected: `Executed 20 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/LinkCKit/Board/BoardModel.swift Tests/LinkCKitTests/BoardModelTests.swift
git diff --cached --stat
git commit -m "feat(board): the board model — load, write, undo, and every content edit"
git log -1 --format=%B | grep -ic claude   # must print 0
```

---

### Task 6: The board model — moving, resizing and laying out

**Files:**
- Create: `Sources/LinkCKit/Board/BoardModel+Space.swift`
- Modify: `Sources/LinkCKit/Board/BoardModel.swift` (`mapLoaded()` calls the layout pass)
- Test: `Tests/LinkCKitTests/BoardModelSpaceTests.swift`

**Interfaces:**
- Consumes: everything Task 5 produced, including the internal hooks `edit(_:)`, `refuse(_:)`, `elementRects(_:excluding:)`, `frameRects(_:excluding:)`, `index(of:in:)`, and `BoardGeometry` (Task 4).
- Produces, on `BoardModel`:
  - `func move(_ elements: Set<Element>, by delta: BoardPoint)`
  - `func resizeFrame(_ label: String, to proposed: BoardRect)`
  - `static func laidOut(_ map: BoardMap) -> BoardMap` — pure: gives every frame a rect and every component, note and text a position, with nothing overlapping and every component inside its place's frame.
  - `func rect(of element: Element) -> BoardRect?`
  - `var contentBounds: BoardRect?` — everything on the board as one rect (the canvas's "fit everything" reads it)

- [ ] **Step 1: Write the failing tests**

Create `Tests/LinkCKitTests/BoardModelSpaceTests.swift`:

```swift
import XCTest
@testable import LinkCKit

@MainActor
final class BoardModelSpaceTests: XCTestCase {
    nonisolated(unsafe) private var workspace: URL!

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-board-space-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: workspace)
    }

    private func fresh() -> BoardModel {
        let board = BoardModel(store: BoardMapStore(workspacePath: workspace.path), settle: .seconds(3600), sleep: { _ in })
        board.load()
        board.startMap()
        return board
    }

    private func overlaps(_ board: BoardModel) -> Bool {
        let rects = BoardModel.elementRects(board.map, excluding: [])
        for (i, a) in rects.enumerated() {
            for b in rects[(i + 1)...] where a.intersects(b) { return true }
        }
        return false
    }

    func testMovingABoxIntoAFrameMakesItLiveThereAndOutMakesItNotPlaced() throws {
        let board = fresh()
        let label = try XCTUnwrap(board.addFrame(BoardRect(x: 0, y: 0, w: 400, h: 200)))
        let api = try XCTUnwrap(board.addComponent(kind: .service, at: BoardPoint(x: 600, y: 0)))
        board.move([.component(api)], by: BoardPoint(x: -560, y: 40))
        XCTAssertEqual(board.map.components.first { $0.name == api }?.place, label)
        board.move([.component(api)], by: BoardPoint(x: 800, y: 0))
        XCTAssertEqual(board.map.components.first { $0.name == api }?.place, BoardMap.notPlaced)
    }

    func testABoxDroppedOnAnotherSlidesClear() throws {
        let board = fresh()
        let a = try XCTUnwrap(board.addComponent(kind: .service, at: BoardPoint(x: 0, y: 0)))
        let b = try XCTUnwrap(board.addComponent(kind: .service, at: BoardPoint(x: 400, y: 0)))
        board.move([.component(b)], by: BoardPoint(x: -400, y: 0))
        XCTAssertFalse(overlaps(board))
        XCTAssertNotEqual(board.map.components.first { $0.name == a }?.at, board.map.components.first { $0.name == b }?.at)
    }

    func testMovingAFrameCarriesItsComponents() throws {
        let board = fresh()
        let label = try XCTUnwrap(board.addFrame(BoardRect(x: 0, y: 0, w: 400, h: 200)))
        let api = try XCTUnwrap(board.addComponent(kind: .service, at: BoardPoint(x: 16, y: 16)))
        let before = try XCTUnwrap(board.map.components.first { $0.name == api }?.at)
        board.move([.frame(label)], by: BoardPoint(x: 0, y: 400))
        let after = try XCTUnwrap(board.map.components.first { $0.name == api }?.at)
        XCTAssertEqual(after.y - before.y, 400)
        XCTAssertEqual(board.map.components.first { $0.name == api }?.place, label)
    }

    func testAFrameNeverLandsOnAnotherFrame() throws {
        let board = fresh()
        let first = try XCTUnwrap(board.addFrame(BoardRect(x: 0, y: 0, w: 400, h: 200)))
        let second = try XCTUnwrap(board.addFrame(BoardRect(x: 0, y: 400, w: 400, h: 200)))
        board.move([.frame(second)], by: BoardPoint(x: 0, y: -400))
        let a = try XCTUnwrap(board.map.frames.first { $0.label == first }?.rect)
        let b = try XCTUnwrap(board.map.frames.first { $0.label == second }?.rect)
        XCTAssertFalse(a.intersects(b))
    }

    func testAMoveIsOneUndoStep() throws {
        let board = fresh()
        let api = try XCTUnwrap(board.addComponent(kind: .service, at: BoardPoint(x: 0, y: 0)))
        let before = board.map.components.first { $0.name == api }?.at
        board.move([.component(api)], by: BoardPoint(x: 200, y: 0))
        board.undo()
        XCTAssertEqual(board.map.components.first { $0.name == api }?.at, before)
    }

    func testAMoveOfNothingIsNotAnEdit() throws {
        let board = fresh()
        let api = try XCTUnwrap(board.addComponent(kind: .service, at: BoardPoint(x: 0, y: 0)))
        board.move([.component(api)], by: BoardPoint(x: 0, y: 0))
        board.undo()
        XCTAssertTrue(board.map.components.isEmpty, "the zero move added no undo step, so one undo removes the component")
    }

    func testContentBoundsCoverEverything() throws {
        let board = fresh()
        XCTAssertNil(board.contentBounds)
        _ = try XCTUnwrap(board.addFrame(BoardRect(x: 0, y: 0, w: 400, h: 200)))
        _ = try XCTUnwrap(board.addComponent(kind: .service, at: BoardPoint(x: 800, y: 600)))
        let bounds = try XCTUnwrap(board.contentBounds)
        XCTAssertLessThanOrEqual(bounds.minX, 0)
        XCTAssertGreaterThanOrEqual(bounds.maxX, 952)
        XCTAssertGreaterThanOrEqual(bounds.maxY, 656)
    }

    /// A note wholly inside a frame goes along when the frame moves.
    func testMovingAFrameCarriesANoteInsideIt() throws {
        let board = fresh()
        let label = try XCTUnwrap(board.addFrame(BoardRect(x: 0, y: 0, w: 400, h: 200)))
        let note = try XCTUnwrap(board.addNote(at: BoardPoint(x: 16, y: 16)))
        let before = try XCTUnwrap(board.map.notes.first { $0.id == note }?.at)
        board.move([.frame(label)], by: BoardPoint(x: 0, y: 400))
        let after = try XCTUnwrap(board.map.notes.first { $0.id == note }?.at)
        XCTAssertEqual(after.y - before.y, 400)
    }

    func testResizingNeverShrinksPastItsContents() throws {
        let board = fresh()
        let label = try XCTUnwrap(board.addFrame(BoardRect(x: 0, y: 0, w: 400, h: 200)))
        _ = try XCTUnwrap(board.addComponent(kind: .service, at: BoardPoint(x: 200, y: 100)))
        board.resizeFrame(label, to: BoardRect(x: 0, y: 0, w: 100, h: 100))
        let rect = try XCTUnwrap(board.map.frames.first?.rect)
        XCTAssertTrue(BoardGeometry.interior(of: rect).contains(try XCTUnwrap(board.rect(of: .component(board.map.components[0].name)))))
    }

    /// A hand-written map with no layout: every place gets a frame on the board, every
    /// component a position inside its own frame, and nothing overlaps — without writing.
    func testAMapWithNoLayoutIsLaidOut() throws {
        var map = BoardMap.empty
        map.frames = [BoardFrame(label: "Oracle box"), BoardFrame(label: "Local docker")]
        map.components = [
            BoardComponent(name: "api", kind: .service, place: "Local docker"),
            BoardComponent(name: "db", kind: .database, place: "Local docker"),
            BoardComponent(name: "audio", kind: .host, place: "Oracle box"),
            BoardComponent(name: "loose", kind: .external),
        ]
        map.notes = [BoardNote(text: "hi")]
        let laid = BoardModel.laidOut(map)

        XCTAssertTrue(laid.frames.allSatisfy { $0.rect != nil })
        XCTAssertTrue(laid.components.allSatisfy { $0.at != nil })
        XCTAssertTrue(laid.notes.allSatisfy { $0.at != nil })
        for component in laid.components {
            let rect = BoardGeometry.rect(ofComponentAt: try XCTUnwrap(component.at))
            let frame = laid.frames.first { $0.label == component.place }?.rect
            if let frame {
                XCTAssertTrue(BoardGeometry.interior(of: frame).contains(rect), component.name)
            } else {
                XCTAssertFalse(laid.frames.compactMap(\.rect).contains { $0.intersects(rect) }, component.name)
            }
        }
        let frames = laid.frames.compactMap(\.rect)
        XCTAssertFalse(frames[0].intersects(frames[1]))
        XCTAssertEqual(BoardModel.laidOut(laid), laid, "laying out a laid-out map changes nothing")
    }

    /// A box the file lists under one place but positions in another frame moves to its place —
    /// the file's places are what agents read, so they win.
    func testTheFilesPlaceWinsOverAStrayPosition() throws {
        var map = BoardMap.empty
        map.frames = [BoardFrame(label: "A", rect: BoardRect(x: 0, y: 0, w: 400, h: 200)),
                      BoardFrame(label: "B", rect: BoardRect(x: 600, y: 0, w: 400, h: 200))]
        map.components = [BoardComponent(name: "api", kind: .service, place: "B", at: BoardPoint(x: 16, y: 16))]
        let laid = BoardModel.laidOut(map)
        let rect = BoardGeometry.rect(ofComponentAt: try XCTUnwrap(laid.components[0].at))
        XCTAssertTrue(BoardGeometry.interior(of: BoardRect(x: 600, y: 0, w: 400, h: 200)).contains(rect))
    }

    func testLoadingLaysOutWithoutWriting() throws {
        let store = BoardMapStore(workspacePath: workspace.path)
        let bytes = Data(#"{"version": 2, "places": {"Not placed": {"a": {}, "b": {}}}}"#.utf8)
        try bytes.write(to: store.fileURL)
        let board = BoardModel(store: store, settle: .seconds(3600), sleep: { _ in })
        board.load()
        XCTAssertTrue(board.map.components.allSatisfy { $0.at != nil })
        XCTAssertFalse(overlaps(board))
        board.saveNow()
        XCTAssertEqual(try Data(contentsOf: store.fileURL), bytes)
    }
}
```

- [ ] **Step 2: Run the tests and see them fail**

Run: `swift test --filter BoardModelSpaceTests`
Expected: build failure — `value of type 'BoardModel' has no member 'move'`.

- [ ] **Step 3: Implement**

Create `Sources/LinkCKit/Board/BoardModel+Space.swift`:

```swift
import Foundation

extension BoardModel {
    public func rect(of element: Element) -> BoardRect? {
        switch element {
        case .component(let name):
            return Self.index(of: name, in: map).flatMap { map.components[$0].at }.map(BoardGeometry.rect(ofComponentAt:))
        case .frame(let label):
            return map.frames.first { $0.label == label }?.rect
        case .note(let id):
            return map.notes.first { $0.id == id }?.at.map(BoardGeometry.rect(ofNoteAt:))
        case .text(let id):
            return map.texts.first { $0.id == id }.map(BoardGeometry.rect(of:))
        case .arrow:
            return nil
        }
    }

    /// Moves the elements by `delta`, then settles them: frames first — each carrying its
    /// components and any note or text wholly inside it — then everything else, each sliding
    /// clear of what is already settled and taking the place its centre lands in. One undo step;
    /// a move of nothing is not an edit.
    public func move(_ elements: Set<Element>, by delta: BoardPoint) {
        guard delta.x != 0 || delta.y != 0 else { return }
        edit { map in
            let frames = elements.compactMap { element -> String? in
                if case .frame(let label) = element { return label } else { return nil }
            }.sorted()
            var carried: Set<Element> = []
            var changed = false

            for label in frames {
                guard let index = map.frames.firstIndex(where: { $0.label == label }), let rect = map.frames[index].rect else { continue }
                let interior = BoardGeometry.interior(of: rect)
                let members = Set(map.components.filter { $0.place == label }.map(\.name))
                let notes = Set(map.notes.filter { $0.at.map { interior.contains(BoardGeometry.rect(ofNoteAt: $0)) } ?? false }.map(\.id))
                let texts = Set(map.texts.filter { interior.contains(BoardGeometry.rect(of: $0)) }.map(\.id))
                let riders = Set(members.map { Element.component($0) })
                    .union(notes.map { Element.note($0) })
                    .union(texts.map { Element.text($0) })
                let landed = BoardGeometry.frameDrop(
                    rect.offsetBy(dx: delta.x, dy: delta.y).snapped,
                    otherFrames: Self.frameRects(map, excluding: [label]),
                    foreignElements: Self.elementRects(map, excluding: riders))
                let dx = landed.x - rect.x
                let dy = landed.y - rect.y
                guard dx != 0 || dy != 0 else { continue }
                map.frames[index].rect = landed
                for i in map.components.indices where members.contains(map.components[i].name) {
                    if let at = map.components[i].at { map.components[i].at = BoardPoint(x: at.x + dx, y: at.y + dy) }
                }
                for i in map.notes.indices where notes.contains(map.notes[i].id) {
                    if let at = map.notes[i].at { map.notes[i].at = BoardPoint(x: at.x + dx, y: at.y + dy) }
                }
                for i in map.texts.indices where texts.contains(map.texts[i].id) {
                    map.texts[i].at = BoardPoint(x: map.texts[i].at.x + dx, y: map.texts[i].at.y + dy)
                }
                carried.formUnion(riders)
                changed = true
            }

            let loose = elements.filter { element in
                switch element {
                case .component, .note, .text: return !carried.contains(element)
                case .frame, .arrow: return false
                }
            }
            for element in loose.sorted(by: { Self.sortKey($0) < Self.sortKey($1) }) {
                let others = Self.elementRects(map, excluding: [element])
                let frameRects = Self.frameRects(map, excluding: [])
                switch element {
                case .component(let name):
                    guard let index = Self.index(of: name, in: map), let at = map.components[index].at else { continue }
                    let landed = BoardGeometry.elementDrop(
                        BoardGeometry.rect(ofComponentAt: at).offsetBy(dx: delta.x, dy: delta.y).snapped,
                        otherElements: others, frames: frameRects)
                    map.components[index].at = landed.origin
                    map.components[index].place = BoardGeometry.frame(containing: landed, frames: map.frames)?.label ?? BoardMap.notPlaced
                    changed = changed || landed.origin != at
                case .note(let id):
                    guard let index = map.notes.firstIndex(where: { $0.id == id }), let at = map.notes[index].at else { continue }
                    let landed = BoardGeometry.elementDrop(
                        BoardGeometry.rect(ofNoteAt: at).offsetBy(dx: delta.x, dy: delta.y).snapped,
                        otherElements: others, frames: frameRects)
                    map.notes[index].at = landed.origin
                    changed = changed || landed.origin != at
                case .text(let id):
                    guard let index = map.texts.firstIndex(where: { $0.id == id }) else { continue }
                    let text = map.texts[index]
                    let landed = BoardGeometry.elementDrop(
                        BoardGeometry.rect(of: text).offsetBy(dx: delta.x, dy: delta.y).snapped,
                        otherElements: others, frames: frameRects)
                    map.texts[index].at = landed.origin
                    changed = changed || landed.origin != text.at
                case .frame, .arrow:
                    continue
                }
            }
            return changed
        }
    }

    /// Everything on the board as one rect — what "fit everything" shows. nil for an empty board.
    public var contentBounds: BoardRect? {
        let rects = Self.elementRects(map, excluding: []) + Self.frameRects(map, excluding: [])
        guard let first = rects.first else { return nil }
        return rects.dropFirst().reduce(first) { union, rect in
            let minX = min(union.minX, rect.minX), minY = min(union.minY, rect.minY)
            return BoardRect(x: minX, y: minY, w: max(union.maxX, rect.maxX) - minX, h: max(union.maxY, rect.maxY) - minY)
        }
    }

    /// Resizes a frame from its bottom-right corner, within `BoardGeometry.frameResize`'s limits.
    public func resizeFrame(_ label: String, to proposed: BoardRect) {
        edit { map in
            guard let index = map.frames.firstIndex(where: { $0.label == label }), let original = map.frames[index].rect else { return false }
            let members = map.components.filter { $0.place == label }
            let memberRects = members.compactMap { $0.at.map(BoardGeometry.rect(ofComponentAt:)) }
            let foreign = Self.elementRects(map, excluding: Set(members.map { .component($0.name) })).filter { !original.contains($0) }
            let resized = BoardGeometry.frameResize(
                proposed.snapped, original: original, members: memberRects,
                otherFrames: Self.frameRects(map, excluding: [label]), foreignElements: foreign)
            guard resized != original else { return false }
            map.frames[index].rect = resized
            return true
        }
    }

    /// Gives everything the file left without a place on the board one: a rect for each frame
    /// (sized for its components, in a row to the right of what is already laid out), a
    /// position inside its own frame for each component (the file's place wins over a stray
    /// position), and room for every note and text — nothing overlapping. Pure and idempotent.
    public static func laidOut(_ source: BoardMap) -> BoardMap {
        var map = source
        let size = BoardGeometry.componentSize
        let gap = 16

        func contentRight() -> Int {
            (frameRects(map, excluding: []) + elementRects(map, excluding: [])).map(\.maxX).max() ?? 0
        }

        // Frames: every frame gets a rect, in label order.
        for index in map.frames.indices.sorted(by: { map.frames[$0].label < map.frames[$1].label }) where map.frames[index].rect == nil {
            let count = max(1, map.components.filter { $0.place == map.frames[index].label }.count)
            let columns = min(2, count)
            let rows = (count + columns - 1) / columns
            let wanted = BoardRect(x: 0, y: 0,
                                   w: max(BoardGeometry.frameMinSize.x, columns * (size.x + gap) + gap),
                                   h: max(BoardGeometry.frameMinSize.y, rows * (size.y + gap) + gap)).snapped
            let seed = wanted.offsetBy(dx: contentRight() + (contentRight() == 0 ? 0 : 48), dy: 0).snapped
            map.frames[index].rect = BoardGeometry.frameDrop(
                seed, otherFrames: frameRects(map, excluding: [map.frames[index].label]), foreignElements: elementRects(map, excluding: []))
        }

        // Components: each settles inside its own place's frame, or outside every frame.
        for index in map.components.indices.sorted(by: { map.components[$0].name < map.components[$1].name }) {
            let component = map.components[index]
            let frame = map.frames.first { $0.label == component.place }?.rect
            let others = elementRects(map, excluding: [.component(component.name)])
            let current = component.at.map(BoardGeometry.rect(ofComponentAt:))
            if let frame {
                let interior = BoardGeometry.interior(of: frame)
                if let current, interior.contains(current), !others.contains(where: { $0.intersects(current) }) { continue }
                let seed = BoardRect(x: interior.x, y: interior.y, w: size.x, h: size.y)
                let members = map.components.filter { $0.place == component.place && $0.name != component.name }
                var spot = BoardGeometry.nearestFreeSpot(for: current.map { interior.contains($0) ? $0 : seed } ?? seed,
                                                         avoiding: others, inside: interior)
                if spot == nil, let frameIndex = map.frames.firstIndex(where: { $0.label == component.place }),
                   let grown = BoardGeometry.grow(frame, toFit: size,
                                                  members: members.compactMap { $0.at.map(BoardGeometry.rect(ofComponentAt:)) },
                                                  otherFrames: frameRects(map, excluding: [component.place]),
                                                  foreignElements: elementRects(map, excluding: Set(members.map { .component($0.name) } + [.component(component.name)])).filter { !frame.contains($0) }) {
                    map.frames[frameIndex].rect = grown
                    spot = BoardGeometry.nearestFreeSpot(for: seed, avoiding: others, inside: BoardGeometry.interior(of: grown))
                }
                if let spot {
                    map.components[index].at = spot.origin
                    continue
                }
                map.components[index].place = BoardMap.notPlaced
            }
            let frames = frameRects(map, excluding: [])
            if let current, !frames.contains(where: { $0.intersects(current) }), !others.contains(where: { $0.intersects(current) }) { continue }
            let seed = current ?? BoardRect(x: 0, y: (frames.map(\.maxY).max() ?? 0) + 48, w: size.x, h: size.y)
            map.components[index].at = (BoardGeometry.nearestFreeSpot(for: seed, avoiding: others, outside: frames) ?? seed).origin
        }

        // Notes and texts: kept where they are when that is allowed, else settled by the same drop
        // rule a hand-placed one follows — so a note wholly inside a frame stays there.
        let bottom = (frameRects(map, excluding: []) + elementRects(map, excluding: [])).map(\.maxY).max() ?? 0
        for index in map.notes.indices {
            let note = map.notes[index]
            let seed = note.at.map(BoardGeometry.rect(ofNoteAt:))
                ?? BoardRect(x: 0, y: bottom + 48, w: BoardGeometry.noteSize.x, h: BoardGeometry.noteSize.y)
            map.notes[index].at = BoardGeometry.elementDrop(
                seed, otherElements: elementRects(map, excluding: [.note(note.id)]), frames: frameRects(map, excluding: [])).origin
        }
        for index in map.texts.indices {
            let text = map.texts[index]
            map.texts[index].at = BoardGeometry.elementDrop(
                BoardGeometry.rect(of: text), otherElements: elementRects(map, excluding: [.text(text.id)]),
                frames: frameRects(map, excluding: [])).origin
        }
        return map
    }

    private static func sortKey(_ element: Element) -> String {
        switch element {
        case .component(let name): return "1:\(name)"
        case .note(let id): return "2:\(id.uuidString)"
        case .text(let id): return "3:\(id.uuidString)"
        case .frame(let label): return "0:\(label)"
        case .arrow(let arrow): return "4:\(arrow.from)>\(arrow.to)"
        }
    }
}
```

Then, in `Sources/LinkCKit/Board/BoardModel.swift`, change `mapLoaded()` so that loading lays the map out — in memory only, never as an edit:

```swift
    /// Called after every load: lays out whatever the file left without a place on the board. In
    /// memory only — this is not an edit, so it writes nothing.
    func mapLoaded() {
        map = Self.laidOut(map)
        recomputeRoutes()
        reconcile(with: lastDiscovered)
    }
```

- [ ] **Step 4: Run the tests and see them pass**

Run: `swift test --filter "BoardModelSpaceTests|BoardModelTests"`
Expected: all pass. If `testAMapWithNoLayoutIsLaidOut`'s idempotence assertion fails, the layout pass is moving something that was already valid — fix the pass, not the test.

- [ ] **Step 5: Commit**

```bash
git add Sources/LinkCKit/Board/BoardModel+Space.swift Sources/LinkCKit/Board/BoardModel.swift Tests/LinkCKitTests/BoardModelSpaceTests.swift
git diff --cached --stat
git commit -m "feat(board): move, resize and lay out, with nothing ever overlapping"
git log -1 --format=%B | grep -ic claude   # must print 0
```

---
### Task 7: Tabs, keys and the saved viewport

**Files:**
- Create: `Sources/LinkCKit/Board/ProjectTabs.swift`
- Create: `Sources/LinkCKit/Board/BoardKeys.swift`
- Modify: `Sources/LinkCKit/Preferences/SidebarState.swift` (a viewport per project)
- Test: `Tests/LinkCKitTests/ProjectTabsTests.swift`, `Tests/LinkCKitTests/BoardKeysTests.swift`, and additions to `Tests/LinkCKitTests/SidebarStateTests.swift`

**Interfaces:**
- Consumes: `Session`, `SessionState`, `AgentKind` (`Sources/LinkCKit/Core/Domain.swift`), `ShellRow` (`Sources/LinkCKit/Terminal/ShellTerminalStore.swift`), `BoardViewport` (Task 4).
- Produces:
  - `struct ProjectTab: Equatable, Sendable, Identifiable` — `id: String`, `kind: Kind` (`.board`, `.agent(AgentKind)`, `.terminal`), `title: String`, `isWorking: Bool`
  - `enum ProjectTabs` — `boardID(_ path:) -> String`, `standardized(_:) -> String`, `tabs(project:sessions:shells:titles:) -> [ProjectTab]`, `tab(forDigit:in:) -> ProjectTab?`, `cycle(from:in:backwards:) -> ProjectTab?`
  - `struct KeyPress: Equatable, Sendable` — `key: Key` (`.character(String)`, `.tab`, `.escape`, `.delete`, `.space`), `command`, `control`, `shift`, `option`, `init(_:command:control:shift:option:)`
  - `enum TabCommand: Equatable, Sendable { case select(digit: Int), next, previous }` and `enum TabKeyMap { static func command(for:) -> TabCommand? }`
  - `enum BoardCommand: Equatable, Sendable { case selectTool, componentTool, arrowTool, frameTool, noteTool, textTool, delete, cancel, undo, redo, fitAll }` and `enum BoardKeyMap { static func command(for:isEditingText:) -> BoardCommand? }`
  - on `SidebarState`: `func boardViewport(for path: String) -> BoardViewport?`, `func setBoardViewport(_ viewport: BoardViewport, for path: String)`

The key maps take a `KeyPress` whose character is the key's *unshifted* character — `⇧1` arrives as `.character("1")` with `shift: true`. The app target builds `KeyPress` values from `NSEvent`s in Task 8.

- [ ] **Step 1: Write the failing tests**

Create `Tests/LinkCKitTests/ProjectTabsTests.swift`:

```swift
import XCTest
@testable import LinkCKit

final class ProjectTabsTests: XCTestCase {
    private func session(_ id: String, _ cwd: String, _ state: SessionState = .ready, agent: AgentKind = .claude) -> Session {
        var session = Session(id: id, cwd: cwd, title: "title-\(id)", state: state)
        session.agentKind = agent
        return session
    }

    private func shell(_ id: String, _ cwd: String) -> ShellRow {
        ShellRow(id: id, cwd: cwd, title: "shell-\(id)", state: .running)
    }

    func testTheBoardComesFirstThenAgentsThenTerminals() {
        let tabs = ProjectTabs.tabs(
            project: "/p/june",
            sessions: [session("a1", "/p/june"), session("x", "/p/other"), session("a2", "/p/june/", agent: .codex)],
            shells: [shell("s1", "/p/june"), shell("s2", "/p/other")],
            titles: ["a1": "audio pipeline"])
        XCTAssertEqual(tabs.map(\.id), [ProjectTabs.boardID("/p/june"), "a1", "a2", "s1"])
        XCTAssertEqual(tabs[0].kind, .board)
        XCTAssertEqual(tabs[1].title, "audio pipeline", "a live title wins")
        XCTAssertEqual(tabs[2].kind, .agent(.codex))
        XCTAssertEqual(tabs[3].kind, .terminal)
    }

    func testAProjectWithNoSessionsHasOnlyItsBoard() {
        XCTAssertEqual(ProjectTabs.tabs(project: "/p/empty", sessions: [], shells: [], titles: [:]).map(\.kind), [.board])
    }

    func testAWorkingSessionIsMarked() {
        let tabs = ProjectTabs.tabs(project: "/p", sessions: [session("a", "/p", .working), session("b", "/p", .finished)], shells: [], titles: [:])
        XCTAssertEqual(tabs.map(\.isWorking), [false, true, false])
    }

    func testDigitsPickTabsInOrder() {
        let tabs = ProjectTabs.tabs(project: "/p", sessions: [session("a", "/p")], shells: [], titles: [:])
        XCTAssertEqual(ProjectTabs.tab(forDigit: 1, in: tabs)?.kind, .board)
        XCTAssertEqual(ProjectTabs.tab(forDigit: 2, in: tabs)?.id, "a")
        XCTAssertNil(ProjectTabs.tab(forDigit: 3, in: tabs))
        XCTAssertNil(ProjectTabs.tab(forDigit: 0, in: tabs))
    }

    func testCyclingWrapsBothWays() {
        let tabs = ProjectTabs.tabs(project: "/p", sessions: [session("a", "/p"), session("b", "/p")], shells: [], titles: [:])
        XCTAssertEqual(ProjectTabs.cycle(from: "b", in: tabs, backwards: false)?.kind, .board)
        XCTAssertEqual(ProjectTabs.cycle(from: ProjectTabs.boardID("/p"), in: tabs, backwards: true)?.id, "b")
        XCTAssertEqual(ProjectTabs.cycle(from: "gone", in: tabs, backwards: false)?.id, "a", "an unknown current starts from the Board")
    }
}
```

Create `Tests/LinkCKitTests/BoardKeysTests.swift`:

```swift
import XCTest
@testable import LinkCKit

final class BoardKeysTests: XCTestCase {
    func testTabKeys() {
        XCTAssertEqual(TabKeyMap.command(for: KeyPress(.character("1"), command: true)), .select(digit: 1))
        XCTAssertEqual(TabKeyMap.command(for: KeyPress(.character("9"), command: true)), .select(digit: 9))
        XCTAssertNil(TabKeyMap.command(for: KeyPress(.character("0"), command: true)))
        XCTAssertNil(TabKeyMap.command(for: KeyPress(.character("1"))), "a bare digit is typing, not a tab")
        XCTAssertNil(TabKeyMap.command(for: KeyPress(.character("1"), command: true, shift: true)))
        XCTAssertEqual(TabKeyMap.command(for: KeyPress(.tab, control: true)), .next)
        XCTAssertEqual(TabKeyMap.command(for: KeyPress(.tab, control: true, shift: true)), .previous)
        XCTAssertNil(TabKeyMap.command(for: KeyPress(.tab)))
    }

    func testBoardTools() {
        let expected: [(String, BoardCommand)] = [("v", .selectTool), ("c", .componentTool), ("a", .arrowTool),
                                                   ("f", .frameTool), ("n", .noteTool), ("t", .textTool)]
        for (key, command) in expected {
            XCTAssertEqual(BoardKeyMap.command(for: KeyPress(.character(key)), isEditingText: false), command, key)
            XCTAssertEqual(BoardKeyMap.command(for: KeyPress(.character(key.uppercased())), isEditingText: false), command, key)
        }
    }

    func testBoardEditingKeys() {
        XCTAssertEqual(BoardKeyMap.command(for: KeyPress(.delete), isEditingText: false), .delete)
        XCTAssertEqual(BoardKeyMap.command(for: KeyPress(.escape), isEditingText: false), .cancel)
        XCTAssertEqual(BoardKeyMap.command(for: KeyPress(.character("z"), command: true), isEditingText: false), .undo)
        XCTAssertEqual(BoardKeyMap.command(for: KeyPress(.character("z"), command: true, shift: true), isEditingText: false), .redo)
        XCTAssertEqual(BoardKeyMap.command(for: KeyPress(.character("1"), shift: true), isEditingText: false), .fitAll)
        XCTAssertNil(BoardKeyMap.command(for: KeyPress(.character("c"), command: true), isEditingText: false), "⌘C is not the component tool")
    }

    /// While a field is being typed into, every key belongs to the field.
    func testTypingIntoAFieldIsNeverACommand() {
        for press in [KeyPress(.character("v")), KeyPress(.delete), KeyPress(.escape), KeyPress(.character("z"), command: true)] {
            XCTAssertNil(BoardKeyMap.command(for: press, isEditingText: true))
        }
    }
}
```

Add to `Tests/LinkCKitTests/SidebarStateTests.swift` (its `setUp` already provides a throwaway `defaults`):

```swift
    func testABoardViewportIsRememberedPerProjectAndPruned() {
        let state = SidebarState(defaults: defaults)
        XCTAssertNil(state.boardViewport(for: "/p"))
        let viewport = BoardViewport(originX: 12, originY: -40, zoom: 1.5)
        state.setBoardViewport(viewport, for: "/p")
        XCTAssertEqual(state.boardViewport(for: "/p"), viewport)
        XCTAssertNil(state.boardViewport(for: "/other"))
        XCTAssertEqual(SidebarState(defaults: defaults).boardViewport(for: "/p"), viewport, "it survives a relaunch")
        state.prune(keeping: ["/other"])
        XCTAssertNil(state.boardViewport(for: "/p"))
    }
```

- [ ] **Step 2: Run the tests and see them fail**

Run: `swift test --filter "ProjectTabsTests|BoardKeysTests|SidebarStateTests"`
Expected: build failure — `cannot find 'ProjectTabs' in scope`.

- [ ] **Step 3: Implement the tabs**

Create `Sources/LinkCKit/Board/ProjectTabs.swift`:

```swift
import Foundation

/// One tab in a project's strip: its Board, one of its agent sessions, or one of its terminals.
public struct ProjectTab: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case board
        case agent(AgentKind)
        case terminal
    }

    public let id: String
    public let kind: Kind
    public let title: String
    /// Mid-turn: closing it asks first.
    public let isWorking: Bool

    public init(id: String, kind: Kind, title: String, isWorking: Bool) {
        self.id = id
        self.kind = kind
        self.title = title
        self.isWorking = isWorking
    }
}

/// A project's tabs and how keys move between them. Pure: sessions and terminals come in as values.
public enum ProjectTabs {
    public static func standardized(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    public static func boardID(_ path: String) -> String {
        "board:" + standardized(path)
    }

    /// The Board, then the project's agent sessions, then its terminals — each in the order they
    /// were opened. `titles` holds live session titles, which win over the stored ones.
    public static func tabs(project path: String, sessions: [Session], shells: [ShellRow], titles: [String: String]) -> [ProjectTab] {
        let folder = standardized(path)
        var tabs = [ProjectTab(id: boardID(folder), kind: .board, title: "Board", isWorking: false)]
        for session in sessions where standardized(session.cwd) == folder {
            tabs.append(ProjectTab(
                id: session.id, kind: .agent(session.agentKind),
                title: titles[session.id] ?? session.title,
                isWorking: session.state.bucket == .active))
        }
        for shell in shells where standardized(shell.cwd) == folder {
            tabs.append(ProjectTab(id: shell.id, kind: .terminal, title: shell.title, isWorking: false))
        }
        return tabs
    }

    /// ⌘1 is the Board; ⌘2–⌘9 are the sessions in order.
    public static func tab(forDigit digit: Int, in tabs: [ProjectTab]) -> ProjectTab? {
        guard (1...9).contains(digit), digit <= tabs.count else { return nil }
        return tabs[digit - 1]
    }

    /// The next or previous tab, wrapping. An unknown current tab counts as the Board.
    public static func cycle(from current: String?, in tabs: [ProjectTab], backwards: Bool) -> ProjectTab? {
        guard !tabs.isEmpty else { return nil }
        let index = tabs.firstIndex { $0.id == current } ?? 0
        let next = backwards ? (index - 1 + tabs.count) % tabs.count : (index + 1) % tabs.count
        return tabs[next]
    }
}
```

- [ ] **Step 4: Implement the key maps**

Create `Sources/LinkCKit/Board/BoardKeys.swift`:

```swift
import Foundation

/// One key press, reduced to what the key maps need. `character` is the key's unshifted
/// character, lowercased by the maps — so ⇧1 is `.character("1")` with `shift`.
public struct KeyPress: Equatable, Sendable {
    public enum Key: Equatable, Sendable {
        case character(String)
        case tab
        case escape
        case delete
        case space
    }

    public let key: Key
    public let command: Bool
    public let control: Bool
    public let shift: Bool
    public let option: Bool

    public init(_ key: Key, command: Bool = false, control: Bool = false, shift: Bool = false, option: Bool = false) {
        self.key = key
        self.command = command
        self.control = control
        self.shift = shift
        self.option = option
    }
}

public enum TabCommand: Equatable, Sendable {
    case select(digit: Int)
    case next
    case previous
}

public enum TabKeyMap {
    /// ⌘1–⌘9 pick a tab; ⌃Tab and ⌃⇧Tab cycle.
    public static func command(for press: KeyPress) -> TabCommand? {
        switch press.key {
        case .character(let character):
            guard press.command, !press.control, !press.option, !press.shift,
                  let digit = Int(character), (1...9).contains(digit) else { return nil }
            return .select(digit: digit)
        case .tab:
            guard press.control, !press.command, !press.option else { return nil }
            return press.shift ? .previous : .next
        default:
            return nil
        }
    }
}

public enum BoardCommand: Equatable, Sendable {
    case selectTool, componentTool, arrowTool, frameTool, noteTool, textTool
    case delete, cancel, undo, redo, fitAll
}

public enum BoardKeyMap {
    /// The canvas's keys. While a field is being typed into, every key belongs to the field.
    public static func command(for press: KeyPress, isEditingText: Bool) -> BoardCommand? {
        guard !isEditingText else { return nil }
        let noModifiers = !press.command && !press.control && !press.option
        switch press.key {
        case .escape where noModifiers:
            return .cancel
        case .delete where noModifiers:
            return .delete
        case .character(let raw):
            let character = raw.lowercased()
            if press.command, !press.control, !press.option, character == "z" {
                return press.shift ? .redo : .undo
            }
            if press.shift, noModifiers, character == "1" { return .fitAll }
            guard noModifiers, !press.shift else { return nil }
            switch character {
            case "v": return .selectTool
            case "c": return .componentTool
            case "a": return .arrowTool
            case "f": return .frameTool
            case "n": return .noteTool
            case "t": return .textTool
            default: return nil
            }
        default:
            return nil
        }
    }
}
```

- [ ] **Step 5: Remember a viewport per project**

In `Sources/LinkCKit/Preferences/SidebarState.swift`:
- add `var boardViewports: [String: BoardViewport]?` to the private `Stored` struct (optional, so older blobs still decode);
- add `private var boardViewports: [String: BoardViewport] = [:]`, read in `init` as `stored.boardViewports ?? [:]`, written in `save()` alongside the other fields;
- in `prune(keeping:)`, drop viewports for projects not kept, and include that change in the method's "did anything change" check;
- add:

```swift
    /// Where this project's Board was last looked at. Personal, kept on this Mac only.
    public func boardViewport(for path: String) -> BoardViewport? {
        boardViewports[path]
    }

    public func setBoardViewport(_ viewport: BoardViewport, for path: String) {
        guard boardViewports[path] != viewport else { return }
        boardViewports[path] = viewport
        save()
    }
```

- [ ] **Step 6: Run the tests and see them pass**

Run: `swift test --filter "ProjectTabsTests|BoardKeysTests|SidebarStateTests"`
Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/LinkCKit/Board/ProjectTabs.swift Sources/LinkCKit/Board/BoardKeys.swift Sources/LinkCKit/Preferences/SidebarState.swift \
  Tests/LinkCKitTests/ProjectTabsTests.swift Tests/LinkCKitTests/BoardKeysTests.swift Tests/LinkCKitTests/SidebarStateTests.swift
git diff --cached --stat
git commit -m "feat(board): a project's tabs, the keys that move between them, and a remembered viewport"
git log -1 --format=%B | grep -ic claude   # must print 0
```

---

### Task 8: The canvas — drawing, panning, zooming, selecting and moving

**Files:**
- Create: `Sources/linkc/Board/BoardPane.swift`
- Create: `Sources/linkc/Board/BoardCanvas.swift`
- Create: `Sources/linkc/Board/BoardElements.swift`
- Create: `Sources/linkc/Board/BoardInput.swift`
- Modify: `Sources/linkc/Theme.swift` (board colours)
- Modify: `Sources/linkc/LinkCApp.swift` (`AppModel.board(for:)`; save every board on quit)

**Interfaces:**
- Consumes: `BoardModel` and its types (Tasks 5–6), `BoardGeometry`, `BoardViewport` (Task 4), `KeyPress`, `BoardKeyMap`, `BoardCommand` (Task 7), `SidebarState.boardViewport(for:)`/`setBoardViewport(_:for:)` (Task 7), `AppModel.discoveredThings(in:)` (existing), `AppModel.toolServers` (existing, `@Observable`).
- Produces:
  - `struct BoardPane: View` — `init(model: AppModel, path: String)` (Task 10 mounts it)
  - `struct BoardCanvas: View` and its element views; `final class BoardInput` (an `NSEvent` local monitor for keys, scroll and pinch)
  - `AppModel.board(for path: String) -> BoardModel`

This task gives the canvas everything except its tools, which Task 9 adds: the board is drawn, pans, zooms, fits, selects (click, ⇧-click, drag a selection box), moves its selection, deletes it, undoes and redoes, and shows its empty, locked and failure states. No view is mounted yet — Task 10 puts the Board in its tab — so verification here is the build and the full suite.

The rules the views follow — they hold no logic of their own beyond drawing and gestures:
- A view body never writes observable state. Writes happen in gesture handlers, `.onAppear`, `.onDisappear` and `.onChange`.
- Grid, frames and arrows are drawn in one `Canvas`; components, notes, texts and frame handles are views on one layer that is scaled and offset as a whole. Elements outside the visible rect (inflated by 64 points) are not built.
- During a drag only a `@State` offset changes; `BoardModel.move` runs once, on release.
- `BoardInput` installs its monitor in `.onAppear` and removes it in `.onDisappear`; nothing runs while the Board is not showing.

- [ ] **Step 1: Board colours**

In `Sources/linkc/Theme.swift`, beside the other colours:

```swift
    // The board: a quiet dark canvas, a faint dot grid, and warm sticky notes.
    static let boardBackground = Color(red: 0.071, green: 0.071, blue: 0.078)
    static let boardDot = Color.white.opacity(0.075)
    static let boardFrameFill = Color.white.opacity(0.02)
    static let boardFrameStroke = Color.white.opacity(0.13)
    static let boardArrow = Color.white.opacity(0.45)
    static let boardBox = Color(red: 0.149, green: 0.149, blue: 0.169)
    static let boardBoxStroke = Color.white.opacity(0.09)
    static let noteFill = Color(red: 0.231, green: 0.204, blue: 0.137)
    static let noteText = Color(red: 0.937, green: 0.886, blue: 0.749)
```

- [ ] **Step 2: One board model per project**

In `Sources/linkc/LinkCApp.swift`, next to `discoveredThings(in:)` on `AppModel`:

```swift
    /// One board model per project for the life of the app, so undo and unwritten edits survive
    /// switching tabs and projects.
    @ObservationIgnored private var boards: [String: BoardModel] = [:]

    func board(for path: String) -> BoardModel {
        let key = (path as NSString).standardizingPath
        if let board = boards[key] { return board }
        let board = BoardModel(store: BoardMapStore(workspacePath: key))
        boards[key] = board
        return board
    }
```

and in `flushStateToDisk()`, first line of the body, write any edit still waiting out its settle:

```swift
        for board in boards.values { board.saveNow() }
```

- [ ] **Step 3: Keys, scroll and pinch**

Create `Sources/linkc/Board/BoardInput.swift`:

```swift
import AppKit
import LinkCKit

/// The Board's keys, scroll and pinch, through one `NSEvent` local monitor — installed when the
/// Board appears and removed when it goes, so nothing listens while it is not showing. A local
/// monitor needs no Accessibility permission.
@MainActor
final class BoardInput {
    /// A key the Board may act on. Returns whether it was handled (and so swallowed).
    var onKey: (KeyPress) -> Bool = { _ in false }
    /// Space pressed or released, for pan-by-dragging.
    var onSpace: (Bool) -> Void = { _ in }
    /// A scroll over the canvas: location in canvas-view points, deltas, whether the deltas are
    /// precise (trackpad), whether ⌘ is held.
    var onScroll: (CGPoint, CGFloat, CGFloat, Bool, Bool) -> Void = { _, _, _, _, _ in }
    /// A pinch over the canvas: location in canvas-view points, and the magnification step.
    var onMagnify: (CGPoint, CGFloat) -> Void = { _, _ in }
    /// The canvas's frame in window coordinates, top-left origin (SwiftUI's global space).
    var canvasFrame: () -> CGRect = { .zero }

    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .scrollWheel, .magnify]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Whether a text field or editor has the keyboard.
    static var isEditingText: Bool {
        NSApp.keyWindow?.firstResponder is NSText
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let window = event.window else { return false }
        switch event.type {
        case .keyDown, .keyUp:
            guard window.isKeyWindow, !Self.isEditingText else { return false }
            if event.keyCode == 49 {   // space
                onSpace(event.type == .keyDown)
                return true
            }
            guard event.type == .keyDown, let press = Self.press(from: event) else { return false }
            return onKey(press)
        case .scrollWheel, .magnify:
            let point = Self.location(of: event, in: window)
            let frame = canvasFrame()
            guard frame.contains(point) else { return false }
            let local = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
            if event.type == .magnify {
                onMagnify(local, event.magnification)
            } else {
                onScroll(local, event.scrollingDeltaX, event.scrollingDeltaY,
                         event.hasPreciseScrollingDeltas, event.modifierFlags.contains(.command))
            }
            return true
        default:
            return false
        }
    }

    /// The event's location in window coordinates with a top-left origin.
    private static func location(of event: NSEvent, in window: NSWindow) -> CGPoint {
        let height = window.contentView?.bounds.height ?? window.frame.height
        return CGPoint(x: event.locationInWindow.x, y: height - event.locationInWindow.y)
    }

    /// Digits by key code, so ⇧1 still reads as "1" whatever the layout's shifted character is.
    private static let digitKeyCodes: [UInt16: String] = [
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
    ]

    static func press(from event: NSEvent) -> KeyPress? {
        let flags = event.modifierFlags
        let key: KeyPress.Key
        switch event.keyCode {
        case 48: key = .tab
        case 53: key = .escape
        case 51, 117: key = .delete
        case 49: key = .space
        default:
            if let digit = digitKeyCodes[event.keyCode] {
                key = .character(digit)
            } else if let characters = event.charactersIgnoringModifiers?.lowercased(), !characters.isEmpty {
                key = .character(characters)
            } else {
                return nil
            }
        }
        return KeyPress(key, command: flags.contains(.command), control: flags.contains(.control),
                        shift: flags.contains(.shift), option: flags.contains(.option))
    }
}
```

- [ ] **Step 4: The element views**

Create `Sources/linkc/Board/BoardElements.swift`:

```swift
import SwiftUI
import LinkCKit

extension ComponentKind {
    /// The kind's glyph. Anything linkC does not know draws as a service.
    var glyph: String {
        switch self {
        case .database: return "cylinder.split.1x2"
        case .cache: return "bolt.horizontal"
        case .queue: return "tray.full"
        case .storage: return "externaldrive"
        case .host: return "server.rack"
        case .external: return "cloud"
        default: return "shippingbox"
        }
    }
}

/// A component's box: solid when it exists, dashed while planned, dimmed when linkC looked for
/// it and did not find it, a green dot when it is running now.
struct ComponentBox: View {
    let component: BoardComponent
    let status: ComponentStatus?
    let isSelected: Bool

    private var isMissing: Bool { status == .missing && !component.planned }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: component.kind.glyph)
                .font(.system(size: 11))
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.07)))
                .foregroundStyle(Theme.textSecondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(component.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if let reachedBy = component.reachedBy, !reachedBy.isEmpty {
                    Text(reachedBy)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 2)
            if status == .present {
                Circle().fill(Theme.statusRunning).frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: CGFloat(BoardGeometry.componentSize.x), height: CGFloat(BoardGeometry.componentSize.y))
        .background(RoundedRectangle(cornerRadius: 10).fill(component.planned ? Color.clear : Theme.boardBox))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    isSelected ? Theme.accent : (component.planned ? Theme.textTertiary : Theme.boardBoxStroke),
                    style: StrokeStyle(lineWidth: isSelected ? 1.5 : 1, dash: component.planned && !isSelected ? [4, 3] : [])))
        .opacity(isMissing ? 0.5 : 1)
        .help(help)
    }

    private var help: String {
        var parts = [component.kind.raw]
        if let does = component.does, !does.isEmpty { parts.append(does) }
        switch status {
        case .present: parts.append("running now")
        case .missing: parts.append("linkC looked for this and did not find it")
        case .unchecked, nil: parts.append("linkC cannot check this one")
        }
        if component.planned { parts.append("planned — does not exist yet") }
        return parts.joined(separator: " · ")
    }
}

/// A sticky note: a long note is cut short here and shown in full when selected.
struct NoteCard: View {
    let note: BoardNote
    let isSelected: Bool

    var body: some View {
        Text(note.text.isEmpty ? "Note" : note.text)
            .font(.system(size: 11))
            .foregroundStyle(note.text.isEmpty ? Theme.noteText.opacity(0.4) : Theme.noteText)
            .lineLimit(7)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(10)
            .frame(width: CGFloat(BoardGeometry.noteSize.x), height: CGFloat(BoardGeometry.noteSize.y))
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.noteFill))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isSelected ? Theme.accent : .clear, lineWidth: 1.5))
            .help(note.text)
    }
}

/// A heading or label on the canvas.
struct TextLabel: View {
    let text: BoardText
    let isSelected: Bool

    var body: some View {
        Text(text.text)
            .font(TextLabel.font(text.style))
            .foregroundStyle(text.style == .title ? Theme.textPrimary : Theme.textSecondary)
            .lineLimit(1)
            .fixedSize()
            .frame(width: CGFloat(max(text.width, BoardPoint.grid)),
                   height: CGFloat(BoardGeometry.textHeight(text.style)), alignment: .leading)
            .overlay(Rectangle().strokeBorder(isSelected ? Theme.accent.opacity(0.7) : .clear, lineWidth: 1))
    }

    static func font(_ style: BoardTextStyle) -> Font {
        style == .title ? .system(size: 20, weight: .bold) : .system(size: 12, weight: .medium)
    }

    /// The width a text needs, measured once when its words change — never by reading layout
    /// back, so measuring can never cause a write.
    static func width(of text: String, style: BoardTextStyle) -> Int {
        let font = style == .title ? NSFont.systemFont(ofSize: 20, weight: .bold) : NSFont.systemFont(ofSize: 12, weight: .medium)
        let measured = (text as NSString).size(withAttributes: [.font: font]).width
        return Int(measured.rounded(.up)) + 4
    }
}

/// A frame's label, sitting on its top border. Dragging it moves the frame.
struct FrameLabel: View {
    let label: String
    let isSelected: Bool

    var body: some View {
        Text(label.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(isSelected ? Theme.accent : Theme.textSecondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Theme.boardBackground))
            .fixedSize()
    }
}

/// A frame's resize grip, at its bottom-right corner.
struct FrameGrip: View {
    var body: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(Theme.textTertiary)
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
    }
}
```

- [ ] **Step 5: The pane**

Create `Sources/linkc/Board/BoardPane.swift`:

```swift
import SwiftUI
import LinkCKit

/// A project's Board. Loads the map and compares it with what linkC sees running when the Board
/// appears, again when linkC's container list changes, and writes any pending edit when it goes.
/// Nothing here runs while the Board is not on screen.
struct BoardPane: View {
    let model: AppModel
    let path: String
    @State private var board: BoardModel

    init(model: AppModel, path: String) {
        self.model = model
        self.path = path
        _board = State(wrappedValue: model.board(for: path))
    }

    var body: some View {
        BoardCanvas(board: board, projectPath: path, sidebarState: model.sidebarState) {
            board.load()
            board.reconcile(with: model.discoveredThings(in: path))
        }
        .onChange(of: model.toolServers?.projects) { _, _ in
            board.reconcile(with: model.discoveredThings(in: path))
        }
        .onDisappear { board.saveNow() }
    }
}
```

- [ ] **Step 6: The canvas**

Create `Sources/linkc/Board/BoardCanvas.swift`:

```swift
import SwiftUI
import LinkCKit

/// The Board's canvas. The dot grid, frames and arrows are one `Canvas` pass; components, notes,
/// texts and frame handles are views on one layer that pans and zooms as a whole. Only what is
/// on screen is built, and a drag moves one offset until it is dropped.
struct BoardCanvas: View {
    @Bindable var board: BoardModel
    let projectPath: String
    let sidebarState: SidebarState
    /// Loads the board; called once when the canvas appears, before the viewport is placed.
    let prepare: () -> Void

    static let space = "board"

    @State private var viewport: BoardViewport = .initial
    @State private var size: CGSize = .zero
    @State private var canvasFrame: CGRect = .zero
    /// Screen offset of the elements being dragged, until they are dropped.
    @State private var dragOffset: CGSize = .zero
    @State private var dragging: Set<BoardModel.Element> = []
    /// The selection box being drawn, in screen points.
    @State private var marquee: CGRect?
    @State private var spaceHeld = false
    @State private var panStart: BoardViewport?
    /// A frame being resized: its label and the proposed rect, until release.
    @State private var resizing: (label: String, rect: BoardRect)?
    @State private var input = BoardInput()

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                background
                drawing
                elements
                overlays
            }
            .coordinateSpace(.named(Self.space))
            .clipped()
            .onAppear {
                size = geometry.size
                canvasFrame = geometry.frame(in: .global)
                prepare()
                placeViewport()
                wireInput()
                input.start()
            }
            .onChange(of: geometry.size) { _, newSize in
                size = newSize
                canvasFrame = geometry.frame(in: .global)
            }
            .onDisappear {
                input.stop()
                sidebarState.setBoardViewport(viewport, for: projectPath)
            }
        }
        .background(Theme.boardBackground)
    }

    // MARK: - Layers

    /// Empty canvas: tapping clears the selection; dragging draws a selection box, or pans while
    /// Space is held.
    private var background: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
                    .onChanged(backgroundDragChanged)
                    .onEnded(backgroundDragEnded))
            .onTapGesture(count: 1, coordinateSpace: .named(Self.space)) { location in
                backgroundTapped(at: location)
            }
    }

    private var drawing: some View {
        Canvas { context, canvasSize in
            drawGrid(in: &context, size: canvasSize)
            drawFrames(in: &context)
            drawArrows(in: &context)
            if let marquee {
                let path = Path(roundedRect: marquee, cornerRadius: 3)
                context.fill(path, with: .color(Theme.accent.opacity(0.08)))
                context.stroke(path, with: .color(Theme.accent.opacity(0.6)), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }

    private var elements: some View {
        let visible = visibleCanvasRect()
        return ZStack(alignment: .topLeading) {
            ForEach(board.map.frames.filter { frameRect($0)?.intersects(visible) == true }) { frame in
                frameHandles(frame)
            }
            ForEach(board.map.components.filter { componentRect($0)?.intersects(visible) == true }) { component in
                if let at = component.at {
                    ComponentBox(component: component, status: board.statuses[component.name],
                                 isSelected: board.selection.contains(.component(component.name)))
                        .offset(x: CGFloat(at.x), y: CGFloat(at.y))
                        .offset(liveOffset(for: .component(component.name), place: component.place))
                        .gesture(elementDrag(.component(component.name)))
                        .onTapGesture { select(.component(component.name)) }
                }
            }
            ForEach(board.map.notes.filter { note in note.at.map { BoardGeometry.rect(ofNoteAt: $0).intersects(visible) } ?? false }) { note in
                if let at = note.at {
                    NoteCard(note: note, isSelected: board.selection.contains(.note(note.id)))
                        .offset(x: CGFloat(at.x), y: CGFloat(at.y))
                        .offset(liveOffset(for: .note(note.id), place: nil, rect: BoardGeometry.rect(ofNoteAt: at)))
                        .gesture(elementDrag(.note(note.id)))
                        .onTapGesture { select(.note(note.id)) }
                }
            }
            ForEach(board.map.texts.filter { BoardGeometry.rect(of: $0).intersects(visible) }) { text in
                TextLabel(text: text, isSelected: board.selection.contains(.text(text.id)))
                    .offset(x: CGFloat(text.at.x), y: CGFloat(text.at.y))
                    .offset(liveOffset(for: .text(text.id), place: nil, rect: BoardGeometry.rect(of: text)))
                    .gesture(elementDrag(.text(text.id)))
                    .onTapGesture { select(.text(text.id)) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .scaleEffect(viewport.zoom, anchor: .topLeading)
        .offset(x: -viewport.originX * viewport.zoom, y: -viewport.originY * viewport.zoom)
    }

    @ViewBuilder
    private func frameHandles(_ frame: BoardFrame) -> some View {
        if let rect = frameRect(frame) {
            let offset = liveOffset(for: .frame(frame.label), place: nil)
            FrameLabel(label: frame.label, isSelected: board.selection.contains(.frame(frame.label)))
                .offset(x: CGFloat(rect.x + 12), y: CGFloat(rect.y) - 9)
                .offset(offset)
                .gesture(elementDrag(.frame(frame.label)))
                .onTapGesture { select(.frame(frame.label)) }
            FrameGrip()
                .offset(x: CGFloat(rect.maxX) - 16, y: CGFloat(rect.maxY) - 16)
                .offset(offset)
                .gesture(resizeDrag(frame.label))
        }
    }

    @ViewBuilder
    private var overlays: some View {
        switch board.state {
        case .failed(let reason):
            BoardNotice(
                title: "This map couldn't be read", detail: reason, tone: Theme.statusError,
                action: ("Try again", { board.reload() }))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            BoardEmptyState(
                runningCount: board.suggestions.count,
                addRunning: { board.addAllRunning(); fitAll() },
                startEmpty: { board.startMap() })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            VStack(spacing: 6) {
                if board.changedOnDisk {
                    BoardBanner(text: "system-map.json changed on disk. Reload to see it — edits not yet saved here are dropped.",
                                tone: Theme.contextWarn, action: ("Reload", { board.reload() }))
                }
                if let failure = board.writeFailure {
                    BoardBanner(text: "Couldn't save the map: \(failure)", tone: Theme.contextWarn,
                                action: ("Retry", { board.saveNow() }))
                }
                Spacer()
                if let refusal = board.refusal {
                    Text(refusal)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.accent)
                        .padding(.bottom, 58)
                }
            }
            .padding(.top, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Drawing

    private func drawGrid(in context: inout GraphicsContext, size: CGSize) {
        var spacing = 16.0
        while spacing * viewport.zoom < 12 { spacing *= 2 }
        let visible = viewport.visibleRect(width: size.width, height: size.height)
        let startX = (Double(visible.minX) / spacing).rounded(.down) * spacing
        let startY = (Double(visible.minY) / spacing).rounded(.down) * spacing
        var dots = Path()
        var x = startX
        while x <= Double(visible.maxX) {
            var y = startY
            while y <= Double(visible.maxY) {
                let point = viewport.toScreen(CGPoint(x: x, y: y))
                dots.addEllipse(in: CGRect(x: point.x - 0.8, y: point.y - 0.8, width: 1.6, height: 1.6))
                y += spacing
            }
            x += spacing
        }
        context.fill(dots, with: .color(Theme.boardDot))
    }

    private func drawFrames(in context: inout GraphicsContext) {
        for frame in board.map.frames {
            guard let rect = frameRect(frame) else { continue }
            let offset = liveOffset(for: .frame(frame.label), place: nil)
            let origin = viewport.toScreen(CGPoint(x: Double(rect.x), y: Double(rect.y)))
            let screen = CGRect(x: origin.x + offset.width * viewport.zoom, y: origin.y + offset.height * viewport.zoom,
                                width: Double(rect.w) * viewport.zoom, height: Double(rect.h) * viewport.zoom)
            let path = Path(roundedRect: screen, cornerRadius: 12 * viewport.zoom)
            context.fill(path, with: .color(Theme.boardFrameFill))
            let selected = board.selection.contains(.frame(frame.label))
            context.stroke(path, with: .color(selected ? Theme.accent.opacity(0.7) : Theme.boardFrameStroke), lineWidth: 1)
        }
    }

    private func drawArrows(in context: inout GraphicsContext) {
        for component in board.map.components {
            for (target, label) in component.uses {
                let key = BoardModel.ArrowKey(from: component.name, to: target)
                guard let points = livePoints(for: key) else { continue }
                let screen = points.map { viewport.toScreen(CGPoint(x: Double($0.x), y: Double($0.y))) }
                let selected = board.selection.contains(.arrow(key))
                let planned = board.map.components.first { $0.name == target }?.planned == true
                let colour = selected ? Theme.accent : Theme.boardArrow
                context.stroke(arrowPath(screen), with: .color(colour),
                               style: StrokeStyle(lineWidth: selected ? 1.8 : 1.3, lineCap: .round, lineJoin: .round, dash: planned ? [4, 4] : []))
                if let head = arrowHead(screen) { context.fill(head, with: .color(colour)) }
                if !label.isEmpty, let mid = labelPoint(screen) {
                    let text = context.resolve(Text(label).font(.system(size: 9.5)).foregroundColor(Theme.textSecondary))
                    let measured = text.measure(in: CGSize(width: 240, height: 40))
                    let box = CGRect(x: mid.x - measured.width / 2 - 5, y: mid.y - measured.height / 2 - 2,
                                     width: measured.width + 10, height: measured.height + 4)
                    context.fill(Path(roundedRect: box, cornerRadius: 4), with: .color(Theme.boardBackground))
                    context.draw(text, at: mid)
                }
            }
        }
    }

    /// A straight arrow draws as a gentle curve leaving and entering along its anchor sides; an
    /// elbow draws through its points with rounded joins.
    private func arrowPath(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first, let last = points.last else { return path }
        path.move(to: first)
        if points.count == 2 {
            let horizontal = abs(last.x - first.x) >= abs(last.y - first.y)
            let pull = horizontal ? (last.x - first.x) * 0.4 : (last.y - first.y) * 0.4
            let c1 = horizontal ? CGPoint(x: first.x + pull, y: first.y) : CGPoint(x: first.x, y: first.y + pull)
            let c2 = horizontal ? CGPoint(x: last.x - pull, y: last.y) : CGPoint(x: last.x, y: last.y - pull)
            path.addCurve(to: last, control1: c1, control2: c2)
        } else {
            for point in points.dropFirst() { path.addLine(to: point) }
        }
        return path
    }

    /// The head points the way the arrow arrives: along its anchor side for a curve, along the
    /// last segment for an elbow.
    private func arrowHead(_ points: [CGPoint]) -> Path? {
        guard points.count >= 2, let tip = points.last else { return nil }
        let angle: Double
        if points.count == 2 {
            let first = points[0]
            angle = abs(tip.x - first.x) >= abs(tip.y - first.y)
                ? (tip.x >= first.x ? 0 : .pi)
                : (tip.y >= first.y ? .pi / 2 : -.pi / 2)
        } else {
            let from = points[points.count - 2]
            angle = atan2(tip.y - from.y, tip.x - from.x)
        }
        let length = 7.0
        var path = Path()
        path.move(to: tip)
        path.addLine(to: CGPoint(x: tip.x - length * cos(angle - 0.45), y: tip.y - length * sin(angle - 0.45)))
        path.addLine(to: CGPoint(x: tip.x - length * cos(angle + 0.45), y: tip.y - length * sin(angle + 0.45)))
        path.closeSubpath()
        return path
    }

    private func labelPoint(_ points: [CGPoint]) -> CGPoint? {
        guard points.count >= 2 else { return nil }
        let index = (points.count - 1) / 2
        let a = points[index], b = points[index + 1]
        return CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }

    // MARK: - Geometry helpers

    private func visibleCanvasRect() -> BoardRect {
        let rect = viewport.visibleRect(width: size.width, height: size.height)
        return BoardRect(x: rect.x - 64, y: rect.y - 64, w: rect.w + 128, h: rect.h + 128)
    }

    private func componentRect(_ component: BoardComponent) -> BoardRect? {
        component.at.map(BoardGeometry.rect(ofComponentAt:))
    }

    private func frameRect(_ frame: BoardFrame) -> BoardRect? {
        if let resizing, resizing.label == frame.label { return resizing.rect }
        return frame.rect
    }

    /// The canvas offset of an element mid-drag: its own, or the frame's it lives in or sits
    /// wholly inside.
    private func liveOffset(for element: BoardModel.Element, place: String?, rect: BoardRect? = nil) -> CGSize {
        guard !dragging.isEmpty else { return .zero }
        let carriedByPlace = place.map { dragging.contains(.frame($0)) } ?? false
        let carriedByFrame = rect.map { rect in
            board.map.frames.contains { frame in
                dragging.contains(.frame(frame.label)) && (frame.rect.map { BoardGeometry.interior(of: $0).contains(rect) } ?? false)
            }
        } ?? false
        guard dragging.contains(element) || carriedByPlace || carriedByFrame else { return .zero }
        return CGSize(width: dragOffset.width / viewport.zoom, height: dragOffset.height / viewport.zoom)
    }

    /// An arrow's points, following its ends live while either is being dragged.
    private func livePoints(for key: BoardModel.ArrowKey) -> [BoardPoint]? {
        guard !dragging.isEmpty else { return board.routes[key] }
        func liveRect(_ name: String) -> BoardRect? {
            guard let component = board.map.components.first(where: { $0.name == name }), let rect = componentRect(component) else { return nil }
            let offset = liveOffset(for: .component(name), place: component.place)
            return rect.offsetBy(dx: Int(offset.width), dy: Int(offset.height))
        }
        guard let from = liveRect(key.from), let to = liveRect(key.to) else { return nil }
        let moved = liveOffset(for: .component(key.from), place: nil) != .zero
            || liveOffset(for: .component(key.to), place: nil) != .zero
            || board.map.components.contains { ($0.name == key.from || $0.name == key.to) && dragging.contains(.frame($0.place)) }
        return moved ? BoardGeometry.route(from: from, to: to, obstacles: []) : board.routes[key]
    }

    // MARK: - Viewport

    private func placeViewport() {
        if let saved = sidebarState.boardViewport(for: projectPath) {
            viewport = saved
        } else if !board.isEmpty {
            fitAll()
        } else {
            viewport = .initial
        }
    }

    private func fitAll() {
        guard let bounds = board.contentBounds else { return }
        viewport = BoardViewport.fitting(bounds, width: size.width, height: size.height)
    }

    private func wireInput() {
        input.canvasFrame = { canvasFrame }
        input.onSpace = { spaceHeld = $0 }
        input.onScroll = { point, dx, dy, precise, command in
            if command {
                let factor = precise ? exp(Double(dy) * 0.01) : (dy > 0 ? 1.1 : 1 / 1.1)
                viewport = viewport.zoomed(by: factor, aroundScreen: point)
            } else {
                let scale = precise ? 1.0 : 8.0
                viewport = viewport.panned(byScreenDX: Double(dx) * scale, dy: Double(dy) * scale)
            }
        }
        input.onMagnify = { point, magnification in
            viewport = viewport.zoomed(by: 1 + Double(magnification), aroundScreen: point)
        }
        input.onKey = { press in
            guard let command = BoardKeyMap.command(for: press, isEditingText: BoardInput.isEditingText) else { return false }
            perform(command)
            return true
        }
    }

    private func perform(_ command: BoardCommand) {
        switch command {
        case .delete: board.delete(board.selection)
        case .cancel:
            board.selection = []
            board.tool = .select
        case .undo: board.undo()
        case .redo: board.redo()
        case .fitAll: fitAll()
        case .selectTool: board.tool = .select
        case .componentTool: board.tool = .component(.service)
        case .arrowTool: board.tool = .arrow
        case .frameTool: board.tool = .frame
        case .noteTool: board.tool = .note
        case .textTool: board.tool = .text
        }
    }

    // MARK: - Gestures

    private func select(_ element: BoardModel.Element) {
        if NSEvent.modifierFlags.contains(.shift) {
            if board.selection.contains(element) { board.selection.remove(element) } else { board.selection.insert(element) }
        } else {
            board.selection = [element]
        }
    }

    private func elementDrag(_ element: BoardModel.Element) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if dragging.isEmpty {
                    if !board.selection.contains(element) { board.selection = [element] }
                    dragging = board.selection.filter { if case .arrow = $0 { return false } else { return true } }
                }
                dragOffset = value.translation
            }
            .onEnded { value in
                let delta = BoardPoint(x: Int((value.translation.width / viewport.zoom).rounded()),
                                       y: Int((value.translation.height / viewport.zoom).rounded()))
                let moved = dragging
                dragging = []
                dragOffset = .zero
                board.move(moved, by: delta)
            }
    }

    private func resizeDrag(_ label: String) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.space))
            .onChanged { value in
                guard let rect = board.map.frames.first(where: { $0.label == label })?.rect else { return }
                resizing = (label, BoardRect(x: rect.x, y: rect.y,
                                             w: rect.w + Int(value.translation.width / viewport.zoom),
                                             h: rect.h + Int(value.translation.height / viewport.zoom)))
            }
            .onEnded { _ in
                if let resizing { board.resizeFrame(resizing.label, to: resizing.rect) }
                resizing = nil
            }
    }

    private func backgroundDragChanged(_ value: DragGesture.Value) {
        if spaceHeld || panStart != nil {
            if panStart == nil { panStart = viewport }
            if let panStart {
                viewport = panStart.panned(byScreenDX: value.translation.width, dy: value.translation.height)
            }
            return
        }
        guard board.tool == .select else { return }
        marquee = CGRect(x: min(value.startLocation.x, value.location.x), y: min(value.startLocation.y, value.location.y),
                         width: abs(value.location.x - value.startLocation.x), height: abs(value.location.y - value.startLocation.y))
    }

    private func backgroundDragEnded(_ value: DragGesture.Value) {
        if panStart != nil {
            panStart = nil
            return
        }
        guard let marquee else { return }
        self.marquee = nil
        let topLeft = viewport.toCanvas(marquee.origin)
        let bottomRight = viewport.toCanvas(CGPoint(x: marquee.maxX, y: marquee.maxY))
        let area = BoardRect(x: Int(topLeft.x), y: Int(topLeft.y),
                             w: Int(bottomRight.x - topLeft.x), h: Int(bottomRight.y - topLeft.y))
        var picked: Set<BoardModel.Element> = []
        for component in board.map.components where componentRect(component)?.intersects(area) == true {
            picked.insert(.component(component.name))
        }
        for note in board.map.notes where note.at.map({ BoardGeometry.rect(ofNoteAt: $0).intersects(area) }) == true {
            picked.insert(.note(note.id))
        }
        for text in board.map.texts where BoardGeometry.rect(of: text).intersects(area) {
            picked.insert(.text(text.id))
        }
        board.selection = NSEvent.modifierFlags.contains(.shift) ? board.selection.union(picked) : picked
    }

    /// A tap on empty canvas selects the arrow under it, if any, and otherwise clears the selection.
    private func backgroundTapped(at location: CGPoint) {
        if let arrow = arrow(near: location) {
            select(.arrow(arrow))
        } else {
            board.selection = []
        }
    }

    /// The arrow within 6 screen points of `location`, if any.
    func arrow(near location: CGPoint) -> BoardModel.ArrowKey? {
        for (key, points) in board.routes {
            let screen = points.map { viewport.toScreen(CGPoint(x: Double($0.x), y: Double($0.y))) }
            for (a, b) in zip(screen, screen.dropFirst()) where distance(from: location, toSegment: a, b) < 6 {
                return key
            }
        }
        return nil
    }

    private func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}

/// The Board of a project with no map: start from what is running, or start empty.
struct BoardEmptyState: View {
    let runningCount: Int
    let addRunning: () -> Void
    let startEmpty: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text("No map for this project yet")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(runningCount > 0
                 ? "linkC can see \(runningCount) container\(runningCount == 1 ? "" : "s") running for this project. Start from those, or draw it yourself."
                 : "Draw what this project is made of: its databases, services and hosts, and how they talk.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            HStack(spacing: 8) {
                if runningCount > 0 {
                    Button("Add what's running (\(runningCount))", action: addRunning)
                        .buttonStyle(.borderedProminent)
                }
                Button("Start empty", action: startEmpty)
                    .buttonStyle(.bordered)
            }
            .controlSize(.regular)
            Text("Nothing is written until you add something.")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textTertiary.opacity(0.8))
        }
    }
}

/// A centred notice for a Board that cannot be used as it is.
struct BoardNotice: View {
    let title: String
    let detail: String
    let tone: Color
    let action: (String, () -> Void)

    var body: some View {
        VStack(spacing: 8) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tone)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button(action.0, action: action.1)
                .buttonStyle(.bordered)
        }
    }
}

/// A one-line banner across the top of the canvas.
struct BoardBanner: View {
    let text: String
    let tone: Color
    let action: (String, () -> Void)

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(tone)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
            Button(action.0, action: action.1)
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tone)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(Theme.boardBox))
        .overlay(Capsule().strokeBorder(tone.opacity(0.35), lineWidth: 1))
    }
}
```

- [ ] **Step 7: Build and run the suite**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!` — with no warnings in the new files (`swift build 2>&1 | grep -E "Board.*warning"` prints nothing).

Run: `swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1`
Expected: 0 failures.

- [ ] **Step 8: Commit**

```bash
git add Sources/linkc/Board Sources/linkc/Theme.swift Sources/linkc/LinkCApp.swift
git diff --cached --stat
git commit -m "feat(board): the canvas — one drawing pass, pan, zoom, select and move"
git log -1 --format=%B | grep -ic claude   # must print 0
```

---
### Task 9: The canvas's tools — placing, connecting, editing

**Files:**
- Modify: `Sources/linkc/Board/BoardCanvas.swift`
- Create: `Sources/linkc/Board/BoardTools.swift` (toolbar, inspector, editors, quick add, chip, system field)

**Interfaces:**
- Consumes: everything Task 8 built in `BoardCanvas` (`board`, `viewport`, `select(_:)`, `elementDrag(_:)`, `backgroundTapped(at:)`, `arrow(near:)`, `perform(_:)`, `liveOffset(for:place:)`, `componentRect(_:)`, `drawing`, `elements`, `overlays`), and on `BoardModel`: `tool`, `addComponent(kind:at:)`, `addNote(at:)`, `addText(at:style:text:width:)`, `addFrame(_:)`, `updateComponent(_:to:)`, `renameFrame(_:to:)`, `setNoteText(_:to:)`, `setText(_:to:width:)`, `addArrow(from:to:)`, `setArrowLabel(_:to:)`, `addSuggestion(_:)`, `addAllRunning()`, `setSystem(_:)`, `suggestions`, `refusal`.
- Produces: the finished canvas. No new public API.

What it adds, from the spec's §2:
- **Toolbar** at the bottom centre: Select (V), Component (C, a menu of kinds; the last kind is remembered), Arrow (A), Frame (F), Note (N), Text (T). The active tool is highlighted. After placing anything the tool returns to Select.
- **Placing:** with Component, Note or Text, a click on empty canvas places one there, centred on the pointer. With Frame, dragging on empty canvas draws the frame; a plain click places a 320 × 200 frame. A new component opens its inspector; a new note, text or frame opens its inline editor.
- **Arrows:** hovering a component in Select shows a handle on each side; dragging from a handle onto another component draws an arrow. With the Arrow tool, dragging from a component's body does the same. A dashed accent line follows the pointer while drawing.
- **Inspector:** clicking a component (no ⇧) selects it and opens a card beside it — name, kind, what it does, reached by, runs, still planned; lives in and uses, read-only. Done commits through `updateComponent`; a refusal keeps the card open, with what was typed, and shows why.
- **Inline editing:** double-click a note, a text or a frame's label to edit it in place; commit on Return (for single-line fields) or when focus leaves. Double-click an arrow to edit its label. An emptied text is removed (the model does this).
- **Quick add:** double-click empty canvas (away from any arrow) opens a menu at the pointer: every component kind, a note, a text, a frame.
- **Chip:** at the top right, "N running, not on the map" when the board has suggestions; its popover lists each with Add, plus Add all.
- **System line:** a one-line field pinned to the top left, "What is this project?" until filled; commits on Return or focus loss through `setSystem` (which ignores an unchanged value, so focusing and leaving writes nothing).

- [ ] **Step 1: The tool views**

Create `Sources/linkc/Board/BoardTools.swift`:

```swift
import SwiftUI
import LinkCKit

/// The floating toolbar at the bottom of the canvas.
struct BoardToolbar: View {
    @Bindable var board: BoardModel
    @Binding var lastKind: ComponentKind

    var body: some View {
        HStack(spacing: 2) {
            toolButton(.select, glyph: "cursorarrow", title: "Select", key: "V")
            Menu {
                ForEach(ComponentKind.known, id: \.raw) { kind in
                    Button {
                        lastKind = kind
                        board.tool = .component(kind)
                    } label: {
                        Label(kind.raw.capitalized, systemImage: kind.glyph)
                    }
                }
            } label: {
                toolLabel(glyph: lastKind.glyph, title: "Component", key: "C", isOn: isComponentTool)
            } primaryAction: {
                board.tool = .component(lastKind)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            toolButton(.arrow, glyph: "arrow.right", title: "Arrow", key: "A")
            toolButton(.frame, glyph: "rectangle.dashed", title: "Frame", key: "F")
            toolButton(.note, glyph: "note.text", title: "Note", key: "N")
            toolButton(.text, glyph: "textformat", title: "Text", key: "T")
        }
        .padding(5)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.boardBox.opacity(0.96)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 12, y: 6)
    }

    private var isComponentTool: Bool {
        if case .component = board.tool { return true }
        return false
    }

    private func toolButton(_ tool: BoardModel.Tool, glyph: String, title: String, key: String) -> some View {
        Button { board.tool = tool } label: {
            toolLabel(glyph: glyph, title: title, key: key, isOn: board.tool == tool)
        }
        .buttonStyle(.plain)
    }

    private func toolLabel(glyph: String, title: String, key: String, isOn: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: glyph).font(.system(size: 11))
            Text(title).font(.system(size: 11))
            Text(key).font(.system(size: 9)).foregroundStyle(Theme.textTertiary)
        }
        .foregroundStyle(isOn ? Theme.accent : Theme.textSecondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(isOn ? Theme.accent.opacity(0.16) : .clear))
        .contentShape(Rectangle())
        .help("\(title) (\(key))")
    }
}

/// The card beside a selected component.
struct ComponentInspector: View {
    let original: String
    let livesIn: String
    let uses: [(target: String, label: String)]
    let refusal: String?
    /// Commits the draft; returns false when the board refused it, which keeps the card open.
    let commit: (BoardComponent) -> Bool
    let close: () -> Void

    @State private var draft: BoardComponent

    init(component: BoardComponent, livesIn: String, uses: [(target: String, label: String)], refusal: String?,
         commit: @escaping (BoardComponent) -> Bool, close: @escaping () -> Void) {
        self.original = component.name
        self.livesIn = livesIn
        self.uses = uses
        self.refusal = refusal
        self.commit = commit
        self.close = close
        _draft = State(wrappedValue: component)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            field("Name", text: $draft.name)
            VStack(alignment: .leading, spacing: 3) {
                caption("Kind")
                Picker("", selection: $draft.kind) {
                    ForEach(kinds, id: \.raw) { kind in
                        Label(kind.raw.capitalized, systemImage: kind.glyph).tag(kind)
                    }
                }
                .labelsHidden()
            }
            field("What it does", text: optional(\.does), prompt: "one line: what this is for")
            field("Reached by", text: optional(\.reachedBy), prompt: "DATABASE_URL, a URL, a host")
            field("Runs", text: optional(\.runs), prompt: "docker compose (db) — how linkC finds it running")
            Toggle("Still planned — doesn't exist yet", isOn: $draft.planned)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.system(size: 11))
            Divider()
            readOnly("Lives in", livesIn)
            readOnly("Uses", uses.isEmpty ? "nothing yet — drag an arrow from its side"
                     : uses.map { $0.label.isEmpty ? $0.target : "\($0.target) (\($0.label))" }.joined(separator: ", "))
            if let refusal {
                Text(refusal).font(.system(size: 10.5)).foregroundStyle(Theme.accent)
            }
            HStack {
                Spacer()
                Button("Done") {
                    if commit(draft) { close() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 11))
        .padding(12)
        .frame(width: 280)
    }

    /// The known kinds, plus this component's own kind when linkC does not know it — so a
    /// preserved custom kind is shown, and kept unless changed.
    private var kinds: [ComponentKind] {
        draft.kind.isKnown ? ComponentKind.known : ComponentKind.known + [draft.kind]
    }

    private func optional(_ keyPath: WritableKeyPath<BoardComponent, String?>) -> Binding<String> {
        Binding(get: { draft[keyPath: keyPath] ?? "" }, set: { draft[keyPath: keyPath] = $0 })
    }

    private func field(_ title: String, text: Binding<String>, prompt: String = "") -> some View {
        VStack(alignment: .leading, spacing: 3) {
            caption(title)
            TextField(prompt, text: text)
        }
    }

    private func caption(_ title: String) -> some View {
        Text(title.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(0.5).foregroundStyle(Theme.textTertiary)
    }

    private func readOnly(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            caption(title)
            Text(value).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A note being edited in place. Commits when focus leaves.
struct NoteEditor: View {
    let commit: (String) -> Void
    @State private var text: String
    @FocusState private var focused: Bool

    init(text: String, commit: @escaping (String) -> Void) {
        self.commit = commit
        _text = State(wrappedValue: text)
    }

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 11))
            .foregroundStyle(Theme.noteText)
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(width: CGFloat(BoardGeometry.noteSize.x), height: CGFloat(BoardGeometry.noteSize.y))
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.noteFill))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.accent, lineWidth: 1.5))
            .focused($focused)
            .onAppear { focused = true }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commit(text) }
            }
    }
}

/// A single line being edited in place — a text, a frame's label, an arrow's label. Commits on
/// Return or when focus leaves.
struct LineEditor: View {
    let font: Font
    let width: CGFloat
    let commit: (String) -> Void
    @State private var text: String
    @State private var committed = false
    @FocusState private var focused: Bool

    init(text: String, font: Font, width: CGFloat, commit: @escaping (String) -> Void) {
        self.font = font
        self.width = width
        self.commit = commit
        _text = State(wrappedValue: text)
    }

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(font)
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 4)
            .frame(width: width)
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.boardBox))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.accent, lineWidth: 1))
            .focused($focused)
            .onAppear { focused = true }
            .onSubmit(finish)
            .onChange(of: focused) { _, isFocused in
                if !isFocused { finish() }
            }
    }

    private func finish() {
        guard !committed else { return }
        committed = true
        commit(text)
    }
}

/// What double-clicking empty canvas offers.
struct QuickAddMenu: View {
    let add: (QuickAddChoice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(ComponentKind.known, id: \.raw) { kind in
                row(kind.raw.capitalized, glyph: kind.glyph) { add(.component(kind)) }
            }
            Divider().padding(.vertical, 3)
            row("Note", glyph: "note.text") { add(.note) }
            row("Text", glyph: "textformat") { add(.text) }
            row("Frame", glyph: "rectangle.dashed") { add(.frame) }
        }
        .padding(6)
        .frame(width: 170)
    }

    private func row(_ title: String, glyph: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: glyph)
                .font(.system(size: 11.5))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

enum QuickAddChoice {
    case component(ComponentKind)
    case note
    case text
    case frame
}

/// What linkC sees running that the map does not name.
struct SuggestionList: View {
    let suggestions: [MapSuggestion]
    let add: (MapSuggestion) -> Void
    let addAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(suggestions) { suggestion in
                HStack(spacing: 8) {
                    Image(systemName: suggestion.kind.glyph).foregroundStyle(Theme.textSecondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(suggestion.name).font(.system(size: 11.5, weight: .medium))
                        Text(suggestion.detail).font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                    }
                    Spacer(minLength: 12)
                    Button("Add") { add(suggestion) }.font(.system(size: 11))
                }
            }
            if suggestions.count > 1 {
                Divider()
                Button("Add all \(suggestions.count)", action: addAll).font(.system(size: 11))
            }
        }
        .padding(12)
        .frame(width: 300)
    }
}
```

- [ ] **Step 2: Wire the tools into the canvas**

In `Sources/linkc/Board/BoardCanvas.swift`:

1. Add this state beside the existing `@State` properties:

```swift
    @State private var lastKind: ComponentKind = .service
    /// The component whose inspector card is open.
    @State private var inspecting: String?
    @State private var editingNote: UUID?
    @State private var editingText: UUID?
    @State private var editingFrame: String?
    @State private var editingArrow: BoardModel.ArrowKey?
    /// A component under the pointer, whose side handles are showing.
    @State private var hovered: String?
    /// An arrow being drawn: the component it leaves and the pointer, in screen points.
    @State private var arrowDraft: (from: String, to: CGPoint)?
    /// A frame being drawn, in screen points.
    @State private var frameDraft: CGRect?
    /// Where the quick-add menu opens, in screen points.
    @State private var quickAddAt: CGPoint?
    @State private var showingSuggestions = false
    @State private var systemDraft = ""
    @FocusState private var systemFocused: Bool
```

2. In `perform(_:)`, make the component tool use the remembered kind:

```swift
        case .componentTool: board.tool = .component(lastKind)
```

3. Replace the `background` view so it also handles double-clicks, and routes both taps by tool:

```swift
    private var background: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
                    .onChanged(backgroundDragChanged)
                    .onEnded(backgroundDragEnded))
            .onTapGesture(count: 2, coordinateSpace: .named(Self.space)) { location in
                backgroundDoubleTapped(at: location)
            }
            .onTapGesture(count: 1, coordinateSpace: .named(Self.space)) { location in
                backgroundTapped(at: location)
            }
    }
```

4. Replace `backgroundTapped(at:)` and add the double-tap and placement handlers:

```swift
    /// A tap on empty canvas places what the tool makes, or — with Select — selects the arrow
    /// under it, or clears the selection.
    private func backgroundTapped(at location: CGPoint) {
        let point = viewport.toCanvas(location)
        switch board.tool {
        case .component(let kind): place(.component(kind), at: point)
        case .note: place(.note, at: point)
        case .text: place(.text, at: point)
        case .frame: place(.frame, at: point)
        case .arrow: board.selection = []
        case .select:
            if let arrow = arrow(near: location) { select(.arrow(arrow)) } else { board.selection = [] }
        }
    }

    private func backgroundDoubleTapped(at location: CGPoint) {
        guard board.tool == .select else { return }
        if let arrow = arrow(near: location) {
            board.selection = [.arrow(arrow)]
            editingArrow = arrow
        } else {
            quickAddAt = location
        }
    }

    /// Places one thing centred on `point` (canvas), opens its editor, and returns to Select.
    private func place(_ choice: QuickAddChoice, at point: CGPoint) {
        let x = Int(point.x), y = Int(point.y)
        switch choice {
        case .component(let kind):
            let size = BoardGeometry.componentSize
            if let name = board.addComponent(kind: kind, at: BoardPoint(x: x - size.x / 2, y: y - size.y / 2)) {
                inspecting = name
            }
        case .note:
            let size = BoardGeometry.noteSize
            editingNote = board.addNote(at: BoardPoint(x: x - size.x / 2, y: y - size.y / 2))
        case .text:
            let width = TextLabel.width(of: "Text", style: .label)
            editingText = board.addText(at: BoardPoint(x: x - width / 2, y: y - 10), style: .label, text: "Text", width: width)
        case .frame:
            editingFrame = board.addFrame(BoardRect(x: x - 160, y: y - 100, w: 320, h: 200))
        }
        board.tool = .select
    }
```

5. In `backgroundDragChanged`, before the `guard board.tool == .select` line, draw a frame with the Frame tool:

```swift
        if board.tool == .frame {
            frameDraft = CGRect(x: min(value.startLocation.x, value.location.x), y: min(value.startLocation.y, value.location.y),
                                width: abs(value.location.x - value.startLocation.x), height: abs(value.location.y - value.startLocation.y))
            return
        }
```

and in `backgroundDragEnded`, after the pan early-return, finish it:

```swift
        if let frameDraft {
            self.frameDraft = nil
            let topLeft = viewport.toCanvas(frameDraft.origin)
            let bottomRight = viewport.toCanvas(CGPoint(x: frameDraft.maxX, y: frameDraft.maxY))
            editingFrame = board.addFrame(BoardRect(x: Int(topLeft.x), y: Int(topLeft.y),
                                                    w: Int(bottomRight.x - topLeft.x), h: Int(bottomRight.y - topLeft.y)))
            board.tool = .select
            return
        }
```

6. In `drawing`, after the marquee, draw the drafts:

```swift
            if let frameDraft {
                let path = Path(roundedRect: frameDraft, cornerRadius: 12 * viewport.zoom)
                context.stroke(path, with: .color(Theme.accent.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            }
            if let arrowDraft, let source = board.map.components.first(where: { $0.name == arrowDraft.from }),
               let rect = componentRect(source) {
                let start = viewport.toScreen(CGPoint(x: Double(rect.center.x), y: Double(rect.center.y)))
                var path = Path()
                path.move(to: start)
                path.addLine(to: arrowDraft.to)
                context.stroke(path, with: .color(Theme.accent), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            }
```

7. In `elements`, replace the component `ForEach` body so a component shows its handles on hover, opens its inspector, and — with the Arrow tool — draws an arrow instead of moving:

```swift
            ForEach(board.map.components.filter { componentRect($0)?.intersects(visible) == true }) { component in
                if let at = component.at {
                    ComponentBox(component: component, status: board.statuses[component.name],
                                 isSelected: board.selection.contains(.component(component.name)))
                        .overlay { if hovered == component.name && board.tool == .select && dragging.isEmpty { handles(for: component.name) } }
                        .onHover { inside in
                            if inside { hovered = component.name } else if hovered == component.name { hovered = nil }
                        }
                        .popover(isPresented: Binding(get: { inspecting == component.name }, set: { if !$0 { inspecting = nil } }),
                                 arrowEdge: .trailing) {
                            ComponentInspector(
                                component: component,
                                livesIn: component.place,
                                uses: component.uses.keys.sorted().map { ($0, component.uses[$0] ?? "") },
                                refusal: board.refusal,
                                commit: { board.updateComponent(component.name, to: $0) },
                                close: { inspecting = nil })
                        }
                        .offset(x: CGFloat(at.x), y: CGFloat(at.y))
                        .offset(liveOffset(for: .component(component.name), place: component.place))
                        .gesture(board.tool == .arrow ? AnyGesture(arrowDrag(from: component.name).map { _ in () })
                                                      : AnyGesture(elementDrag(.component(component.name)).map { _ in () }))
                        .onTapGesture {
                            select(.component(component.name))
                            if !NSEvent.modifierFlags.contains(.shift) { inspecting = component.name }
                        }
                }
            }
```

8. Replace the note and text `ForEach` bodies so they edit in place on double-click:

```swift
            ForEach(board.map.notes.filter { note in note.at.map { BoardGeometry.rect(ofNoteAt: $0).intersects(visible) } ?? false }) { note in
                if let at = note.at {
                    Group {
                        if editingNote == note.id {
                            NoteEditor(text: note.text) { text in
                                board.setNoteText(note.id, to: text)
                                editingNote = nil
                            }
                        } else {
                            NoteCard(note: note, isSelected: board.selection.contains(.note(note.id)))
                                .gesture(elementDrag(.note(note.id)))
                                .onTapGesture(count: 2) { editingNote = note.id }
                                .onTapGesture { select(.note(note.id)) }
                        }
                    }
                    .offset(x: CGFloat(at.x), y: CGFloat(at.y))
                    .offset(liveOffset(for: .note(note.id), place: nil, rect: BoardGeometry.rect(ofNoteAt: at)))
                }
            }
            ForEach(board.map.texts.filter { BoardGeometry.rect(of: $0).intersects(visible) }) { text in
                Group {
                    if editingText == text.id {
                        LineEditor(text: text.text, font: TextLabel.font(text.style), width: CGFloat(max(text.width, 120))) { words in
                            board.setText(text.id, to: words, width: TextLabel.width(of: words, style: text.style))
                            editingText = nil
                        }
                    } else {
                        TextLabel(text: text, isSelected: board.selection.contains(.text(text.id)))
                            .gesture(elementDrag(.text(text.id)))
                            .onTapGesture(count: 2) { editingText = text.id }
                            .onTapGesture { select(.text(text.id)) }
                    }
                }
                .offset(x: CGFloat(text.at.x), y: CGFloat(text.at.y))
                .offset(liveOffset(for: .text(text.id), place: nil, rect: BoardGeometry.rect(of: text)))
            }
```

9. In `frameHandles(_:)`, let the label be edited on double-click:

```swift
            Group {
                if editingFrame == frame.label {
                    LineEditor(text: frame.label, font: .system(size: 10, weight: .semibold), width: 160) { label in
                        board.renameFrame(frame.label, to: label)
                        editingFrame = nil
                    }
                } else {
                    FrameLabel(label: frame.label, isSelected: board.selection.contains(.frame(frame.label)))
                        .gesture(elementDrag(.frame(frame.label)))
                        .onTapGesture(count: 2) { editingFrame = frame.label }
                        .onTapGesture { select(.frame(frame.label)) }
                }
            }
            .offset(x: CGFloat(rect.x + 12), y: CGFloat(rect.y) - 9)
            .offset(offset)
```

(replacing the `FrameLabel` lines Task 8 wrote; the `FrameGrip` stays as it is.)

10. Add the handles and the arrow gesture:

```swift
    /// The four side handles on a hovered component; dragging one draws an arrow.
    private func handles(for name: String) -> some View {
        let size = BoardGeometry.componentSize
        let points = [CGPoint(x: size.x / 2, y: 0), CGPoint(x: size.x, y: size.y / 2),
                      CGPoint(x: size.x / 2, y: size.y), CGPoint(x: 0, y: size.y / 2)]
        return ZStack(alignment: .topLeading) {
            ForEach(points.indices, id: \.self) { index in
                Circle()
                    .fill(Theme.boardBackground)
                    .overlay(Circle().strokeBorder(Theme.accent, lineWidth: 1.5))
                    .frame(width: 10, height: 10)
                    .position(points[index])
                    .gesture(arrowDrag(from: name))
            }
        }
        .frame(width: CGFloat(size.x), height: CGFloat(size.y))
    }

    private func arrowDrag(from name: String) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.space))
            .onChanged { value in arrowDraft = (name, value.location) }
            .onEnded { value in
                arrowDraft = nil
                let point = viewport.toCanvas(value.location)
                let dropped = BoardPoint(x: Int(point.x), y: Int(point.y))
                if let target = board.map.components.first(where: { componentRect($0)?.contains(dropped) == true }) {
                    board.addArrow(from: name, to: target.name)
                }
                board.tool = .select
            }
    }
```

11. In `overlays`' `.loaded` case, add the toolbar, the chip, the system line, the quick-add menu and the arrow-label editor. Replace that case's `VStack` with:

```swift
        case .loaded:
            ZStack {
                VStack(spacing: 6) {
                    HStack(alignment: .top) {
                        TextField("What is this project?", text: $systemDraft)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(maxWidth: 360, alignment: .leading)
                            .focused($systemFocused)
                            .onSubmit { board.setSystem(systemDraft) }
                            .onChange(of: systemFocused) { _, focused in
                                if !focused { board.setSystem(systemDraft) }
                            }
                        Spacer()
                        if !board.suggestions.isEmpty {
                            Button { showingSuggestions = true } label: {
                                Text("\(board.suggestions.count) running, not on the map ›")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.accent)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Capsule().fill(Theme.accent.opacity(0.12)))
                                    .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.3), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .popover(isPresented: $showingSuggestions) {
                                SuggestionList(
                                    suggestions: board.suggestions,
                                    add: { board.addSuggestion($0) },
                                    addAll: { board.addAllRunning(); showingSuggestions = false })
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    if board.changedOnDisk {
                        BoardBanner(text: "system-map.json changed on disk. Reload to see it — edits not yet saved here are dropped.",
                                    tone: Theme.contextWarn, action: ("Reload", { board.reload() }))
                    }
                    if let failure = board.writeFailure {
                        BoardBanner(text: "Couldn't save the map: \(failure)", tone: Theme.contextWarn,
                                    action: ("Retry", { board.saveNow() }))
                    }
                    Spacer()
                    if let refusal = board.refusal {
                        Text(refusal).font(.system(size: 11)).foregroundStyle(Theme.accent)
                    }
                    BoardToolbar(board: board, lastKind: $lastKind)
                        .padding(.bottom, 12)
                }
                .padding(.top, 10)

                if let quickAddAt {
                    Color.clear
                        .frame(width: 1, height: 1)
                        .position(quickAddAt)
                        .popover(isPresented: Binding(get: { self.quickAddAt != nil }, set: { if !$0 { self.quickAddAt = nil } })) {
                            QuickAddMenu { choice in
                                place(choice, at: viewport.toCanvas(quickAddAt))
                                self.quickAddAt = nil
                            }
                        }
                }

                if let editingArrow, let points = board.routes[editingArrow], let mid = labelPoint(
                    points.map { viewport.toScreen(CGPoint(x: Double($0.x), y: Double($0.y))) }) {
                    LineEditor(
                        text: board.map.components.first { $0.name == editingArrow.from }?.uses[editingArrow.to] ?? "",
                        font: .system(size: 10), width: 160
                    ) { label in
                        board.setArrowLabel(editingArrow, to: label)
                        self.editingArrow = nil
                    }
                    .position(mid)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: board.map.system, initial: true) { _, system in
                if !systemFocused { systemDraft = system ?? "" }
            }
```

12. In `perform(_:)`, make `.cancel` also close any open editor and draft:

```swift
        case .cancel:
            board.selection = []
            board.tool = .select
            inspecting = nil
            quickAddAt = nil
            arrowDraft = nil
            frameDraft = nil
```

- [ ] **Step 3: Build and run the suite**

Run: `swift build 2>&1 | tail -3` — expected `Build complete!`, with `swift build 2>&1 | grep -E "Board.*warning"` printing nothing.
Run: `swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1` — expected 0 failures.

- [ ] **Step 4: Commit**

```bash
git add Sources/linkc/Board/BoardCanvas.swift Sources/linkc/Board/BoardTools.swift
git diff --cached --stat
git commit -m "feat(board): tools, arrows, the inspector and editing in place"
git log -1 --format=%B | grep -ic claude   # must print 0
```

---

### Task 10: The tab strip, the Board row, and putting the Board on screen

**Files:**
- Create: `Sources/linkc/Board/ProjectTabStrip.swift`
- Modify: `Sources/linkc/LinkCApp.swift` (`AppModel`: which Board is showing, the current project, its tabs, selecting and closing tabs, remembering the Board across relaunch)
- Modify: `Sources/linkc/PanelView.swift` (`Pane`, `RightPane`, the narrow-panel branch)
- Modify: `Sources/linkc/Sidebar.swift` (the Board row; a session row is not selected while a Board shows)

**Interfaces:**
- Consumes: `ProjectTab`, `ProjectTabs`, `TabKeyMap`, `TabCommand` (Task 7); `BoardInput.press(from:)` (Task 8); `BoardPane` (Task 8); existing `AppModel.focus(_:)`, `stop(_:)`, `stopShell(_:)`, `spawnTeammate(in:agent:)`, `sessionTitles`, `sessions`, `shellRows`, `selectedId`, `activeScreen`, `flushStateToDisk()`, the start-up restore of `"LinkCLastSelectedSessionId"`.
- Produces, on `AppModel`: `boardProject: String?`, `currentProject: String?`, `projectTabs: [ProjectTab]`, `selectedTabID: String?`, `showBoard(_:)`, `select(_ tab:)`, `close(_ tab:)`.

- [ ] **Step 1: The model's side**

In `Sources/linkc/LinkCApp.swift`, on `AppModel`:

```swift
    /// The project whose Board is showing, or nil when a terminal — or nothing — is.
    private(set) var boardProject: String?

    /// The project the tab strip belongs to: the Board's, or the open session's or terminal's folder.
    var currentProject: String? {
        if let boardProject { return boardProject }
        guard let id = selectedId else { return nil }
        if let session = sessions.first(where: { $0.id == id }) { return ProjectTabs.standardized(session.cwd) }
        if let shell = shellRows.first(where: { $0.id == id }) { return ProjectTabs.standardized(shell.cwd) }
        return nil
    }

    var projectTabs: [ProjectTab] {
        guard let project = currentProject else { return [] }
        return ProjectTabs.tabs(project: project, sessions: sessions, shells: shellRows, titles: sessionTitles)
    }

    /// The tab showing: the project's Board, or the selected session or terminal.
    var selectedTabID: String? {
        if let boardProject { return ProjectTabs.boardID(boardProject) }
        return selectedId
    }

    func showBoard(_ path: String) {
        boardProject = ProjectTabs.standardized(path)
        activeScreen = nil
    }

    func select(_ tab: ProjectTab) {
        switch tab.kind {
        case .board:
            if let project = currentProject { showBoard(project) }
        case .agent, .terminal:
            focus(tab.id)
        }
    }

    /// Stops the tab's session. When that leaves nothing showing, the project's Board shows, so
    /// the strip does not vanish from under the pointer.
    func close(_ tab: ProjectTab) {
        let project = currentProject
        switch tab.kind {
        case .board: return
        case .agent: stop(tab.id)
        case .terminal: stopShell(tab.id)
        }
        if selectedId == nil, boardProject == nil, let project { showBoard(project) }
    }
```

Change `focus(_:)` so opening a session leaves the Board:

```swift
    func focus(_ id: String) {
        coordinator?.focusSession(id)
        boardProject = nil
        activeScreen = nil
    }
```

Change `goBack()` so Back from a Board returns to the sidebar:

```swift
    func goBack() {
        if activeScreen != nil {
            activeScreen = nil
        } else if boardProject != nil {
            boardProject = nil
            coordinator?.terminals.deselect()
        } else {
            coordinator?.terminals.deselect()
        }
    }
```

In `flushStateToDisk()`, after the existing `LinkCLastSelectedSessionId` write, remember the Board:

```swift
        UserDefaults.standard.set(boardProject, forKey: "LinkCLastBoardProject")
```

and in `start()`, immediately after the block that restores `LinkCLastSelectedSessionId`, reopen it:

```swift
        if let path = UserDefaults.standard.string(forKey: "LinkCLastBoardProject"),
           FileManager.default.fileExists(atPath: path) {
            showBoard(path)
        }
```

- [ ] **Step 2: The tab strip**

Create `Sources/linkc/Board/ProjectTabStrip.swift`:

```swift
import AppKit
import SwiftUI
import LinkCKit

/// The Chrome-style strip above the right pane: the project's Board, pinned, then a tab per
/// session, then ＋. ⌘1–⌘9 pick a tab and ⌃Tab cycles, through a local key monitor that exists
/// only while the strip does.
struct ProjectTabStrip: View {
    let model: AppModel
    let onBack: (() -> Void)?

    @State private var confirming: ProjectTab?
    @State private var keys = TabKeys()

    private static let minTab: CGFloat = 96
    private static let maxTab: CGFloat = 180

    var body: some View {
        let tabs = model.projectTabs
        let selected = model.selectedTabID
        HStack(spacing: 4) {
            if let onBack {
                ChromeButton(systemName: "chevron.left", help: "Back", action: onBack)
            }
            if let board = tabs.first {
                TabChip(tab: board, isSelected: board.id == selected, width: nil,
                        onSelect: { model.select(board) }, onClose: nil)
            }
            Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1, height: 14)
            GeometryReader { geometry in
                let sessions = Array(tabs.dropFirst())
                let width = sessions.isEmpty
                    ? Self.maxTab
                    : min(Self.maxTab, max(Self.minTab, geometry.size.width / CGFloat(sessions.count) - 2))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(sessions) { tab in
                            TabChip(tab: tab, isSelected: tab.id == selected, width: width,
                                    onSelect: { model.select(tab) }, onClose: { requestClose(tab) })
                        }
                    }
                    .frame(height: geometry.size.height, alignment: .bottom)
                }
                .scrollDisabled(CGFloat(sessions.count) * (width + 2) <= geometry.size.width)
            }
            .frame(height: 30)
            Menu {
                ForEach(AgentKind.allCases.filter { $0 != .shell }, id: \.self) { kind in
                    Button("Add \(kind.displayName)") {
                        if let project = model.currentProject { model.spawnTeammate(in: project, agent: kind) }
                    }
                }
            } label: {
                RowGlyph(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add an agent to this project")
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .background(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
        }
        .onAppear {
            keys.onCommand = handle
            keys.start()
        }
        .onDisappear { keys.stop() }
        .confirmationDialog(
            "Stop \(confirming?.title ?? "this session")?",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            presenting: confirming
        ) { tab in
            Button("Stop", role: .destructive) { model.close(tab) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It's in the middle of a turn.")
        }
    }

    /// A session mid-turn asks first; an idle one closes at once.
    private func requestClose(_ tab: ProjectTab) {
        if tab.isWorking {
            confirming = tab
        } else {
            model.close(tab)
        }
    }

    private func handle(_ command: TabCommand) {
        let tabs = model.projectTabs
        switch command {
        case .select(let digit):
            if let tab = ProjectTabs.tab(forDigit: digit, in: tabs) { model.select(tab) }
        case .next, .previous:
            if let tab = ProjectTabs.cycle(from: model.selectedTabID, in: tabs, backwards: command == .previous) {
                model.select(tab)
            }
        }
    }
}

/// One tab.
private struct TabChip: View {
    let tab: ProjectTab
    let isSelected: Bool
    let width: CGFloat?
    let onSelect: () -> Void
    let onClose: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            switch tab.kind {
            case .board:
                Image(systemName: "square.grid.2x2").font(.system(size: 10))
            case .agent(let kind):
                RoundedRectangle(cornerRadius: 2).fill(Theme.agentColor(kind)).frame(width: 7, height: 7)
            case .terminal:
                Image(systemName: "terminal").font(.system(size: 9))
            }
            Text(tab.title)
                .font(.system(size: 11.5))
                .lineLimit(1)
                .truncationMode(.tail)
            if let onClose {
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .opacity(hovering || isSelected ? 1 : 0)
                .help("Stop this session")
            }
        }
        .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
        .padding(.horizontal, 10)
        .frame(width: width, height: 28, alignment: .leading)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8)
                .fill(isSelected ? Color.white.opacity(0.08) : (hovering ? Theme.hover : .clear)))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .help(tab.title)
    }
}

/// ⌘1–⌘9 and ⌃Tab, through a local key monitor installed only while the strip is showing.
@MainActor
final class TabKeys {
    var onCommand: (TabCommand) -> Void = { _ in }
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window?.isKeyWindow == true,
                  let press = BoardInput.press(from: event),
                  let command = TabKeyMap.command(for: press) else { return event }
            self.onCommand(command)
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
```

- [ ] **Step 3: Put it in the right pane**

In `Sources/linkc/PanelView.swift`:

1. `Pane` gains the Board:

```swift
private enum Pane: Equatable {
    case terminal, board(String), screen(PanelScreen), launcher

    @MainActor init(_ model: AppModel) {
        if let screen = model.activeScreen { self = .screen(screen) }
        else if let board = model.boardProject { self = .board(board) }
        else if model.selectedId != nil { self = .terminal }
        else { self = .launcher }
    }
}
```

2. In `PanelView.body`, the narrow-panel branch shows the right pane for a Board too:

```swift
                            } else if model.selectedId != nil || model.activeScreen != nil || model.boardProject != nil {
```

3. In `RightPane.body`, replace the `else if model.selectedId != nil { TerminalPane(...) }` branch with the strip above the Board or the terminal:

```swift
            } else if model.currentProject != nil {
                VStack(spacing: 0) {
                    ProjectTabStrip(model: model, onBack: showsBack ? { model.goBack() } : nil)
                    if let board = model.boardProject {
                        BoardPane(model: model, path: board)
                            .id(board)
                    } else {
                        TerminalPane(model: model, onBack: nil)
                    }
                }
                .transition(.opacity)
            } else {
```

(The Back button now lives in the strip, so the terminal's header strip no longer shows one.)

- [ ] **Step 4: The Board row in the sidebar**

In `Sources/linkc/Sidebar.swift`, in `ProjectsSection.body`, show the Board row first under an expanded project, and stop marking a session selected while a Board is showing:

```swift
                if project.isExpanded {
                    BoardRow(isSelected: model.boardProject == ProjectTabs.standardized(project.path)) {
                        model.showBoard(project.path)
                    }
                    ForEach(project.sessions) { row in
                        SessionRow(row: row, isSelected: row.id == model.selectedId && model.boardProject == nil, model: model)
                    }
                }
```

and add, beside `SessionRow`:

```swift
/// The first row under an expanded project: its Board.
private struct BoardRow: View {
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        SidebarRow(
            title: "Board",
            titleColor: Theme.textSecondary,
            isSelected: isSelected,
            indent: 18,
            help: "This project's system map",
            action: action
        ) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 12)
        } trailing: { _ in
            EmptyView()
        }
    }
}
```

- [ ] **Step 5: Build and run the suite**

Run: `swift build 2>&1 | tail -3` — expected `Build complete!`.
Run: `swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1` — expected 0 failures.
Run: `grep -rn "Workbench" Sources Tests` — expected no output.

- [ ] **Step 6: Commit**

```bash
git add Sources/linkc/Board/ProjectTabStrip.swift Sources/linkc/LinkCApp.swift Sources/linkc/PanelView.swift Sources/linkc/Sidebar.swift
git diff --cached --stat
git commit -m "feat(board): a tab strip above the terminal, with each project's Board pinned first"
git log -1 --format=%B | grep -ic claude   # must print 0
```

---

### Final verification (controller, not a subagent)

- [ ] **Revert-proof** each rule the model holds — break it, see its tests go red, restore it: no write without an edit; the changed-on-disk refusal; a failed read locking the board; unknown keys surviving; the nearest-free-spot tie order; frames never overlapping; a frame move carrying its components; the arrow elbow; the file's place winning in layout; the tab digit mapping.
- [ ] **Build the app** with `./build-app.sh` (ends `==> Done:`), install it, and on a real project:
  - the Board row and the Board tab both open the Board; ⌘1 opens it from a terminal; ⌃Tab cycles;
  - an empty board offers "Add what's running" when containers run for the folder, and `git status` shows nothing until something is added;
  - add a component, a frame around it, a second component, an arrow between them, a note and a title; drag, drop one on another (it slides), drag a frame (its contents come too); undo and redo;
  - `system-map.json` reads architecture-first: places, what each does and uses, notes, then one layout block;
  - a hand edit to `system-map.json` while the Board is open is refused on the next save, with a Reload offer;
  - `linkc_get_project_context` from a linkC-hosted agent shows the System section grouped by place.
- [ ] **Power:** with the Board showing and untouched for a minute, Activity Monitor shows linkC at 0.0% CPU; with the Board hidden, the same. A 200-component map (generate one with a small script into a scratch folder) pans and zooms without stutter.
- [ ] Whole-branch review on the most capable model, then fix, merge and push.

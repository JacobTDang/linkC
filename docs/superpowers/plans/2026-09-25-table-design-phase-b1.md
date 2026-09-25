# Table design, phase B1: the table kind, its size, editing, import and export

> **For agentic workers:** work task by task, test first. Each task ends with one commit.

**Goal:** `table` becomes a real `ComponentKind`; a table's box is sized from its columns, and
every place in LinkCKit that assumed a fixed 176×84 box now asks the part its real size; agents can
add, change and drop a table's columns through `linkc_edit_board`; a parsed SQL schema becomes an
ordinary board edit (one undo step, the Board's own placement); and a board's tables can be read
back out as `SQLSchema.Table` values for export.

**Spec:** `docs/superpowers/specs/2026-09-25-table-design-design.md` (§1, §2's "box size" bullet,
§3, §4's "Import into the board", §5's phase-B bullets).

**Depends on (already merged into `main`, and present in this worktree):**
- Phase A: `Sources/LinkCKit/Board/BoardColumn.swift` (`BoardColumn`, `BoardColumnReference`),
  `columns` on `BoardComponent`, and `Sources/LinkCKit/Board/BoardMap.swift`'s column
  decoding/encoding.
- `Sources/LinkCKit/SQL/SQLSchema.swift`, `SQLSchemaParser.swift`, `SQLTokenizer.swift`,
  `SQLSchemaWriter.swift` (`SQLSchema.parse(_:)`, `SQLSchema.createStatements(for:)`,
  `SQLSchema.Table`, `SQLSchema.Parsed`).
- Board drill-down phase 1 (merged as `feat/board-drill-down`): `outside: BoardGhostSide?` and
  `detail: String?` on `BoardComponent`, and the ghost-ignoring rules `BoardEdit.swift` already
  follows (see `applyDetail`, `applyUpdate`'s `outside != nil` guard).

**Out of scope for B1 (say so, don't build it):**
- Foreign-key line routing from a column's `references` — routing still only draws `uses` arrows.
  A table's `references` values are carried and exported correctly; nothing yet draws a line for
  one.
- The Supabase dump runner (`supabase db dump --schema-only` through a login shell) — that's a
  process-seam piece for a later phase.
- Everything under `Sources/linkc/` — the table box's drawing, the column grid inspector, and the
  Import/Export SQL menus are the app half, built once `ComponentKind.table` joins
  `ComponentKind.groups` (a separate, later change, made together with the app's drawing code so
  the app's Component menu never offers a kind it can't draw).

## Global Constraints

- **Where to work:** the worktree `/Users/jacobdang/Projects/linkC/.worktrees/table-design-b1`,
  branch `feat/table-design-b1`. Never edit, build or run git in `/Users/jacobdang/Projects/linkC`
  itself or in any other `.worktrees` folder. Never touch anything under `Sources/linkc/` — the app
  half is being built by another agent right now, in this same worktree's ancestry.
- **Test first:** write the test, add a stub so it compiles, run it and see it fail on an
  assertion (never a compile error), implement, run it and see it pass. Copy the red and green
  lines into your report.
- **Fail loud:** refuse bad input with a clear reason naming the step or the part. Never swallow an
  error or silently drop a column, a table, or an edit. Never use `try?`. If you ever add an
  `NSLog`, it must take format arguments (`NSLog("%@", x)`), never string interpolation baked into
  the format string.
- **Style:** 4-space indentation, one statement per line, `///` doc comments on every new public
  (and reused internal) declaration — match the surrounding file's voice; read a neighbouring
  doc comment before writing your own.
- **Determinism:** the same input always gives the same output. Sort anything whose order isn't
  already fixed by file order, using `.lowercased()` on ASCII input, exactly as the rest of
  `Board/` already does (see `componentsList`, `placesList` in `BoardEdit.swift`).
- **Build:** `swift build 2>&1 | tail -1`. `swift build --build-tests 2>&1 | grep -E "warning:"`
  must print nothing after every task.
- **Suite:** `swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1` must report 0 failures
  after every task. Main is at 1535 tests. Every existing test must stay green, **especially**
  `BoardMapTests.testEncodedMatchesTheGoldenBytesExactly` — the byte-exact golden board test. A
  board file with no `columns` and no `table` parts must encode byte for byte exactly as before
  every one of your changes.
  - Two existing tests in `Tests/LinkCKitTests/BoardEditTests.swift` assert the exact text of the
    `add`/`update` "unknown field" refusal, which lists every field those verbs take. Once you add
    `columns` to that list (Task 2), those two assertions' expected strings change — Task 2 tells
    you exactly which lines and what the new expected strings are. That is the *only* editing of an
    existing test file this plan calls for; every other existing test must need no edit at all.
- **Commits:**
  - one per task, with the message the task gives;
  - stage files by name, never `git add -A` or `git add .`;
  - **no trailers of any kind:** no Co-Authored-By, no "Generated with", no session links;
  - the word "claude" never appears in a message, in any case;
  - never push, merge or rebase.
- **Clean finish:** no scratch files, debug prints or commented-out code. `git status --short` is
  empty when you finish each task (besides that task's own staged changes).

---

## Task 1: `ComponentKind.table`, box size from the part, and the LinkCKit-wide migration

**Files:**
- Modify: `Sources/LinkCKit/Board/ComponentKind.swift` — adds `ComponentKind.table`.
- Modify: `Sources/LinkCKit/Board/BoardGeometry.swift` — adds `size(of:)`, `rect(of:)` (component
  overload), and a private `roundUpTo8`.
- Modify (migration; every site listed below, file:line as currently in this worktree):
  `Sources/LinkCKit/Board/BoardLabels.swift`, `Sources/LinkCKit/Board/BoardLayout.swift`,
  `Sources/LinkCKit/Board/BoardModel.swift`, `Sources/LinkCKit/Board/BoardModel+Space.swift`,
  `Sources/LinkCKit/Board/BoardRouter.swift`.
- Test: modify `Tests/LinkCKitTests/ComponentKindTests.swift`,
  `Tests/LinkCKitTests/BoardGeometryTests.swift`, `Tests/LinkCKitTests/BoardLayoutTests.swift`,
  `Tests/LinkCKitTests/BoardRouterTests.swift`, `Tests/LinkCKitTests/BoardPlacementTests.swift`,
  `Tests/LinkCKitTests/BoardEditTests.swift` (adds only — no existing test in these six files is
  changed by this task).

**Do NOT change:** `BoardGeometry.rect(ofComponentAt:)` and `BoardGeometry.componentSize` stay
`public`, unchanged, and still used by existing tests (`BoardGeometryTests`, `BoardLayoutTests`,
`BoardPlacementTests`, `BoardEditTests` all call them directly to verify results) — the app target
still uses both, and another agent is editing those app files right now.

### 1a. `ComponentKind.table`

In `Sources/LinkCKit/Board/ComponentKind.swift`, add a new section after the `System` group's
constants (after `external`, before the `// MARK: - AI agents` line):

```swift
    // MARK: - Data (not yet offered by the app; added to `groups` once it can draw one)

    /// A database's own table, drawn as an ER box. Deliberately left out of `groups` — and so out
    /// of `known` — until the app can draw one: the Component menu must never offer a kind it
    /// can't draw. An agent can still `add` a part of this kind; `isKnown` gates the app's menu
    /// only (`Sources/linkc/Board/BoardTools.swift`), nothing in LinkCKit's decode or edit path.
    public static let table = ComponentKind("table")
```

Do not add `.table` to the `groups` array or anywhere `known` would pick it up.

**Test** — add to `Tests/LinkCKitTests/ComponentKindTests.swift`:

```swift
    func testTableIsAKnownIDButNotYetInAnyGroup() {
        XCTAssertEqual(ComponentKind.table.raw, "table")
        XCTAssertFalse(ComponentKind.groups.flatMap(\.kinds).contains(.table), "the app can't draw it yet")
        XCTAssertFalse(ComponentKind.known.contains(.table))
        XCTAssertFalse(ComponentKind.table.isKnown)
    }
```

**Test** — add to `Tests/LinkCKitTests/BoardEditTests.swift` (anywhere; e.g. right after
`testAnEmptyMapStartsFromNothing`):

```swift
    /// `isKnown` gates only the app's Component menu (`Sources/linkc/Board/BoardTools.swift`) —
    /// nothing in `BoardEdit` or `BoardMap` reads it, so an agent can add a "table" part today,
    /// even though `.table` is not in `ComponentKind.groups` yet.
    func testAnAgentCanAddATableKindPartEvenThoughTheAppCannotDrawItYet() throws {
        let result = try apply([["add": "orders", "kind": "table"]], to: .empty)
        XCTAssertEqual(result.map.components.first?.kind, .table)
    }
```

### 1b. Box size from the part

In `Sources/LinkCKit/Board/BoardGeometry.swift`, add (near `rect(ofComponentAt:)`; keep that
function exactly as it is):

```swift
    /// A part's box size. Every kind but `.table` is `componentSize`. A table is wide enough for
    /// its longest "name — type" row and tall enough for a header plus one row per column — a
    /// table with no columns still counts as one row.
    public static func size(of component: BoardComponent) -> BoardPoint {
        guard component.kind == .table else { return componentSize }
        let longestName = component.columns.map(\.name.count).max() ?? 0
        let longestType = component.columns.map(\.type.count).max() ?? 0
        let width = max(componentSize.x, roundUpTo8(24 + 7 * (longestName + longestType) + 24))
        let height = roundUpTo8(36 + 22 * max(1, component.columns.count) + 8)
        return BoardPoint(x: width, y: height)
    }

    /// `component`'s box, from its own `at` and `size(of:)` — nil when it has no `at` yet (not
    /// placed on the board). The general replacement for `rect(ofComponentAt:)` everywhere the
    /// component itself, not just its position, is known.
    public static func rect(of component: BoardComponent) -> BoardRect? {
        guard let at = component.at else { return nil }
        let size = size(of: component)
        return BoardRect(x: at.x, y: at.y, w: size.x, h: size.y)
    }

    /// Rounds up to the next multiple of 8 — `BoardPoint.grid`'s own step, but a ceiling, not
    /// `BoardPoint.snap`'s round-to-nearest. Kept local rather than reusing
    /// `BoardModel.roundedUpToGrid` (the same formula) — `BoardGeometry` is the board's pure maths
    /// and must not depend on `BoardModel`, a stateful `@MainActor` class one layer up.
    private static func roundUpTo8(_ value: Int) -> Int {
        ((value + BoardPoint.grid - 1) / BoardPoint.grid) * BoardPoint.grid
    }
```

**Worked numbers** (verify these against the formula before writing the test — they're what the
test below asserts):
- No columns: width = max(176, roundUpTo8(24 + 7×0 + 24)) = max(176, roundUpTo8(48)) = max(176, 48)
  = **176**. height = roundUpTo8(36 + 22×1 + 8) = roundUpTo8(66) = **72**.
- A table with columns `id`(uuid, pk), `handle`(character varying(40)),
  `status`(text), `avatar_url`(text, planned) — longest name `avatar_url` = 10, longest type
  `character varying(40)` = 22: width = max(176, roundUpTo8(24 + 7×32 + 24)) =
  max(176, roundUpTo8(272)) = max(176, 272) = **272** (272 is already a multiple of 8). height =
  roundUpTo8(36 + 22×4 + 8) = roundUpTo8(132) = **136**.
- Ten columns named `c1`…`c10`, each typed `int` — longest name 3 (`c10`), longest type 3: width =
  max(176, roundUpTo8(24 + 7×6 + 24)) = max(176, roundUpTo8(90)) = max(176, 96) = **176** (the
  176 floor wins). height = roundUpTo8(36 + 22×10 + 8) = roundUpTo8(264) = **264** (already a
  multiple of 8) — a **176×264** table: much taller than a normal 176×84 box, and this is your
  "tall table" fixture for every test below.

**Test** — add to `Tests/LinkCKitTests/BoardGeometryTests.swift`:

```swift
    func testATablesSizeComesFromItsColumns() {
        XCTAssertEqual(BoardGeometry.size(of: BoardComponent(name: "t", kind: .table)), BoardPoint(x: 176, y: 72))

        let profiles = BoardComponent(name: "profiles", kind: .table, columns: [
            BoardColumn(name: "id", type: "uuid", pk: true, references: BoardColumnReference(table: "auth.users", column: "id")),
            BoardColumn(name: "handle", type: "character varying(40)", nullable: false, unique: true),
            BoardColumn(name: "status", type: "text"),
            BoardColumn(name: "avatar_url", type: "text", planned: true),
        ])
        XCTAssertEqual(BoardGeometry.size(of: profiles), BoardPoint(x: 272, y: 136))

        let tall = BoardComponent(name: "wide", kind: .table, columns: (1...10).map { BoardColumn(name: "c\($0)", type: "int") })
        XCTAssertEqual(BoardGeometry.size(of: tall), BoardPoint(x: 176, y: 264), "the floor wins on width; height grows with rows")

        XCTAssertEqual(BoardGeometry.size(of: BoardComponent(name: "api", kind: .service)), BoardGeometry.componentSize)
    }

    func testATablesRectComesFromItsOwnPositionAndSize() {
        var t = BoardComponent(name: "t", kind: .table, at: BoardPoint(x: 40, y: 40))
        XCTAssertEqual(BoardGeometry.rect(of: t), BoardRect(x: 40, y: 40, w: 176, h: 72))
        t.at = nil
        XCTAssertNil(BoardGeometry.rect(of: t), "not placed yet")
    }
```

### 1c. The migration — every LinkCKit use of `rect(ofComponentAt:)` or `componentSize` where the
component is known

Grep used to find every site (run it yourself to confirm nothing has moved since this plan was
written): `grep -rn "rect(ofComponentAt:\|BoardGeometry\.componentSize" Sources/LinkCKit/Board/*.swift`.
It must return **only** the 30 lines below (across the 5 files); if it returns others, migrate
those too, the same way, and note it in your report.

For every site, the rule is the same: wherever a `BoardComponent` (not just its `.at`) is already
in scope, replace the fixed-size call with the part's own size or rect. Where only `.at` was in
scope, the component is right there too — bind to it instead.

#### `Sources/LinkCKit/Board/BoardLabels.swift`

Line 96, inside `obstacles(for map:)`:
```swift
// before
for component in map.components {
    if let at = component.at { result.append(BoardGeometry.rect(ofComponentAt: at)) }
}
// after
for component in map.components {
    if let rect = BoardGeometry.rect(of: component) { result.append(rect) }
}
```

#### `Sources/LinkCKit/Board/BoardModel.swift`

Line 330, inside `addComponent(kind:at:)` — build a probe first, the same pattern `addText`
already uses just below it (lines 362–366) with a probe `BoardText`:
```swift
// before
let rect = BoardGeometry.elementDrop(
    BoardGeometry.rect(ofComponentAt: point).snapped,
    otherElements: Self.elementRects(map, excluding: []), frames: Self.frameRects(map, excluding: []))
// after
let probe = BoardComponent(name: name, kind: kind, at: point)
let rect = BoardGeometry.elementDrop(
    BoardGeometry.rect(of: probe)!.snapped,
    otherElements: Self.elementRects(map, excluding: []), frames: Self.frameRects(map, excluding: []))
```
(The force-unwrap is safe: `probe.at` is `point`, never nil, so `rect(of:)` never returns nil here.)

Line 394, inside `addFrame(_:)`:
```swift
// before
for index in map.components.indices {
    if let at = map.components[index].at, interior.contains(BoardGeometry.rect(ofComponentAt: at)) {
        map.components[index].place = label
    }
}
// after
for index in map.components.indices {
    if let rect = BoardGeometry.rect(of: map.components[index]), interior.contains(rect) {
        map.components[index].place = label
    }
}
```

Line 749, inside `elementRects(_:excluding:)`:
```swift
// before
for component in map.components where !excluded.contains(.component(component.name)) {
    if let at = component.at { rects.append(BoardGeometry.rect(ofComponentAt: at)) }
}
// after
for component in map.components where !excluded.contains(.component(component.name)) {
    if let rect = BoardGeometry.rect(of: component) { rects.append(rect) }
}
```

Line 772, inside `marqueePick(in:map:visibleParts:)`:
```swift
// before
guard let at = component.at, BoardGeometry.rect(ofComponentAt: at).intersects(area) else { continue }
// after
guard let rect = BoardGeometry.rect(of: component), rect.intersects(area) else { continue }
```

Lines 819 and 826, inside `placeComponent(_:inFrame:into:)`:
```swift
// before (819)
let size = BoardGeometry.componentSize
// after
let size = BoardGeometry.size(of: component)
```
```swift
// before (826)
let members = map.components.filter { memberComponents.contains($0.name) }.compactMap { $0.at.map(BoardGeometry.rect(ofComponentAt:)) }
    + map.notes.filter { memberNotes.contains($0.id) }.compactMap { $0.at.map(BoardGeometry.rect(ofNoteAt:)) }
    + map.texts.filter { memberTexts.contains($0.id) }.map(BoardGeometry.rect(of:))
// after
let members = map.components.filter { memberComponents.contains($0.name) }.compactMap(BoardGeometry.rect(of:))
    + map.notes.filter { memberNotes.contains($0.id) }.compactMap { $0.at.map(BoardGeometry.rect(ofNoteAt:)) }
    + map.texts.filter { memberTexts.contains($0.id) }.map(BoardGeometry.rect(of:))
```

Line 865, inside `placeLoose(_:into:)`:
```swift
// before
let size = BoardGeometry.componentSize
// after
let size = BoardGeometry.size(of: component)
```

Line 940, inside `place(_ suggestions:into:)` — **leave this one alone.** It sizes the "Local
docker" frame's first guess from a *count* of `MapSuggestion` values, which are never tables
(process discovery never suggests a table) and have no `columns` to size from — there is no real
`BoardComponent` to ask yet. Note this in your report as an intentional non-change.

#### `Sources/LinkCKit/Board/BoardModel+Space.swift`

Line 7, inside `BoardModel.rect(of element:)`:
```swift
// before
case .component(let name):
    return Self.index(of: name, in: map).flatMap { map.components[$0].at }.map(BoardGeometry.rect(ofComponentAt:))
// after
case .component(let name):
    return Self.index(of: name, in: map).flatMap { BoardGeometry.rect(of: map.components[$0]) }
```

Line 95, inside `move(_:by:)`'s loose-component case:
```swift
// before
case .component(let name):
    guard let index = Self.index(of: name, in: map), let at = map.components[index].at else { continue }
    let landed = BoardGeometry.elementDrop(
        BoardGeometry.rect(ofComponentAt: at).offsetBy(dx: delta.x, dy: delta.y).snapped,
        otherElements: others, frames: frameRects)
    map.components[index].at = landed.origin
    map.components[index].place = BoardGeometry.frame(containing: landed, frames: map.frames)?.label ?? BoardMap.notPlaced
    changed = changed || landed.origin != at
    settledElements.append(landed)
// after
case .component(let name):
    guard let index = Self.index(of: name, in: map), let box = BoardGeometry.rect(of: map.components[index]) else { continue }
    let at = box.origin
    let landed = BoardGeometry.elementDrop(
        box.offsetBy(dx: delta.x, dy: delta.y).snapped,
        otherElements: others, frames: frameRects)
    map.components[index].at = landed.origin
    map.components[index].place = BoardGeometry.frame(containing: landed, frames: map.frames)?.label ?? BoardMap.notPlaced
    changed = changed || landed.origin != at
    settledElements.append(landed)
```

Line 142, inside `resizeFrame(_:to:)`:
```swift
// before
let memberRects = members.compactMap { $0.at.map(BoardGeometry.rect(ofComponentAt:)) }
    + map.notes.compactMap { $0.at.map(BoardGeometry.rect(ofNoteAt:)) }.filter { interior.contains($0) }
    + map.texts.map(BoardGeometry.rect(of:)).filter { interior.contains($0) }
// after
let memberRects = members.compactMap(BoardGeometry.rect(of:))
    + map.notes.compactMap { $0.at.map(BoardGeometry.rect(ofNoteAt:)) }.filter { interior.contains($0) }
    + map.texts.map(BoardGeometry.rect(of:)).filter { interior.contains($0) }
```

Line 161 (`let size = BoardGeometry.componentSize` at the top of `laidOut(_:)`) and its uses at
lines 169–190 (the brand-new frame's row/column guess, and the `minFrameSize` floor for frames made
before `componentSize` grew) — **leave these alone.** No single component is known yet at that
point (it's a *count* of members, same reasoning as `BoardModel.swift:940` above); `grow()` (called
later, per-component) corrects any frame that guessed too small. Keep the `size` binding — it is
still used, unchanged, by the parts of `laidOut` this plan doesn't touch.

Lines 239, 243, 245, 248–251, 263–264, inside `laidOut(_:)`'s per-component placement loop — the
whole loop body changes to size each component from itself, not from the outer `size`:
```swift
// before
for index in map.components.indices.sorted(by: { map.components[$0].name < map.components[$1].name }) {
    let component = map.components[index]
    let frame = map.frames.first { $0.label == component.place }?.rect
    if frame == nil, component.place != BoardMap.notPlaced {
        map.components[index].place = BoardMap.notPlaced
    }
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
// after
for index in map.components.indices.sorted(by: { map.components[$0].name < map.components[$1].name }) {
    let component = map.components[index]
    let componentSize = BoardGeometry.size(of: component)
    let frame = map.frames.first { $0.label == component.place }?.rect
    if frame == nil, component.place != BoardMap.notPlaced {
        map.components[index].place = BoardMap.notPlaced
    }
    let others = elementRects(map, excluding: [.component(component.name)])
    let current = BoardGeometry.rect(of: component)
    if let frame {
        let interior = BoardGeometry.interior(of: frame)
        if let current, interior.contains(current), !others.contains(where: { $0.intersects(current) }) { continue }
        let seed = BoardRect(x: interior.x, y: interior.y, w: componentSize.x, h: componentSize.y)
        let members = map.components.filter { $0.place == component.place && $0.name != component.name }
        var spot = BoardGeometry.nearestFreeSpot(for: current.map { interior.contains($0) ? $0 : seed } ?? seed,
                                                 avoiding: others, inside: interior)
        if spot == nil, let frameIndex = map.frames.firstIndex(where: { $0.label == component.place }),
           let grown = BoardGeometry.grow(frame, toFit: componentSize,
                                          members: members.compactMap(BoardGeometry.rect(of:)),
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
    let seed = current ?? BoardRect(x: 0, y: (frames.map(\.maxY).max() ?? 0) + 48, w: componentSize.x, h: componentSize.y)
    map.components[index].at = (BoardGeometry.nearestFreeSpot(for: seed, avoiding: others, outside: frames) ?? seed).origin
}
```

Lines 290 and 293, inside `laidOut(_:)`'s overlap-with-an-earlier-component pass (right after the
loop above):
```swift
// before
for index in map.components.indices.sorted(by: { map.components[$0].name < map.components[$1].name }) {
    guard let at = map.components[index].at else { continue }
    let name = map.components[index].name
    let current = BoardGeometry.rect(ofComponentAt: at)
    let earlier = map.components.indices
        .filter { map.components[$0].name < name }
        .compactMap { map.components[$0].at.map(BoardGeometry.rect(ofComponentAt:)) }
    guard earlier.contains(where: { $0.intersects(current) }) else { continue }
    let landed = BoardGeometry.elementDrop(
        current, otherElements: elementRects(map, excluding: [.component(name)]), frames: frameRects(map, excluding: []))
    map.components[index].at = landed.origin
    map.components[index].place = BoardGeometry.frame(containing: landed, frames: map.frames)?.label ?? BoardMap.notPlaced
}
// after
for index in map.components.indices.sorted(by: { map.components[$0].name < map.components[$1].name }) {
    guard let current = BoardGeometry.rect(of: map.components[index]) else { continue }
    let name = map.components[index].name
    let earlier = map.components.indices
        .filter { map.components[$0].name < name }
        .compactMap { BoardGeometry.rect(of: map.components[$0]) }
    guard earlier.contains(where: { $0.intersects(current) }) else { continue }
    let landed = BoardGeometry.elementDrop(
        current, otherElements: elementRects(map, excluding: [.component(name)]), frames: frameRects(map, excluding: []))
    map.components[index].at = landed.origin
    map.components[index].place = BoardGeometry.frame(containing: landed, frames: map.frames)?.label ?? BoardMap.notPlaced
}
```

#### `Sources/LinkCKit/Board/BoardRouter.swift`

Line 73, inside `routes(for:isCancelled:)`'s `componentBox` dictionary:
```swift
// before
let componentBox = Dictionary(uniqueKeysWithValues: map.components.compactMap { c -> (String, BoardRect)? in
    guard let at = c.at else { return nil }
    return (c.name.lowercased(), BoardGeometry.rect(ofComponentAt: at))
})
// after
let componentBox = Dictionary(uniqueKeysWithValues: map.components.compactMap { c -> (String, BoardRect)? in
    guard let rect = BoardGeometry.rect(of: c) else { return nil }
    return (c.name.lowercased(), rect)
})
```

Lines 89–93 (the `guard` right above, and the two lines it feeds):
```swift
// before
guard let source = byLowercasedName[key.from.lowercased()], let target = byLowercasedName[key.to.lowercased()],
      let sourceAt = source.at, let targetAt = target.at
else { continue }
let sourceBox = BoardGeometry.rect(ofComponentAt: sourceAt)
let targetBox = BoardGeometry.rect(ofComponentAt: targetAt)
// after
guard let source = byLowercasedName[key.from.lowercased()], let target = byLowercasedName[key.to.lowercased()],
      let sourceBox = BoardGeometry.rect(of: source), let targetBox = BoardGeometry.rect(of: target)
else { continue }
```

Lines 224–226, inside `bundles(arrowKeys:labelOf:byLowercasedName:)`'s out-anchors loop:
```swift
// before
guard let source = byLowercasedName[keys[0].from.lowercased()], let at = source.at else { continue }
let box = BoardGeometry.rect(ofComponentAt: at)
let others = keys.compactMap { byLowercasedName[$0.to.lowercased()]?.at }.map(BoardGeometry.rect(ofComponentAt:))
// after
guard let source = byLowercasedName[keys[0].from.lowercased()], let box = BoardGeometry.rect(of: source) else { continue }
let others = keys.compactMap { byLowercasedName[$0.to.lowercased()] }.compactMap(BoardGeometry.rect(of:))
```

Lines 234–236, the matching in-anchors loop right below it:
```swift
// before
guard let target = byLowercasedName[keys[0].to.lowercased()], let at = target.at else { continue }
let box = BoardGeometry.rect(ofComponentAt: at)
let others = keys.compactMap { byLowercasedName[$0.from.lowercased()]?.at }.map(BoardGeometry.rect(ofComponentAt:))
// after
guard let target = byLowercasedName[keys[0].to.lowercased()], let box = BoardGeometry.rect(of: target) else { continue }
let others = keys.compactMap { byLowercasedName[$0.from.lowercased()] }.compactMap(BoardGeometry.rect(of:))
```

#### `Sources/LinkCKit/Board/BoardLayout.swift`

This file gets the biggest change: `clusterLayout` and the placement loop in `arranged(_:)` move
from "col/row index × fixed componentSize" arithmetic to "each column's own real width, each row's
own real height" — still built from `columnsAndRows`'s existing col/row *assignment* (unchanged:
that part is about arrow flow, not size), just no longer assuming every box is the same size. The
formula is written so that when every component in a cluster really is `componentSize` (true for
every board with no tables), every number it produces is byte-identical to today's — this is what
keeps the golden board test, and every other existing `BoardLayoutTests` assertion, green.

Replace the `ClusterLayout` struct (around line 26):
```swift
// before
private struct ClusterLayout {
    var width: Int
    var height: Int
    var positions: [String: (col: Int, row: Int)]
}
// after
/// A cluster's computed size, and where each of its components sits, as an offset from the
/// cluster's own top-left corner — already includes each component's own `BoardGeometry.size(of:)`,
/// so a tall or wide table never overlaps a sibling in the same cluster.
private struct ClusterLayout {
    var width: Int
    var height: Int
    var origins: [String: BoardPoint]
}
```

Replace `placedGhosts(_:)` in full (it currently spans roughly lines 32–76):
```swift
    public static func placedGhosts(_ map: BoardMap) -> BoardMap {
        var result = map
        let innerRects = result.components
            .filter { $0.outside == nil }
            .compactMap(BoardGeometry.rect(of:))
            + result.frames.compactMap(\.rect)

        let inner: BoardRect
        if let first = innerRects.first {
            let minX = innerRects.map(\.minX).min() ?? first.minX
            let minY = innerRects.map(\.minY).min() ?? first.minY
            let maxX = innerRects.map(\.maxX).max() ?? first.maxX
            let maxY = innerRects.map(\.maxY).max() ?? first.maxY
            inner = BoardRect(x: minX, y: minY, w: maxX - minX, h: maxY - minY)
        } else {
            inner = BoardRect(x: 0, y: 0, w: 0, h: 0)
        }

        // 124 was every ghost's fixed row step when every box was `componentSize` (84) tall; 40 is
        // that same gap, now added to each ghost's own height, so a tall table ghost never
        // overlaps the next row. 84 + 40 = 124, so nothing here changes when every ghost is a
        // plain, `componentSize`-sized part.
        let ghostRowGap = 40

        let inGhosts = result.components
            .enumerated()
            .filter { $0.element.outside == .in }
            .sorted { $0.element.name.lowercased() < $1.element.name.lowercased() }
        let inWidth = inGhosts.map { BoardGeometry.size(of: $0.element).x }.max() ?? BoardGeometry.componentSize.x
        let inX = inner.minX - inWidth - 96
        var inY = inner.minY
        for item in inGhosts {
            result.components[item.offset].place = BoardMap.notPlaced
            result.components[item.offset].at = BoardPoint(x: inX, y: inY)
            inY += BoardGeometry.size(of: item.element).y + ghostRowGap
        }

        let outGhosts = result.components
            .enumerated()
            .filter { $0.element.outside == .out }
            .sorted { $0.element.name.lowercased() < $1.element.name.lowercased() }
        let outX = inner.maxX + 96
        var outY = inner.minY
        for item in outGhosts {
            result.components[item.offset].place = BoardMap.notPlaced
            result.components[item.offset].at = BoardPoint(x: outX, y: outY)
            outY += BoardGeometry.size(of: item.element).y + ghostRowGap
        }

        return result
    }
```

In `arranged(_:)`, the "Texts" section (around line 155):
```swift
// before
let boxes = result.components.compactMap { $0.at.map(BoardGeometry.rect(ofComponentAt:)) }
    + result.notes.compactMap { $0.at.map(BoardGeometry.rect(ofNoteAt:)) }
// after
let boxes = result.components.compactMap(BoardGeometry.rect(of:))
    + result.notes.compactMap { $0.at.map(BoardGeometry.rect(ofNoteAt:)) }
```

In `arranged(_:)`, the per-component placement loop inside the cluster loop (around lines 128–141):
```swift
// before
for component in cluster.components {
    guard let position = layout.positions[component.name],
          let index = result.components.firstIndex(where: { $0.name == component.name }) else { continue }
    let at = BoardPoint(
        x: rect.x + framePadding + position.col * (BoardGeometry.componentSize.x + columnGapInFrame),
        y: rect.y + frameTitleBand + position.row * rowStep)
    result.components[index].at = at.snapped
}
// after
for component in cluster.components {
    guard let origin = layout.origins[component.name],
          let index = result.components.firstIndex(where: { $0.name == component.name }) else { continue }
    result.components[index].at = BoardPoint(x: rect.x + origin.x, y: rect.y + origin.y).snapped
}
```

Replace `clusterLayout(for:)` in full:
```swift
    /// Sizes a cluster and places its components, using each component's own `BoardGeometry.size(of:)`
    /// — not a fixed `componentSize` — so a tall or wide table gets the room it needs and nothing
    /// after it overlaps. `columnsAndRows` still decides *which* column and row each component
    /// goes in, purely from the cluster's own arrows; only the pixel arithmetic changes here.
    /// Reduces to today's exact numbers whenever every component in the cluster is `componentSize`
    /// — true for any board with no tables — so a map with no tables lays out byte-for-byte as
    /// before.
    private static func clusterLayout(for cluster: Cluster) -> ClusterLayout {
        let (positions, cols, _) = columnsAndRows(for: cluster.components)
        let byName = Dictionary(uniqueKeysWithValues: cluster.components.map { ($0.name, $0) })
        func size(_ name: String) -> BoardPoint { byName[name].map(BoardGeometry.size(of:)) ?? BoardGeometry.componentSize }

        var byColumn: [[String]] = Array(repeating: [], count: max(cols, 1))
        for (name, position) in positions { byColumn[position.col].append(name) }
        for index in byColumn.indices {
            byColumn[index].sort { (positions[$0]?.row ?? 0) < (positions[$1]?.row ?? 0) }
        }

        let rowGap = rowStep - BoardGeometry.componentSize.y
        var origins: [String: BoardPoint] = [:]
        var columnWidths: [Int] = []
        var columnHeights: [Int] = []
        var x = framePadding
        for names in byColumn {
            let width = names.map { size($0).x }.max() ?? BoardGeometry.componentSize.x
            var y = frameTitleBand
            for name in names {
                origins[name] = BoardPoint(x: x, y: y)
                y += size(name).y + rowGap
            }
            columnHeights.append(names.isEmpty ? BoardGeometry.componentSize.y : y - rowGap - frameTitleBand)
            columnWidths.append(width)
            x += width + columnGapInFrame
        }

        let width = 2 * framePadding + columnWidths.reduce(0, +) + max(0, columnWidths.count - 1) * columnGapInFrame
        let height = frameTitleBand + (columnHeights.max() ?? BoardGeometry.componentSize.y) + framePadding
        return ClusterLayout(width: width, height: height, origins: origins)
    }
```

**Test** — add to `Tests/LinkCKitTests/BoardLayoutTests.swift`:

```swift
    /// Two unrelated parts (no arrow between them) land in the same virtual cluster, ordered by
    /// name — "accounts" before "neighbour" — so "accounts" (the tall table) sits directly above
    /// "neighbour" in the same column. Real per-row heights must keep them clear of each other.
    func testBoardLayoutPlacesATallTableWithoutOverlappingItsNeighbour() throws {
        var m = BoardMap()
        m.components = [
            BoardComponent(name: "accounts", kind: .table, columns: (1...10).map { BoardColumn(name: "c\($0)", type: "int") }),
            BoardComponent(name: "neighbour", kind: .service),
        ]
        let arranged = BoardLayout.arranged(m)
        let big = try XCTUnwrap(BoardGeometry.rect(of: try XCTUnwrap(arranged.components.first { $0.name == "accounts" })))
        let small = try XCTUnwrap(BoardGeometry.rect(of: try XCTUnwrap(arranged.components.first { $0.name == "neighbour" })))
        XCTAssertFalse(big.intersects(small), "\(big) overlaps \(small)")
        XCTAssertEqual(big.h, 264, "the table really used its own height")
    }
```

**Test** — add to `Tests/LinkCKitTests/BoardRouterTests.swift` (this file already has a private
`crosses(_:_:_:)` helper at the top — reuse it):

```swift
    /// Under the old fixed-84-tall model, a straight line at y=200 between "sender" and "receiver"
    /// would have found no obstacle (the fake box only reached y=84) and cut straight through the
    /// real table, which is 264 tall. The router must see the table's real rect and bend around it.
    func testRouterRoutesAroundATallTablesRealRect() throws {
        var m = BoardMap()
        m.components = [
            BoardComponent(name: "orders", kind: .table, at: BoardPoint(x: 200, y: 0),
                           columns: (1...10).map { BoardColumn(name: "c\($0)", type: "int") }),
            BoardComponent(name: "sender", kind: .service, uses: ["receiver": ""], at: BoardPoint(x: 0, y: 158)),
            BoardComponent(name: "receiver", kind: .service, at: BoardPoint(x: 500, y: 158)),
        ]
        let tableRect = try XCTUnwrap(BoardGeometry.rect(of: m.components[0]))
        XCTAssertEqual(tableRect, BoardRect(x: 200, y: 0, w: 176, h: 264), "the table really is 264 tall, not 84")
        let route = try XCTUnwrap(BoardRouter.routes(for: m)[BoardModel.ArrowKey(from: "sender", to: "receiver")])
        for (a, b) in zip(route.points, route.points.dropFirst()) {
            XCTAssertFalse(crosses(a, b, tableRect), "\(a)->\(b) crosses the table's real rect")
        }
    }
```

**Test** — add to `Tests/LinkCKitTests/BoardPlacementTests.swift`:

```swift
    func testPlacementFindsAFreeSpotForATallTable() throws {
        var map = BoardMap()
        map.frames = [BoardFrame(label: "Schema", rect: BoardRect(x: 0, y: 0, w: 400, h: 120))]
        map.components = [BoardComponent(name: "existing", kind: .service, place: "Schema", at: BoardPoint(x: 8, y: 8))]
        let table = BoardComponent(name: "accounts", kind: .table, columns: (1...10).map { BoardColumn(name: "c\($0)", type: "int") })
        XCTAssertTrue(BoardModel.placeComponent(table, inFrame: "Schema", into: &map))
        let placed = try XCTUnwrap(map.components.last)
        let placedRect = try XCTUnwrap(BoardGeometry.rect(of: placed))
        XCTAssertEqual(placedRect.w, 176)
        XCTAssertEqual(placedRect.h, 264, "the table's own height, not the fixed 84")
        let existingRect = try XCTUnwrap(BoardGeometry.rect(of: map.components[0]))
        XCTAssertFalse(placedRect.intersects(existingRect))
        let frame = try XCTUnwrap(map.frames.first?.rect)
        XCTAssertTrue(BoardGeometry.interior(of: frame).contains(placedRect), "the frame grew to fit the table's real height")
    }
```

### Steps

- [ ] **Step 1: Write the failing tests.** Add every test above to its file. Add the `ComponentKind.table`
  declaration and the `BoardGeometry.size(of:)`/`rect(of:)` stub (return `componentSize`/`nil` —
  whatever compiles without doing the real sizing yet) so the suite compiles. Run
  `swift test --filter "ComponentKindTests|BoardGeometryTests|BoardLayoutTests|BoardRouterTests|BoardPlacementTests|BoardEditTests"`
  and confirm the new tests fail on **assertions**, not compile errors.
- [ ] **Step 2: Implement** `size(of:)`/`rect(of:)`/`roundUpTo8` for real, then every migration site
  in 1c, file by file.
- [ ] **Step 3: Run** the same filtered test command and see everything pass. Then run the full
  suite (`swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1`) and the warnings check
  (`swift build --build-tests 2>&1 | grep -E "warning:"`, must be empty). Confirm
  `BoardMapTests.testEncodedMatchesTheGoldenBytesExactly` is still green.
- [ ] **Step 4: Commit.** Stage by name every file this task touched. Message:
  `feat(board): a table's box is sized from its columns`

---

## Task 2: Edit steps — `columns` on add/update, and the new `column` step

**Files:**
- Modify: `Sources/LinkCKit/Board/BoardMap.swift` — extracts the per-entry validation out of the
  private `columns(_:context:)` into a new `static func parsedColumns(_:context:)` (default
  access — reachable from `BoardEdit.swift` in the same module), leaving `columns(_:context:)`'s
  own behaviour and every one of its existing callers and tests untouched.
- Modify: `Sources/LinkCKit/Board/BoardEdit.swift` — adds `BoardColumnFields`, a `.column` case on
  `BoardEditStep`, `columns` on `BoardComponentFields`, decode/apply logic for both, and refactors
  `decodeStep`'s two smallest field readers into shared statics.
- Modify: `Sources/LinkCKit/MCP/MCPServer.swift` — documents `columns` and the `column` step in
  `stepsSchemaDescription`, and lists `column` in the tool's own `description`.
- Test: modify `Tests/LinkCKitTests/BoardEditTests.swift` (adds, plus the two exact-string edits
  below), add to `Tests/LinkCKitTests/MCPServerBoardTests.swift`.

**Consumes:** `ComponentKind.table` (Task 1), `BoardColumn`/`BoardColumnReference` (phase A).

### 2a. Reuse the board-file column decoder — `BoardMap.parsedColumns(_:context:)`

In `Sources/LinkCKit/Board/BoardMap.swift`, split `private static func columns(_ raw: [String: Any],
context: String) throws -> [BoardColumn]` into two functions. `columns(_:context:)` keeps its exact
signature, access level and behaviour — only its body changes, to the two lines below. Everything
from `let knownKeys: Set<String> = [...]` to the closing `return result` (the per-entry validation
loop) moves, unchanged, into a new function with the same body but taking the already-unwrapped
`entries` list:

```swift
    private static func columns(_ raw: [String: Any], context: String) throws -> [BoardColumn] {
        guard let value = raw["columns"] else { return [] }
        guard let entries = value as? [[String: Any]] else {
            throw LinkCError.parse("\(context) has \"columns\" but it is not a list of objects")
        }
        return try parsedColumns(entries, context: context)
    }

    /// The per-entry validation the board file's own `"columns"` follows (name, type, no
    /// duplicates, a primary key is never nullable, an unknown key, a malformed `references`) —
    /// shared with `linkc_edit_board`'s `"columns"` step field (`BoardEdit`), so a column is
    /// refused with the same reason wherever it's written. Not `private`: `BoardEdit` calls it
    /// directly, in the same module.
    static func parsedColumns(_ entries: [[String: Any]], context: String) throws -> [BoardColumn] {
        let knownKeys: Set<String> = ["name", "type", "pk", "nullable", "unique", "default", "references", "status"]
        var result: [BoardColumn] = []
        var seen: Set<String> = []
        for entry in entries {
            guard let name = try string(entry, "name", context: context),
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LinkCError.parse("\(context) has a column with no \"name\"")
            }
            let columnContext = "\(context)'s column \"\(name)\""
            if let unknown = entry.keys.sorted().first(where: { !knownKeys.contains($0) }) {
                throw LinkCError.parse("\(context) column \"\(name)\" has an unknown key \"\(unknown)\"")
            }
            guard let type = try string(entry, "type", context: columnContext),
                  !type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LinkCError.parse("\(context) column \"\(name)\" has no \"type\"")
            }
            guard seen.insert(name.lowercased()).inserted else {
                throw LinkCError.parse("\(context) names column \"\(name)\" twice")
            }
            let pk = try bool(entry, "pk", context: columnContext) ?? false
            let nullable = try bool(entry, "nullable", context: columnContext) ?? true
            if pk && entry["nullable"] != nil && nullable {
                throw LinkCError.parse("\(context) column \"\(name)\" is a primary key, so it can't be nullable")
            }
            var reference: BoardColumnReference?
            if let referenceText = try string(entry, "references", context: columnContext) {
                guard let parsed = BoardColumnReference(parsing: referenceText) else {
                    throw LinkCError.parse("\(context) column \"\(name)\" has \"references\" \"\(referenceText)\" but it is not table.column")
                }
                reference = parsed
            }
            result.append(BoardColumn(
                name: name,
                type: type,
                pk: pk,
                nullable: nullable,
                unique: try bool(entry, "unique", context: columnContext) ?? false,
                defaultValue: try string(entry, "default", context: columnContext),
                references: reference,
                planned: try plannedStatus(entry, context: columnContext)))
        }
        return result
    }
```

No existing `BoardColumnTests` or `BoardMapTests` behaviour changes — this is a pure extraction.

### 2b. `columns` on `add` and `update`

In `Sources/LinkCKit/Board/BoardEdit.swift`:

`BoardComponentFields` gains one new field, appended last (every existing call site keeps
compiling — see `BoardModel.swift`'s `updateComponent` overloads, which build one without
`columns:` and must not need editing):

```swift
public struct BoardComponentFields: Equatable, Sendable {
    public var kind: ComponentKind?
    public var does: String?
    public var reachedBy: String?
    public var runs: String?
    public var tech: String?
    public var planned: Bool?
    public var columns: [BoardColumn]?   // nil: leave alone (update) / none (add); given: the whole list

    public init(
        kind: ComponentKind? = nil, does: String? = nil, reachedBy: String? = nil, runs: String? = nil,
        tech: String? = nil, planned: Bool? = nil, columns: [BoardColumn]? = nil
    ) {
        self.kind = kind
        self.does = does
        self.reachedBy = reachedBy
        self.runs = runs
        self.tech = tech
        self.planned = planned
        self.columns = columns
    }
}
```

`allowedFields` gains `"columns"` on `add` and `update`, appended last:
```swift
    private static let allowedFields: [String: [String]] = [
        "add": ["kind", "tech", "in", "does", "reached_by", "runs", "planned", "columns"],
        "update": ["kind", "tech", "in", "does", "reached_by", "runs", "planned", "rename", "columns"],
        "remove": [],
        "connect": ["to", "label", "style", "bits"],
        "disconnect": ["to"],
        "place": ["rename"],
        "remove_place": [],
        "note": [],
        "remove_note": [],
        "system": [],
        "detail": [],
    ]
```

**This changes two existing tests' expected strings** — the "takes:" list they assert now ends
with `, columns`. In `Tests/LinkCKitTests/BoardEditTests.swift`:
- `testUnknownFieldRefusalCatchesAFieldAnotherVerbTakes`: change
  `#"step 1: unknown field "to" — add takes: kind, tech, in, does, reached_by, runs, planned"#`
  to
  `#"step 1: unknown field "to" — add takes: kind, tech, in, does, reached_by, runs, planned, columns"#`.
- `testUnknownFieldRefusalListsTheVerbsAllowedFields`: change
  `#"step 1: unknown field "name" — add takes: kind, tech, in, does, reached_by, runs, planned"#`
  to
  `#"step 1: unknown field "name" — add takes: kind, tech, in, does, reached_by, runs, planned, columns"#`,
  and change
  `#"step 1: unknown field "name" — update takes: kind, tech, in, does, reached_by, runs, planned, rename"#`
  to
  `#"step 1: unknown field "name" — update takes: kind, tech, in, does, reached_by, runs, planned, rename, columns"#`.
  (The `connect`/`place`/`remove` assertions in both tests are unaffected — leave them.)

`decodeStep` gains a `columns` decode, right after the existing field reads (after `let bits = try
intField("bits")`, before the `switch verb {`):
```swift
        var columns: [BoardColumn]?
        if let rawColumns = object["columns"] {
            guard let entries = rawColumns as? [[String: Any]] else {
                throw BoardEditRefusal(step: step, reason: "\"columns\" must be a list of objects")
            }
            do {
                columns = try BoardMap.parsedColumns(entries, context: "\"\(verbValue)\"")
            } catch let error as LinkCError {
                throw BoardEditRefusal(step: step, reason: error.errorDescription ?? "\(error)")
            }
        }
```
(This only ever runs for `add`/`update` — every other verb's `allowedFields` list has no
`"columns"`, so the earlier unknown-field loop already refuses it there.)

The `add` and `update` switch cases pass `columns` through:
```swift
        case "add":
            let fields = BoardComponentFields(kind: kind.map(ComponentKind.init), does: does, reachedBy: reachedBy, runs: runs, tech: tech, planned: planned, columns: columns)
            return .add(verbValue, fields, place: inPlace)
        case "update":
            let fields = BoardComponentFields(kind: kind.map(ComponentKind.init), does: does, reachedBy: reachedBy, runs: runs, tech: tech, planned: planned, columns: columns)
            return .update(verbValue, fields, place: inPlace, rename: rename)
```

`applyAdd` gains the kind check and passes columns through, right after the existing-name guard:
```swift
    private static func applyAdd(_ rawName: String, _ fields: BoardComponentFields, place: String?, number: Int, map: inout BoardMap) throws -> String {
        let name = trimmed(rawName)
        guard !name.isEmpty else { throw BoardEditRefusal(step: number, reason: "A component needs a name.") }
        guard BoardModel.index(of: name, in: map) == nil else {
            throw BoardEditRefusal(step: number, reason: "a component named \"\(name)\" already exists")
        }
        let kind = fields.kind ?? .service
        if fields.columns != nil, kind != .table {
            throw BoardEditRefusal(step: number, reason: "\"columns\" belong to a table; \"\(name)\" is a \(kind.raw)")
        }
        let component = BoardComponent(
            name: name,
            kind: kind,
            does: fields.does,
            reachedBy: fields.reachedBy,
            runs: fields.runs,
            tech: fields.tech,
            planned: fields.planned ?? false,
            columns: fields.columns ?? [])
        try placeComponent(component, at: place, number: number, map: &map)
        let added = map.components.last!
        return "added \(added.name) (\(bracket(for: added)))" + (added.place != BoardMap.notPlaced ? " in \(added.place)" : "")
    }
```

`applyUpdate` gains `columns` to its ghost guard and its own field application:
```swift
    private static func applyUpdate(
        _ rawName: String, _ fields: BoardComponentFields, place: String?, rename: String?, number: Int, map: inout BoardMap
    ) throws -> String {
        let name = trimmed(rawName)
        let index = try requireComponent(name, in: map, step: number)
        let oldName = map.components[index].name
        if map.components[index].outside != nil {
            if fields.kind != nil || rename != nil || fields.columns != nil {
                throw BoardEditRefusal(step: number, reason: "\"\(oldName)\" comes from the overview; change it there")
            }
        }
        var component = map.components[index]

        if let kind = fields.kind { component.kind = kind }
        if let does = fields.does { component.does = does.isEmpty ? nil : does }
        if let reachedBy = fields.reachedBy { component.reachedBy = reachedBy.isEmpty ? nil : reachedBy }
        if let runs = fields.runs { component.runs = runs.isEmpty ? nil : runs }
        if let tech = fields.tech { component.tech = tech.isEmpty ? nil : tech }
        if let planned = fields.planned { component.planned = planned }
        if let columns = fields.columns {
            guard component.kind == .table else {
                throw BoardEditRefusal(step: number, reason: "\"columns\" belong to a table; \"\(oldName)\" is a \(component.kind.raw)")
            }
            component.columns = columns
        }
        // ... the rest of applyUpdate (rename, place) is unchanged.
```

A `column` step changes a table's `columns` without re-running placement — exactly like every other
field an `update` changes (kind, tech, does…) leaves the part where it already sits. If growing a
table's columns makes its real box overlap a neighbour, the existing "Tidy up" action
(`BoardModel.tidyUp()` → `BoardLayout.arranged`) straightens it, same as any other manual overlap.
B1 does not add automatic re-settling on a column change.

### 2c. The `column` step

Still in `Sources/LinkCKit/Board/BoardEdit.swift`.

`BoardColumnFields` — a new public type, next to `BoardComponentFields`:
```swift
/// The editable fields of a column, as carried by a "column" step's `"set"`. `nil` means "leave it
/// alone" when changing an existing column; a new column added by this step uses the default for
/// whichever of `pk`/`nullable`/`unique`/`planned` is `nil` — `false`, `true`, `false`, `false`, the
/// same defaults `BoardColumn.init` itself uses.
public struct BoardColumnFields: Equatable, Sendable {
    public var type: String?
    public var pk: Bool?
    public var nullable: Bool?
    public var unique: Bool?
    public var defaultValue: String?   // "" clears
    public var references: String?     // "" clears; parsed with BoardColumnReference(parsing:)
    public var planned: Bool?

    public init(
        type: String? = nil, pk: Bool? = nil, nullable: Bool? = nil, unique: Bool? = nil,
        defaultValue: String? = nil, references: String? = nil, planned: Bool? = nil
    ) {
        self.type = type
        self.pk = pk
        self.nullable = nullable
        self.unique = unique
        self.defaultValue = defaultValue
        self.references = references
        self.planned = planned
    }
}
```

`BoardEditStep` gains one case, appended last:
```swift
public enum BoardEditStep: Equatable, Sendable {
    case add(String, BoardComponentFields, place: String?)
    case update(String, BoardComponentFields, place: String?, rename: String?)
    case remove(String)
    case connect(String, to: String, label: String?, style: BoardArrowStyle?, bits: Int?)
    case disconnect(String, to: String)
    case addPlace(String)
    case renamePlace(String, to: String)
    case removePlace(String)
    case note(String)
    case removeNote(String)
    case system(String)
    case detail(String)
    case column(table: String, column: String, set: BoardColumnFields?, drop: Bool)
}
```

Two of `decodeStep`'s local closures become thin wrappers around new shared statics, so
`decodeColumnStep` can reuse the same JSON-typed-field logic without duplicating it. Replace:
```swift
        func stringField(_ key: String) throws -> String? {
            guard let value = object[key] else { return nil }
            guard let text = value as? String else { throw BoardEditRefusal(step: step, reason: "\"\(key)\" must be text") }
            return text
        }
        func boolField(_ key: String) throws -> Bool? {
            guard let value = object[key] else { return nil }
            // `JSONSerialization` bridges every number to `NSNumber`, and `NSNumber as? Bool`
            // bridges any of them — `1`, not just `true` — to `Bool`. A real boolean carries the
            // `CFBoolean` type; a plain number does not, so it is refused rather than silently
            // treated as true or false. Matches `BoardMapJSON.isBoolNumber`'s own check.
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                throw BoardEditRefusal(step: step, reason: "\"\(key)\" must be true or false")
            }
            return number.boolValue
        }
```
with:
```swift
        func stringField(_ key: String) throws -> String? { try Self.stringField(key, object, step) }
        func boolField(_ key: String) throws -> Bool? { try Self.boolField(key, object, step) }
```
and add the two shared statics near `decodeStep` (e.g. right above it):
```swift
    private static func stringField(_ key: String, _ object: [String: Any], _ step: Int) throws -> String? {
        guard let value = object[key] else { return nil }
        guard let text = value as? String else { throw BoardEditRefusal(step: step, reason: "\"\(key)\" must be text") }
        return text
    }

    /// `JSONSerialization` bridges every number to `NSNumber`, and `NSNumber as? Bool` bridges any
    /// of them — `1`, not just `true` — to `Bool`. A real boolean carries the `CFBoolean` type; a
    /// plain number does not, so it is refused rather than silently treated as true or false.
    /// Matches `BoardMapJSON.isBoolNumber`'s own check.
    private static func boolField(_ key: String, _ object: [String: Any], _ step: Int) throws -> Bool? {
        guard let value = object[key] else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw BoardEditRefusal(step: step, reason: "\"\(key)\" must be true or false")
        }
        return number.boolValue
    }
```

`decodeStep` special-cases `"op"` right at its top, before the existing `verbsPresent` logic:
```swift
    private static func decodeStep(_ raw: Any, step: Int) throws -> BoardEditStep {
        guard let object = raw as? [String: Any] else {
            throw BoardEditRefusal(step: step, reason: "a step must be an object")
        }
        if object["op"] != nil {
            return try decodeColumnStep(object, step: step)
        }
        let verbsPresent = verbKeys.intersection(object.keys)
        // ... unchanged from here
```

`decodeColumnStep` and `applyColumn` are new functions (place them near the other `add`/`update`
decode and apply code):
```swift
    private static let columnStepKnownKeys: Set<String> = ["op", "table", "column", "set", "drop"]
    private static let columnSetKnownKeys: Set<String> = ["type", "pk", "nullable", "unique", "default", "references", "status"]

    private static func decodeColumnStep(_ object: [String: Any], step: Int) throws -> BoardEditStep {
        guard let op = object["op"] as? String, op == "column" else {
            throw BoardEditRefusal(step: step, reason: "\"op\" must be \"column\"")
        }
        for key in object.keys where !columnStepKnownKeys.contains(key) {
            throw BoardEditRefusal(step: step, reason: "unknown field \"\(key)\" — column takes: table, column, set, drop")
        }
        guard let table = try stringField("table", object, step), !table.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BoardEditRefusal(step: step, reason: "a \"column\" step needs \"table\"")
        }
        guard let column = try stringField("column", object, step), !column.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BoardEditRefusal(step: step, reason: "a \"column\" step needs \"column\"")
        }
        let drop = try boolField("drop", object, step) ?? false
        let rawSet = object["set"]
        if drop, rawSet != nil {
            throw BoardEditRefusal(step: step, reason: "a \"column\" step can't set and drop at once")
        }
        guard drop || rawSet != nil else {
            throw BoardEditRefusal(step: step, reason: "a \"column\" step needs \"set\" or \"drop\"")
        }

        var fields: BoardColumnFields?
        if let rawSet {
            guard let setObject = rawSet as? [String: Any] else {
                throw BoardEditRefusal(step: step, reason: "\"set\" must be an object")
            }
            for key in setObject.keys where !columnSetKnownKeys.contains(key) {
                throw BoardEditRefusal(step: step, reason: "column \"\(column)\" has an unknown key \"\(key)\"")
            }
            let type = try stringField("type", setObject, step)
            let pk = try boolField("pk", setObject, step)
            let nullable = try boolField("nullable", setObject, step)
            if pk == true, nullable == true {
                throw BoardEditRefusal(step: step, reason: "column \"\(column)\" is a primary key, so it can't be nullable")
            }
            let unique = try boolField("unique", setObject, step)
            let defaultValue = try stringField("default", setObject, step)
            let references = try stringField("references", setObject, step)
            var planned: Bool?
            if let status = try stringField("status", setObject, step) {
                guard status == "planned" else {
                    throw BoardEditRefusal(step: step, reason: "column \"\(column)\": the only status is \"planned\"")
                }
                planned = true
            }
            fields = BoardColumnFields(
                type: type, pk: pk, nullable: nullable, unique: unique,
                defaultValue: defaultValue, references: references, planned: planned)
        }
        return .column(table: trimmed(table), column: trimmed(column), set: fields, drop: drop)
    }

    private static func tablesList(_ map: BoardMap) -> String {
        let names = map.components.filter { $0.kind == .table }.map(\.name).sorted { $0.lowercased() < $1.lowercased() }
        return names.isEmpty ? "(none)" : names.joined(separator: ", ")
    }

    private static func applyColumn(
        table tableName: String, column columnName: String, set fields: BoardColumnFields?, drop: Bool, number: Int, map: inout BoardMap
    ) throws -> String {
        guard let index = BoardModel.index(of: tableName, in: map) else {
            throw BoardEditRefusal(step: number, reason: "no table \"\(tableName)\" — tables: \(tablesList(map))")
        }
        var component = map.components[index]
        guard component.outside == nil else {
            throw BoardEditRefusal(step: number, reason: "\"\(component.name)\" comes from the overview; change it there")
        }
        guard component.kind == .table else {
            throw BoardEditRefusal(step: number, reason: "\"\(component.name)\" is a \(component.kind.raw), not a table")
        }
        let columnIndex = component.columns.firstIndex { $0.name.lowercased() == columnName.lowercased() }

        if drop {
            guard let columnIndex else {
                throw BoardEditRefusal(step: number, reason: "table \"\(component.name)\" has no column \"\(columnName)\"")
            }
            let droppedName = component.columns[columnIndex].name
            component.columns.remove(at: columnIndex)
            map.components[index] = component
            return "dropped \(component.name).\(droppedName)"
        }

        guard let fields else {
            throw BoardEditRefusal(step: number, reason: "a \"column\" step needs \"set\" or \"drop\"")
        }

        if let columnIndex {
            var column = component.columns[columnIndex]
            if let type = fields.type { column.type = type }
            if let pk = fields.pk { column.pk = pk }
            if let nullable = fields.nullable { column.nullable = nullable }
            if let unique = fields.unique { column.unique = unique }
            if let defaultValue = fields.defaultValue { column.defaultValue = defaultValue.isEmpty ? nil : defaultValue }
            if let referencesText = fields.references {
                if referencesText.isEmpty {
                    column.references = nil
                } else {
                    guard let parsed = BoardColumnReference(parsing: referencesText) else {
                        throw BoardEditRefusal(step: number, reason: "column \"\(column.name)\" has \"references\" \"\(referencesText)\" but it is not table.column")
                    }
                    column.references = parsed
                }
            }
            if let planned = fields.planned { column.planned = planned }
            if column.pk { column.nullable = false }
            component.columns[columnIndex] = column
            map.components[index] = component
            return "changed \(component.name).\(column.name)"
        }

        guard let type = fields.type, !type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BoardEditRefusal(step: number, reason: "column \"\(columnName)\" needs \"type\" to be added")
        }
        var reference: BoardColumnReference?
        if let referencesText = fields.references, !referencesText.isEmpty {
            guard let parsed = BoardColumnReference(parsing: referencesText) else {
                throw BoardEditRefusal(step: number, reason: "column \"\(columnName)\" has \"references\" \"\(referencesText)\" but it is not table.column")
            }
            reference = parsed
        }
        let newColumn = BoardColumn(
            name: columnName, type: type, pk: fields.pk ?? false, nullable: fields.nullable ?? true, unique: fields.unique ?? false,
            defaultValue: (fields.defaultValue?.isEmpty ?? true) ? nil : fields.defaultValue,
            references: reference, planned: fields.planned ?? false)
        component.columns.append(newColumn)
        map.components[index] = component
        return "added \(component.name).\(newColumn.name)"
    }
```

`applyStep`'s switch gains one case:
```swift
        case .column(let table, let column, let set, let drop):
            return try applyColumn(table: table, column: column, set: set, drop: drop, number: number, map: &map)
```

### 2d. The tool description

In `Sources/LinkCKit/MCP/MCPServer.swift`, `stepsSchemaDescription`:
```swift
    static let stepsSchemaDescription = """
        1 to 50 steps, applied in order, all or nothing. One verb per step, naming its fields exactly:
        add: {"add": name, "kind"?, "tech"?, "in"?: place, "does"?, "reached_by"?, "runs"?, "planned"?: bool, "columns"?: [column]}
        update: {"update": name, same optional fields, "rename"?: new name}
        remove: {"remove": name}
        connect: {"connect": from, "to": to, "label"?, "style"?: plain|conditional|control|bus, "bits"?: 1-4096 (bus only)}
        disconnect: {"disconnect": from, "to": to}
        place: {"place": label} or {"place": label, "rename": new label}
        remove_place: {"remove_place": label}
        note: {"note": text}
        remove_note: {"remove_note": exact text}
        system: {"system": one line}
        detail: {"detail": name}
        column: {"op": "column", "table": name, "column": name, "set"?: {column keys except name}, "drop"?: true} — adds the column when it's missing (needs "type"), changes it when present, drops it with "drop": true.
        a column: {"name", "type", "pk"?: bool, "nullable"?: bool, "unique"?: bool, "default"?, "references"?: "table.column", "status"?: "planned"}. "columns" and the "column" step only work on a "table" part.
        "kind": \(ComponentKind.groupedKindList) — any other kind is kept and drawn as a service. "memory" is the AI agent's checkpointer; "ram" is hardware memory. "table" is a database's own table, its box sized to fit its columns.
        "planned": true marks something not built yet — linkc_get_board shows it as "status": "planned".
        "tech": a known technology id or alias — \(BoardTech.knownIDs.joined(separator: ", "))
        A new arrow from a router defaults to conditional, from a control unit to control.
        Parts marked outside come from the parent board and are read-only here.
        """
```

And the tool's own short `description` (around line 260) gets `column` added to its verb list —
change `"...system, detail. Optional board:..."` to `"...system, detail, column. Optional board:..."`
(the rest of that string is unchanged).

**Test** — add to `Tests/LinkCKitTests/BoardEditTests.swift`:

```swift
    // MARK: - "columns" (the whole list) on add / update

    func testAddAcceptsColumnsOnATable() throws {
        let result = try apply([["add": "orgs", "kind": "table", "columns": [
            ["name": "id", "type": "bigint", "pk": true],
            ["name": "name", "type": "text", "nullable": false],
        ]]], to: .empty)
        let orgs = try XCTUnwrap(result.map.components.first { $0.name == "orgs" })
        XCTAssertEqual(orgs.columns, [
            BoardColumn(name: "id", type: "bigint", pk: true),
            BoardColumn(name: "name", type: "text", nullable: false),
        ])
    }

    func testUpdateReplacesTheWholeColumnsList() throws {
        let base = try apply([["add": "orgs", "kind": "table", "columns": [["name": "id", "type": "bigint", "pk": true]]]], to: .empty).map
        let result = try apply([["update": "orgs", "columns": [["name": "slug", "type": "text"]]]], to: base)
        let orgs = try XCTUnwrap(result.map.components.first { $0.name == "orgs" })
        XCTAssertEqual(orgs.columns, [BoardColumn(name: "slug", type: "text")])
    }

    func testColumnsOnANonTablePartIsRefused() throws {
        XCTAssertEqual(refusal([["add": "api", "columns": [["name": "id", "type": "uuid"]]]], on: .empty)?.description,
                       #"step 1: "columns" belong to a table; "api" is a service"#)
        let withApi = try apply([["add": "api"]], to: .empty).map
        XCTAssertEqual(refusal([["update": "api", "columns": [["name": "id", "type": "uuid"]]]], on: withApi)?.description,
                       #"step 1: "columns" belong to a table; "api" is a service"#)
    }

    func testABadColumnInTheWholeListReusesTheBoardMapMessage() throws {
        XCTAssertEqual(refusal([["add": "orgs", "kind": "table", "columns": [["type": "uuid"]]]], on: .empty)?.description,
                       #"step 1: "orgs" has a column with no "name""#)
        XCTAssertEqual(refusal([["add": "orgs", "kind": "table", "columns": [["name": "id", "type": "uuid", "pk": true, "nullable": true]]]], on: .empty)?.description,
                       #"step 1: "orgs" column "id" is a primary key, so it can't be nullable"#)
    }

    // MARK: - the "column" step

    func testColumnStepAddsAMissingColumn() throws {
        let base = try apply([["add": "orgs", "kind": "table"]], to: .empty).map
        let result = try apply([["op": "column", "table": "orgs", "column": "id", "set": ["type": "bigint", "pk": true]]], to: base)
        let orgs = try XCTUnwrap(result.map.components.first { $0.name == "orgs" })
        XCTAssertEqual(orgs.columns, [BoardColumn(name: "id", type: "bigint", pk: true)])
        XCTAssertEqual(result.lines, ["added orgs.id"])
    }

    func testColumnStepChangesAnExistingColumn() throws {
        let base = try apply([["add": "orgs", "kind": "table", "columns": [["name": "name", "type": "text"]]]], to: .empty).map
        let result = try apply([["op": "column", "table": "orgs", "column": "name", "set": ["unique": true, "nullable": false]]], to: base)
        let orgs = try XCTUnwrap(result.map.components.first { $0.name == "orgs" })
        XCTAssertEqual(orgs.columns, [BoardColumn(name: "name", type: "text", nullable: false, unique: true)])
        XCTAssertEqual(result.lines, ["changed orgs.name"])
    }

    func testColumnStepDropsAColumn() throws {
        let base = try apply([["add": "orgs", "kind": "table", "columns": [["name": "id", "type": "bigint"], ["name": "legacy", "type": "text"]]]], to: .empty).map
        let result = try apply([["op": "column", "table": "orgs", "column": "legacy", "drop": true]], to: base)
        let orgs = try XCTUnwrap(result.map.components.first { $0.name == "orgs" })
        XCTAssertEqual(orgs.columns.map(\.name), ["id"])
        XCTAssertEqual(result.lines, ["dropped orgs.legacy"])
    }

    func testColumnStepOnAnUnknownTableIsRefused() throws {
        XCTAssertEqual(refusal([["op": "column", "table": "ghosttable", "column": "id", "drop": true]], on: .empty)?.description,
                       #"step 1: no table "ghosttable" — tables: (none)"#)
    }

    func testColumnStepOnAPartThatIsNotATableIsRefused() throws {
        let base = try apply([["add": "api"]], to: .empty).map
        XCTAssertEqual(refusal([["op": "column", "table": "api", "column": "id", "drop": true]], on: base)?.description,
                       #"step 1: "api" is a service, not a table"#)
    }

    func testColumnStepOnAGhostIsRefused() throws {
        var map = BoardMap()
        map.components = [BoardComponent(name: "orgs", kind: .table, columns: [BoardColumn(name: "id", type: "bigint")], outside: .in)]
        XCTAssertEqual(refusal([["op": "column", "table": "orgs", "column": "id", "drop": true]], on: map)?.description,
                       #"step 1: "orgs" comes from the overview; change it there"#)
    }

    func testDroppingAMissingColumnIsRefused() throws {
        let base = try apply([["add": "orgs", "kind": "table"]], to: .empty).map
        XCTAssertEqual(refusal([["op": "column", "table": "orgs", "column": "nope", "drop": true]], on: base)?.description,
                       #"step 1: table "orgs" has no column "nope""#)
    }

    func testAddingAColumnWithoutATypeIsRefused() throws {
        let base = try apply([["add": "orgs", "kind": "table"]], to: .empty).map
        XCTAssertEqual(refusal([["op": "column", "table": "orgs", "column": "id", "set": ["pk": true]]], on: base)?.description,
                       #"step 1: column "id" needs "type" to be added"#)
    }

    func testDropWithSetIsRefused() throws {
        let base = try apply([["add": "orgs", "kind": "table"]], to: .empty).map
        XCTAssertEqual(refusal([["op": "column", "table": "orgs", "column": "id", "set": ["type": "bigint"], "drop": true]], on: base)?.description,
                       #"step 1: a "column" step can't set and drop at once"#)
    }

    func testAMalformedReferenceInAColumnStepIsRefused() throws {
        let base = try apply([["add": "orgs", "kind": "table"]], to: .empty).map
        XCTAssertEqual(refusal([["op": "column", "table": "orgs", "column": "org_id", "set": ["type": "bigint", "references": "orgs"]]], on: base)?.description,
                       #"step 1: column "org_id" has "references" "orgs" but it is not table.column"#)
    }

    func testColumnStepNeedsSetOrDrop() throws {
        let base = try apply([["add": "orgs", "kind": "table"]], to: .empty).map
        XCTAssertEqual(refusal([["op": "column", "table": "orgs", "column": "id"]], on: base)?.description,
                       #"step 1: a "column" step needs "set" or "drop""#)
    }
```

**Test** — add to `Tests/LinkCKitTests/MCPServerBoardTests.swift`:

```swift
    func testStepsSchemaDescriptionDocumentsColumnsAndTheColumnStep() {
        let text = MCPServer.stepsSchemaDescription
        XCTAssertTrue(text.contains(#""columns"?"#), text)
        XCTAssertTrue(text.contains(#""op": "column""#), text)
        XCTAssertTrue(text.contains(#""drop""#), text)
        XCTAssertTrue(text.contains("only work on a \"table\" part"), text)
    }
```

### Steps

- [ ] **Step 1: Write the failing tests.** Add every test above. Add the stubs needed to compile
  (`BoardColumnFields`, the `.column` case, `columns` on `BoardComponentFields`,
  `BoardMap.parsedColumns`) with bodies that don't yet implement the real behaviour (e.g.
  `decodeColumnStep` throwing a placeholder refusal, `applyColumn` returning `""`). Run
  `swift test --filter "BoardEditTests|MCPServerBoardTests"` and confirm the new tests fail on
  assertions.
- [ ] **Step 2: Implement** 2a–2d in full.
- [ ] **Step 3: Run** the same filtered command, see it pass, then the full suite and the warnings
  check.
- [ ] **Step 4: Commit.** Stage by name every file this task touched (including the two edited
  assertions in `BoardEditTests.swift`). Message:
  `feat(board): agents can add, change and drop a table's columns`

---

## Task 3: Import as a board edit — `BoardSchemaImport.steps(for:into:)`

**Files:**
- Create: `Sources/LinkCKit/Board/BoardSchemaImport.swift`.
- Test: create `Tests/LinkCKitTests/BoardSchemaImportTests.swift`.

**Consumes:** `SQLSchema.Parsed`/`SQLSchema.Table` (phase A), `BoardColumn` (phase A),
`ComponentKind.table` (Task 1), `BoardEditStep`/`BoardComponentFields`/`BoardEdit.apply` (Task 2 for
the `columns` field; `BoardEdit.apply` itself is unchanged since phase A).

**Behaviour** (spec §4 "Import into the board", and the B1 brief):

For each table `SQLSchema.parse` found, in the order `parsed.tables` gives them:
- If a **non-ghost** component with that name exists (case-insensitively) **and its kind is
  `.table`**: emit an `update` step. Its `columns` is the SQL's columns, in SQL order, each not
  planned, followed by every column already on the board part whose name (case-insensitively)
  isn't among the SQL's column names, each forced `planned: true` — the design-only tail. Its
  `planned` is `false` — the table itself is no longer just planned, now that SQL confirms it. A
  column that used to be design-only and now appears in the SQL moves into the DB-columns group,
  losing `planned`, because it's simply no longer in the design-only tail.
- Otherwise (no existing part by that name, or an existing part by that name that isn't kind
  `.table` — an unresolvable name clash `BoardEdit.apply` will itself refuse, loud): emit an `add`
  step, kind `.table`, `columns` the SQL's columns exactly (`SQLSchema.parse` never marks a
  column planned, so no extra marking is needed).

Then, for every **non-ghost**, `.table`-kind component already on the board whose name didn't match
any parsed table (sorted by lowercased name, for determinism): emit an `update` step marking it
`planned: true`, with every one of its own columns copied but forced `planned: true` too. Nothing
is ever removed — a table or column only in the design just becomes visibly planned.

Ghost components (`outside != nil`) are left alone entirely — never matched against, never swept.
A detail board's own tables are this board's to import into; a ghost mirrors a *different* board
and `BoardEdit` already refuses a `columns`/kind change on one (Task 2). If a parsed table's name
happens to collide with an existing ghost's name, the resulting `add` step is refused by
`BoardEdit.apply` exactly like any other name clash — an acceptable, fail-loud, untested edge case
for B1.

```swift
import Foundation

/// Turns a parsed SQL schema into ordinary `BoardEditStep`s, so importing a database's schema is
/// one call to `BoardEdit.apply` — one undo step, using the Board's own placement. Nothing is ever
/// deleted: a table or column that's only in the design stays, marked planned.
public enum BoardSchemaImport {
    /// `parsed`'s tables reconciled against `map`'s own `.table`-kind parts. See the doc comment
    /// in the phase B1 plan for the exact matching and "design-only" rules; in short: a table the
    /// SQL names is added or updated with the SQL's columns first (not planned) then any
    /// design-only columns kept (forced planned); a table-kind part the SQL doesn't name is marked
    /// planned, columns included.
    public static func steps(for parsed: SQLSchema.Parsed, into map: BoardMap) -> [BoardEditStep] {
        var result: [BoardEditStep] = []
        let byLowercasedName = Dictionary(
            uniqueKeysWithValues: map.components.filter { $0.outside == nil }.map { ($0.name.lowercased(), $0) })
        var matchedNames: Set<String> = []

        for table in parsed.tables {
            let key = table.name.lowercased()
            if let existing = byLowercasedName[key], existing.kind == .table {
                matchedNames.insert(key)
                let dbNames = Set(table.columns.map { $0.name.lowercased() })
                let designOnly = existing.columns
                    .filter { !dbNames.contains($0.name.lowercased()) }
                    .map { column -> BoardColumn in var c = column; c.planned = true; return c }
                let fields = BoardComponentFields(planned: false, columns: table.columns + designOnly)
                result.append(.update(existing.name, fields, place: nil, rename: nil))
            } else {
                let fields = BoardComponentFields(kind: .table, columns: table.columns)
                result.append(.add(table.name, fields, place: nil))
            }
        }

        let missing = map.components
            .filter { $0.kind == .table && $0.outside == nil && !matchedNames.contains($0.name.lowercased()) }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
        for component in missing {
            let plannedColumns = component.columns.map { column -> BoardColumn in var c = column; c.planned = true; return c }
            let fields = BoardComponentFields(planned: true, columns: plannedColumns)
            result.append(.update(component.name, fields, place: nil, rename: nil))
        }

        return result
    }
}
```

**Test** — create `Tests/LinkCKitTests/BoardSchemaImportTests.swift`:

```swift
import XCTest
@testable import LinkCKit

final class BoardSchemaImportTests: XCTestCase {
    func testAFreshImportAddsTables() throws {
        let parsed = try SQLSchema.parse("create table orgs (id bigint primary key, name text not null);")
        let steps = BoardSchemaImport.steps(for: parsed, into: .empty)
        XCTAssertEqual(steps, [.add("orgs", BoardComponentFields(kind: .table, columns: parsed.tables[0].columns), place: nil)])

        let applied = try BoardEdit.apply(steps, to: .empty)
        let orgs = try XCTUnwrap(applied.map.components.first { $0.name == "orgs" })
        XCTAssertEqual(orgs.kind, .table)
        XCTAssertEqual(orgs.columns, parsed.tables[0].columns)
        XCTAssertFalse(orgs.planned)
    }

    func testAReImportKeepsDesignOnlyTablesAndColumnsAsPlanned() throws {
        let parsed = try SQLSchema.parse("create table orgs (id bigint primary key);")
        var map = try BoardEdit.apply(BoardSchemaImport.steps(for: parsed, into: .empty), to: .empty).map
        map = try BoardEdit.apply([
            ["op": "column", "table": "orgs", "column": "notes", "set": ["type": "text"]],
            ["add": "wishlist", "kind": "table", "columns": [["name": "id", "type": "uuid"]]],
        ], to: map).map

        let steps = BoardSchemaImport.steps(for: parsed, into: map)
        let applied = try BoardEdit.apply(steps, to: map).map

        let orgs = try XCTUnwrap(applied.components.first { $0.name == "orgs" })
        XCTAssertFalse(orgs.planned)
        XCTAssertEqual(orgs.columns.map(\.name), ["id", "notes"])
        XCTAssertFalse(orgs.columns[0].planned, "the database column")
        XCTAssertTrue(orgs.columns[1].planned, "the design-only column")

        let wishlist = try XCTUnwrap(applied.components.first { $0.name == "wishlist" })
        XCTAssertTrue(wishlist.planned, "missing from the SQL, so it's planned")
        XCTAssertTrue(wishlist.columns.allSatisfy(\.planned))
    }

    func testAColumnThatReappearsLosesPlanned() throws {
        let firstParsed = try SQLSchema.parse("create table orgs (id bigint primary key);")
        var map = try BoardEdit.apply(BoardSchemaImport.steps(for: firstParsed, into: .empty), to: .empty).map
        map = try BoardEdit.apply([["op": "column", "table": "orgs", "column": "name", "set": ["type": "text"]]], to: map).map
        XCTAssertTrue(try XCTUnwrap(map.components.first?.columns.last).planned)

        let secondParsed = try SQLSchema.parse("create table orgs (id bigint primary key, name text not null);")
        let applied = try BoardEdit.apply(BoardSchemaImport.steps(for: secondParsed, into: map), to: map).map
        let name = try XCTUnwrap(applied.components.first { $0.name == "orgs" }?.columns.first { $0.name == "name" })
        XCTAssertFalse(name.planned)
        XCTAssertEqual(name.type, "text")
        XCTAssertFalse(name.nullable)
    }

    func testImportStepsApplyCleanlyThroughBoardEdit() throws {
        let parsed = try SQLSchema.parse("""
        create table orgs (id bigint primary key);
        create table users (id uuid primary key, org_id bigint references orgs (id));
        """)
        let applied = try BoardEdit.apply(BoardSchemaImport.steps(for: parsed, into: .empty), to: .empty)
        XCTAssertEqual(Set(applied.map.components.map(\.name)), ["orgs", "users"])
        XCTAssertEqual(applied.lines.count, 2)
    }
}
```

### Steps

- [ ] **Step 1: Write the failing tests.** Create the test file above. Add a stub
  `BoardSchemaImport.steps(for:into:)` returning `[]` so it compiles. Run
  `swift test --filter BoardSchemaImportTests` and confirm every test fails on an assertion.
- [ ] **Step 2: Implement** `BoardSchemaImport.swift` as above.
- [ ] **Step 3: Run** `swift test --filter BoardSchemaImportTests`, see it pass, then the full
  suite and the warnings check.
- [ ] **Step 4: Commit.** Stage by name. Message:
  `feat(board): importing SQL is an ordinary board edit`

---

## Task 4: Export helper — `SQLSchema.tables(in:)`

**Files:**
- Modify: `Sources/LinkCKit/SQL/SQLSchema.swift`.
- Test: create `Tests/LinkCKitTests/SQLSchemaTablesTests.swift`.

**Consumes:** `ComponentKind.table` (Task 1); `SQLSchema.Table`, `SQLSchema.parse`,
`SQLSchema.createStatements(for:)` (phase A).

Add, inside the `SQLSchema` enum body (e.g. right after `quotedIfNeeded`, before the closing
`}`):

```swift
    /// The table-kind parts of `map`, lowercased-name order, ready for `createStatements(for:)`.
    /// Planned tables and planned columns are included — only `kind` decides membership.
    public static func tables(in map: BoardMap) -> [Table] {
        map.components
            .filter { $0.kind == .table }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
            .map { Table(name: $0.name, columns: $0.columns) }
    }
```

**Test** — create `Tests/LinkCKitTests/SQLSchemaTablesTests.swift`:

```swift
import XCTest
@testable import LinkCKit

final class SQLSchemaTablesTests: XCTestCase {
    func testTablesAreReturnedInLowercasedNameOrderWithTheirColumns() {
        var map = BoardMap()
        map.components = [
            BoardComponent(name: "Users", kind: .table, columns: [BoardColumn(name: "id", type: "uuid", pk: true)]),
            BoardComponent(name: "accounts", kind: .table, columns: [BoardColumn(name: "id", type: "bigint", pk: true)]),
            BoardComponent(name: "api", kind: .service),
        ]
        XCTAssertEqual(SQLSchema.tables(in: map), [
            SQLSchema.Table(name: "accounts", columns: [BoardColumn(name: "id", type: "bigint", pk: true)]),
            SQLSchema.Table(name: "Users", columns: [BoardColumn(name: "id", type: "uuid", pk: true)]),
        ])
    }

    func testPlannedTablesAndColumnsAreIncluded() {
        var map = BoardMap()
        map.components = [BoardComponent(name: "wishlist", kind: .table, planned: true, columns: [
            BoardColumn(name: "id", type: "uuid", pk: true, planned: true),
        ])]
        let tables = SQLSchema.tables(in: map)
        XCTAssertEqual(tables.count, 1)
        XCTAssertTrue(tables[0].columns[0].planned)
    }

    func testAnEmptyMapExportsNoTables() {
        XCTAssertEqual(SQLSchema.tables(in: .empty), [])
    }

    /// Round trip: a table's columns survive export → `createStatements` → `parse`.
    func testExportedTablesReadBackTheSame() throws {
        var map = BoardMap()
        map.components = [BoardComponent(name: "orgs", kind: .table, columns: [
            BoardColumn(name: "id", type: "bigint", pk: true),
            BoardColumn(name: "name", type: "text", nullable: false),
        ])]
        let tables = SQLSchema.tables(in: map)
        let parsed = try SQLSchema.parse(SQLSchema.createStatements(for: tables))
        XCTAssertEqual(parsed.tables, tables)
    }
}
```

### Steps

- [ ] **Step 1: Write the failing tests.** Create the test file above. Add a stub
  `SQLSchema.tables(in:)` returning `[]` so it compiles. Run
  `swift test --filter SQLSchemaTablesTests` and confirm every test fails on an assertion.
- [ ] **Step 2: Implement** as above.
- [ ] **Step 3: Run** `swift test --filter SQLSchemaTablesTests`, see it pass, then the full suite
  and the warnings check.
- [ ] **Step 4: Commit.** Stage by name. Message:
  `feat(sql): a board's tables export ready for CREATE TABLE SQL`

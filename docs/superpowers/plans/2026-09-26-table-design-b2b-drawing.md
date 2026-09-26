# Table design, phase B2b: drawing tables

> **For agentic workers:** work task by task, test first where LinkCKit changes at all. Each task
> ends with one commit. The app target has no UI tests — every UI task ends with a build and a full
> suite run instead of a red/green cycle, and its own manual hand-check.

**Goal:** the Component menu can place a `table` part, and it actually looks like one — a header
plus one row per column, at the exact heights `BoardGeometry` already reserves for them — and every
place the app used to assume a fixed 176×84 box now asks the part its own size, so a table's boxes,
handles, hit-testing and glow are never wrong. Foreign-key lines run between rows, real routes or
stubs, exactly as `BoardModel` already computes them.

**Spec:** `docs/superpowers/specs/2026-09-25-table-design-design.md`, §2 ("How it looks") and §3's
mention that a new column is never planned when it's added, plus the ghost-service-neighbour and
foreign-key-line paragraphs. §1 (the column model), §4 (import/export) and the inspector's editable
grid are the sibling plan, `feat/table-grid` — not this one.

**Depends on (already merged into `main`, and present in this worktree):**
- `ComponentKind.table` (`Sources/LinkCKit/Board/ComponentKind.swift`) — deliberately outside
  `ComponentKind.groups` and `.known` until now; this plan's Task 1 is the one that changes that.
- `BoardGeometry.size(of:)` / `rect(of:)` (`Sources/LinkCKit/Board/BoardGeometry.swift`) — a table's
  box grows to fit its columns: header 36, 22 per row, 8 padding, rounded up to the 8-pt grid.
  `rect(of:)` returns `nil` exactly when `.at` is `nil`, same as the fixed-size
  `rect(ofComponentAt:)` it's meant to replace.
- `BoardGeometry.rowCenterY(ofColumnAt:in:)` — the vertical centre of column `index`'s row inside a
  placed table's rect: `rect.y + 36 + 22 * index + 11`.
- `BoardForeignKey` (`Sources/LinkCKit/Board/BoardForeignKey.swift`) — one column's foreign key,
  derived from its own `references`, never stored twice.
- `BoardModel.foreignKeyRoutes: [BoardForeignKey: BoardRoute]` and
  `BoardModel.foreignKeyStubs: [BoardForeignKey: (from: BoardPoint, to: BoardPoint)]`
  (`Sources/LinkCKit/Board/BoardModel.swift`) — published, read-only, recomputed alongside `routes`
  every time the map changes. A route's `points.first` is the foreign-key column's own port; its
  `points.last` is the referenced column's port. A stub's `from`/`to` are already screen-space-ready
  canvas points 40 pt apart, horizontal, off the table's right side.
- `BoardLens.includes(_:)` (`Sources/LinkCKit/Board/BoardLens.swift`) and `BoardFocus.Visible`
  (`Sources/LinkCKit/Board/BoardFocus.swift`) — `Visible.parts: Set<String>` is exactly what this
  plan checks a foreign key's two table names against.

**Out of scope for this plan (the sibling plan, `feat/table-grid`, owns all of it):**
- `BoardColumn`, `BoardColumnReference`, the column model itself.
- The column grid in the docked inspector.
- The Schema menu (Import SQL…, Import from Supabase, Copy SQL, Export SQL…) and the result banner.
- Any pure LinkCKit helper for the column grid (`nextColumnName`, `referenceOptions`).

This plan does not depend on the sibling plan's changes and must not wait for them or reference
their commits. Both worktrees started at the same commit (`9fd6f5c`).

## Global Constraints

- **Where to work:** the worktree `/Users/jacobdang/Projects/linkC/.worktrees/table-draw`, branch
  `feat/table-draw`. Never edit, build or run git in `/Users/jacobdang/Projects/linkC` itself, in
  `.worktrees/table-grid`, or in any other `.worktrees` folder.
- **Logic stays in LinkCKit.** This plan's one LinkCKit change (Task 1) is a static-data edit, not
  new logic — nothing else here needs a pure helper. If implementing turns up a need for one
  anyway, put it in `Sources/LinkCKit/`, with complete test code, test first — never inline logic
  in a SwiftUI view that belongs in LinkCKit.
- **No view body writes state.** Every `@State` mutation happens in a gesture handler, a button
  action, or a method the view calls from one of those — never inside a `body` or computed-view
  property's own evaluation.
- **Fail loud.** No `try?` anywhere in this plan's changes. If you add an `NSLog`, it must take
  format arguments (`NSLog("%@", x)`), never string interpolation baked into the format string.
- **Style:** 4-space indentation, one statement per line, `///` doc comments on every new
  declaration (and on any existing one whose behaviour you change) — match the surrounding file's
  voice; read a neighbouring doc comment before writing your own.
- **Build:** `swift build 2>&1 | tail -1` after every task. `swift build --build-tests 2>&1 | grep
  -E "warning:"` must print nothing after every task.
- **Suite:** `swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1` must report 0 failures
  after every task. Main is at 1621 tests.
- **Commits:**
  - one per task, with the message the task gives;
  - stage files by name, never `git add -A` or `git add .`;
  - **no trailers of any kind:** no Co-Authored-By, no "Generated with", no session links;
  - the word "claude" never appears in a message, in any case;
  - never push, merge or rebase.
- **Clean finish:** no scratch files, debug prints or commented-out code. `git status --short` is
  empty when you finish each task (besides that task's own staged changes).

**Shared file — `Sources/linkc/Board/BoardCanvas.swift` — read this before touching it.** The
sibling plan (`feat/table-grid`) also edits this file, in its own worktree, on its own branch. The
two plans' edits are disjoint by line; this plan may touch **only**:
- line 240 (inside `drawing`): one inserted line, right after `drawArrows(in: &context)`.
- line 391 (inside `componentItemView`): the `handles(...)` call's arguments.
- right after line 818 (the end of `drawArrows(in:)`, before the blank line and `isMoving`'s doc
  comment): one new function, `drawForeignKeys(in:)`.
- lines 1112–1114: `componentRect(_:)`'s body.
- lines 1260–1278: `handles(for:kind:)`, renamed `handles(for:)`.

Do not touch anything else in this file — in particular, never touch `dockedInspectorOverlay`
(~line 623), the banner stack in `overlays` (~lines 540–560), the `BoardToolbar(...)` call
(~line 564), or the `@State` declarations block (~lines 24–94): all sibling-plan territory. If any
of the line numbers above don't match what you read (they shouldn't — both worktrees started
identical and this plan is the only one meant to touch these five spots), locate the edit by the
function or comment named here, not by line number alone, and say so in your report.

---

## Task 1: `.table` joins the Component menu

**Files:**
- Modify: `Sources/LinkCKit/Board/ComponentKind.swift` — `groups`' `System` group, and `table`'s
  own declaration and doc comment.
- Modify: `Tests/LinkCKitTests/ComponentKindTests.swift` — three existing tests updated for the new
  group membership (no test added; the group's shape has changed).
- Modify: `Sources/linkc/Board/BoardElements.swift` — `ComponentKind.glyph` gets a `.table` case.

### 1a. Test first — update `ComponentKindTests.swift`

This task makes `testTableIsAKnownIDButNotYetInAnyGroup` false on its face — its whole premise is
what this task removes. Replace it, and fix the two tests whose exact counts and text change:

Change:
```swift
    func testTheGroupsCoverEveryKnownKindOnce() {
        let grouped = ComponentKind.groups.flatMap(\.kinds)
        XCTAssertEqual(grouped.count, Set(grouped).count)
        XCTAssertEqual(Set(grouped), Set(ComponentKind.known))
        XCTAssertEqual(ComponentKind.groups.map(\.title), ["System", "AI agents", "Hardware"])
        XCTAssertEqual(ComponentKind.groups.map(\.kinds.count), [7, 12, 10])
    }
```
to:
```swift
    func testTheGroupsCoverEveryKnownKindOnce() {
        let grouped = ComponentKind.groups.flatMap(\.kinds)
        XCTAssertEqual(grouped.count, Set(grouped).count)
        XCTAssertEqual(Set(grouped), Set(ComponentKind.known))
        XCTAssertEqual(ComponentKind.groups.map(\.title), ["System", "AI agents", "Hardware"])
        XCTAssertEqual(ComponentKind.groups.map(\.kinds.count), [8, 12, 10])
    }
```

Change:
```swift
    func testGroupedKindListNamesEachGroupWithItsKinds() {
        let text = ComponentKind.groupedKindList
        XCTAssertTrue(text.hasPrefix("System: database, cache, queue, storage, service, host, external; "), text)
```
to:
```swift
    func testGroupedKindListNamesEachGroupWithItsKinds() {
        let text = ComponentKind.groupedKindList
        XCTAssertTrue(text.hasPrefix("System: database, table, cache, queue, storage, service, host, external; "), text)
```

Replace:
```swift
    func testTableIsAKnownIDButNotYetInAnyGroup() {
        XCTAssertEqual(ComponentKind.table.raw, "table")
        XCTAssertFalse(ComponentKind.groups.flatMap(\.kinds).contains(.table), "the app can't draw it yet")
        XCTAssertFalse(ComponentKind.known.contains(.table))
        XCTAssertFalse(ComponentKind.table.isKnown)
    }
```
with:
```swift
    func testTableIsInTheSystemGroupRightAfterDatabase() {
        XCTAssertEqual(ComponentKind.table.raw, "table")
        XCTAssertEqual(ComponentKind.groups[0].kinds, [.database, .table, .cache, .queue, .storage, .service, .host, .external])
        XCTAssertTrue(ComponentKind.known.contains(.table))
        XCTAssertTrue(ComponentKind.table.isKnown)
    }
```

Run `swift test --filter ComponentKindTests` and confirm all four tests fail — the three changed
ones on assertions against the still-old code, the replaced one the same way (it now asserts what
isn't true yet).

### 1b. Implement — `ComponentKind.swift`

Change:
```swift
    // MARK: - System

    public static let database = ComponentKind("database")
    public static let cache = ComponentKind("cache")
    public static let queue = ComponentKind("queue")
    public static let storage = ComponentKind("storage")
    public static let service = ComponentKind("service")
    public static let host = ComponentKind("host")
    public static let external = ComponentKind("external")

    // MARK: - Data

    /// A database table. It remains outside `groups` until the app can draw it.
    public static let table = ComponentKind("table")

    // MARK: - AI agents
```
to:
```swift
    // MARK: - System

    public static let database = ComponentKind("database")
    /// A database table, drawn as a header plus one row per column (`ComponentBox`, in the app
    /// target) rather than the plain card every other System kind gets.
    public static let table = ComponentKind("table")
    public static let cache = ComponentKind("cache")
    public static let queue = ComponentKind("queue")
    public static let storage = ComponentKind("storage")
    public static let service = ComponentKind("service")
    public static let host = ComponentKind("host")
    public static let external = ComponentKind("external")

    // MARK: - AI agents
```
(The now-empty `// MARK: - Data` is deleted along with the line it introduced.)

Change:
```swift
    public static let groups: [Group] = [
        Group(title: "System", kinds: [.database, .cache, .queue, .storage, .service, .host, .external]),
```
to:
```swift
    public static let groups: [Group] = [
        Group(title: "System", kinds: [.database, .table, .cache, .queue, .storage, .service, .host, .external]),
```

### 1c. Implement — `ComponentKind.glyph`'s new case

In `Sources/linkc/Board/BoardElements.swift`, change:
```swift
        case .database: return "cylinder.split.1x2"
        case .cache: return "bolt.horizontal"
```
to:
```swift
        case .database: return "cylinder.split.1x2"
        case .table: return "tablecells"
        case .cache: return "bolt.horizontal"
```
`tablecells` is a small-grid SF Symbol — what the Component menu (`BoardToolbar`'s Menu,
`QuickAddMenu`'s row) shows next to "Table".

### Steps

- [ ] **Step 1:** make the test edits in 1a. Run `swift test --filter ComponentKindTests` and
  confirm all four tests fail on assertions.
- [ ] **Step 2:** implement 1b and 1c.
- [ ] **Step 3:** run `swift test --filter ComponentKindTests`, see all four pass, then the full
  suite and the warnings check.
- [ ] **Step 4: Commit.** Stage `Sources/LinkCKit/Board/ComponentKind.swift`,
  `Tests/LinkCKitTests/ComponentKindTests.swift`, `Sources/linkc/Board/BoardElements.swift` by
  name. Message: `feat(board): .table joins the Component menu`

---

## Task 2: every app box, handle and hit-test uses the part's real size

**Files:** Modify only `Sources/linkc/Board/BoardCanvas.swift`.

**Every app site that assumed a fixed 176×84 box, and what happens to each:**

| Site | What it does today | Change |
|---|---|---|
| `componentRect(_:)`, lines 1112–1114 | `component.at.map(BoardGeometry.rect(ofComponentAt:))` — always the fixed box | Body becomes `BoardGeometry.rect(of: component)` |
| Line 251, `drawing`'s arrow-draft preview | calls `componentRect(source)` | Fixed automatically — no separate edit |
| Line 271, `elements`' visibility filter | calls `componentRect(component)` | Fixed automatically |
| Lines 834/838, `extendedEndpoints` | calls `componentRect(source)` / `componentRect(target)` | Fixed automatically |
| Line 935, `arrowDraw`'s `liveRect(_:)` | calls `componentRect(component)` | Fixed automatically |
| Line 1287, `arrowDrag`'s drop target | calls `componentRect($0)` | Fixed automatically |
| `handles(for:kind:)`, lines 1260–1278 | `let size = BoardGeometry.componentSize` | Takes the whole `BoardComponent`; `size = BoardGeometry.size(of: component)` |
| Line 391, `componentItemView`'s handles overlay | `handles(for: component.name, kind: component.kind)` | `handles(for: component)` |
| `heightTrimmedInset`, line 893 | `let w = CGFloat(BoardGeometry.componentSize.x), h = ...` | **No change** — see below |
| `place(_:at:)`, line 1375 | `let size = BoardGeometry.componentSize` (quick-add ghost, before the component exists) | **No change** — no component exists yet to ask |

`componentRect(_:)` is the single choke point: fixing its body fixes every one of its six call
sites at once. Don't edit any of those six sites individually.

`heightTrimmedInset` stays untouched. It only reaches its `w`/`h` fixed-box lines when
`BoardShape.insets(for: kind)`'s constant for that side is non-zero (its very first guard:
`guard constantForSide != 0 else { return 0 }`). The sibling task in this same plan (Task 3) gives
`.table` `insets` of `(0, 0, 0, 0)` on every side, so that guard always fires first for a table —
this function's fixed-box math is never reached for one. An ordinary arrow into or out of a table
still lands correctly on the table's real (possibly much larger) edge, because `insetEndpoint`
computes the landing point from `box.minX`/`.maxX`/`.minY`/`.maxY` — the box `componentRect` already
gives it, real size and all — not from the fixed constants `heightTrimmedInset` never reaches.

### 2a. `componentRect(_:)`

Change:
```swift
    private func componentRect(_ component: BoardComponent) -> BoardRect? {
        component.at.map(BoardGeometry.rect(ofComponentAt:))
    }
```
to:
```swift
    private func componentRect(_ component: BoardComponent) -> BoardRect? {
        BoardGeometry.rect(of: component)
    }
```

### 2b. `handles(for:kind:)` → `handles(for:)`

Change:
```swift
    /// The four side handles on a hovered component, on the kind's drawn outline rather than the
    /// box behind it; dragging one draws an arrow.
    private func handles(for name: String, kind: ComponentKind) -> some View {
        let size = BoardGeometry.componentSize
        let inset = BoardShape.insets(for: kind)
        let points = [CGPoint(x: CGFloat(size.x) / 2, y: inset.top), CGPoint(x: CGFloat(size.x) - inset.right, y: CGFloat(size.y) / 2),
                      CGPoint(x: CGFloat(size.x) / 2, y: CGFloat(size.y) - inset.bottom), CGPoint(x: inset.left, y: CGFloat(size.y) / 2)]
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
```
to:
```swift
    /// The four side handles on a hovered component, on the kind's drawn outline rather than the
    /// box behind it; dragging one draws an arrow. Sized to the component's own box —
    /// `BoardGeometry.size(of:)`, a table's grown box included, not the fixed 176×84 every other
    /// kind still uses.
    private func handles(for component: BoardComponent) -> some View {
        let size = BoardGeometry.size(of: component)
        let inset = BoardShape.insets(for: component.kind)
        let points = [CGPoint(x: CGFloat(size.x) / 2, y: inset.top), CGPoint(x: CGFloat(size.x) - inset.right, y: CGFloat(size.y) / 2),
                      CGPoint(x: CGFloat(size.x) / 2, y: CGFloat(size.y) - inset.bottom), CGPoint(x: inset.left, y: CGFloat(size.y) / 2)]
        return ZStack(alignment: .topLeading) {
            ForEach(points.indices, id: \.self) { index in
                Circle()
                    .fill(Theme.boardBackground)
                    .overlay(Circle().strokeBorder(Theme.accent, lineWidth: 1.5))
                    .frame(width: 10, height: 10)
                    .position(points[index])
                    .gesture(arrowDrag(from: component.name))
            }
        }
        .frame(width: CGFloat(size.x), height: CGFloat(size.y))
    }
```

### 2c. The call site

Change (line 391):
```swift
            .overlay { if hovered == component.name && board.tool == .select && dragging.isEmpty { handles(for: component.name, kind: component.kind) } }
```
to:
```swift
            .overlay { if hovered == component.name && board.tool == .select && dragging.isEmpty { handles(for: component) } }
```

### Steps

- [ ] **Step 1:** make edits 2a–2c.
- [ ] **Step 2:** `swift build 2>&1 | tail -1` — clean build. `swift build --build-tests 2>&1 | grep
  -E "warning:"` — empty.
- [ ] **Step 3:** `swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1` — 0 failures.
- [ ] **Step 4: Commit.** Stage `Sources/linkc/Board/BoardCanvas.swift` by name. Message:
  `feat(board): every app box, handle and hit-test uses the part's real size`

---

## Task 3: the table box — a header and one row per column

**Files:** Modify only `Sources/linkc/Board/BoardElements.swift`.

A ghost table (`component.outside != nil`) is unaffected by the content changes below — `content`'s
existing `if isGhost { Text(component.name)... }` branch (unchanged) still runs for it, and still
gives it the plain name-only ghost style. It's still sized correctly, though: `shape`'s new `.table`
case (3c) runs for a ghost table too — `shape` doesn't check `isGhost` at all, only `fillColor`,
`strokeColor` and `dash` do, and they already handle `isGhost` generically, for every kind — so a
ghost table gets a properly-sized, dashed, faint box with just its name in it, which is exactly what
"a ghost table keeps the ghost style (name only)" means once boxes are sized by their own columns.

### 3a. Two new computed properties: `boxWidth` / `boxHeight`

Right after the existing fixed-size constants:
```swift
    private static let width = CGFloat(BoardGeometry.componentSize.x)
    private static let height = CGFloat(BoardGeometry.componentSize.y)
```
add:
```swift
    /// The box's actual drawn width and height: `BoardGeometry.size(of:)` for a table, which grows
    /// to fit its columns; `Self.width`/`Self.height` (the fixed 176×84) for every other kind,
    /// unchanged. A ghost table uses this too — sized like a real one, drawn like a ghost.
    private var boxWidth: CGFloat { component.kind == .table ? CGFloat(BoardGeometry.size(of: component).x) : Self.width }
    private var boxHeight: CGFloat { component.kind == .table ? CGFloat(BoardGeometry.size(of: component).y) : Self.height }
```

### 3b. `body`'s two fixed-size frames become dynamic

Change:
```swift
            content
                .padding(.leading, isGhost ? 14 : inset.leading)
                .frame(width: Self.width, height: Self.height, alignment: .leading)
                .offset(y: isGhost ? 0 : inset.verticalOffset)
        }
        .frame(width: Self.width, height: Self.height)
```
to:
```swift
            content
                .padding(.leading, isGhost ? 14 : inset.leading)
                .frame(width: boxWidth, height: boxHeight, alignment: .leading)
                .offset(y: isGhost ? 0 : inset.verticalOffset)
        }
        .frame(width: boxWidth, height: boxHeight)
```
Nothing else in `body` changes — the status-dot and stale-ghost overlays are alignment-based
(`.overlay(alignment: .topTrailing)` / `.topLeading`) and already position correctly against
whatever size the frame they overlay actually is.

### 3c. `shape`'s new `.table` case

Change:
```swift
    @ViewBuilder
    private var shape: some View {
        switch component.kind {
        case .database, .cache, .vectorStore, .memory:
            BoardShape.cylinderBody.fill(fillColor(Theme.boardBox))
            BoardShape.cylinderBody.stroke(strokeColor, style: strokeStyle)
            BoardShape.cylinderRim.fill(fillColor(Theme.boardCylinderRim))
            BoardShape.cylinderRim.stroke(strokeColor, style: strokeStyle)
        default:
            BoardShape.path(for: component.kind).fill(fillColor(BoardShape.fillColor(for: component.kind)))
            BoardShape.path(for: component.kind).stroke(strokeColor, style: strokeStyle)
        }
    }
```
to:
```swift
    @ViewBuilder
    private var shape: some View {
        switch component.kind {
        case .database, .cache, .vectorStore, .memory:
            BoardShape.cylinderBody.fill(fillColor(Theme.boardBox))
            BoardShape.cylinderBody.stroke(strokeColor, style: strokeStyle)
            BoardShape.cylinderRim.fill(fillColor(Theme.boardCylinderRim))
            BoardShape.cylinderRim.stroke(strokeColor, style: strokeStyle)
        case .table:
            // A plain rounded rect, sized to `boxWidth`/`boxHeight` by SwiftUI's own `Shape`
            // sizing (unlike `BoardShape.path(for:)`, whose paths are plotted in the fixed
            // 176×84 space and can't stretch) — never `BoardShape.path(for: .table)`, which this
            // case exists specifically so nothing ever calls.
            RoundedRectangle(cornerRadius: 8).fill(fillColor(Theme.boardBox))
            RoundedRectangle(cornerRadius: 8).stroke(strokeColor, style: strokeStyle)
        default:
            BoardShape.path(for: component.kind).fill(fillColor(BoardShape.fillColor(for: component.kind)))
            BoardShape.path(for: component.kind).stroke(strokeColor, style: strokeStyle)
        }
    }
```
Do **not** add a `.table` case to `BoardShape.path(for:)` itself — this `shape` case is checked
first and intercepts every table before `BoardShape.path(for:)` would ever be asked for one.

### 3d. `content`'s new `.table` case, and the row content itself

Change:
```swift
        } else {
            switch component.kind {
            case _ where Self.centeredLabelKinds.contains(component.kind):
                centeredLabelContent
            case _ where Self.embeddedNameKinds.contains(component.kind):
                embeddedNameContent
            case _ where Self.noIconKinds.contains(component.kind):
                textStack
            default:
                standardContent
            }
        }
    }
```
to:
```swift
        } else {
            switch component.kind {
            case _ where Self.centeredLabelKinds.contains(component.kind):
                centeredLabelContent
            case _ where Self.embeddedNameKinds.contains(component.kind):
                embeddedNameContent
            case _ where Self.noIconKinds.contains(component.kind):
                textStack
            case .table:
                tableRowsContent
            default:
                standardContent
            }
        }
    }
```

Right after `standardContent`'s definition, add:
```swift
    /// A table's own content: a header with its name, then one row per column, at exactly the
    /// rows `BoardGeometry.rowCenterY(ofColumnAt:in:)` implies for this same box — a 36 pt header,
    /// then 22 pt per row, hairline separators between them. Never reached for a ghost table (see
    /// `content`'s `if isGhost` branch above, unchanged).
    private var tableRowsContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(component.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(width: boxWidth, height: 36, alignment: .leading)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.boardBoxStroke).frame(height: 1) }
            ForEach(Array(component.columns.enumerated()), id: \.offset) { index, column in
                tableRow(column)
                    .overlay(alignment: .bottom) {
                        if index < component.columns.count - 1 {
                            Rectangle().fill(Theme.boardBoxStroke).frame(height: 1)
                        }
                    }
            }
        }
    }

    /// One column's row: a key mark (a filled key for a primary key, a link for a foreign key, the
    /// same glyph at zero opacity — "a blank of the same width" — for neither), the name, and the
    /// type right-aligned and dimmed. A nullable column draws its whole row at 60% opacity; a
    /// planned column's name draws in `Theme.textTertiary` instead of `Theme.textPrimary` — the
    /// same faint colour a planned part's own outline already switches to (`strokeColor`, above).
    private func tableRow(_ column: BoardColumn) -> some View {
        HStack(spacing: 6) {
            Image(systemName: column.pk ? "key.fill" : "link")
                .font(.system(size: 9))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 11, alignment: .center)
                .opacity(column.pk || column.references != nil ? 1 : 0)
            Text(column.name)
                .font(.system(size: 11.5))
                .foregroundStyle(column.planned ? Theme.textTertiary : Theme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(column.type)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(width: boxWidth, height: 22, alignment: .leading)
        .opacity(column.nullable ? 0.6 : 1)
    }
```
`BoardColumn` needs no `Identifiable` conformance — `Array(component.columns.enumerated())` keyed
by `\.offset` is enough for `ForEach`, and duplicate column names are already refused elsewhere so
this never needs to disambiguate by name.

### 3e. `BoardShape.insets(for:)`'s new `.table` case

Change:
```swift
    static func insets(for kind: ComponentKind) -> (left: CGFloat, right: CGFloat, top: CGFloat, bottom: CGFloat) {
        switch kind {
        case .database, .cache, .vectorStore, .memory: return (0, 0, 0, 0)
        case .queue: return (0, 0, 12, 12)
```
to:
```swift
    static func insets(for kind: ComponentKind) -> (left: CGFloat, right: CGFloat, top: CGFloat, bottom: CGFloat) {
        switch kind {
        case .database, .cache, .vectorStore, .memory: return (0, 0, 0, 0)
        case .table: return (0, 0, 0, 0)
        case .queue: return (0, 0, 12, 12)
```
This is what makes `heightTrimmedInset` (Task 2's table above) skip its fixed-box math for a table,
and it's also what `handles(for:)` (Task 2b) reads for a table's own handle positions — flush with
the box on every side, same as `.database`/`.host`.

### 3f. `ComponentBox.inset`'s new `.table` case

`tableRowsContent` manages its own 10 pt horizontal padding per row, so the outer wrapper in `body`
must not add a second, kind-generic one on top of it. Change:
```swift
        case _ where Self.centeredLabelKinds.contains(component.kind): return (0, 0)
        case _ where Self.embeddedNameKinds.contains(component.kind): return (0, 0)
        default: return (14, 0)
        }
    }
```
to:
```swift
        case _ where Self.centeredLabelKinds.contains(component.kind): return (0, 0)
        case _ where Self.embeddedNameKinds.contains(component.kind): return (0, 0)
        case .table: return (0, 0)
        default: return (14, 0)
        }
    }
```

**No change needed** (verify, don't edit): `BoardShape.strokeColor(for:)`, `BoardShape.fillColor(for:)`
and `BoardShape.accents(for:)` — a table not being cased in any of the three already falls through
to a sensible `default`: `Theme.boardBoxStroke`, `Theme.boardBox`, and `EmptyView()` respectively.
`BoardShape.statusDotInset(for:)` also needs no change — its `default` reads `insets(for: kind)`,
which 3e just gave `.table` a `(0, 0)` top/right, flush with the box's corner like `.host`.

### Steps

- [ ] **Step 1:** make edits 3a–3f, in order (3a and 3b first, so the file still compiles with the
  dynamic frame before the table-specific content exists; then 3c–3f).
- [ ] **Step 2:** `swift build 2>&1 | tail -1` — clean build. `swift build --build-tests 2>&1 | grep
  -E "warning:"` — empty.
- [ ] **Step 3:** `swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1` — 0 failures (this
  task touches no LinkCKit code, so this is really just confirming nothing else broke).
- [ ] **Step 4: Commit.** Stage `Sources/linkc/Board/BoardElements.swift` by name. Message:
  `feat(board): the table box draws a header and one row per column`

---

## Task 4: foreign-key lines between table rows

**Files:** Modify only `Sources/linkc/Board/BoardCanvas.swift` — see the shared-file note in
**Global Constraints** for exactly which lines this plan may touch here.

### 4a. One inserted line in `drawing`

Change:
```swift
    private var drawing: some View {
        Canvas { context, canvasSize in
            drawGrid(in: &context, size: canvasSize)
            drawFrames(in: &context)
            drawArrows(in: &context)
            if let marquee {
```
to:
```swift
    private var drawing: some View {
        Canvas { context, canvasSize in
            drawGrid(in: &context, size: canvasSize)
            drawFrames(in: &context)
            drawArrows(in: &context)
            drawForeignKeys(in: &context)
            if let marquee {
```

### 4b. The new function

Right after `drawArrows(in:)` ends (its closing `}`, immediately before the blank line and
`isMoving`'s doc comment), add:
```swift
    /// Foreign-key lines between table rows: `board.foreignKeyRoutes`' real routes, each a 1.2 pt
    /// line in `Theme.textSecondary` at 70% with a small filled arrowhead at the referenced end
    /// (`route.points.last`) and a 3 pt dot at the foreign-key end (`route.points.first` — always
    /// the source in a route `BoardRouter.foreignKeyRoutes` built, self-references included), plus
    /// `board.foreignKeyStubs` for a key whose reference isn't resolved on the board, the same line
    /// style with "→ <refTable>.<refColumn>" in 10 pt secondary text at the stub's far end. Data,
    /// like a plain arrow: hidden outright under the Control lens (they're never control flow), and
    /// — while Focus is on — drawn only when Focus keeps the key's own table visible; a resolved
    /// route additionally needs the referenced table visible too, since a stub's referenced table
    /// is by definition not even on the board for Focus to ever keep visible.
    private func drawForeignKeys(in context: inout GraphicsContext) {
        guard viewport.lens != .control else { return }
        let focusFilter = focusVisible
        let color = Theme.textSecondary.opacity(0.7)
        for (key, route) in board.foreignKeyRoutes {
            guard focusFilter?.parts.contains(key.table) ?? true, focusFilter?.parts.contains(key.refTable) ?? true else { continue }
            let screen = route.points.map { viewport.toScreen(CGPoint(x: Double($0.x), y: Double($0.y))) }
            context.stroke(roundedArrowPath(screen), with: .color(color), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
            if let head = arrowHead(screen, scale: 0.7) {
                context.fill(head, with: .color(color))
            }
            if let from = screen.first {
                context.fill(Path(ellipseIn: CGRect(x: from.x - 1.5, y: from.y - 1.5, width: 3, height: 3)), with: .color(color))
            }
        }
        for (key, stub) in board.foreignKeyStubs {
            guard focusFilter?.parts.contains(key.table) ?? true else { continue }
            let from = viewport.toScreen(CGPoint(x: Double(stub.from.x), y: Double(stub.from.y)))
            let to = viewport.toScreen(CGPoint(x: Double(stub.to.x), y: Double(stub.to.y)))
            var path = Path()
            path.move(to: from)
            path.addLine(to: to)
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
            let text = Text("→ \(key.refTable).\(key.refColumn)").font(.system(size: 10)).foregroundColor(Theme.textSecondary)
            context.draw(context.resolve(text), at: CGPoint(x: to.x + 4, y: to.y), anchor: .leading)
        }
    }

```
This reuses two existing private helpers unchanged: `roundedArrowPath(_:radius:)` (falls back to a
straight line for a 2-point route on its own) and `arrowHead(_:scale:)` (reads `points[count-2]`
and `points.last` for direction — exactly what a foreign-key route's own last two points give it).

### Steps

- [ ] **Step 1:** make edits 4a–4b.
- [ ] **Step 2:** `swift build 2>&1 | tail -1` — clean build. `swift build --build-tests 2>&1 | grep
  -E "warning:"` — empty.
- [ ] **Step 3:** `swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1` — 0 failures.
- [ ] **Step 4: Commit.** Stage `Sources/linkc/Board/BoardCanvas.swift` by name. Message:
  `feat(board): foreign-key lines draw between table rows`

---

## Hand checks (after Task 4 — no commit, no code change)

The app target has no UI tests, so this is a real, human-eye check before calling the plan done:

1. Build and launch linkC (`swift build` succeeded above; run the built app against a real project
   with a database).
2. Open (or use an existing MCP/CLI session to reach) a database's detail board. Add a `table` part
   from the new Component menu entry, then give it a few columns with an agent's `column` steps
   (`{"op": "column", "table": "<name>", "column": "<name>", ...}` — one call per column, at least
   one `pk`, one plain, and one with a `references` naming a second table's column you also add).
3. Confirm, by eye: the table's header shows its name; each row shows the right key mark (🔑/🔗/
   blank), name, and right-aligned dimmed type; a nullable column looks visibly fainter than a
   non-nullable one; hairlines separate the rows; the box is exactly as tall as its rows plus the
   header (no dead space, nothing clipped).
4. Confirm the foreign-key line lands exactly on the two rows it names — not offset above or below
   them — for both a same-board reference (a real routed line) and a reference to a table not on
   the board (a stub with its "→ table.column" label).
5. Toggle the Control lens and confirm foreign-key lines disappear; toggle Focus on the table and
   confirm a foreign-key line to a table Focus hides also disappears, and reappears once that table
   is visible again.

Report what you saw, including anything that didn't match this plan's exact geometry or colours —
don't silently patch it into a shape that "looks right" instead of what §2/§3 above actually specify.

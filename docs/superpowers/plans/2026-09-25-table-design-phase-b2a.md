# Table design, phase B2a: foreign keys, row geometry, board operations, the Supabase dump

> **For agentic workers:** work task by task, test first. Each task ends with one commit.

**Goal:** a foreign key becomes a real, routable thing — `BoardForeignKey` names it, a new
`BoardGeometry` formula finds its row, `BoardRouter` draws a real route for it (or a stub when its
target isn't on the board), and `BoardModel` publishes both alongside its ordinary arrow routes.
Three board operations the app will call — importing a parsed SQL schema, exporting the board's
tables as SQL, and replacing a table's whole column list — each become one undo step, reusing the
model's own edit path. And a Supabase project's live schema can be pulled through the user's own
`supabase` CLI, run through the login shell, with no credential ever touching linkC.

**Spec:** `docs/superpowers/specs/2026-09-25-table-design-design.md` (§1 "Foreign keys aren't
stored twice", §2's foreign-key-lines bullet, §4's "Import into the board" and the Supabase bullet
under "Import sources", §5's phase-B bullets for foreign-key routes and the Supabase dump runner).

**Depends on (already merged into `main`, and present in this worktree):**
- Phase A: `Sources/LinkCKit/Board/BoardColumn.swift` (`BoardColumn`, `BoardColumnReference`), and
  `columns` on `BoardComponent`.
- Phase B1 (merged as `feat/table-design-b1`):
  - `ComponentKind.table` (deliberately outside `ComponentKind.groups` and `.known` — the app
    can't draw one yet).
  - `BoardGeometry.size(of:)` / `rect(of:)` — a table's box size and rect, from its own columns;
    header 36, one row per column at 22 each, 8 padding, everything rounded up to the 8-pt grid.
    Every LinkCKit site that used to assume a fixed 176×84 box now asks the part its own size.
  - `BoardColumnFields`, the `column` edit step (`add`/`change`/`drop` one column), and `columns`
    on `add`/`update` (`BoardEdit.swift`, `BoardComponentFields`).
  - `BoardSchemaImport.steps(for:into:)` (`Sources/LinkCKit/Board/BoardSchemaImport.swift`) — a
    parsed SQL schema reconciled against the board's own tables, as ordinary `BoardEditStep`s.
  - `SQLSchema.tables(in:)` (`Sources/LinkCKit/SQL/SQLSchema.swift`) — a board's table-kind parts,
    ready for `SQLSchema.createStatements(for:)`.
- Board drill-down phase 1 (merged as `feat/board-drill-down`): `outside: BoardGhostSide?` and
  `detail: String?` on `BoardComponent`, and the ghost-ignoring rules `BoardEdit.swift` already
  follows (`applyUpdate`'s `outside != nil` guard, `applyColumn`'s own ghost guard).
- `Sources/LinkCKit/Config/ProcessRunner.swift` (the `ProcessRunner` protocol, faked in tests) and
  `Sources/LinkCKit/Verification/VerificationRunner.swift` (the real precedent in this codebase for
  running a command through the user's login shell: `runner.runCapturing(shell, args: ["-l", "-c",
  command], cwd:, timeout:)`, tested with a scripted `ProcessRunner`).

**Out of scope for B2a (say so, don't build it) — all of it is the app half, phase B2b, once**
**`ComponentKind.table` joins `ComponentKind.groups`:**
- Drawing a table box and its rows, and drawing foreign-key lines (real routes or stubs) between
  them.
- The column grid in the inspector.
- The Import SQL… / Export SQL… menus and panels, and running a `.sql` file the user picks.
- Adding `.table` to `ComponentKind.groups`.
- Everything under `Sources/linkc/`.

## Global Constraints

- **Where to work:** the worktree `/Users/jacobdang/Projects/linkC/.worktrees/table-design-b2a`,
  branch `feat/table-design-b2a`. Never edit, build or run git in `/Users/jacobdang/Projects/linkC`
  itself or in any other `.worktrees` folder. Never touch anything under `Sources/linkc/` — the app
  half is a later phase.
- **Test first:** write the test, add a stub so it compiles, run it and see it fail on an
  assertion (never a compile error), implement, run it and see it pass. Copy the red and green
  lines into your report.
- **Fail loud:** refuse bad input with a clear reason naming the part or table. Never swallow an
  error or silently drop a route, a stub, or an edit. Never use `try?`. If you ever add an `NSLog`,
  it must take format arguments (`NSLog("%@", x)`), never string interpolation baked into the
  format string.
- **Style:** 4-space indentation, one statement per line, `///` doc comments on every new public
  (and reused internal) declaration — match the surrounding file's voice; read a neighbouring doc
  comment before writing your own.
- **Determinism:** the same input always gives the same output. Sort anything whose order isn't
  already fixed by file order, using `.lowercased()` on ASCII input, exactly as the rest of
  `Board/` already does.
- **Build:** `swift build 2>&1 | tail -1`. `swift build --build-tests 2>&1 | grep -E "warning:"`
  must print nothing after every task.
- **Suite:** `swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1` must report 0 failures
  after every task. Main is at 1577 tests. Every existing test must stay green, **especially**
  `BoardMapTests.testEncodedMatchesTheGoldenBytesExactly` — the byte-exact golden board test.
  Nothing in this phase touches board-file encoding or decoding, so no existing test's expected
  string should need editing anywhere in this plan; if implementing a task turns out to require
  editing an existing test's assertion, stop and reconcile that against this plan before
  proceeding — it means either the plan or the code you read has drifted.
- **Commits:**
  - one per task, with the message the task gives;
  - stage files by name, never `git add -A` or `git add .`;
  - **no trailers of any kind:** no Co-Authored-By, no "Generated with", no session links;
  - the word "claude" never appears in a message, in any case;
  - never push, merge or rebase.
- **Clean finish:** no scratch files, debug prints or commented-out code. `git status --short` is
  empty when you finish each task (besides that task's own staged changes).

---

## Task 1: `BoardForeignKey`, row geometry, and `BoardRouter`'s foreign-key routes and stubs

**Files:**
- Create: `Sources/LinkCKit/Board/BoardForeignKey.swift`.
- Modify: `Sources/LinkCKit/Board/BoardGeometry.swift` — adds `rowCenterY(ofColumnAt:in:)`.
- Modify: `Sources/LinkCKit/Board/BoardRouter.swift` — adds a new "Foreign keys" section:
  `foreignKeyRoutes(for:)`, `foreignKeyStubs(for:)`, and their private helpers. No existing
  function in this file changes.
- Test: create `Tests/LinkCKitTests/BoardForeignKeyTests.swift`; modify
  `Tests/LinkCKitTests/BoardGeometryTests.swift` and `Tests/LinkCKitTests/BoardRouterTests.swift`
  (adds only — no existing test in either file is changed by this task).

**Consumes:** `BoardColumn`/`BoardColumnReference` (phase A), `ComponentKind.table`,
`BoardGeometry.size(of:)`/`rect(of:)` (phase B1).

### 1a. `BoardForeignKey`

Create `Sources/LinkCKit/Board/BoardForeignKey.swift`:

```swift
/// One column's foreign key: the table and column it's on, and the table and column it points to.
/// Derived, never stored twice — a table's foreign keys always come from its own columns'
/// `references` (see `BoardColumn`), never from a separate list on the table or a `uses` arrow.
public struct BoardForeignKey: Hashable, Sendable {
    public var table: String
    public var column: String
    public var refTable: String
    public var refColumn: String

    public init(table: String, column: String, refTable: String, refColumn: String) {
        self.table = table
        self.column = column
        self.refTable = refTable
        self.refColumn = refColumn
    }

    /// Every column with `references` on a `table`-kind part of `map`, sorted by (table, column),
    /// both lowercased — deterministic regardless of file order or casing. Includes a ghost
    /// table's own columns: this only lists what a column's `references` says, never whether
    /// anything is drawn for it — `BoardRouter.foreignKeyRoutes`/`foreignKeyStubs` decide that.
    public static func all(in map: BoardMap) -> [BoardForeignKey] {
        map.components
            .filter { $0.kind == .table }
            .flatMap { component in
                component.columns.compactMap { column -> BoardForeignKey? in
                    guard let reference = column.references else { return nil }
                    return BoardForeignKey(
                        table: component.name, column: column.name,
                        refTable: reference.table, refColumn: reference.column)
                }
            }
            .sorted { ($0.table.lowercased(), $0.column.lowercased()) < ($1.table.lowercased(), $1.column.lowercased()) }
    }
}
```

**Test** — create `Tests/LinkCKitTests/BoardForeignKeyTests.swift`:

```swift
import XCTest
@testable import LinkCKit

final class BoardForeignKeyTests: XCTestCase {
    func testAllListsEveryColumnWithAReferenceSortedByTableThenColumn() {
        var map = BoardMap()
        map.components = [
            BoardComponent(name: "Orders", kind: .table, columns: [
                BoardColumn(name: "id", type: "uuid", pk: true),
                BoardColumn(name: "customer_id", type: "bigint", references: BoardColumnReference(table: "customers", column: "id")),
            ]),
            BoardComponent(name: "accounts", kind: .table, columns: [
                BoardColumn(name: "org_id", type: "bigint", references: BoardColumnReference(table: "orgs", column: "id")),
                BoardColumn(name: "owner_id", type: "bigint", references: BoardColumnReference(table: "Orders", column: "id")),
            ]),
            BoardComponent(name: "plain", kind: .service),
        ]
        XCTAssertEqual(BoardForeignKey.all(in: map), [
            BoardForeignKey(table: "accounts", column: "org_id", refTable: "orgs", refColumn: "id"),
            BoardForeignKey(table: "accounts", column: "owner_id", refTable: "Orders", refColumn: "id"),
            BoardForeignKey(table: "Orders", column: "customer_id", refTable: "customers", refColumn: "id"),
        ])
    }

    func testATableWithNoReferencesContributesNothing() {
        var map = BoardMap()
        map.components = [BoardComponent(name: "t", kind: .table, columns: [BoardColumn(name: "id", type: "uuid", pk: true)])]
        XCTAssertEqual(BoardForeignKey.all(in: map), [])
    }

    /// A non-table kind never carries columns in practice, but the filter here is by `kind`, not
    /// by an empty-columns check — guard it explicitly so a future bug can't slip a service's
    /// stray columns into the list.
    func testANonTablePartsColumnsAreNeverListedEvenIfPresent() {
        var map = BoardMap()
        map.components = [BoardComponent(name: "svc", kind: .service, columns: [
            BoardColumn(name: "x", type: "int", references: BoardColumnReference(table: "t", column: "id")),
        ])]
        XCTAssertEqual(BoardForeignKey.all(in: map), [])
    }
}
```

### 1b. Row geometry

In `Sources/LinkCKit/Board/BoardGeometry.swift`, add right after `rect(of: component)` (the
`BoardComponent` overload) and before the private `roundUpTo8`:

```swift
    /// The vertical centre of one column's row inside a table's box: 36 for the header, 22 per
    /// row, landing on the row's own centre (half of 22). Matches `size(of:)`'s own formula
    /// exactly, so a column's drawn row and its foreign-key port always line up.
    public static func rowCenterY(ofColumnAt index: Int, in rect: BoardRect) -> Int {
        rect.y + 36 + 22 * index + 11
    }
```

**Test** — add to `Tests/LinkCKitTests/BoardGeometryTests.swift`:

```swift
    func testRowCenterYMatchesTheSizeFormula() {
        let rect = BoardRect(x: 0, y: 100, w: 176, h: 88)
        XCTAssertEqual(BoardGeometry.rowCenterY(ofColumnAt: 0, in: rect), 147)
        XCTAssertEqual(BoardGeometry.rowCenterY(ofColumnAt: 1, in: rect), 169)
        XCTAssertEqual(BoardGeometry.rowCenterY(ofColumnAt: 3, in: rect), 213)
    }
```

### 1c. `BoardRouter.foreignKeyRoutes(for:)` and `foreignKeyStubs(for:)`

In `Sources/LinkCKit/Board/BoardRouter.swift`, add a new section right after the "Public entry
point" section's `routes(for:isCancelled:)` function ends (i.e. right before the existing `// MARK:
- Ordering` line) — placement doesn't matter to the compiler (nothing here is called by
`routes(for:)`, and nothing it calls is declared after it), this is just where it reads best next
to the router's other public entry point:

```swift
    // MARK: - Foreign keys

    /// Every foreign key's own route — a key whose table and referenced table are both on the
    /// board and placed. Ports are fixed (one row's centre, on the side facing the other table),
    /// never negotiated with siblings the way an ordinary `uses` arrow's `spreadEnds` does, so
    /// each foreign key gets the router's ordinary path search (`aStar`, the same obstacles, the
    /// same margins) run once with its own two fixed ends — no new router. A self-reference never
    /// reaches the path search at all: it always draws its own fixed loop off the table's right
    /// side. A key this doesn't resolve a route for is exactly the key `foreignKeyStubs` draws a
    /// stub for instead — the two partition `BoardForeignKey.all(in:)` for a placed source table.
    public static func foreignKeyRoutes(for map: BoardMap) -> [BoardForeignKey: BoardRoute] {
        let byLowercasedName = placedByLowercasedName(map)
        guard !byLowercasedName.isEmpty else { return [:] }
        let componentBox = placedBoxByLowercasedName(map)
        let noteBoxes = map.notes.compactMap { $0.at.map(BoardGeometry.rect(ofNoteAt:)) }

        var results: [BoardForeignKey: BoardRoute] = [:]
        for key in BoardForeignKey.all(in: map) {
            guard let source = byLowercasedName[key.table.lowercased()], let sourceBox = componentBox[key.table.lowercased()],
                  let columnIndex = source.columns.firstIndex(where: { $0.name.lowercased() == key.column.lowercased() }),
                  let (target, refIndex) = resolvedReference(key, in: byLowercasedName)
            else { continue }
            let targetBox = componentBox[target.name.lowercased()]!

            if key.table.lowercased() == key.refTable.lowercased() {
                results[key] = BoardRoute(points: foreignKeySelfLoop(sourceBox, from: columnIndex, to: refIndex), bundle: nil)
                continue
            }

            let sourceSide = horizontalSide(from: sourceBox.center, to: targetBox.center)
            let targetSide = horizontalSide(from: targetBox.center, to: sourceBox.center)
            let sourcePort = foreignKeyPort(sourceBox, sourceSide, rowIndex: columnIndex)
            let targetPort = foreignKeyPort(targetBox, targetSide, rowIndex: refIndex)

            let (othersRaw, frameObstacles) = obstaclesFor(
                map: map, sourceName: source.name, targetName: target.name, sourceBox: sourceBox, targetBox: targetBox,
                componentBox: componentBox, noteBoxes: noteBoxes)
            let rawObstacles = othersRaw + [sourceBox, targetBox]
            let marginObstacles = rawObstacles.map { inflate($0, by: clearance) }
            let sourceStub = stub(sourcePort, sourceSide, avoiding: othersRaw)
            let targetStub = stub(targetPort, targetSide, avoiding: othersRaw)
            let fkId = "fk:\(key.table.lowercased()).\(key.column.lowercased())"
            let path = aStar(
                from: sourceStub, to: targetStub, rawObstacles: rawObstacles, marginObstacles: marginObstacles,
                frames: frameObstacles, avoid: [], selfId: fkId) ?? lastResort()
            results[key] = BoardRoute(points: simplify([sourcePort] + path + [targetPort]), bundle: nil)
        }
        return results
    }

    /// A 40 pt horizontal stub off the right side of the foreign-key row, for a key whose
    /// referenced table or column isn't on the board (or isn't placed) — the app labels it with
    /// the reference's own text. Never produced for a key `foreignKeyRoutes` already drew a real
    /// route for.
    public static func foreignKeyStubs(for map: BoardMap) -> [BoardForeignKey: (from: BoardPoint, to: BoardPoint)] {
        let byLowercasedName = placedByLowercasedName(map)
        let componentBox = placedBoxByLowercasedName(map)
        var results: [BoardForeignKey: (from: BoardPoint, to: BoardPoint)] = [:]
        for key in BoardForeignKey.all(in: map) {
            guard let source = byLowercasedName[key.table.lowercased()], let sourceBox = componentBox[key.table.lowercased()],
                  let columnIndex = source.columns.firstIndex(where: { $0.name.lowercased() == key.column.lowercased() })
            else { continue }
            guard resolvedReference(key, in: byLowercasedName) == nil else { continue }
            let from = BoardPoint(x: sourceBox.maxX, y: BoardGeometry.rowCenterY(ofColumnAt: columnIndex, in: sourceBox))
            results[key] = (from: from, to: BoardPoint(x: from.x + 40, y: from.y))
        }
        return results
    }

    /// Same shape as the inline dictionary `routes(for:)` builds for itself at its own top — kept
    /// as a separate, reusable helper here rather than rewiring `routes(for:)` to share it, so
    /// this task touches nothing about how ordinary arrows already route.
    private static func placedByLowercasedName(_ map: BoardMap) -> [String: BoardComponent] {
        Dictionary(uniqueKeysWithValues: map.components.compactMap { c -> (String, BoardComponent)? in
            guard c.at != nil else { return nil }
            return (c.name.lowercased(), c)
        })
    }

    private static func placedBoxByLowercasedName(_ map: BoardMap) -> [String: BoardRect] {
        Dictionary(uniqueKeysWithValues: map.components.compactMap { c -> (String, BoardRect)? in
            guard let rect = BoardGeometry.rect(of: c) else { return nil }
            return (c.name.lowercased(), rect)
        })
    }

    /// `key`'s referenced table and column, when both are on the board and placed —
    /// `byLowercasedName` is already placed-only, so this never resolves an unplaced part.
    /// Resolved means `foreignKeyRoutes` draws a route for `key`; unresolved means
    /// `foreignKeyStubs` draws a stub instead.
    private static func resolvedReference(
        _ key: BoardForeignKey, in byLowercasedName: [String: BoardComponent]
    ) -> (target: BoardComponent, columnIndex: Int)? {
        guard let target = byLowercasedName[key.refTable.lowercased()],
              let index = target.columns.firstIndex(where: { $0.name.lowercased() == key.refColumn.lowercased() })
        else { return nil }
        return (target, index)
    }

    /// Always left or right — a foreign-key port never faces top or bottom, whatever the two
    /// boxes' relative position, since a row is a horizontal band at one fixed y. A tied x-centre
    /// resolves to `.right` on both ends; a self-reference never reaches this function at all.
    private static func horizontalSide(from source: BoardPoint, to target: BoardPoint) -> Side {
        target.x >= source.x ? .right : .left
    }

    private static func foreignKeyPort(_ box: BoardRect, _ side: Side, rowIndex: Int) -> BoardPoint {
        BoardPoint(x: side == .left ? box.minX : box.maxX, y: BoardGeometry.rowCenterY(ofColumnAt: rowIndex, in: box))
    }

    /// A self-reference's own fixed loop: out the FK row on the table's right side, 24 pt further
    /// right, then back in at the referenced row — never through the path search, since both ends
    /// are always on the very box a self-reference never actually leaves. Two points, not four,
    /// when the two rows coincide — still a visible loop, never a zero-length one collapsed onto a
    /// single point off the box.
    private static func foreignKeySelfLoop(_ box: BoardRect, from rowIndex: Int, to refRowIndex: Int) -> [BoardPoint] {
        let rightX = box.maxX
        let outX = rightX + 24
        let fromY = BoardGeometry.rowCenterY(ofColumnAt: rowIndex, in: box)
        let toY = BoardGeometry.rowCenterY(ofColumnAt: refRowIndex, in: box)
        guard fromY != toY else { return [BoardPoint(x: rightX, y: fromY), BoardPoint(x: outX, y: fromY)] }
        return [
            BoardPoint(x: rightX, y: fromY),
            BoardPoint(x: outX, y: fromY),
            BoardPoint(x: outX, y: toY),
            BoardPoint(x: rightX, y: toY),
        ]
    }
```

This reuses, unchanged, five `private` members that already exist in this file: the `Side` enum,
`stub(_:_:avoiding:)`, `obstaclesFor(map:sourceName:targetName:sourceBox:targetBox:componentBox:noteBoxes:)`,
`inflate(_:by:)`, `aStar(from:to:rawObstacles:marginObstacles:frames:avoid:selfId:)`, `simplify(_:)`
and `lastResort()` — all declared `private static` in the same type, so they're visible here
without any signature change. `clearance` is `public static let clearance = 12`, already visible.

**Test** — add to `Tests/LinkCKitTests/BoardRouterTests.swift` (this file already has private
`segments(_:)` and `crosses(_:_:_:)` helpers at the top of the class — reuse them):

```swift
    // MARK: - Foreign keys

    func testForeignKeyPortsSitAtExactRowCentresOnTheFacingSides() throws {
        var m = BoardMap()
        m.components = [
            BoardComponent(name: "orders", kind: .table, at: BoardPoint(x: 0, y: 0), columns: [
                BoardColumn(name: "id", type: "uuid", pk: true),
                BoardColumn(name: "cust_id", type: "bigint", references: BoardColumnReference(table: "customers", column: "id")),
            ]),
            BoardComponent(name: "customers", kind: .table, at: BoardPoint(x: 400, y: 0), columns: [
                BoardColumn(name: "id", type: "uuid", pk: true),
            ]),
        ]
        let ordersBox = try XCTUnwrap(BoardGeometry.rect(of: m.components[0]))
        let customersBox = try XCTUnwrap(BoardGeometry.rect(of: m.components[1]))
        XCTAssertEqual(ordersBox, BoardRect(x: 0, y: 0, w: 176, h: 88))
        XCTAssertEqual(customersBox, BoardRect(x: 400, y: 0, w: 176, h: 72))

        let key = BoardForeignKey(table: "orders", column: "cust_id", refTable: "customers", refColumn: "id")
        let route = try XCTUnwrap(BoardRouter.foreignKeyRoutes(for: m)[key])
        XCTAssertEqual(route.points.first, BoardPoint(x: 176, y: 69), "orders' right side, the cust_id row")
        XCTAssertEqual(route.points.last, BoardPoint(x: 400, y: 47), "customers' left side, the id row")
        for (a, b) in zip(route.points, route.points.dropFirst()) {
            XCTAssertTrue(a.x == b.x || a.y == b.y, "orthogonal")
        }
        XCTAssertNil(BoardRouter.foreignKeyStubs(for: m)[key], "resolved: a route, not a stub")
    }

    func testForeignKeyRouteBendsAroundABoxBetweenTheTables() throws {
        var m = BoardMap()
        m.components = [
            BoardComponent(name: "orders", kind: .table, at: BoardPoint(x: 0, y: 0), columns: [
                BoardColumn(name: "id", type: "uuid", pk: true),
                BoardColumn(name: "cust_id", type: "bigint", references: BoardColumnReference(table: "customers", column: "id")),
            ]),
            BoardComponent(name: "customers", kind: .table, at: BoardPoint(x: 400, y: 0), columns: [
                BoardColumn(name: "id", type: "uuid", pk: true),
            ]),
            BoardComponent(name: "wall", kind: .service, at: BoardPoint(x: 200, y: 0)),
        ]
        let wallBox = try XCTUnwrap(BoardGeometry.rect(of: m.components[2]))
        XCTAssertEqual(wallBox, BoardRect(x: 200, y: 0, w: 176, h: 84), "spans both rows' y (47 and 69), blocking a direct line")

        let key = BoardForeignKey(table: "orders", column: "cust_id", refTable: "customers", refColumn: "id")
        let route = try XCTUnwrap(BoardRouter.foreignKeyRoutes(for: m)[key])
        XCTAssertEqual(route.points.first, BoardPoint(x: 176, y: 69))
        XCTAssertEqual(route.points.last, BoardPoint(x: 400, y: 47))
        for (a, b) in zip(route.points, route.points.dropFirst()) {
            XCTAssertFalse(crosses(a, b, wallBox), "\(a)->\(b) crosses the wall")
        }
    }

    func testForeignKeySelfReferenceLoopsOutTheRightSide() throws {
        var m = BoardMap()
        m.components = [
            BoardComponent(name: "categories", kind: .table, at: BoardPoint(x: 0, y: 0), columns: [
                BoardColumn(name: "id", type: "uuid", pk: true),
                BoardColumn(name: "parent_id", type: "uuid", references: BoardColumnReference(table: "categories", column: "id")),
            ]),
        ]
        let box = try XCTUnwrap(BoardGeometry.rect(of: m.components[0]))
        XCTAssertEqual(box, BoardRect(x: 0, y: 0, w: 176, h: 88))
        let fromY = BoardGeometry.rowCenterY(ofColumnAt: 1, in: box)
        let toY = BoardGeometry.rowCenterY(ofColumnAt: 0, in: box)

        let key = BoardForeignKey(table: "categories", column: "parent_id", refTable: "categories", refColumn: "id")
        let route = try XCTUnwrap(BoardRouter.foreignKeyRoutes(for: m)[key])
        XCTAssertEqual(route.points, [
            BoardPoint(x: box.maxX, y: fromY),
            BoardPoint(x: box.maxX + 24, y: fromY),
            BoardPoint(x: box.maxX + 24, y: toY),
            BoardPoint(x: box.maxX, y: toY),
        ])
        XCTAssertTrue(route.points.allSatisfy { $0.x >= box.maxX }, "never crosses back into the table")
        XCTAssertNil(BoardRouter.foreignKeyStubs(for: m)[key])
    }

    func testAMissingReferencedTableGivesAStubAndNoRoute() throws {
        var m = BoardMap()
        m.components = [
            BoardComponent(name: "orders", kind: .table, at: BoardPoint(x: 0, y: 0), columns: [
                BoardColumn(name: "id", type: "uuid", pk: true),
                BoardColumn(name: "cust_id", type: "bigint", references: BoardColumnReference(table: "customers", column: "id")),
            ]),
        ]
        let box = try XCTUnwrap(BoardGeometry.rect(of: m.components[0]))
        let key = BoardForeignKey(table: "orders", column: "cust_id", refTable: "customers", refColumn: "id")

        XCTAssertNil(BoardRouter.foreignKeyRoutes(for: m)[key], "customers isn't on the board")
        let stub = try XCTUnwrap(BoardRouter.foreignKeyStubs(for: m)[key])
        let y = BoardGeometry.rowCenterY(ofColumnAt: 1, in: box)
        XCTAssertEqual(stub.from, BoardPoint(x: box.maxX, y: y))
        XCTAssertEqual(stub.to, BoardPoint(x: box.maxX + 40, y: y))
    }

    func testAPresentTableWithAMissingReferencedColumnAlsoGivesAStub() throws {
        var m = BoardMap()
        m.components = [
            BoardComponent(name: "orders", kind: .table, at: BoardPoint(x: 0, y: 0), columns: [
                BoardColumn(name: "id", type: "uuid", pk: true),
                BoardColumn(name: "cust_id", type: "bigint", references: BoardColumnReference(table: "customers", column: "ghost_id")),
            ]),
            BoardComponent(name: "customers", kind: .table, at: BoardPoint(x: 400, y: 0), columns: [
                BoardColumn(name: "id", type: "uuid", pk: true),
            ]),
        ]
        let key = BoardForeignKey(table: "orders", column: "cust_id", refTable: "customers", refColumn: "ghost_id")
        XCTAssertNil(BoardRouter.foreignKeyRoutes(for: m)[key])
        XCTAssertNotNil(BoardRouter.foreignKeyStubs(for: m)[key])
    }

    /// An unplaced part (no `at` yet) counts the same as one that isn't on the board at all: there
    /// is no row to point a route at, so this is a stub too, never a dangling, undrawn key.
    func testAnUnplacedReferencedTableAlsoGivesAStub() throws {
        var m = BoardMap()
        m.components = [
            BoardComponent(name: "orders", kind: .table, at: BoardPoint(x: 0, y: 0), columns: [
                BoardColumn(name: "id", type: "uuid", pk: true),
                BoardColumn(name: "cust_id", type: "bigint", references: BoardColumnReference(table: "customers", column: "id")),
            ]),
            BoardComponent(name: "customers", kind: .table, columns: [BoardColumn(name: "id", type: "uuid", pk: true)]),
        ]
        let key = BoardForeignKey(table: "orders", column: "cust_id", refTable: "customers", refColumn: "id")
        XCTAssertNil(BoardRouter.foreignKeyRoutes(for: m)[key])
        XCTAssertNotNil(BoardRouter.foreignKeyStubs(for: m)[key])
    }

    func testForeignKeyRoutesAndStubsAreDeterministic() throws {
        let decoded = try BoardMap.decode(Data(#"""
        { "version": 2, "places": { "Not placed": {
          "orders": {"kind":"table","columns":[
            {"name":"id","type":"uuid","pk":true},
            {"name":"cust_id","type":"bigint","references":"customers.id"}
          ]},
          "customers": {"kind":"table","columns":[{"name":"id","type":"uuid","pk":true}]}
        } } }
        """#.utf8))
        let arranged = BoardLayout.arranged(decoded)
        XCTAssertEqual(BoardRouter.foreignKeyRoutes(for: arranged), BoardRouter.foreignKeyRoutes(for: arranged))
        let firstStubs = BoardRouter.foreignKeyStubs(for: arranged).mapValues { [$0.from, $0.to] }
        let secondStubs = BoardRouter.foreignKeyStubs(for: arranged).mapValues { [$0.from, $0.to] }
        XCTAssertEqual(firstStubs, secondStubs)
    }
```

### Steps

- [ ] **Step 1: Write the failing tests.** Add every test above. Add `BoardForeignKey`,
  `BoardGeometry.rowCenterY(ofColumnAt:in:)`, and `BoardRouter.foreignKeyRoutes(for:)` /
  `foreignKeyStubs(for:)` (the latter two can `return [:]` as a stub) so the suite compiles. Run
  `swift test --filter "BoardForeignKeyTests|BoardGeometryTests|BoardRouterTests"` and confirm the
  new tests fail on **assertions**, not compile errors.
- [ ] **Step 2: Implement** 1a–1c in full.
- [ ] **Step 3: Run** the same filtered command, see it pass, then the full suite
  (`swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1`) and the warnings check
  (`swift build --build-tests 2>&1 | grep -E "warning:"`, must be empty).
- [ ] **Step 4: Commit.** Stage by name every file this task touched. Message:
  `feat(board): foreign-key routes and stubs from a column's references`

---

## Task 2: `BoardModel` publishes foreign-key routes and stubs

**Files:**
- Modify: `Sources/LinkCKit/Board/BoardModel.swift` — two new public properties, `routingTask`'s
  type, `routesAndLabels(for:isCancelled:)`'s return type and body, `recomputeRoutes()`'s body.
- Test: modify `Tests/LinkCKitTests/BoardModelTests.swift` (adds only).

**Consumes:** `BoardForeignKey`, `BoardRouter.foreignKeyRoutes(for:)` / `foreignKeyStubs(for:)`
(Task 1).

**Do NOT change:** the existing `routes`/`labelRects` properties, or any other line of
`recomputeRoutes()`/`routesAndLabels(for:isCancelled:)` beyond what's shown below. Two existing
call sites already pattern-match this tuple by label — `BoardModelTests.swift`'s
`testRoutesAndLabelsSkipsLabellingOnceCancelledBetweenRouterAndLabels` and
`BoardLabelsTests.swift`'s `testAnUnlabelledBusGetsAPlacedPill` both read only `.routes` /
`.labelRects` off the result — adding two more named elements to the tuple doesn't touch either of
them; leave them exactly as they are.

### 2a. Two new published properties

In `Sources/LinkCKit/Board/BoardModel.swift`, right after the existing declaration of `labelRects`:

```swift
    public private(set) var routes: [ArrowKey: BoardRoute] = [:]
    /// Where each labelled arrow's pill goes; kept in step with `routes`, the same recompute.
    public private(set) var labelRects: [ArrowKey: BoardRect] = [:]
```

add:

```swift
    /// One route per foreign key whose table and referenced table are both on the board and
    /// placed; kept in step with `routes`, the same recompute.
    public private(set) var foreignKeyRoutes: [BoardForeignKey: BoardRoute] = [:]
    /// A 40 pt stub for a foreign key whose referenced table or column isn't on the board (or
    /// isn't placed). `foreignKeyRoutes` and this partition every key `BoardForeignKey.all(in:)`
    /// lists for a placed source table — see `BoardRouter.foreignKeyRoutes`/`foreignKeyStubs`.
    public private(set) var foreignKeyStubs: [BoardForeignKey: (from: BoardPoint, to: BoardPoint)] = [:]
```

### 2b. `routingTask`'s type

Change:

```swift
    @ObservationIgnored var routingTask: Task<(routes: [ArrowKey: BoardRoute], labelRects: [ArrowKey: BoardRect])?, Never>?
```

to:

```swift
    @ObservationIgnored var routingTask: Task<(
        routes: [ArrowKey: BoardRoute], labelRects: [ArrowKey: BoardRect],
        foreignKeyRoutes: [BoardForeignKey: BoardRoute], foreignKeyStubs: [BoardForeignKey: (from: BoardPoint, to: BoardPoint)]
    )?, Never>?
```

### 2c. `recomputeRoutes()` and `routesAndLabels(for:isCancelled:)`

Change:

```swift
    @discardableResult
    func recomputeRoutes() -> Task<Void, Never> {
        routingGeneration += 1
        let scheduled = routingGeneration
        let snapshot = map
        routingTask?.cancel()
        let detached = Task.detached {
            Self.routesAndLabels(for: snapshot)
        }
        routingTask = detached
        return Task { @MainActor [weak self] in
            guard let result = await detached.value, !Task.isCancelled else { return }
            guard let self, self.routingGeneration == scheduled else { return }
            self.routes = result.routes
            self.labelRects = result.labelRects
        }
    }
```

to:

```swift
    @discardableResult
    func recomputeRoutes() -> Task<Void, Never> {
        routingGeneration += 1
        let scheduled = routingGeneration
        let snapshot = map
        routingTask?.cancel()
        let detached = Task.detached {
            Self.routesAndLabels(for: snapshot)
        }
        routingTask = detached
        return Task { @MainActor [weak self] in
            guard let result = await detached.value, !Task.isCancelled else { return }
            guard let self, self.routingGeneration == scheduled else { return }
            self.routes = result.routes
            self.labelRects = result.labelRects
            self.foreignKeyRoutes = result.foreignKeyRoutes
            self.foreignKeyStubs = result.foreignKeyStubs
        }
    }
```

Change the doc comment right above `routesAndLabels` from:

```swift
    /// The pure computation `recomputeRoutes()` runs off the main actor: every arrow's route, then
    /// every labelled arrow's pill, from the same routes. Routing is the pricier of the two
    /// (measured at 7–43 ms; labelling at 0.3 ms) and checks `isCancelled` itself, between arrows;
    /// `isCancelled` is checked again once routing returns, before the labelling pass, in case
    /// cancellation lands in the gap between them — cheap insurance either way against doing work
    /// for a result about to be dropped. Internal, not private, and `isCancelled` is injectable,
    /// so a test can drive it deterministically instead of racing real `Task` cancellation.
```

to:

```swift
    /// The pure computation `recomputeRoutes()` runs off the main actor: every arrow's route, then
    /// every labelled arrow's pill, then every foreign key's own route or stub — all from the same
    /// map. Routing is the pricier of the phases (measured at 7–43 ms; labelling at 0.3 ms) and
    /// checks `isCancelled` itself, between arrows; `isCancelled` is checked again once routing
    /// returns, before the labelling pass, and a third time before the foreign-key pass, in case
    /// cancellation lands in one of the gaps — cheap insurance either way against doing work for a
    /// result about to be dropped. Internal, not private, and `isCancelled` is injectable, so a
    /// test can drive it deterministically instead of racing real `Task` cancellation.
```

Change the function itself from:

```swift
    nonisolated static func routesAndLabels(
        for map: BoardMap, isCancelled: () -> Bool = { Task.isCancelled }
    ) -> (routes: [ArrowKey: BoardRoute], labelRects: [ArrowKey: BoardRect])? {
        let routes = BoardRouter.routes(for: map)
        guard !isCancelled() else { return nil }
        // The placer's text is the arrow's full pill — label and width combined, or width alone
        // for an unlabelled bus — never the router's own bundling label, which stays `arrow.label`
        // so bundling is unaffected by what the pill happens to show.
        var labelOf: [ArrowKey: String] = [:]
        for component in map.components {
            for (target, arrow) in component.uses {
                guard let pill = BoardLabels.pillText(for: arrow) else { continue }
                labelOf[ArrowKey(from: component.name, to: target)] = pill
            }
        }
        let labelRects = BoardLabels.placed(routes: routes, labels: labelOf, obstacles: BoardLabels.obstacles(for: map))
        return (routes, labelRects)
    }
```

to:

```swift
    nonisolated static func routesAndLabels(
        for map: BoardMap, isCancelled: () -> Bool = { Task.isCancelled }
    ) -> (
        routes: [ArrowKey: BoardRoute], labelRects: [ArrowKey: BoardRect],
        foreignKeyRoutes: [BoardForeignKey: BoardRoute], foreignKeyStubs: [BoardForeignKey: (from: BoardPoint, to: BoardPoint)]
    )? {
        let routes = BoardRouter.routes(for: map)
        guard !isCancelled() else { return nil }
        // The placer's text is the arrow's full pill — label and width combined, or width alone
        // for an unlabelled bus — never the router's own bundling label, which stays `arrow.label`
        // so bundling is unaffected by what the pill happens to show.
        var labelOf: [ArrowKey: String] = [:]
        for component in map.components {
            for (target, arrow) in component.uses {
                guard let pill = BoardLabels.pillText(for: arrow) else { continue }
                labelOf[ArrowKey(from: component.name, to: target)] = pill
            }
        }
        let labelRects = BoardLabels.placed(routes: routes, labels: labelOf, obstacles: BoardLabels.obstacles(for: map))
        guard !isCancelled() else { return nil }
        return (routes, labelRects, BoardRouter.foreignKeyRoutes(for: map), BoardRouter.foreignKeyStubs(for: map))
    }
```

> If Swift's strict-concurrency checker objects to the `[BoardForeignKey: (from: BoardPoint, to:
> BoardPoint)]` dictionary crossing the `Task.detached` boundary (tuples of `Sendable` types are
> implicitly `Sendable`, so this is expected to just work) — do not change the public
> `foreignKeyStubs` signature to fix it; only that value needs to stay exactly what §3's foreign-key
> design calls for. If it truly doesn't compile, wrap the pair in a tiny private `Sendable` struct
> at the crossing point and convert back to the tuple in `recomputeRoutes()`, and say so in your
> report.

**Test** — add to `Tests/LinkCKitTests/BoardModelTests.swift` (reuses the existing `fresh()`
helper already in this file):

```swift
    func testForeignKeyRoutesArePublishedAlongsideOrdinaryRoutes() async throws {
        let board = fresh()
        board.map.components = [
            BoardComponent(name: "orders", kind: .table, at: BoardPoint(x: 0, y: 0), columns: [
                BoardColumn(name: "id", type: "uuid", pk: true),
                BoardColumn(name: "cust_id", type: "bigint", references: BoardColumnReference(table: "customers", column: "id")),
            ]),
            BoardComponent(name: "customers", kind: .table, at: BoardPoint(x: 400, y: 0), columns: [
                BoardColumn(name: "id", type: "uuid", pk: true),
            ]),
        ]
        await board.recomputeRoutes().value
        let key = BoardForeignKey(table: "orders", column: "cust_id", refTable: "customers", refColumn: "id")
        XCTAssertEqual(board.foreignKeyRoutes[key], BoardRouter.foreignKeyRoutes(for: board.map)[key])
        XCTAssertNotNil(board.foreignKeyRoutes[key])
        XCTAssertTrue(board.foreignKeyStubs.isEmpty)
    }

    func testForeignKeyStubsArePublishedForAMissingReference() async throws {
        let board = fresh()
        board.map.components = [
            BoardComponent(name: "orders", kind: .table, at: BoardPoint(x: 0, y: 0), columns: [
                BoardColumn(name: "id", type: "uuid", pk: true),
                BoardColumn(name: "cust_id", type: "bigint", references: BoardColumnReference(table: "customers", column: "id")),
            ]),
        ]
        await board.recomputeRoutes().value
        let key = BoardForeignKey(table: "orders", column: "cust_id", refTable: "customers", refColumn: "id")
        XCTAssertTrue(board.foreignKeyRoutes.isEmpty)
        XCTAssertNotNil(board.foreignKeyStubs[key])
    }
```

`board.map` is `public internal(set)`, so `@testable import LinkCKit` can assign it directly — this
is fixture setup for testing that `recomputeRoutes()` wires the new properties through, not a test
of any edit or undo path, so it deliberately bypasses `edit(_:)`.

### Steps

- [ ] **Step 1: Write the failing tests.** Add both tests above. Make the stub changes to
  `routingTask`'s type, `routesAndLabels`, and `recomputeRoutes()` needed to compile (returning
  empty dictionaries for the two new elements is fine for a first pass). Run
  `swift test --filter "BoardModelTests|BoardLabelsTests"` and confirm the two new tests fail on
  assertions, and that `testRoutesAndLabelsSkipsLabellingOnceCancelledBetweenRouterAndLabels` and
  `testAnUnlabelledBusGetsAPlacedPill` still pass unchanged.
- [ ] **Step 2: Implement** 2a–2c in full.
- [ ] **Step 3: Run** the same filtered command, see everything pass, then the full suite and the
  warnings check.
- [ ] **Step 4: Commit.** Stage by name. Message:
  `feat(board): the model publishes foreign-key routes and stubs`

---

## Task 3: Board operations — import, export, and the column grid's save, each one undo step

**Files:**
- Modify: `Sources/LinkCKit/Board/BoardSchemaImport.swift` — adds `Summary` and `plan(for:into:)`;
  `steps(for:into:)` becomes `plan(for:into:).steps`, with its own behaviour completely unchanged.
- Modify: `Sources/LinkCKit/Board/BoardModel.swift` — adds a private `editOrThrow(_:)` hook next to
  `edit(_:)`, and a new "Schema (tables)" section: `importSchema(_:)`, `exportSchemaSQL()`,
  `setColumns(of:to:)`.
- Test: modify `Tests/LinkCKitTests/BoardSchemaImportTests.swift` and
  `Tests/LinkCKitTests/BoardModelTests.swift` (adds only — no existing test in either file changes).

**Consumes:** `BoardSchemaImport.steps(for:into:)`, `SQLSchema.tables(in:)`,
`SQLSchema.createStatements(for:)`, `BoardEdit.apply`, `BoardComponentFields`, `BoardEditStep`,
`BoardEditRefusal` (all phase B1 or earlier, unchanged).

### 3a. `BoardSchemaImport.Summary` and `plan(for:into:)`

`steps(for:into:)`'s own reconciliation logic already knows, as it builds each step, which of
three things it's doing: adding a table the board didn't have, updating one the SQL still names, or
marking planned one the SQL no longer names. Rather than re-deriving that classification a second
time from the finished `[BoardEditStep]` list (which would have to reverse-engineer "why" from two
steps that are both spelled `.update`), `plan(for:into:)` counts as it goes, once, and
`steps(for:into:)` becomes a one-line wrapper around it — so the two can never disagree, and every
existing test of `steps(for:into:)` keeps passing unchanged, because its behaviour hasn't changed
at all.

Replace the whole current file (`Sources/LinkCKit/Board/BoardSchemaImport.swift`) with:

```swift
import Foundation

/// Turns a parsed SQL schema into ordinary `BoardEditStep`s, so importing a database's schema is
/// one call to `BoardEdit.apply`. Nothing is deleted: design-only tables and columns stay planned.
public enum BoardSchemaImport {
    /// What one import did: how many tables were newly added, how many existing tables were
    /// reconciled with the SQL, how many board-only tables were marked planned because the SQL no
    /// longer names them, and how many SQL constructs the parser itself already reported as not
    /// kept (`skipped`) or not modelled (`notModelled`) — carried through unchanged from
    /// `SQLSchema.Parsed`, since import neither fixes nor hides either list.
    public struct Summary: Equatable, Sendable {
        public var added: Int
        public var updated: Int
        public var markedPlanned: Int
        public var skipped: Int
        public var notModelled: Int

        public init(added: Int, updated: Int, markedPlanned: Int, skipped: Int, notModelled: Int) {
            self.added = added
            self.updated = updated
            self.markedPlanned = markedPlanned
            self.skipped = skipped
            self.notModelled = notModelled
        }
    }

    /// `parsed`'s tables reconciled against `map`'s own `.table`-kind parts, and what that
    /// reconciliation did. For each table `parsed` names, in `parsed.tables`' own order:
    /// - a **non-ghost** existing part by that name, kind `.table`: an `update` step whose
    ///   `columns` is the SQL's columns (not planned) followed by every column already on the
    ///   part whose name isn't among the SQL's (forced planned) — counted as `updated`;
    /// - otherwise: an `add` step, kind `.table`, the SQL's columns exactly — counted as `added`.
    /// Then, for every **non-ghost**, `.table`-kind part already on the board that no parsed table
    /// matched (sorted by lowercased name): an `update` step marking it, and every one of its own
    /// columns, planned — counted as `markedPlanned`. Ghost components (`outside != nil`) are left
    /// alone entirely — never matched against, never swept.
    public static func plan(for parsed: SQLSchema.Parsed, into map: BoardMap) -> (steps: [BoardEditStep], summary: Summary) {
        var result: [BoardEditStep] = []
        var added = 0
        var updated = 0
        var markedPlanned = 0
        let byLowercasedName = Dictionary(
            uniqueKeysWithValues: map.components
                .filter { $0.outside == nil }
                .map { ($0.name.lowercased(), $0) })
        var matchedNames: Set<String> = []

        for table in parsed.tables {
            let key = table.name.lowercased()
            if let existing = byLowercasedName[key], existing.kind == .table {
                matchedNames.insert(key)
                let databaseNames = Set(table.columns.map { $0.name.lowercased() })
                let designOnly = existing.columns
                    .filter { !databaseNames.contains($0.name.lowercased()) }
                    .map { column -> BoardColumn in
                        var plannedColumn = column
                        plannedColumn.planned = true
                        return plannedColumn
                    }
                let fields = BoardComponentFields(
                    planned: false,
                    columns: table.columns + designOnly)
                result.append(.update(existing.name, fields, place: nil, rename: nil))
                updated += 1
            } else {
                let fields = BoardComponentFields(kind: .table, columns: table.columns)
                result.append(.add(table.name, fields, place: nil))
                added += 1
            }
        }

        let missing = map.components
            .filter {
                $0.kind == .table &&
                    $0.outside == nil &&
                    !matchedNames.contains($0.name.lowercased())
            }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
        for component in missing {
            let plannedColumns = component.columns.map { column -> BoardColumn in
                var plannedColumn = column
                plannedColumn.planned = true
                return plannedColumn
            }
            let fields = BoardComponentFields(planned: true, columns: plannedColumns)
            result.append(.update(component.name, fields, place: nil, rename: nil))
            markedPlanned += 1
        }

        let summary = Summary(
            added: added, updated: updated, markedPlanned: markedPlanned,
            skipped: parsed.skipped.count, notModelled: parsed.notModelled.count)
        return (result, summary)
    }

    /// `plan(for:into:).steps` — kept as its own entry point since it's what an import actually
    /// applies; `BoardModel.importSchema` wants the summary alongside it, from the same pass.
    public static func steps(for parsed: SQLSchema.Parsed, into map: BoardMap) -> [BoardEditStep] {
        plan(for: parsed, into: map).steps
    }
}
```

**Test** — add to `Tests/LinkCKitTests/BoardSchemaImportTests.swift` (reuses the file's own private
`apply(_:to:)` helper, already defined at its top: `try BoardEdit.apply(BoardEdit.steps(from:
json), to: map)`):

```swift
    func testPlanCountsANewlyAddedTable() throws {
        let parsed = try SQLSchema.parse("create table orgs (id bigint primary key);")
        let (_, summary) = BoardSchemaImport.plan(for: parsed, into: .empty)
        XCTAssertEqual(summary, BoardSchemaImport.Summary(added: 1, updated: 0, markedPlanned: 0, skipped: 0, notModelled: 0))
    }

    func testPlanCountsUpdatedAndMarkedPlannedAndStepsMatchesPlan() throws {
        let parsed = try SQLSchema.parse("create table orgs (id bigint primary key);")
        var map = try BoardEdit.apply(BoardSchemaImport.steps(for: parsed, into: .empty), to: .empty).map
        map = try apply([
            ["op": "column", "table": "orgs", "column": "notes", "set": ["type": "text"]],
            ["add": "wishlist", "kind": "table", "columns": [["name": "id", "type": "uuid"]]],
        ], to: map).map

        let (steps, summary) = BoardSchemaImport.plan(for: parsed, into: map)
        XCTAssertEqual(summary, BoardSchemaImport.Summary(added: 0, updated: 1, markedPlanned: 1, skipped: 0, notModelled: 0))
        XCTAssertEqual(steps, BoardSchemaImport.steps(for: parsed, into: map), "steps(for:into:) is exactly plan(for:into:).steps")
    }

    func testPlanCarriesTheParsersOwnSkippedAndNotModelledCounts() throws {
        let parsed = try SQLSchema.parse("""
        create table orgs (id bigint primary key, name text, check (name <> ''));
        create index orgs_name_idx on orgs (name);
        """)
        XCTAssertEqual(parsed.notModelled.count, 1)
        XCTAssertEqual(parsed.skipped.count, 1)
        let (_, summary) = BoardSchemaImport.plan(for: parsed, into: .empty)
        XCTAssertEqual(summary.skipped, 1)
        XCTAssertEqual(summary.notModelled, 1)
    }
```

### 3b. `BoardModel.editOrThrow(_:)`

In `Sources/LinkCKit/Board/BoardModel.swift`, right after `edit(_:)` and before `refuse(_:)`:

```swift
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
```

add:

```swift
    /// Like `edit(_:)`, but `change` may throw instead of returning `false` — nothing is applied
    /// and no undo step is recorded when it does, exactly as when `edit(_:)`'s own closure returns
    /// `false` (including while the board is locked, when `edit(_:)` never even calls `change` —
    /// a caller that must react differently while locked checks `isLocked` itself). The thrown
    /// error's message becomes `refusal` too, so the board's refusal banner keeps working for a
    /// throwing edit exactly as for every other one, and the error is also rethrown so a caller
    /// with its own place to show it (an import summary, a column-grid save) doesn't have to poll
    /// `refusal` instead.
    func editOrThrow(_ change: (inout BoardMap) throws -> Void) throws {
        var thrown: Error?
        edit { current in
            let before = current
            do {
                try change(&current)
            } catch {
                thrown = error
                return false
            }
            return current != before
        }
        if let thrown {
            refusal = message(for: thrown)
            throw thrown
        }
    }
```

### 3c. `importSchema`, `exportSchemaSQL`, `setColumns`

Still in `Sources/LinkCKit/Board/BoardModel.swift`. Add a new section right after `tidyUp()`'s
closing brace and before the existing `// MARK: - Hooks the spatial edits share` line:

```swift
    // MARK: - Schema (tables)

    /// Reconciles a parsed SQL schema with the board's own tables, as one undo step —
    /// `BoardEdit`'s own `add`/`update` steps (`BoardSchemaImport.plan(for:into:)`, which
    /// `steps(for:into:)` is defined in terms of), the same transformation an agent's `columns`
    /// edit already goes through, so a table-name clash or any other refusal `BoardEdit.apply`
    /// would give an agent is given here too. Nothing is written to disk directly: the change
    /// lands in `map` exactly as any other edit does, and the model's own scheduled write picks
    /// it up. A schema with nothing to reconcile against this board changes nothing and leaves no
    /// undo step, exactly as `tidyUp()` does when the map is already arranged.
    @discardableResult
    public func importSchema(_ parsed: SQLSchema.Parsed) throws -> BoardSchemaImport.Summary {
        let (steps, summary) = BoardSchemaImport.plan(for: parsed, into: map)
        try editOrThrow { current in
            current = try BoardEdit.apply(steps, to: current).map
        }
        return summary
    }

    /// The current board's tables as CREATE TABLE SQL, in foreign-key order. Pure: nothing is
    /// edited, nothing is written.
    public func exportSchemaSQL() -> String {
        SQLSchema.createStatements(for: SQLSchema.tables(in: map))
    }

    /// Replaces one table's whole column list, as one undo step — the app's column-grid save.
    /// Refuses with the board-file decoder's reason for a blank name or type, a duplicate name,
    /// or a reference with a blank table or column. Applying the ordinary `update … columns`
    /// step also refuses a part that isn't a table or that comes from the overview (a ghost).
    public func setColumns(of table: String, to columns: [BoardColumn]) throws {
        let step = BoardEditStep.update(table, BoardComponentFields(columns: columns), place: nil, rename: nil)
        try editOrThrow { current in
            do {
                try BoardColumn.validate(columns, context: "\"\(table)\"")
            } catch let error as LinkCError {
                throw BoardEditRefusal(step: 0, reason: error.errorDescription ?? "\(error)")
            }
            do {
                current = try BoardEdit.apply([step], to: current).map
            } catch let refusal as BoardEditRefusal {
                throw BoardEditRefusal(step: 0, reason: refusal.reason)
            }
        }
    }
```

`BoardEditRefusal(step: 0, ...)` gives a plain reason with no "step N:" prefix in its
`.description` (`step > 0 ? "step \(step): \(reason)" : reason`) — right for a call that isn't
part of a numbered list of steps.

**Test** — add to `Tests/LinkCKitTests/BoardModelTests.swift`:

```swift
    // MARK: - Schema (tables)

    func testImportSchemaAddsANewTableAsOneUndoStep() throws {
        let board = fresh()
        let parsed = try SQLSchema.parse("create table orgs (id bigint primary key, name text not null);")
        XCTAssertFalse(board.canUndo)
        let summary = try board.importSchema(parsed)
        XCTAssertEqual(summary, BoardSchemaImport.Summary(added: 1, updated: 0, markedPlanned: 0, skipped: 0, notModelled: 0))
        let orgs = try XCTUnwrap(board.map.components.first { $0.name == "orgs" })
        XCTAssertEqual(orgs.kind, .table)
        XCTAssertEqual(orgs.columns, parsed.tables[0].columns)
        XCTAssertTrue(board.canUndo)
        board.undo()
        XCTAssertTrue(board.map.components.isEmpty)
    }

    func testImportSchemaUpdatesAnExistingTableAndKeepsDesignOnlyColumnsPlanned() throws {
        let board = fresh()
        _ = try board.importSchema(try SQLSchema.parse("create table orgs (id bigint primary key);"))
        try board.setColumns(of: "orgs", to: [
            BoardColumn(name: "id", type: "bigint", pk: true),
            BoardColumn(name: "notes", type: "text"),
        ])

        let secondParsed = try SQLSchema.parse("create table orgs (id bigint primary key, name text not null);")
        let summary = try board.importSchema(secondParsed)
        XCTAssertEqual(summary, BoardSchemaImport.Summary(added: 0, updated: 1, markedPlanned: 0, skipped: 0, notModelled: 0))

        let orgs = try XCTUnwrap(board.map.components.first { $0.name == "orgs" })
        XCTAssertFalse(orgs.planned)
        XCTAssertEqual(orgs.columns.map(\.name), ["id", "name", "notes"])
        XCTAssertFalse(orgs.columns[1].planned, "the database column")
        XCTAssertTrue(orgs.columns[2].planned, "the design-only column")
    }

    func testImportSchemaMarksADesignOnlyTablePlanned() throws {
        let board = fresh()
        let wishlist = try XCTUnwrap(board.addComponent(kind: .table, at: BoardPoint(x: 400, y: 0)))
        try board.setColumns(of: wishlist, to: [BoardColumn(name: "id", type: "uuid")])

        let summary = try board.importSchema(try SQLSchema.parse("create table orgs (id bigint primary key);"))
        XCTAssertEqual(summary, BoardSchemaImport.Summary(added: 1, updated: 0, markedPlanned: 1, skipped: 0, notModelled: 0))

        let wishlistAfter = try XCTUnwrap(board.map.components.first { $0.name == wishlist })
        XCTAssertTrue(wishlistAfter.planned)
        XCTAssertTrue(wishlistAfter.columns.allSatisfy(\.planned))
    }

    func testImportSchemaSummarySkippedAndNotModelledComeFromTheParser() throws {
        let board = fresh()
        let parsed = try SQLSchema.parse("""
        create table orgs (id bigint primary key, name text, check (name <> ''));
        create index orgs_name_idx on orgs (name);
        """)
        let summary = try board.importSchema(parsed)
        XCTAssertEqual(summary.skipped, 1)
        XCTAssertEqual(summary.notModelled, 1)
    }

    func testImportSchemaWithNothingToReconcileIsNotAnEdit() throws {
        let board = fresh()
        XCTAssertFalse(board.canUndo)
        let summary = try board.importSchema(SQLSchema.Parsed(tables: [], skipped: [], notModelled: []))
        XCTAssertEqual(summary, BoardSchemaImport.Summary(added: 0, updated: 0, markedPlanned: 0, skipped: 0, notModelled: 0))
        XCTAssertFalse(board.canUndo, "nothing changed, so nothing to undo")
    }

    func testExportSchemaSQLMatchesSQLSchemaCreateStatements() throws {
        let board = fresh()
        _ = try board.importSchema(try SQLSchema.parse("create table orgs (id bigint primary key, name text not null);"))
        XCTAssertEqual(board.exportSchemaSQL(), SQLSchema.createStatements(for: SQLSchema.tables(in: board.map)))
        XCTAssertTrue(board.exportSchemaSQL().contains("CREATE TABLE"))
    }

    func testExportSchemaSQLOnAnEmptyBoardIsEmpty() {
        XCTAssertEqual(fresh().exportSchemaSQL(), "")
    }

    func testSetColumnsReplacesTheWholeListAsOneUndoStepEachTime() throws {
        let board = fresh()
        let name = try XCTUnwrap(board.addComponent(kind: .table, at: BoardPoint(x: 0, y: 0)))
        try board.setColumns(of: name, to: [BoardColumn(name: "id", type: "uuid", pk: true)])
        XCTAssertEqual(board.map.components.first?.columns, [BoardColumn(name: "id", type: "uuid", pk: true)])

        try board.setColumns(of: name, to: [BoardColumn(name: "slug", type: "text")])
        XCTAssertEqual(board.map.components.first?.columns, [BoardColumn(name: "slug", type: "text")])

        board.undo()
        XCTAssertEqual(board.map.components.first?.columns, [BoardColumn(name: "id", type: "uuid", pk: true)])
        board.undo()
        XCTAssertEqual(board.map.components.first?.columns, [])
    }

    func testSetColumnsRefusesANonTablePartAndLeavesNoUndoStepOfItsOwn() throws {
        let board = fresh()
        let name = try XCTUnwrap(board.addComponent(kind: .service, at: BoardPoint(x: 0, y: 0)))
        XCTAssertThrowsError(try board.setColumns(of: name, to: [BoardColumn(name: "id", type: "uuid")])) { error in
            XCTAssertEqual((error as? BoardEditRefusal)?.reason, "\"columns\" belong to a table; \"\(name)\" is a service")
        }
        XCTAssertEqual(board.refusal, "\"columns\" belong to a table; \"\(name)\" is a service")
        board.undo()
        XCTAssertTrue(board.map.components.isEmpty, "the refused setColumns left no undo step of its own")
    }

    func testSetColumnsRefusesAGhost() throws {
        let board = fresh()
        board.map.components = [BoardComponent(name: "orgs", kind: .table, at: BoardPoint(x: 0, y: 0), outside: .in)]
        XCTAssertThrowsError(try board.setColumns(of: "orgs", to: [BoardColumn(name: "id", type: "uuid")])) { error in
            XCTAssertEqual((error as? BoardEditRefusal)?.reason, "\"orgs\" comes from the overview; change it there")
        }
    }

    func testSetColumnsRefusesADuplicateColumnName() throws {
        let board = fresh()
        let name = try XCTUnwrap(board.addComponent(kind: .table, at: BoardPoint(x: 0, y: 0)))
        XCTAssertThrowsError(try board.setColumns(of: name, to: [
            BoardColumn(name: "id", type: "uuid"),
            BoardColumn(name: "ID", type: "bigint"),
        ])) { error in
            XCTAssertEqual((error as? BoardEditRefusal)?.reason, "\"\(name)\" names column \"ID\" twice")
        }
        XCTAssertEqual(board.refusal, "\"\(name)\" names column \"ID\" twice")
        XCTAssertEqual(board.map.components.first?.columns, [], "nothing changed")
    }
```

### Steps

- [ ] **Step 1: Write the failing tests.** Add every test above. Add `BoardSchemaImport.Summary`
  and a stub `plan(for:into:)` (e.g. returning `([], Summary(added: 0, updated: 0, markedPlanned:
  0, skipped: 0, notModelled: 0))`, with `steps(for:into:)` calling it), and stub
  `BoardModel.editOrThrow(_:)`/`importSchema(_:)`/`exportSchemaSQL()`/`setColumns(of:to:)` so the
  suite compiles. Run `swift test --filter "BoardSchemaImportTests|BoardModelTests"` and confirm
  every new test fails on an assertion, and every existing test in both files still passes.
- [ ] **Step 2: Implement** 3a–3c in full.
- [ ] **Step 3: Run** the same filtered command, see everything pass, then the full suite and the
  warnings check.
- [ ] **Step 4: Commit.** Stage by name every file this task touched. Message:
  `feat(board): import, export and column-grid edits are one undo step`

---

## Task 4: `SupabaseSchemaDump` — the schema dump through the login shell

**Files:**
- Create: `Sources/LinkCKit/Config/SupabaseSchemaDump.swift`.
- Test: create `Tests/LinkCKitTests/SupabaseSchemaDumpTests.swift`.

**Consumes:** `ProcessRunner`/`ProcessRunnerError`/`ProcessResult` (`Sources/LinkCKit/Config/ProcessRunner.swift`),
`ShellResolver.loginShell()` (`Sources/LinkCKit/Terminal/ShellResolver.swift`), `LinkCError.process`.

**Design note, read before implementing:** linkC runs `supabase db dump` "through your login
shell." Schema output is the command's default; `--data-only` is its opposite switch, and the
installed CLI has no `--schema-only` flag. The real precedent for that exact mechanism in this
codebase is `VerificationRunner.execute(_:in:)`
(`Sources/LinkCKit/Verification/VerificationRunner.swift`): `runner.runCapturing(shell, args: ["-l",
"-c", command], cwd:, timeout:)`, with `shell` from `ShellResolver.loginShell()`, tested by
asserting the exact recorded call on a scripted `ProcessRunner`
(`VerificationRunnerTests.testGateRunsTheCommandThroughALoginShellInTheWorkspace`). `SupabaseService`
(`Sources/LinkCKit/Config/SupabaseService.swift`), by contrast, resolves a fixed Homebrew candidate
path (`DockerLocator.resolve`) and calls that CLI directly — it does **not** itself go through a
login shell. This plan follows `VerificationRunner`'s pattern, not `SupabaseService`'s CLI-path
resolution, because it's the one that actually satisfies the spec's own words, and it's a real,
already-tested seam rather than a new one. A missing `supabase` CLI needs no separate check of its
own: the login shell's own "command not found" line is already a clear message, and it reaches the
caller through the same nonzero-exit path as any other failure — tested explicitly below.

Create `Sources/LinkCKit/Config/SupabaseSchemaDump.swift`:

```swift
import Foundation

/// Reads a Supabase project's live schema through the user's own `supabase` CLI. linkC never
/// holds database credentials — `supabase login` keeps its token in the Keychain, and this always
/// runs through the user's own login shell, exactly as `VerificationRunner` runs a task's test
/// command, so it sees the PATH and dotfiles a terminal would, not launchd's minimal one.
public enum SupabaseSchemaDump {
    /// How long `supabase db dump` gets before it's killed — a cold or large project can take a
    /// while to answer, but a stalled dump must not hang the app forever.
    private static let timeout: TimeInterval = 120
    private static let command = "supabase db dump"

    /// Runs `supabase db dump` in `projectPath` and returns stdout. A nonzero exit
    /// throws `LinkCError.process` with the last 5 lines of stderr (this is also what a missing
    /// `supabase` CLI looks like: the shell's own "command not found" on stderr, exit 127); a
    /// timeout throws `LinkCError.process` naming the timeout.
    public static func run(projectPath: String, runner: ProcessRunner) async throws -> String {
        let shell = ShellResolver.loginShell()
        let cwd = URL(fileURLWithPath: projectPath)
        let result: ProcessResult
        do {
            result = try await runner.runCapturing(shell, args: ["-l", "-c", command], cwd: cwd, timeout: timeout)
        } catch ProcessRunnerError.timedOut(let seconds) {
            throw LinkCError.process("\(command) timed out after \(seconds)s")
        }
        guard result.status == 0 else {
            throw LinkCError.process(failureMessage(status: result.status, stderr: result.stderr))
        }
        return result.stdout
    }

    /// The last 5 non-empty, trimmed lines of stderr, newline-joined — enough of a `supabase`
    /// failure to act on without a whole banner. Falls back to naming the exit status alone when
    /// stderr is empty, so the thrown message is never blank.
    private static func failureMessage(status: Int32, stderr: String) -> String {
        let lines = stderr
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return "\(command) exited with status \(status)" }
        return lines.suffix(5).joined(separator: "\n")
    }
}
```

**Test** — create `Tests/LinkCKitTests/SupabaseSchemaDumpTests.swift`, reusing the existing
`CommandStub` fake (`Tests/LinkCKitTests/VerificationRunnerTests.swift` — no access modifier, so
it's visible module-wide in the test target; it already records `executable`, `args`, `cwd` and
`timeout`, and returns a scripted `Result<ProcessResult, Error>`):

```swift
import XCTest
@testable import LinkCKit

final class SupabaseSchemaDumpTests: XCTestCase {
    private let projectPath = "/Users/jacob/Projects/june"

    func testRunsSupabaseDbDumpThroughTheLoginShellInTheProjectFolder() async throws {
        let runner = CommandStub(.success(ProcessResult(status: 0, stdout: "CREATE TABLE orgs ();\n", stderr: "")))
        let output = try await SupabaseSchemaDump.run(projectPath: projectPath, runner: runner)
        XCTAssertEqual(output, "CREATE TABLE orgs ();\n")
        XCTAssertEqual(runner.calls, [
            CommandStub.Call(
                executable: ShellResolver.loginShell(), args: ["-l", "-c", "supabase db dump"],
                cwd: URL(fileURLWithPath: projectPath), timeout: 120),
        ])
    }

    func testANonzeroExitThrowsWithTheLastFiveLinesOfStderr() async {
        let stderr = (1...7).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let runner = CommandStub(.success(ProcessResult(status: 1, stdout: "", stderr: stderr)))
        do {
            _ = try await SupabaseSchemaDump.run(projectPath: projectPath, runner: runner)
            XCTFail("expected a throw")
        } catch let error as LinkCError {
            XCTAssertEqual(error.errorDescription, "line 3\nline 4\nline 5\nline 6\nline 7")
        }
    }

    func testAMissingSupabaseCLIThrowsTheShellsOwnMessage() async {
        let runner = CommandStub(.success(ProcessResult(status: 127, stdout: "", stderr: "zsh:1: command not found: supabase\n")))
        do {
            _ = try await SupabaseSchemaDump.run(projectPath: projectPath, runner: runner)
            XCTFail("expected a throw")
        } catch let error as LinkCError {
            XCTAssertEqual(error.errorDescription, "zsh:1: command not found: supabase")
        }
    }

    func testANonzeroExitWithNoStderrFallsBackToTheExitStatus() async {
        let runner = CommandStub(.success(ProcessResult(status: 2, stdout: "", stderr: "")))
        do {
            _ = try await SupabaseSchemaDump.run(projectPath: projectPath, runner: runner)
            XCTFail("expected a throw")
        } catch let error as LinkCError {
            XCTAssertEqual(error.errorDescription, "supabase db dump exited with status 2")
        }
    }

    func testATimeoutThrowsAClearMessage() async {
        let runner = CommandStub(.failure(ProcessRunnerError.timedOut(seconds: 120)))
        do {
            _ = try await SupabaseSchemaDump.run(projectPath: projectPath, runner: runner)
            XCTFail("expected a throw")
        } catch let error as LinkCError {
            XCTAssertEqual(error.errorDescription, "supabase db dump timed out after 120s")
        }
    }
}
```

### Steps

- [ ] **Step 1: Write the failing tests.** Create the test file above. Add a stub
  `SupabaseSchemaDump.run(projectPath:runner:)` (e.g. `throw LinkCError.process("todo")`) so the
  suite compiles. Run `swift test --filter SupabaseSchemaDumpTests` and confirm every test fails on
  an assertion.
- [ ] **Step 2: Implement** as above.
- [ ] **Step 3: Run** `swift test --filter SupabaseSchemaDumpTests`, see it pass, then the full
  suite and the warnings check.
- [ ] **Step 4: Commit.** Stage by name. Message:
  `feat(config): a Supabase schema dump through the login shell`

# Table design, phase B2b: the column grid, and SQL import and export

> **For agentic workers:** work task by task, test first where LinkCKit changes at all. Each task
> ends with one commit. The app target has no UI tests — every UI task ends with a build and a full
> suite run instead of a red/green cycle, and its own manual hand-check.

**Goal:** a pinned table's docked inspector grows a "Columns" section you can actually edit — add,
remove, reorder, rename, retype, and wire up keys and references — every change one undo step. A
new "Schema" menu on the Board toolbar reads a `.sql` file or a live Supabase project into the
board, and writes the board's tables back out as SQL, to the clipboard or a file. Every outcome, or
failure, shows on the Board's own banner row.

**Spec:** `docs/superpowers/specs/2026-09-25-table-design-design.md`, §3 ("In the app" — the column
grid) and §4 ("Import sources (app half)" and "Export (app half)"). §1 (the column model) and §2
(drawing a table box, and foreign-key lines) are the sibling plan, `feat/table-draw` — not this one.

**Depends on (already merged into `main`, and present in this worktree):**
- `BoardColumn` / `BoardColumnReference` (`Sources/LinkCKit/Board/BoardColumn.swift`) — the column
  model, and `BoardColumn.validate(_:context:)`, which `BoardModel.setColumns` already runs.
- `BoardModel.setColumns(of:to:) throws` (`Sources/LinkCKit/Board/BoardModel.swift`) — replaces one
  table's whole column list as one undo step; refuses (with a reason, before anything changes) a
  blank name or type, a duplicate name ignoring case, a malformed reference, a part that isn't a
  table, or a ghost. Throws `BoardEditRefusal` (or, from the pre-check, wraps a `LinkCError` in one)
  — see the "error text" note in Task 2 before writing any `catch` block against it.
- `BoardModel.importSchema(_:) throws -> BoardSchemaImport.Summary` and
  `BoardModel.exportSchemaSQL() -> String` (same file) — the whole import/export surface this plan's
  menu calls into. `Summary` has `added`, `updated`, `markedPlanned`, `skipped`, `notModelled`, all
  `Int`.
- `SQLSchema.parse(_:) throws -> SQLSchema.Parsed` and `SQLSchema.Parsed.{tables,skipped,notModelled}`
  (`Sources/LinkCKit/SQL/SQLSchema.swift`) — `skipped`/`notModelled` are `[SQLSchema.Note]`, each
  with `.line`/`.text`; this plan only ever reads their `.count`.
- `SupabaseSchemaDump.run(projectPath:runner:) async throws -> String`
  (`Sources/LinkCKit/Config/SupabaseSchemaDump.swift`) — runs `supabase db dump --schema-only`
  (actually the CLI's own default dump — see that file's own doc comment) through the user's login
  shell; throws `LinkCError.process` on a non-zero exit or a timeout.
- `ProcessRunner` / `LiveProcessRunner` (`Sources/LinkCKit/Config/ProcessRunner.swift`) —
  `LiveProcessRunner` has a public, no-argument `init()`. The app has no existing call site that
  constructs one directly; every `*Service` type takes it as a defaulted parameter
  (`runner: ProcessRunner = LiveProcessRunner()`, e.g. `SupabaseService.swift:119`). This plan's
  `importFromSupabase()` is the app's first direct construction — that's expected, not a sign
  you're missing some other app-level runner to reuse.
- `LinkCError` (`Sources/LinkCKit/Core/Domain.swift`) — conforms to `LocalizedError`, so
  `.localizedDescription` gives its real message. `BoardEditRefusal`
  (`Sources/LinkCKit/Board/BoardEdit.swift`) does **not** conform to `LocalizedError` — only to
  plain `Error` and `CustomStringConvertible` — so `.localizedDescription` on one collapses to a
  generic, useless Foundation string. `BoardModel`'s own private `message(for:)` already knows this
  (`Sources/LinkCKit/Board/BoardModel.swift`, ~line 1104); Task 2 below adds the app's own version
  of that same check, since nothing in LinkCKit exposes it publicly.

**Out of scope for this plan (the sibling plan, `feat/table-draw`, owns all of it):**
- `.table` joining `ComponentKind.groups`, and its glyph.
- Every app site that assumes a fixed 176×84 box — `componentRect`, `handles`, and the rest.
- The table box's own drawing (header, rows, key marks) and foreign-key lines between rows.

This plan does not depend on the sibling plan's changes and must not wait for them or reference
their commits. Both worktrees started at the same commit (`9fd6f5c`). Nothing in this plan needs
`.table` to be in `ComponentKind.groups` — a table can already exist on a board (added by hand in
the file, by an agent's `add` step, or by this plan's own SQL import), and the column grid and
Schema menu both work on whatever tables are already there, regardless of whether the Component
menu itself can place a new one yet.

## Global Constraints

- **Where to work:** the worktree `/Users/jacobdang/Projects/linkC/.worktrees/table-grid`, branch
  `feat/table-grid`. Never edit, build or run git in `/Users/jacobdang/Projects/linkC` itself, in
  `.worktrees/table-draw`, or in any other `.worktrees` folder.
- **Logic stays in LinkCKit.** Task 1 below is exactly this: the "column_N" name and the
  references-menu list are pure, so they're LinkCKit, test first. Nothing else in this plan needs a
  new pure helper — don't invent one; if implementing turns up a real need for one, add it to
  `Sources/LinkCKit/`, with complete test code, test first.
- **No view body writes state.** Every `@State` mutation happens in a gesture handler, a button
  action, a menu item's action, or a method called from one of those — never inside a `body` or
  computed-view property's own evaluation.
- **Fail loud.** No `try?` anywhere in this plan's changes — every `throws` call in Tasks 2 and 3
  is inside a `do`/`catch` that reports the failure on the banner or inline in the grid, never
  swallowed. If you add an `NSLog`, it must take format arguments (`NSLog("%@", x)`), never string
  interpolation baked into the format string.
- **Style:** 4-space indentation, one statement per line, `///` doc comments on every new
  declaration — match the surrounding file's voice; read a neighbouring doc comment before writing
  your own.
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
sibling plan (`feat/table-draw`) also edits this file, in its own worktree, on its own branch. The
two plans' edits are disjoint by line; this plan may touch **only**:
- right after line 26 (`@State private var drillError: String?`): one new `@State` declaration.
- lines 623–638 (`dockedInspectorOverlay`): add one new argument to the `BoardDockedInspector(...)`
  call, and one new private function right after it (Task 2 — the grid's wiring).
- right after line 559 (the closing `}` of the `liveUpdatesOff` banner block) and before line 560
  (`Spacer()`): one new banner block (Task 3 — kept in its own clearly marked step below, separate
  from Task 2's wiring, exactly because this is the one line-range closest to the sibling plan's
  own banner-adjacent edits).
- line 564 (`BoardToolbar(board: board, lastKind: $lastKind)`): two new arguments (Task 3).

Do not touch anything else in this file — in particular, never touch `componentRect` (~line 1112),
`handles` (~line 1260), `drawArrows`/`drawing` (~lines 236–260, 777–818), or the `handles(...)` call
inside `componentItemView` (~line 391): all sibling-plan territory. If any of the line numbers above
don't match what you read (they shouldn't — both worktrees started identical and this plan is the
only one meant to touch these four spots), locate the edit by the function or comment named here,
not by line number alone, and say so in your report.

---

## Task 1: the "column_N" name and the references-menu list are pure LinkCKit helpers

**Files:**
- Modify: `Sources/LinkCKit/Board/BoardColumn.swift` — two new `public static func`s on `BoardColumn`.
- Modify: `Tests/LinkCKitTests/BoardColumnTests.swift` — four new tests.

### 1a. Test first

Add to `Tests/LinkCKitTests/BoardColumnTests.swift`:
```swift
    func testNextColumnNameStartsAtOne() {
        XCTAssertEqual(BoardColumn.nextColumnName(avoiding: []), "column_1")
    }

    func testNextColumnNameSkipsUsedNamesIgnoringCase() {
        let existing = [
            BoardColumn(name: "column_1", type: "text"),
            BoardColumn(name: "COLUMN_2", type: "text"),
            BoardColumn(name: "id", type: "uuid"),
        ]
        XCTAssertEqual(BoardColumn.nextColumnName(avoiding: existing), "column_3")
    }

    func testReferenceOptionsListsOtherTablesColumnsSortedByTableThenColumn() {
        var map = BoardMap()
        map.components = [
            BoardComponent(name: "Orders", kind: .table, columns: [
                BoardColumn(name: "id", type: "uuid", pk: true),
                BoardColumn(name: "total", type: "numeric"),
            ]),
            BoardComponent(name: "accounts", kind: .table, columns: [BoardColumn(name: "id", type: "uuid", pk: true)]),
            BoardComponent(name: "svc", kind: .service),
        ]
        XCTAssertEqual(BoardColumn.referenceOptions(in: map, excludingTable: "Orders"), ["accounts.id"])
        XCTAssertEqual(BoardColumn.referenceOptions(in: map, excludingTable: "accounts"), ["Orders.id", "Orders.total"])
    }

    func testReferenceOptionsExcludesTheNamedTableCaseInsensitively() {
        var map = BoardMap()
        map.components = [BoardComponent(name: "Orders", kind: .table, columns: [BoardColumn(name: "id", type: "uuid", pk: true)])]
        XCTAssertEqual(BoardColumn.referenceOptions(in: map, excludingTable: "orders"), [])
    }
```
Add stub implementations (below) so the file compiles, run
`swift test --filter BoardColumnTests` and confirm these four fail on assertions, not compile
errors.

### 1b. Implement

At the end of `BoardColumn`'s body, right after `validate(_:context:)`, add:
```swift
    /// The first "column_N" name (N starting at 1) not already used by `existing`, ignoring case —
    /// what the app's "+ Add column" names a freshly appended column.
    public static func nextColumnName(avoiding existing: [BoardColumn]) -> String {
        let used = Set(existing.map { $0.name.lowercased() })
        var n = 1
        while used.contains("column_\(n)") { n += 1 }
        return "column_\(n)"
    }

    /// Every other table's columns in `map`, as "table.column", sorted by (table, column) both
    /// lowercased — what the app's references `Menu` lists after "None". `table` itself is
    /// excluded, case-insensitively, so a column never offers itself as its own reference.
    public static func referenceOptions(in map: BoardMap, excludingTable table: String) -> [String] {
        map.components
            .filter { $0.kind == .table && $0.name.lowercased() != table.lowercased() }
            .flatMap { component in component.columns.map { BoardColumnReference(table: component.name, column: $0.name) } }
            .sorted { ($0.table.lowercased(), $0.column.lowercased()) < ($1.table.lowercased(), $1.column.lowercased()) }
            .map(\.text)
    }
```

### Steps

- [ ] **Step 1:** add the tests in 1a, plus stub `nextColumnName`/`referenceOptions` bodies (e.g.
  `""` and `[]`) so the suite compiles. Run `swift test --filter BoardColumnTests`, confirm the
  four new tests fail on assertions and every existing test in the file still passes.
- [ ] **Step 2:** implement 1b in full.
- [ ] **Step 3:** run `swift test --filter BoardColumnTests`, see all pass, then the full suite and
  the warnings check.
- [ ] **Step 4: Commit.** Stage `Sources/LinkCKit/Board/BoardColumn.swift` and
  `Tests/LinkCKitTests/BoardColumnTests.swift` by name. Message:
  `feat(board): the "column_N" name and the references-menu list are pure LinkCKit helpers`

---

## Task 2: a pinned table's columns become an editable grid

**Files:**
- Modify: `Sources/linkc/Board/BoardInspector.swift` — `BoardDockedInspector` gains a `columns`
  input; two new types, `BoardColumnsGridInput` and `BoardColumnsGrid`; one new private view,
  `BoardColumnRow`; one new top-level helper, `boardEditErrorText(_:)`.
- Modify: `Sources/linkc/Board/BoardCanvas.swift` — `dockedInspectorOverlay` (lines 623–638) passes
  the new input; one new private function, `columnsGridInput(for:)`, right after it.

**Consumes:** `BoardColumn`, `BoardColumnReference`, `BoardComponent.columns`/`.kind`/`.outside`,
`BoardModel.setColumns(of:to:)`, `BoardColumn.nextColumnName`/`referenceOptions` (Task 1).

### 2a. The error-text helper

`board.setColumns` throws `BoardEditRefusal` on an ordinary refusal (a blank name, a duplicate, a
part that isn't a table) — see the "Depends on" note above for exactly why
`error.localizedDescription` alone is wrong for that type. Add, near the top of
`Sources/linkc/Board/BoardInspector.swift` (module-level, not inside any type, so Task 3's Schema
menu in `BoardTools.swift` can call it too — same module, no import needed):
```swift
/// `error`'s own message: a `BoardEditRefusal`'s plain `reason` (never its "step N:" prefix, which
/// means nothing outside an agent's numbered steps), else a `LinkCError`'s `errorDescription`, else
/// Foundation's own `localizedDescription` — reliable for an ordinary Cocoa error (a bad file read,
/// a pasteboard failure) but NOT for `BoardEditRefusal`, whose plain-`Error` conformance carries no
/// `LocalizedError`, so `.localizedDescription` alone would collapse it to a generic, useless string.
func boardEditErrorText(_ error: Error) -> String {
    if let refusal = error as? BoardEditRefusal { return refusal.reason }
    if let linkCError = error as? LinkCError { return linkCError.localizedDescription }
    return error.localizedDescription
}
```

### 2b. `BoardColumnsGridInput`

Add, above `BoardColumnsGrid` (2c):
```swift
/// What the docked inspector hands `BoardColumnsGrid` for one pinned table: its own name (used as
/// the grid's `.id(_:)`, so switching pinned tables reseeds the grid's edit state instead of
/// showing the previous table's rows), its committed columns, the cross-table "table.column" list
/// its references `Menu` offers, and the app's own commit.
struct BoardColumnsGridInput {
    let tableName: String
    let columns: [BoardColumn]
    let referenceOptions: [String]
    let commit: ([BoardColumn]) throws -> Void
}
```

### 2c. `BoardColumnsGrid`

```swift
/// A pinned, non-ghost table's columns as an editable grid — the docked inspector's "Columns"
/// section. Every committed change calls `input.commit` once with the whole new column list, so
/// it's one undo step. `rows` only ever holds the last change `input.commit` actually accepted —
/// a refused change shows its reason here, in `Theme.contextWarn`, and never touches `rows`, so
/// the refused field(s) revert by construction rather than by any explicit undo of their own.
struct BoardColumnsGrid: View {
    let input: BoardColumnsGridInput

    @State private var rows: [BoardColumn]
    @State private var refusal: String?

    init(input: BoardColumnsGridInput) {
        self.input = input
        _rows = State(wrappedValue: input.columns)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("COLUMNS")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(Theme.textTertiary)
            ForEach(rows.indices, id: \.self) { index in
                BoardColumnRow(
                    column: rows[index], referenceOptions: input.referenceOptions,
                    isFirst: index == 0, isLast: index == rows.count - 1,
                    commit: { commitRow(at: index, to: $0) },
                    moveUp: { move(index, by: -1) },
                    moveDown: { move(index, by: 1) },
                    delete: { removeRow(at: index) })
            }
            Button("+ Add column", action: addRow)
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Theme.accent)
            if let refusal {
                Text(refusal).font(.system(size: 10.5)).foregroundStyle(Theme.contextWarn)
            }
        }
    }

    private func commitRow(at index: Int, to column: BoardColumn) -> Bool {
        var proposed = rows
        proposed[index] = column
        return attemptCommit(proposed)
    }

    private func move(_ index: Int, by delta: Int) {
        var proposed = rows
        proposed.swapAt(index, index + delta)
        attemptCommit(proposed)
    }

    private func removeRow(at index: Int) {
        var proposed = rows
        proposed.remove(at: index)
        attemptCommit(proposed)
    }

    private func addRow() {
        let name = BoardColumn.nextColumnName(avoiding: rows)
        attemptCommit(rows + [BoardColumn(name: name, type: "text")])
    }

    @discardableResult
    private func attemptCommit(_ proposed: [BoardColumn]) -> Bool {
        do {
            try input.commit(proposed)
            rows = proposed
            refusal = nil
            return true
        } catch {
            refusal = boardEditErrorText(error)
            return false
        }
    }
}
```

### 2d. `BoardColumnRow`

```swift
/// One column's editable row: a name field, a type field with a common-types menu, PK/NN/UQ
/// toggles, a default field, a references menu, and reorder/delete buttons. `draft` is this row's
/// own edit buffer, seeded once from `column` and never re-seeded by a later re-render of this same
/// row — only a successful `commit` (which the parent then reflects back as a new `column`) or a
/// refused one (handled entirely inside `submit()`, below) ever changes it.
private struct BoardColumnRow: View {
    let column: BoardColumn
    let referenceOptions: [String]
    let isFirst: Bool
    let isLast: Bool
    /// Tries to commit `draft` as this row's new value; `false` means the board refused it, and
    /// the row reverts to `column` — "the field reverts", per the spec, not "keeps what was typed".
    let commit: (BoardColumn) -> Bool
    let moveUp: () -> Void
    let moveDown: () -> Void
    let delete: () -> Void

    private static let commonTypes = [
        "uuid", "text", "bigint", "integer", "boolean", "timestamptz", "jsonb", "numeric", "date", "varchar(255)",
    ]

    @State private var draft: BoardColumn

    init(column: BoardColumn, referenceOptions: [String], isFirst: Bool, isLast: Bool,
         commit: @escaping (BoardColumn) -> Bool, moveUp: @escaping () -> Void, moveDown: @escaping () -> Void, delete: @escaping () -> Void) {
        self.column = column
        self.referenceOptions = referenceOptions
        self.isFirst = isFirst
        self.isLast = isLast
        self.commit = commit
        self.moveUp = moveUp
        self.moveDown = moveDown
        self.delete = delete
        _draft = State(wrappedValue: column)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                TextField("name", text: $draft.name).onSubmit(submit)
                typeField
                reorderAndDelete
            }
            HStack(spacing: 6) {
                toggle("PK", isOn: draft.pk, set: setPK)
                toggle("NN", isOn: !draft.nullable, set: setNotNull).disabled(draft.pk)
                toggle("UQ", isOn: draft.unique) { draft.unique = $0; submit() }
                referencesMenu
            }
            TextField("default", text: Binding(get: { draft.defaultValue ?? "" }, set: { draft.defaultValue = $0.isEmpty ? nil : $0 }))
                .onSubmit(submit)
        }
        .font(.system(size: 11))
        .textFieldStyle(.roundedBorder)
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) }
    }

    private var typeField: some View {
        HStack(spacing: 2) {
            TextField("type", text: $draft.type).onSubmit(submit)
            Menu {
                ForEach(Self.commonTypes, id: \.self) { type in
                    Button(type) { draft.type = type; submit() }
                }
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 8))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private var referencesMenu: some View {
        Menu {
            Button("None") { draft.references = nil; submit() }
            ForEach(referenceOptions, id: \.self) { option in
                Button(option) { draft.references = BoardColumnReference(parsing: option); submit() }
            }
        } label: {
            Text(draft.references?.text ?? "None").font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
        }
        .menuStyle(.borderlessButton)
    }

    private var reorderAndDelete: some View {
        HStack(spacing: 2) {
            Button(action: moveUp) { Image(systemName: "chevron.up") }.disabled(isFirst)
            Button(action: moveDown) { Image(systemName: "chevron.down") }.disabled(isLast)
            Button(action: delete) { Image(systemName: "xmark") }
        }
        .buttonStyle(.plain)
        .font(.system(size: 9))
        .foregroundStyle(Theme.textTertiary)
    }

    private func toggle(_ title: String, isOn: Bool, set: @escaping (Bool) -> Void) -> some View {
        Button { set(!isOn) } label: {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(isOn ? Theme.accent : Theme.textTertiary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Capsule().fill(isOn ? Theme.accent.opacity(0.16) : .clear))
        }
        .buttonStyle(.plain)
    }

    /// Turning PK on always also forces NN on — a primary key is never nullable
    /// (`BoardColumn.init`'s own rule, from Phase A) — enforced here too, since mutating `draft.pk`
    /// directly does not itself re-run that initializer's coercion: without this, the row could
    /// submit the one combination `BoardColumn.init` exists specifically to prevent.
    private func setPK(_ value: Bool) {
        draft.pk = value
        if value { draft.nullable = false }
        submit()
    }

    private func setNotNull(_ value: Bool) {
        draft.nullable = !value
        submit()
    }

    private func submit() {
        if !commit(draft) { draft = column }
    }
}
```

### 2e. `BoardDockedInspector` gains the grid

Change:
```swift
struct BoardDockedInspector: View {
    let content: BoardInspectionContent
    var parentTitle: String? = nil
    let edit: () -> Void
    var goDeeper: (() -> Void)? = nil
    let close: () -> Void
    static let width: CGFloat = 260

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
            ScrollView {
                BoardInspectionBody(content: content, parentTitle: parentTitle)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
```
to:
```swift
struct BoardDockedInspector: View {
    let content: BoardInspectionContent
    var parentTitle: String? = nil
    let edit: () -> Void
    var goDeeper: (() -> Void)? = nil
    let close: () -> Void
    /// The pinned table's own columns, its cross-table reference options, and the app's commit —
    /// nil unless `content` is a non-ghost `table`-kind part, in which case the Columns grid shows.
    var columns: BoardColumnsGridInput? = nil
    static let width: CGFloat = 260

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    BoardInspectionBody(content: content, parentTitle: parentTitle)
                    if let columns {
                        BoardColumnsGrid(input: columns).id(columns.tableName)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
```
Nothing else in `BoardDockedInspector` changes — `header`, `isGhostPart`, `isPart`, and the trailing
modifiers on `body`'s outer `VStack` are all unaffected.

### 2f. `BoardCanvas.swift`'s wiring (shared file — this plan's only touch to it here)

In `dockedInspectorOverlay` (lines 623–638), change:
```swift
    @ViewBuilder
    private var dockedInspectorOverlay: some View {
        if let pinned, let content = inspectionContent(for: pinned) {
            BoardDockedInspector(
                content: content,
                parentTitle: parentTitle,
                edit: editPinned,
                goDeeper: {
                    if case .part(let name) = pinned {
                        goDeeper(into: name)
                    }
                },
                close: unpin
            )
        }
    }
```
to:
```swift
    @ViewBuilder
    private var dockedInspectorOverlay: some View {
        if let pinned, let content = inspectionContent(for: pinned) {
            BoardDockedInspector(
                content: content,
                parentTitle: parentTitle,
                edit: editPinned,
                goDeeper: {
                    if case .part(let name) = pinned {
                        goDeeper(into: name)
                    }
                },
                close: unpin,
                columns: columnsGridInput(for: pinned)
            )
        }
    }

    /// `BoardColumnsGrid`'s input for `target` — nil unless it names a non-ghost, `table`-kind part
    /// still on the board.
    private func columnsGridInput(for target: BoardInspectionTarget) -> BoardColumnsGridInput? {
        guard case .part(let name) = target,
              let table = board.map.components.first(where: { $0.name == name }), table.kind == .table, table.outside == nil
        else { return nil }
        return BoardColumnsGridInput(
            tableName: table.name, columns: table.columns,
            referenceOptions: BoardColumn.referenceOptions(in: board.map, excludingTable: table.name),
            commit: { columns in try board.setColumns(of: table.name, to: columns) })
    }
```

### Steps

- [ ] **Step 1:** make edits 2a–2f.
- [ ] **Step 2:** `swift build 2>&1 | tail -1` — clean build. `swift build --build-tests 2>&1 | grep
  -E "warning:"` — empty.
- [ ] **Step 3:** `swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1` — 0 failures.
- [ ] **Step 4: hand check** (see the end of this plan) before committing, since this is the one
  task a stray SwiftUI layout mistake would be easy to ship unnoticed in.
- [ ] **Step 5: Commit.** Stage `Sources/linkc/Board/BoardInspector.swift` and
  `Sources/linkc/Board/BoardCanvas.swift` by name. Message:
  `feat(board): a pinned table's columns become an editable grid`

---

## Task 3: the Schema menu — import and export SQL

**Files:**
- Modify: `Sources/linkc/Board/BoardTools.swift` — add `import AppKit` and
  `import UniformTypeIdentifiers`; `BoardToolbar` gains `projectPath`/`schemaOutcome`, a Schema
  `Menu`, and its action methods; one new type, `BoardSchemaOutcome`.
- Modify: `Sources/linkc/Board/BoardCanvas.swift` — three separate, small edits (see below).

**Consumes:** `SQLSchema.parse`/`.tables`/`.skipped`/`.notModelled`, `SupabaseSchemaDump.run`,
`LiveProcessRunner`, `BoardModel.importSchema`/`.exportSchemaSQL`, `boardEditErrorText(_:)` (Task 2).

### 3a. `BoardToolbar`'s new inputs, and the Schema menu

Add the two imports at the top of the file:
```swift
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LinkCKit
```

Change:
```swift
struct BoardToolbar: View {
    @Bindable var board: BoardModel
    @Binding var lastKind: ComponentKind

    var body: some View {
        HStack(spacing: 2) {
```
to:
```swift
struct BoardToolbar: View {
    @Bindable var board: BoardModel
    @Binding var lastKind: ComponentKind
    let projectPath: String
    @Binding var schemaOutcome: BoardSchemaOutcome?

    var body: some View {
        HStack(spacing: 2) {
```

Change:
```swift
            Rectangle().fill(Theme.textTertiary.opacity(0.25)).frame(width: 1, height: 16).padding(.horizontal, 2)
            tidyUpButton
        }
```
to:
```swift
            Rectangle().fill(Theme.textTertiary.opacity(0.25)).frame(width: 1, height: 16).padding(.horizontal, 2)
            tidyUpButton
            Rectangle().fill(Theme.textTertiary.opacity(0.25)).frame(width: 1, height: 16).padding(.horizontal, 2)
            schemaMenu
        }
```

Add, right after `tidyUpButton`'s definition:
```swift
    private var hasTables: Bool { board.map.components.contains { $0.kind == .table } }

    /// Import SQL file… and Import from Supabase are always enabled — a board with no tables yet
    /// is exactly what an import is for. Copy SQL and Export SQL… need at least one `table` part —
    /// same membership `exportSchemaSQL()`/`SQLSchema.tables(in:)` already export from, ghosts
    /// included, so this never disagrees with what a Copy or Export would actually produce.
    private var schemaMenu: some View {
        Menu("Schema") {
            Button("Import SQL file…", action: importSQLFile)
            Button("Import from Supabase", action: importFromSupabase)
            Divider()
            Button("Copy SQL", action: copySQL).disabled(!hasTables)
            Button("Export SQL…", action: exportSQL).disabled(!hasTables)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .font(.system(size: 11))
        .foregroundStyle(Theme.textSecondary)
    }

    private func importSQLFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if let sqlType = UTType(filenameExtension: "sql") { panel.allowedContentTypes = [sqlType] }
        panel.prompt = "Import"
        panel.message = "Choose a .sql file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let sql = try String(contentsOf: url, encoding: .utf8)
            let parsed = try SQLSchema.parse(sql)
            let summary = try board.importSchema(parsed)
            schemaOutcome = BoardSchemaOutcome(text: importedText(summary, parsed), tone: .success)
        } catch {
            schemaOutcome = BoardSchemaOutcome(text: "Couldn't import: \(boardEditErrorText(error))", tone: .error)
        }
    }

    private func importFromSupabase() {
        schemaOutcome = BoardSchemaOutcome(text: "Reading the Supabase schema…", tone: .info)
        Task {
            do {
                let sql = try await SupabaseSchemaDump.run(projectPath: projectPath, runner: LiveProcessRunner())
                let parsed = try SQLSchema.parse(sql)
                let summary = try board.importSchema(parsed)
                schemaOutcome = BoardSchemaOutcome(text: importedText(summary, parsed), tone: .success)
            } catch {
                schemaOutcome = BoardSchemaOutcome(text: "Couldn't import: \(boardEditErrorText(error))", tone: .error)
            }
        }
    }

    /// "Imported N tables: A added, U updated, P marked planned. S statements skipped, M clauses
    /// not modelled." — N is the total tables the import actually touched (added + updated +
    /// marked planned), not `parsed.tables.count`, so it always equals the sum the sentence itself
    /// then breaks down.
    private func importedText(_ summary: BoardSchemaImport.Summary, _ parsed: SQLSchema.Parsed) -> String {
        let total = summary.added + summary.updated + summary.markedPlanned
        return "Imported \(total) tables: \(summary.added) added, \(summary.updated) updated, "
            + "\(summary.markedPlanned) marked planned. \(parsed.skipped.count) statements skipped, "
            + "\(parsed.notModelled.count) clauses not modelled."
    }

    /// Silent on success, like every other copy button in this app (`MCPServersScreen`'s target
    /// copy) — only a failure earns a banner. Clears any stale outcome still showing from an
    /// earlier action, so a leftover error doesn't linger next to a copy that just worked.
    private func copySQL() {
        let sql = board.exportSchemaSQL()
        guard NSPasteboard.general.setString(sql, forType: .string) else {
            schemaOutcome = BoardSchemaOutcome(text: "Couldn't export: the system clipboard refused the text", tone: .error)
            return
        }
        schemaOutcome = nil
    }

    /// Silent on success, same as `copySQL()`; a cancelled panel is not a failure and shows nothing.
    private func exportSQL() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "schema.sql"
        if let sqlType = UTType(filenameExtension: "sql") { panel.allowedContentTypes = [sqlType] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try board.exportSchemaSQL().write(to: url, atomically: true, encoding: .utf8)
            schemaOutcome = nil
        } catch {
            schemaOutcome = BoardSchemaOutcome(text: "Couldn't export: \(error.localizedDescription)", tone: .error)
        }
    }
```
`copySQL`/`exportSQL`'s own errors (`NSPasteboard` refusing a string, a file-write error) are
ordinary Cocoa/Foundation errors, not `BoardEditRefusal` — `.localizedDescription` is the right call
there, unlike in `importSQLFile`/`importFromSupabase`, which is exactly why 3a uses
`boardEditErrorText(error)` for those two and plain `.localizedDescription` for these two.

### 3b. `BoardSchemaOutcome`

Add, near the top of the file (module-level, next to `QuickAddChoice`'s own definition style):
```swift
/// The Schema menu's last outcome, shown on the Board's banner row (`BoardCanvas.overlays`) until
/// the next Schema action replaces or clears it.
struct BoardSchemaOutcome: Equatable {
    enum Tone { case info, success, error }
    let text: String
    let tone: Tone

    var color: Color {
        switch tone {
        case .info: return Theme.textTertiary
        case .success: return Theme.statusRunning
        case .error: return Theme.contextWarn
        }
    }
}
```

### 3c. `BoardCanvas.swift`'s wiring — three separate edits, none touching Task 2's own edits there

**Edit 1 — a new `@State` property.** Right after line 26:
```swift
    @State private var drillError: String?
```
add:
```swift
    /// The Schema menu's last outcome — success or failure — shown on the banner row until the
    /// next Schema action replaces or clears it.
    @State private var schemaOutcome: BoardSchemaOutcome?
```

**Edit 2 — the banner.** Right after line 559 (the closing `}` of the `liveUpdatesOff` block) and
before line 560 (`Spacer()`):
```swift
                    if let liveUpdatesOff = board.liveUpdatesOff {
                        BoardBanner(text: liveUpdatesOff, tone: Theme.textTertiary)
                    }
                    Spacer()
```
becomes:
```swift
                    if let liveUpdatesOff = board.liveUpdatesOff {
                        BoardBanner(text: liveUpdatesOff, tone: Theme.textTertiary)
                    }
                    if let schemaOutcome {
                        BoardBanner(text: schemaOutcome.text, tone: schemaOutcome.color)
                    }
                    Spacer()
```

**Edit 3 — the toolbar call site.** Line 564, change:
```swift
                    BoardToolbar(board: board, lastKind: $lastKind)
```
to:
```swift
                    BoardToolbar(board: board, lastKind: $lastKind, projectPath: projectPath, schemaOutcome: $schemaOutcome)
```

### Steps

- [ ] **Step 1:** make edits 3a–3c.
- [ ] **Step 2:** `swift build 2>&1 | tail -1` — clean build. `swift build --build-tests 2>&1 | grep
  -E "warning:"` — empty.
- [ ] **Step 3:** `swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1` — 0 failures.
- [ ] **Step 4: hand check** (see below) before committing.
- [ ] **Step 5: Commit.** Stage `Sources/linkc/Board/BoardTools.swift` and
  `Sources/linkc/Board/BoardCanvas.swift` by name. Message:
  `feat(board): the Schema menu imports and exports SQL`

---

## Hand checks (after Task 3 — no commit, no code change)

The app target has no UI tests, so this is a real, human-eye check before calling the plan done:

1. Build and launch linkC against a real project. Pin an existing table (add one by hand in its
   board file, or via an agent's `add` step with `"kind": "table"` and a couple of `columns`, if the
   sibling plan's Component menu entry isn't in this worktree).
2. In the docked inspector, confirm the "Columns" section lists every column, edit a name and a
   type, toggle PK/NN/UQ, set a default, pick a reference from the menu, reorder with ↑/↓, delete a
   row, and add one with "+ Add column" — confirm it's named "column_1" (or the first free N).
   Confirm each of these is its own single undo (⌘Z) step.
3. Force a refusal (e.g. rename a column to match an existing one) and confirm the reason shows
   inline in the grid, in the warm gold `contextWarn` colour, and the field snaps back rather than
   keeping the bad text.
4. Use Schema → Import SQL file… on a small `.sql` file with two or three `CREATE TABLE`s (at least
   one foreign key). Confirm the success banner reads exactly
   "Imported N tables: A added, U updated, P marked planned. S statements skipped, M clauses not
   modelled." with numbers that add up. Import it again and confirm the numbers now show updates,
   not fresh adds.
5. Schema → Copy SQL, and paste somewhere to confirm it's real CREATE TABLE SQL. Schema → Export
   SQL…, confirm the panel's default filename is "schema.sql", save it, and diff it against what
   Copy SQL gave you — they should match exactly.
6. Point Schema → Import from Supabase at a project with no `supabase` CLI (or a bad project path)
   and confirm a real failure reason shows as "Couldn't import: …", not a generic or swallowed one.

Report what you saw, including anything that didn't match this plan's exact copy or behaviour —
don't silently patch it into something that "looks right" instead of what §3/§4 above actually
specify.

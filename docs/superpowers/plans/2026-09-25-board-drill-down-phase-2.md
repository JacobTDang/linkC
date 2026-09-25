# Board drill-down, phase 2: moving between boards in the app

> **For agentic workers:** work task by task, test first where the task is LinkCKit. One commit per task.

**Goal:** a project's Board tab shows any of its boards, not only the overview. The breadcrumb, the Boards ▾ menu and ⌘↑ move between them. ↳ Go deeper opens or creates a part's detail board. Parts with a detail board carry a ↳ badge. Ghost neighbours draw faint, can't be dragged, and read as coming from the overview.

**Spec:** `docs/superpowers/specs/2026-09-25-board-drill-down-design.md` §2 (how a ghost draws; read-only) and §3 (moving around).

**Already on main (phase 1; use these, don't rewrite them):**
- `BoardComponent.detail: String?`, `.outside: BoardGhostSide?`, `.stale: Bool`.
- `BoardCatalog.load(workspacePath:projectName:) throws -> BoardCatalog`:
  - `entries` (overview first, linked boards as a tree, unlinked last);
  - `Entry.slug: String?` (nil is the overview);
  - `Entry.path: [String]` (the breadcrumb titles);
  - `Entry.linked`, `Entry.depth`;
  - `entry(for:)`.
- `BoardDrill.detail(of:onBoard:workspacePath:) throws -> String` creates the detail board if it's missing, and returns its slug.
- `BoardDrill.open(_:workspacePath:catalog:) throws -> BoardMap` syncs the ghosts, saves them if they changed, and returns the map.
- `BoardMapStore(workspacePath:board:)`: `board` is a slug, or nil for the overview.
- `BoardModel(store:)`, `.fileURL`, `.saveNow()`.

## Global Constraints

- **Where to work:** the worktree `/Users/jacobdang/Projects/linkC/.worktrees/board-drill-ui`, branch `feat/board-drill-ui`. Never edit, build or run git in `/Users/jacobdang/Projects/linkC` itself or in any other `.worktrees` folder.
- **Logic lives in LinkCKit, unit-tested.** The `linkc` app target only draws and wires. No SwiftUI view body writes model state.
- **Test first** for LinkCKit: stub, see red on an assertion (never a compile error), implement, see green.
- **Fail loud:** no `try?` that hides a failure, and no empty `catch`. A failure the user must know about shows on the Board's existing banner row. NSLog only with format arguments (`NSLog("%@", x)`).
- **Style:** match the surrounding code: 4-space indentation, one statement per line, and `///` doc comments on new types and non-trivial functions.
- **Build:** `swift build 2>&1 | tail -1`. `swift build --build-tests 2>&1 | grep -E "warning:"` must print nothing.
- **Suite:** `swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1` must report 0 failures after every task. Main is at 1535 tests.
- **Commits:**
  - one per task, with the message the task gives;
  - stage files by name;
  - no trailers of any kind;
  - "claude" never appears in a message;
  - never push, merge or rebase.
  - `git status --short` must be clean at the end.

---

### Task 1: Board addresses, breadcrumbs, the menu rows, and ⌘↑ (LinkCKit)

**Files:**
- Create `Sources/LinkCKit/Board/BoardNavigation.swift`.
- Modify `Sources/LinkCKit/Board/BoardKeys.swift`, adding `KeyPress.Key.up` and `BoardCommand.goUp`.
- Test: create `Tests/LinkCKitTests/BoardNavigationTests.swift`, and add to `Tests/LinkCKitTests/BoardKeysTests.swift`.

**Produces:**

```swift
/// One board of one project: the overview (slug nil) or a detail board.
public struct BoardAddress: Hashable, Sendable {
    public let projectPath: String   // standardized
    public let slug: String?
    public init(projectPath: String, slug: String?)
    /// Where this board's viewport and lens are kept: the project path for the overview, so
    /// existing saved viewports still apply; "<path>#<slug>" for a detail board.
    public var viewportKey: String { get }
    /// The board one level up: "a.b" → "a", "a" → the overview, the overview → nil.
    public var up: BoardAddress? { get }
}

public enum BoardNavigation {
    public struct Crumb: Equatable, Sendable {
        public let title: String
        public let address: BoardAddress
    }
    /// The breadcrumb for `address`:
    /// - a linked board gives one crumb per level, pairing `entry.path` with the slug's
    ///   prefixes;
    /// - an unlinked board gives the overview, then the slug;
    /// - a slug the catalog doesn't know gives the overview alone.
    public static func crumbs(for address: BoardAddress, in catalog: BoardCatalog) -> [Crumb]

    public struct MenuRow: Equatable, Sendable {
        public let title: String
        public let indent: Int
        public let address: BoardAddress?   // nil for the "Unlinked" header row
    }
    /// The Boards ▾ menu:
    /// - every linked entry in catalog order, titled by its last path element and indented by
    ///   its depth;
    /// - then, when any exist, an "Unlinked" header row (address nil, indent 0) followed by
    ///   each unlinked entry, titled by its slug and indented by 1.
    public static func menuRows(for catalog: BoardCatalog, projectPath: String) -> [MenuRow]
}
```

**Keys:**
- Add `case up` to `KeyPress.Key`.
- Add `case goUp` to `BoardCommand`.
- In `BoardKeyMap.command(for:isEditingText:)`, `.up` with command only (no control, option or shift) returns `.goUp`.

- [ ] **Step 1: Write the failing tests.** Create `Tests/LinkCKitTests/BoardNavigationTests.swift`:

```swift
import XCTest
@testable import LinkCKit

final class BoardNavigationTests: XCTestCase {
    private let path = "/p/june"
    private func at(_ slug: String?) -> BoardAddress { BoardAddress(projectPath: path, slug: slug) }
    private let catalog = BoardCatalog(entries: [
        .init(slug: nil, path: ["June"], linked: true),
        .init(slug: "audio-engine", path: ["June", "Audio engine"], linked: true),
        .init(slug: "audio-engine.mixer", path: ["June", "Audio engine", "Mixer"], linked: true),
        .init(slug: "api", path: ["June", "API"], linked: true),
        .init(slug: "old-cache", path: ["June", "old-cache"], linked: false),
    ])

    func testTheOverviewKeepsItsOldViewportKey() {
        XCTAssertEqual(at(nil).viewportKey, "/p/june")
        XCTAssertEqual(at("audio-engine.mixer").viewportKey, "/p/june#audio-engine.mixer")
    }

    func testUpGoesOneLevel() {
        XCTAssertEqual(at("audio-engine.mixer").up, at("audio-engine"))
        XCTAssertEqual(at("audio-engine").up, at(nil))
        XCTAssertNil(at(nil).up)
    }

    func testCrumbsFollowTheCatalogPath() {
        XCTAssertEqual(BoardNavigation.crumbs(for: at("audio-engine.mixer"), in: catalog), [
            .init(title: "June", address: at(nil)),
            .init(title: "Audio engine", address: at("audio-engine")),
            .init(title: "Mixer", address: at("audio-engine.mixer")),
        ])
        XCTAssertEqual(BoardNavigation.crumbs(for: at(nil), in: catalog), [.init(title: "June", address: at(nil))])
    }

    func testAnUnlinkedOrUnknownBoardsCrumbs() {
        XCTAssertEqual(BoardNavigation.crumbs(for: at("old-cache"), in: catalog), [
            .init(title: "June", address: at(nil)),
            .init(title: "old-cache", address: at("old-cache")),
        ])
        XCTAssertEqual(BoardNavigation.crumbs(for: at("gone"), in: catalog), [.init(title: "June", address: at(nil))])
    }

    func testTheMenuIsATreeThenUnlinked() {
        XCTAssertEqual(BoardNavigation.menuRows(for: catalog, projectPath: path), [
            .init(title: "June", indent: 0, address: at(nil)),
            .init(title: "Audio engine", indent: 1, address: at("audio-engine")),
            .init(title: "Mixer", indent: 2, address: at("audio-engine.mixer")),
            .init(title: "API", indent: 1, address: at("api")),
            .init(title: "Unlinked", indent: 0, address: nil),
            .init(title: "old-cache", indent: 1, address: at("old-cache")),
        ])
    }

    func testNoUnlinkedHeaderWhenNothingIsUnlinked() {
        let linkedOnly = BoardCatalog(entries: [.init(slug: nil, path: ["June"], linked: true)])
        XCTAssertEqual(BoardNavigation.menuRows(for: linkedOnly, projectPath: path), [.init(title: "June", indent: 0, address: at(nil))])
    }
}
```

Add to `BoardKeysTests`:

```swift
    func testCommandUpGoesUpOneBoard() {
        XCTAssertEqual(BoardKeyMap.command(for: KeyPress(.up, command: true), isEditingText: false), .goUp)
        XCTAssertNil(BoardKeyMap.command(for: KeyPress(.up), isEditingText: false))
        XCTAssertNil(BoardKeyMap.command(for: KeyPress(.up, command: true, shift: true), isEditingText: false))
        XCTAssertNil(BoardKeyMap.command(for: KeyPress(.up, command: true), isEditingText: true))
    }
```

- [ ] **Step 2: Stub** the types with wrong returns (e.g. empty arrays, `viewportKey` returning `""`), and add `.up` and `.goUp`, with the key map still returning nil for them. Run `swift test --filter "BoardNavigationTests|BoardKeysTests"` and see it fail on assertions.
- [ ] **Step 3: Implement.**
  - `up`: drop the text after the slug's last `.`. A slug with no `.` goes to the overview.
  - `crumbs`: for a linked entry, pair `entry.path[i]` with the address whose slug is the first `i` dot-separated parts of the slug (`i = 0` is the overview).
- [ ] **Step 4: Run** the filtered tests (green), then the full suite and the warnings check.
- [ ] **Step 5: Commit:** `feat(board): board addresses, breadcrumbs and the Boards menu rows, and ⌘↑`

---

### Task 2: The Board tab shows any board (app)

**Files:** `Sources/linkc/LinkCApp.swift` (`AppModel`), `Sources/linkc/Board/BoardPane.swift`, `Sources/linkc/Board/BoardCanvas.swift`, `Sources/linkc/Board/BoardInput.swift`, and a new `Sources/linkc/Board/BoardNavigator.swift` for the breadcrumb and menu view.

**Behaviour:**
1. **One model per board.**
   - `AppModel.boards` (LinkCApp.swift ~619) becomes keyed by `BoardAddress`. `board(for path:)` stays for the overview.
   - `board(for address: BoardAddress) throws -> BoardModel` adds detail boards.
   - For a detail board, call `BoardDrill.open(slug, workspacePath:)` first, so its ghosts are synced and saved. Then build `BoardModel(store: BoardMapStore(workspacePath: path, board: slug))`.
   - A throw propagates to the caller, which shows it (item 5).
2. **The current board of each project** lives in `AppModel` as `currentBoard: [String: String]` (project path → slug; a missing entry means the overview), in memory only. It opens on the overview after a relaunch.
   - `AppModel.showBoard(_ address: BoardAddress)` sets it and shows the Board tab.
   - ⌘1 (the Board tab) keeps showing the current board.
3. **The pane.** `BoardPane` builds its canvas for the project's current address.
   - Give the pane's content `.id(address)` so switching boards rebuilds the canvas and its `BoardFileWatcher` for the new `fileURL`.
   - Before switching away, call `saveNow()` on the board being left.
4. **Viewport per board.**
   - `BoardCanvas` gets a `viewportKey: String` (from `address.viewportKey`) and uses it for every `sidebarState.boardViewport(for:)` and `setBoardViewport(_:for:)` call, instead of `projectPath`.
   - `projectPath` stays for everything else.
5. **The navigator row.** At the Board's top-left, above the system-title row (BoardCanvas.swift ~397), show a new `BoardNavigator` view:
   - The breadcrumb comes from `BoardNavigation.crumbs`. Each earlier crumb is a button that navigates; the last crumb is bold and not a button. Crumbs are separated by `›`.
   - The Boards ▾ menu, next to it, is a `Menu` built from `BoardNavigation.menuRows`:
     - rows are indented with leading spaces by their indent;
     - the header row is a disabled item;
     - the current board shows a checkmark.
   - The catalog is loaded with `BoardCatalog.load(workspacePath:projectName:)` when the pane appears and after each board switch or outside file change. `projectName` is the project folder's last path component.
   - If loading throws, the navigator shows only the current crumb, and the Board's banner row says "Couldn't read this project's boards: <reason>" (use the same banner style the Board already uses for its save-failure message).
6. **⌘↑.**
   - In `BoardInput.press(from:)`, map key code 126 to `.up`.
   - In `BoardCanvas.perform(_:)`, `.goUp` navigates to `address.up` when there is one.

- [ ] Build after each item; keep the full suite green.
- [ ] **Commit:** `feat(board): the Board tab shows any of a project's boards, with a breadcrumb, a Boards menu and ⌘↑`

---

### Task 3: Go deeper, the ↳ badge, and ghosts (app)

**Files:** `Sources/linkc/Board/BoardCanvas.swift`, `Sources/linkc/Board/BoardElements.swift` (`ComponentBox`), `Sources/linkc/Board/BoardInspector.swift`.

**Behaviour:**
1. **↳ Go deeper.**
   - Add it to the docked inspector's header (BoardInspector.swift ~173-189), beside Edit…, for a pinned part that isn't a ghost.
   - Also add a `.contextMenu` on each non-ghost part in the canvas, with **↳ Go deeper** and **Edit…**.
   - The action:
     1. call `board.saveNow()`;
     2. call `BoardDrill.detail(of: part.name, onBoard: address.slug, workspacePath: projectPath)`;
     3. navigate to the returned slug.
   - A throw shows on the banner row: "Couldn't open the detail board: <reason>".
   - The parent's new `detail` key reaches the open model through the file watcher, as any outside change does.
2. **The ↳ badge.**
   - `ComponentBox` shows `↳` in `Theme.accent`, 13 pt semibold, at its top right when `component.detail != nil` and it isn't a ghost.
   - When the status dot is also shown (BoardElements.swift ~81-87), the badge sits just left of the dot, never under it.
3. **Ghosts** (`component.outside != nil`):
   - `ComponentBox` draws a clear fill with the dashed outline planned parts use ([4, 3]). It shows the name only, in secondary text: no sub-line, no logo, never a ↳ badge.
   - A stale ghost (`stale == true`) also shows `⚠` at its top left, with `.help("No longer connected on the overview")`.
   - Dragging is refused: in the gesture conditional (BoardCanvas.swift ~261-262), a ghost gets no `elementDrag`. The Arrow tool still draws arrows from and to ghosts. Clicking a ghost still pins it.
   - The inspector:
     - for a pinned ghost, it shows "From the overview · <parent board title>" under the name, where the parent title is the crumb one level up;
     - Edit… is disabled, with `.help("Change it on the overview")`;
     - there is no Go deeper;
     - a double-click on a ghost doesn't open the component editor.
   - The context menu is not shown for ghosts.

- [ ] Build after each item; keep the full suite green.
- [ ] **Commit:** `feat(board): Go deeper, the ↳ badge, and faint read-only ghosts`

---

## Hand checks (the running app, on a project with a Board)

- Pin a part and click ↳ Go deeper: its detail board opens with its neighbours as faint ghosts at the edges. The breadcrumb reads *Project › Part*.
- Draw an arrow from a ghost to a new inner part. Try to drag a ghost; it doesn't move.
- Go back with the breadcrumb, and again with ⌘↑. The part shows ↳, and each board kept its own zoom and lens.
- The Boards ▾ menu lists the tree. Delete the part's `detail` key by hand in the overview file: the detail board shows under *Unlinked*.

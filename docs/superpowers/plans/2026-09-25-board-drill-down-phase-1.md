# Board drill-down, phase 1 (LinkCKit and agent tools) — Implementation Plan

> **For agentic workers:** implement task by task. Steps use checkbox (`- [ ]`) syntax. Every task is test-first.

**Goal:** the LinkCKit half of detail boards:
- detail files (`system-map.<slug>.json`) linked from parts;
- ghost neighbours that stay in sync with the parent board;
- a catalog of a project's boards;
- a `detail` edit step;
- a `board` parameter on the MCP tools.

The app half (breadcrumb, Boards menu, Go deeper, ghost drawing) is phase 2, after the Board-inspect branch merges.

**Architecture:**
- **Pure pieces:** `BoardSlug`, `BoardGhosts`, `BoardLayout.placedGhosts`, and three new fields on `BoardComponent`.
- **File-backed:** `BoardCatalog`, `BoardDrill` and a slug-aware `BoardMapStore`.
- **MCP:** the handlers route to a board by slug.

**Tech Stack:** Swift 6, macOS 14, SwiftPM, XCTest.

Spec: `docs/superpowers/specs/2026-09-25-board-drill-down-design.md`. Read it first.

## Global Constraints

- **Where to work:** the worktree `/Users/jacobdang/Projects/linkC/.worktrees/board-drill`, branch `feat/board-drill-down`. Never touch `/Users/jacobdang/Projects/linkC` itself or any other `.worktrees` folder, where other agents work.
- **Test-first** for every behaviour: write the test, see it FAIL on an assertion (stub first, never a compile error), implement, see it pass. Paste the verbatim red and green lines in the report.
- **A file that never uses the new fields must encode byte for byte as today.** The golden tests in `BoardMapTests` must stay green.
- **Fail loud:** no swallowed errors. A refused edit names its step number, as existing refusals do. Never interpolate text into an NSLog format string.
- **Deterministic:** ghost order is by name, lowercased, and the catalog order is as in the spec.
- **Slugs:** use only `a-z 0-9 - .`. Refuse any other slug from outside (the MCP tools) with a reason. This blocks path tricks such as `../`.
- **Build:** `swift build 2>&1 | tail -1`. The command `swift build --build-tests 2>&1 | grep -E "warning:"` must print nothing.
- **Suite:** `swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1` must report 0 failures. It's 1451 at the start.
- **Commits:**
  - one commit per task, with a one-line message starting `feat(board): `;
  - stage files by name, never `git add -A` or `git add .`;
  - NO trailers of any kind;
  - "claude" never appears in a message, in any case;
  - never push, merge or rebase.

---

### Task 1: Fields, slugs, per-board files and the catalog

**Files:**
- Modify: `Sources/LinkCKit/Board/BoardMap.swift`:
  - add `BoardGhostSide`;
  - add three `BoardComponent` fields;
  - decode and encode them;
  - add them to `componentKeys`.
- Create: `Sources/LinkCKit/Board/BoardSlug.swift` and `Sources/LinkCKit/Board/BoardCatalog.swift`
- Modify: `Sources/LinkCKit/Board/BoardMapStore.swift` (`init(workspacePath:board:)`)
- Test: `Tests/LinkCKitTests/BoardMapTests.swift` and `Tests/LinkCKitTests/BoardMapStoreTests.swift`; create `Tests/LinkCKitTests/BoardSlugTests.swift` and `Tests/LinkCKitTests/BoardCatalogTests.swift`

**Code to add:**

In `BoardMap.swift`:
```swift
/// Which edge of a detail board a ghost sits on: `in` for an overview neighbour whose arrow reaches
/// the detailed part, `out` for one the part's arrows reach.
public enum BoardGhostSide: String, Sendable {
    case `in`, out
}
```
- **`BoardComponent`:** add `public var detail: String?`, `public var outside: BoardGhostSide?` and `public var stale: Bool`. Add them as init parameters at the END of the existing init, with the defaults `detail: String? = nil, outside: BoardGhostSide? = nil, stale: Bool = false`.
- **`componentKeys`:** add `"detail", "outside", "stale"`.
- **Decode** (next to `tech` in the version-2 component decode):
  - `detail: try string(raw, "detail", context: context)`;
  - `outside`: read with `string(...)`. A value other than `in` or `out` throws `LinkCError.parse("\(context): \"outside\" must be \"in\" or \"out\"")`;
  - `stale: try bool(raw, "stale", context: context) ?? false`.

  Pass them to the new init parameters.
- **Encode**, in `rootObject()`, next to `tech`:
```swift
Self.set(&object, "detail", component.detail)
if let side = component.outside { object["outside"] = side.rawValue } else { object.removeValue(forKey: "outside") }
if component.stale { object["stale"] = true } else { object.removeValue(forKey: "stale") }
```

`BoardSlug.swift`:
```swift
import Foundation

/// Names the detail-board files. A detail board's slug is the chain of part names from the
/// overview, each made lowercase words joined by "-", and joined by ".".
public enum BoardSlug {
    /// One name's slug. Whitespace, "-" and "_" separate words; every other character outside
    /// a-z and 0-9 is dropped. A name with nothing left is "part".
    public static func part(_ name: String) -> String {
        var slug = ""
        var pendingDash = false
        for character in name.lowercased() {
            if character.isASCII, character.isLetter || character.isNumber {
                if pendingDash, !slug.isEmpty { slug.append("-") }
                slug.append(character)
                pendingDash = false
            } else if character.isWhitespace || character == "-" || character == "_" {
                pendingDash = true
            }
        }
        return slug.isEmpty ? "part" : slug
    }

    /// The slug for a new detail board of `name` on the board `parent` (nil is the overview),
    /// unique among `taken`: "-2", "-3" … is added when needed.
    public static func new(for name: String, under parent: String?, taken: Set<String>) -> String {
        let base = (parent.map { $0 + "." } ?? "") + part(name)
        guard taken.contains(base) else { return base }
        var suffix = 2
        while taken.contains("\(base)-\(suffix)") { suffix += 1 }
        return "\(base)-\(suffix)"
    }

    /// Whether a slug from outside is well formed: only a-z, 0-9, "-" and ".", no empty
    /// segment, so no path can escape the project folder.
    public static func isValid(_ slug: String) -> Bool {
        guard !slug.isEmpty else { return false }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-.")
        guard slug.allSatisfy({ allowed.contains($0) }) else { return false }
        return !slug.split(separator: ".", omittingEmptySubsequences: false).contains { $0.isEmpty }
    }

    /// The board's file name. nil is the overview.
    public static func fileName(for slug: String?) -> String {
        slug.map { "system-map.\($0).json" } ?? "system-map.json"
    }

    /// The slug in a detail board's file name, or nil for anything else, including the overview.
    public static func slug(fromFileName name: String) -> String? {
        guard name.hasPrefix("system-map."), name.hasSuffix(".json"), name != "system-map.json" else { return nil }
        let slug = String(name.dropFirst("system-map.".count).dropLast(".json".count))
        return isValid(slug) ? slug : nil
    }
}
```

`BoardMapStore.swift`: add, keeping `init(workspacePath:)` exactly as is:
```swift
    /// A detail board's store: `system-map.<slug>.json` beside the overview. nil is the overview.
    public init(workspacePath: String, board slug: String?) {
        let workspace = URL(fileURLWithPath: (workspacePath as NSString).standardizingPath, isDirectory: true)
        fileURL = workspace.appendingPathComponent(BoardSlug.fileName(for: slug))
    }
```

`BoardCatalog.swift`:
```swift
import Foundation

/// Every board of a project: the overview, then each linked detail board under its parent, in
/// name order, then the detail files nothing links to.
public struct BoardCatalog: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        /// nil is the overview.
        public let slug: String?
        /// The breadcrumb: the project's name, then each part name down to this board.
        public let path: [String]
        public let linked: Bool
        public var depth: Int { path.count - 1 }
    }

    public let entries: [Entry]

    public func entry(for slug: String) -> Entry? { entries.first { $0.slug == slug } }

    /// Reads the project folder: which detail files exist, and which parts link to them.
    public static func load(workspacePath: String, projectName: String) throws -> BoardCatalog {
        let folder = URL(fileURLWithPath: (workspacePath as NSString).standardizingPath, isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        let files = Set(names.compactMap(BoardSlug.slug(fromFileName:)))
        var entries = [Entry(slug: nil, path: [projectName], linked: true)]
        var reached: Set<String> = []

        func visit(board slug: String?, path: [String]) throws {
            guard let map = try BoardMapStore(workspacePath: workspacePath, board: slug).load()?.map else { return }
            let children = map.components
                .compactMap { part -> (String, String)? in part.detail.map { (part.name, $0) } }
                .filter { files.contains($0.1) && !reached.contains($0.1) }
                .sorted { $0.0.lowercased() < $1.0.lowercased() }
            for (name, child) in children {
                reached.insert(child)
                entries.append(Entry(slug: child, path: path + [name], linked: true))
                try visit(board: child, path: path + [name])
            }
        }
        try visit(board: nil, path: [projectName])
        for slug in files.subtracting(reached).sorted() {
            entries.append(Entry(slug: slug, path: [slug], linked: false))
        }
        return BoardCatalog(entries: entries)
    }
}
```
(Check the real `BoardMapStore.load()` return type, `Loaded?` with a `.map`, and adapt the call if it differs.)

**Tests (write these first):**

`BoardSlugTests.swift`:
```swift
import XCTest
@testable import LinkCKit

final class BoardSlugTests: XCTestCase {
    func testANameBecomesLowercaseWords() {
        XCTAssertEqual(BoardSlug.part("Audio engine"), "audio-engine")
        XCTAssertEqual(BoardSlug.part("  ALU  Control_Unit "), "alu-control-unit")
        XCTAssertEqual(BoardSlug.part("R&D / Ops"), "rd-ops")
        XCTAssertEqual(BoardSlug.part("✨"), "part")
    }

    func testNestedSlugsAndTheSuffix() {
        XCTAssertEqual(BoardSlug.new(for: "Audio engine", under: nil, taken: []), "audio-engine")
        XCTAssertEqual(BoardSlug.new(for: "Mixer", under: "audio-engine", taken: []), "audio-engine.mixer")
        XCTAssertEqual(BoardSlug.new(for: "Audio engine", under: nil, taken: ["audio-engine", "audio-engine-2"]), "audio-engine-3")
    }

    func testOnlyWellFormedSlugsAreValid() {
        XCTAssertTrue(BoardSlug.isValid("audio-engine.mixer"))
        XCTAssertFalse(BoardSlug.isValid("../etc"))
        XCTAssertFalse(BoardSlug.isValid("a..b"))
        XCTAssertFalse(BoardSlug.isValid("Audio"))
        XCTAssertFalse(BoardSlug.isValid(""))
    }

    func testFileNames() {
        XCTAssertEqual(BoardSlug.fileName(for: nil), "system-map.json")
        XCTAssertEqual(BoardSlug.fileName(for: "audio-engine"), "system-map.audio-engine.json")
        XCTAssertEqual(BoardSlug.slug(fromFileName: "system-map.audio-engine.mixer.json"), "audio-engine.mixer")
        XCTAssertNil(BoardSlug.slug(fromFileName: "system-map.json"))
        XCTAssertNil(BoardSlug.slug(fromFileName: "notes.json"))
    }
}
```

Append to `BoardMapTests` (the new fields, and nothing written when they're unset):
```swift
    func testDetailOutsideAndStaleRoundTripAndAreWrittenOnlyWhenSet() throws {
        let source = Data(#"{"version":2,"places":{"Not placed":{"engine":{"kind":"service","detail":"audio-engine"},"api":{"kind":"service","outside":"in","stale":true},"db":{"kind":"database"}}}}"#.utf8)
        let map = try BoardMap.decode(source)
        XCTAssertEqual(map.components.first { $0.name == "engine" }?.detail, "audio-engine")
        XCTAssertEqual(map.components.first { $0.name == "api" }?.outside, .in)
        XCTAssertEqual(map.components.first { $0.name == "api" }?.stale, true)
        let db = try XCTUnwrap(map.components.first { $0.name == "db" })
        XCTAssertNil(db.detail); XCTAssertNil(db.outside); XCTAssertFalse(db.stale)
        let text = String(decoding: try map.encoded(), as: UTF8.self)
        XCTAssertEqual(text.components(separatedBy: "\"detail\"").count - 1, 1)
        XCTAssertEqual(text.components(separatedBy: "\"outside\"").count - 1, 1)
        XCTAssertEqual(text.components(separatedBy: "\"stale\"").count - 1, 1)
        XCTAssertEqual(try BoardMap.decode(try map.encoded()), map)
    }

    func testAnUnknownGhostSideIsRefused() {
        let source = Data(#"{"version":2,"places":{"Not placed":{"api":{"kind":"service","outside":"sideways"}}}}"#.utf8)
        XCTAssertThrowsError(try BoardMap.decode(source)) { error in
            XCTAssertTrue(error.localizedDescription.contains("\"outside\""))
        }
    }
```

Append to `BoardMapStoreTests`:
```swift
    func testADetailBoardLivesBesideTheOverview() {
        XCTAssertEqual(BoardMapStore(workspacePath: workspace.path, board: "audio-engine").fileURL.lastPathComponent, "system-map.audio-engine.json")
        XCTAssertEqual(BoardMapStore(workspacePath: workspace.path, board: nil).fileURL.lastPathComponent, "system-map.json")
    }
```

`BoardCatalogTests.swift`: in a temp folder (as `BoardMapStoreTests` does), write:
- `system-map.json`, with parts "Audio engine" (`detail: audio-engine`) and "API" (no detail);
- `system-map.audio-engine.json`, with a part "Mixer" (`detail: audio-engine.mixer`);
- `system-map.audio-engine.mixer.json` (empty map);
- `system-map.old-idea.json`, linked by nothing.

Build them with `BoardMap` and `BoardMapStore.save`. Assert:
- the entries' slugs are `[nil, "audio-engine", "audio-engine.mixer", "old-idea"]`;
- the paths are `[["June"], ["June", "Audio engine"], ["June", "Audio engine", "Mixer"], ["old-idea"]]`;
- `linked` is `[true, true, true, false]`;
- a folder with only `system-map.json` gives one entry.

- [ ] **Step 1:** stub, and write the tests. **Step 2:** red. **Step 3:** implement. **Step 4:** green, warnings, full suite. **Step 5:** commit `feat(board): detail-board files, slugs and a catalog of a project's boards`.

---

### Task 2: Ghost sync, ghost placement, and `BoardDrill`

**Files:**
- Create: `Sources/LinkCKit/Board/BoardGhosts.swift` and `Sources/LinkCKit/Board/BoardDrill.swift`
- Modify: `Sources/LinkCKit/Board/BoardLayout.swift`:
  - add `placedGhosts(_:)`;
  - `arranged(_:)` lays out non-ghost parts as today, then places the ghosts.
- Test: create `Tests/LinkCKitTests/BoardGhostsTests.swift` and `Tests/LinkCKitTests/BoardDrillTests.swift`; append to `Tests/LinkCKitTests/BoardLayoutTests.swift`

**`BoardGhosts.sync(detail:parent:part:) -> BoardMap?`**:
- **Neighbours of `part` in `parent`:** compare names lowercased.
  - Every component with an arrow into `part` is an `.in` neighbour.
  - Every target of `part`'s arrows that exists in `parent` is an `.out` neighbour, unless it's already `.in`.
  - The part itself is excluded.
- **For each neighbour, in name order:**
  - The detail map has a ghost (a component with `outside != nil`) of that name: set its `kind` and `outside` to the neighbour's, and `stale` to false. Mark changed if anything differed.
  - The detail map has a NON-ghost part of that name: leave it. That inner part stands in for the neighbour.
  - Otherwise: append `BoardComponent(name: neighbour.name, kind: neighbour.kind, outside: side)` (which lands in `Not placed`), and mark changed.
- **Every ghost that is no longer a neighbour** and isn't yet stale: set `stale = true`, and mark changed. Never remove one.
- **The result:** if changed, return `BoardLayout.placedGhosts(map)`; otherwise nil.

**`BoardLayout.placedGhosts(_:)`**:
- **The frame of reference:**
  - the inner box is the union of the rects of all non-ghost placed parts, `BoardGeometry.rect(ofComponentAt:)`;
  - also include frame rects, if `BoardFrame` exposes a position and size (read it);
  - with no inner parts, use a zero-size box at (0, 0).
- **The columns:**
  - `.in` ghosts, in name order, go at x = inner.minX − 176 − 96 (the box width is 176), with y = inner.minY + row × 124;
  - `.out` ghosts go at x = inner.maxX + 96.
  - Each ghost's `place` is `BoardMap.notPlaced`.
- Nothing else moves.

**`arranged(_:)`:** take the ghosts out, arrange the rest exactly as today, put the ghosts back, and return `placedGhosts(result)`.

**`BoardDrill`:**
```swift
/// Where detail boards are created and opened: the agent tools use it now, and the app's
/// Go deeper will later.
public enum BoardDrill {
    /// The slug of `part`'s detail board on the board `parent` (nil is the overview). When the
    /// part has no detail board, or its file is missing, the board is created: a new slug from
    /// `BoardSlug.new` among the files on disk, the part's `detail` set and saved on the parent,
    /// and a new file whose `system` is the part's name, with its ghosts synced. Calling it again
    /// returns the same slug.
    public static func detail(of part: String, onBoard parent: String?, workspacePath: String) throws -> String

    /// Loads a detail board with its ghosts synced against the board that links to it, saving
    /// the file when the sync changed it. An unlinked board loads without a sync. Throws when
    /// there's no such file.
    public static func open(_ slug: String, workspacePath: String) throws -> BoardMap

    /// Creates the detail file for a part that the parent now links, when the file doesn't exist
    /// yet. `linkc_edit_board`'s `detail` step uses it after saving the parent.
    public static func createDetailFileIfMissing(slug: String, part: BoardComponent, parent: BoardMap, workspacePath: String) throws
}
```
- **Finding the parent:** use the catalog (`BoardCatalog.load(..., projectName: "")`) plus a scan of each board's parts for `detail == slug`.
- **Saving:** go through `BoardMapStore.save(_:expecting:)`, with the bytes you loaded (nil for a new file).
- **Refusals:** a missing part throws `LinkCError.parse("no part named \"X\" on the board")`. A ghost can't have a detail board: throw `LinkCError.parse("\"X\" comes from the overview; go deeper from its own board")`.

**Tests (first):**
- **`BoardGhostsTests`,** with a parent where A→Engine, B→Engine, Engine→C and Engine→D:
  - a first sync on an empty detail map gives ghosts A and B `.in` and C and D `.out`, with A and B in the left column (the same x, y ascending by name) and C and D in the right;
  - a second sync with no parent change returns nil;
  - after removing B→Engine from the parent, B's ghost is `stale == true` and still present;
  - restoring it clears `stale`;
  - an arrow from ghost A to an inner part "Decoder" survives a sync;
  - a neighbour's kind change on the parent is copied to its ghost;
  - an inner part named "C" stands in: no ghost C is added.
- **`BoardLayoutTests`:** `arranged` never moves ghosts into the inner layout. `.in` ghosts are left of every inner part, `.out` ghosts right, and both columns are in name order.
- **`BoardDrillTests`** (temp folder):
  - `detail(of: "Engine", onBoard: nil, …)` returns `"engine"`, writes `system-map.engine.json` with the four ghosts and `system == "Engine"`, and sets `detail` on the overview's Engine;
  - calling it again returns `"engine"` and creates no second file;
  - nested: `detail(of: "Mixer", onBoard: "engine", …)` returns `"engine.mixer"`;
  - `open("engine", …)` after a parent change marks the right ghost stale and saves;
  - `open("nope", …)` throws;
  - `detail` on a ghost throws.
- [ ] **Commit:** `feat(board): ghost neighbours on detail boards, and creating and opening detail boards`

---

### Task 3: The `detail` edit step, ghost refusals, and the `board` parameter

**Files:**
- Modify: `Sources/LinkCKit/Board/BoardEdit.swift`:
  - a new verb `detail`, in `verbKeys`, `allowedFields` (`"detail": []`), `decodeStep` and a new case;
  - `apply(_:to:detailSlug:)` gains a resolver parameter with a default;
  - the ghost refusals.
- Modify: `Sources/LinkCKit/MCP/MCPServer.swift`:
  - `linkc_get_board` and `linkc_edit_board` gain `board` in their schemas and handlers, and their descriptions change;
  - `editBoard(store:steps:…)` creates detail files after saving.
- Test: `Tests/LinkCKitTests/BoardEditTests.swift` and `Tests/LinkCKitTests/MCPServerBoardTests.swift`

**Behaviour:**
- **The `detail` step:** `{"detail": "<part name>"}`.
  - When applied, it refuses a missing part with the step number, as `update` does, and refuses a ghost.
  - When the part has no `detail`, it sets `detail` to `detailSlug(partName)` and adds the line `detail board for <name>: <slug>`.
  - When it already has one, it adds the line `detail board for <name>: <slug> (exists)`.
- **The resolver:** `apply` gains `detailSlug: (String) -> String = { BoardSlug.part($0) }`. The MCP passes `BoardSlug.new(for:under: currentBoardSlug, taken:)`, where `taken` is the files on disk plus the slugs already handed out in this call.
- **Ghost refusals**, as `BoardEditRefusal(step:reason:)`:
  - an `update` that renames a ghost or changes its kind: `"\"X\" comes from the overview; change it there"`;
  - a `connect` whose two ends are both ghosts: `"an arrow between two parts from the overview belongs on the overview"`.
  - Removing a ghost stays allowed; that's how a user clears a stale ghost.
- **MCP `linkc_get_board`:** the optional `board` is `"overview"` (the default) or a slug.
  - A slug that isn't valid (`BoardSlug.isValid`) or isn't in the catalog is refused with `isError`, naming the known slugs.
  - A detail board is read through `BoardDrill.open`, so its ghosts sync.
  - After the JSON, append the `Boards:` section: one line per catalog entry, indented by depth, as `slug — June › Audio engine`, with `overview` for the overview and `(unlinked)` for unlinked entries.
  - Pass the project's folder name as the catalog's `projectName`.
- **MCP `linkc_edit_board`:** the optional `board`, with the same routing and refusal. The store is `BoardMapStore(workspacePath:board:)`.
  - After a successful save, call `BoardDrill.createDetailFileIfMissing` for every part that a `detail` step linked.
  - The descriptions name `board`, the `detail` step, and ghosts ("parts marked outside come from the parent board and are read-only here").
- The existing refusal and `isError` behaviour is unchanged.

**Tests (first):**
- **`BoardEditTests`:**
  - the `detail` step sets the link through a resolver and reports the line;
  - a second `detail` step on the same part reports `(exists)` and doesn't change the link;
  - renaming a ghost is refused at the right step number;
  - changing a ghost's kind is refused;
  - connecting two ghosts is refused;
  - removing a ghost succeeds.
- **`MCPServerBoardTests`:**
  - `linkc_edit_board` with `[["add":"engine","kind":"service"],["add":"api","kind":"service"],["connect":"api","to":"engine","label":"requests"],["detail":"engine"]]` creates `system-map.engine.json`, and the text names the slug. Check the connect field names against `stepsSchemaDescription`;
  - `linkc_get_board` with `board: "engine"` shows `"outside"` for api;
  - `linkc_get_board` shows a `Boards:` section listing `overview` and `engine`;
  - `board: "../x"` and `board: "missing"` are refused with `isError`;
  - `linkc_edit_board` with `board: "engine"` adds a part inside, and the overview file is unchanged.
- [ ] **Commit:** `feat(board): a detail step and a board parameter for agents, with read-only ghosts`

---

## When done

Report with `linkc_complete_task`. Include:
- the three commit hashes;
- for every task, the verbatim red and green lines;
- the final full-suite line and the warnings check;
- any deviation, with its reason.

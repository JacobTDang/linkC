# Board Diagram Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every Board readable:
- a deterministic layout, run after every agent edit and from a Tidy up button;
- orthogonal arrows that route around boxes and foreign frames;
- labels that never overlap;
- a shape per kind, with technology logos.

**Architecture:** Three pure, tested engines in LinkCKit: `BoardLayout`, `BoardRouter` and
`BoardLabels`. There is also a `tech` field with a logo catalog, `BoardTech`. `BoardModel` runs the
router and labels off the main actor on each map change, and the MCP edit tool arranges the map
before it saves. The app only draws: shapes, logos, rounded routes, label pills and hover dimming.

**Tech Stack:** Swift 6, macOS 14, SwiftUI/AppKit, XCTest. No new dependencies. The logos are
Simple Icons SVG data (CC0), embedded as text.

**Spec:** `docs/superpowers/specs/2026-09-24-board-diagram-engine-design.md`

## Global Constraints

- Swift 6 / macOS 14 deployment target. **No new packages or dependencies.** Simple Icons data is
  vendored as generated Swift source, never fetched at build time.
- TDD for everything in LinkCKit: watch each new test fail on an assertion before implementing.
  A compile error doesn't count, so add a stub first if needed. The app target has no UI harness:
  build it, and read your change carefully.
- **Fail loud:**
  - no `try?` on I/O or decoding;
  - no silent fallbacks;
  - an embedded logo that fails to load traps with a message, with a test guarding it.
- **Deterministic engines:** the same map always gives the same layout, routes and labels. Ties
  break by lowercased name.
- **Power:**
  - layout, routes and labels are computed only on a map change, never per frame;
  - routing runs off the main actor, and the latest change wins;
  - hover changes opacity only;
  - nothing runs while idle.
- No view body writes observable state. No debug prints, commented-out code or scratch files.
  Delete what becomes dead, including `BoardGeometry.route` once the router replaces it, if nothing
  else uses it.
- **Commits:**
  - One-line `feat(board): …` / `fix(board): …` / `refactor(board): …` messages.
  - Stage files by name; never `git add -A`.
  - The untracked `system-map.json` at the repository root belongs to the user. Never stage,
    modify or delete it.
  - No message may contain "claude" in any case.
  - No trailers of any kind.
  - Check with `git log -1 --format=%B | grep -ic claude` (must print 0).
- **Verify every task:**
  - `swift build 2>&1 | tail -3` is clean;
  - `swift build 2>&1 | grep -i warning` prints nothing;
  - `swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1` shows 0 failures. The baseline
    is 1274 tests, 5 skipped, 0 failures.

---

### Task 1: The `tech` field

**Files:**
- Modify:
  - `Sources/LinkCKit/Board/BoardMap.swift`: `BoardComponent.tech`, and decoding/encoding.
  - `Sources/LinkCKit/Board/BoardMerge.swift`: `pick` the field.
  - `Sources/LinkCKit/Board/BoardReport.swift`: show it.
  - `Sources/LinkCKit/Board/BoardEdit.swift`: `tech` on `add`/`update`.
  - `Sources/LinkCKit/MCP/MCPServer.swift`: the steps description names `"tech"?`.
- Test: `BoardMapTests`, `BoardMergeTests`, `BoardEditTests`, `BoardReportTests` (add tests).

**Interfaces:**
- Produces: `public var tech: String?` on `BoardComponent`; an init parameter `tech: String? = nil`
  after `runs`; `BoardComponentFields.tech: String?`, where `""` clears.

**Rules:**
- In the file, `"tech"` is a string inside the component in `places`. Add `"tech"` to
  `componentKeys`, and to the version-1 known keys too, so a v1 file carrying it reads it typed.
- A wrong type is refused like the other string fields.
- It is written only when non-empty.
- `BoardMerge` merges it with `pick`, like `does`.
- `BoardReport` appends ` · <tech>` after the kind in the component's head, sanitized.
- `BoardEdit`:
  - `add` and `update` accept `"tech"` (string);
  - `""` on `update` clears it;
  - the per-verb allowed fields and the refusal list include it;
  - the summary line shows the tech instead of the kind when set: `added db (planned, postgres) in Local docker`.
- In `MCPServer`, the `steps` description's `add` line becomes
  `add: {"add": name, "kind"?, "tech"?, "in"?: place, "does"?, "reached_by"?, "runs"?, "planned"?: bool}`,
  and `update` names it the same way.

- [ ] **Step 1: Write the failing tests.**

```swift
// BoardMapTests
func testTechRoundTripsAndIsWrittenOnlyWhenSet() throws {
    let source = Data(#"{"version":2,"places":{"Not placed":{"db":{"kind":"database","tech":"postgres"},"api":{"kind":"service"}}}}"#.utf8)
    let map = try BoardMap.decode(source)
    XCTAssertEqual(map.components.first { $0.name == "db" }?.tech, "postgres")
    XCTAssertNil(map.components.first { $0.name == "api" }?.tech)
    let text = String(decoding: try map.encoded(), as: UTF8.self)
    XCTAssertTrue(text.contains(#""tech": "postgres""#))
    XCTAssertEqual(text.components(separatedBy: "\"tech\"").count - 1, 1, "an unset tech is not written")
    XCTAssertEqual(try BoardMap.decode(try map.encoded()), map)
}

func testATechOfTheWrongTypeIsRefused() {
    XCTAssertThrowsError(try BoardMap.decode(Data(#"{"version":2,"places":{"Not placed":{"db":{"kind":"database","tech":5}}}}"#.utf8)))
}

// BoardMergeTests
func testTechMergesLikeAnyField() {
    let base = map([BoardComponent(name: "db", kind: .database)])
    var mine = base; mine.components[0].tech = "postgres"
    XCTAssertEqual(BoardMerge.merge(base: base, mine: mine, theirs: base).components.first?.tech, "postgres")
}

// BoardEditTests
func testTechOnAddAndUpdateAndClearing() throws {
    var result = try apply([["add": "db", "kind": "database", "tech": "postgres", "planned": true]], to: .empty)
    XCTAssertEqual(result.map.components.first?.tech, "postgres")
    XCTAssertEqual(result.lines, ["added db (planned, postgres)"])
    result = try apply([["update": "db", "tech": ""]], to: result.map)
    XCTAssertNil(result.map.components.first?.tech)
    XCTAssertNotNil(refusal([["connect": "db", "to": "x", "tech": "y"]], on: result.map), "connect takes no tech")
}

// BoardReportTests
func testTheReportShowsTech() throws {
    var m = BoardMap()
    m.components = [BoardComponent(name: "db", kind: .database, tech: "postgres")]
    XCTAssertTrue(BoardReport.markdown(for: m).contains("database · postgres"))
}
```

  Use the helpers those test files already have (`map(...)`, `apply`, `refusal`). Adjust to their
  real names, and keep the assertions.

- [ ] **Step 2: Run them and watch them fail.** Add a stub first: the `tech` property, unused.

- [ ] **Step 3: Implement.** Follow the rules above.

- [ ] **Step 4: Run them and see them pass.** Run the full suite too.

- [ ] **Step 5: Commit:** `feat(board): components carry an optional tech, and agents can set it`

---

### Task 2: `BoardTech`: the logo catalog

**Files:**
- Create:
  - `Sources/LinkCKit/Board/BoardTech.swift`: the catalog API, aliases, display names, inference.
  - `Sources/LinkCKit/Board/BoardTechLogos.swift`: generated. The SVG text for each id, and whether
    its brand colour is dark.
  - `Tests/LinkCKitTests/BoardTechTests.swift`
- Modify: `Sources/LinkCKit/MCP/MCPServer.swift`: the `steps` description lists the known ids.

**Interfaces:**

```swift
public struct BoardTechInfo: Equatable, Sendable {
    public let id: String            // canonical id, e.g. "postgresql"
    public let displayName: String   // "PostgreSQL"
    public let svg: String           // 24×24 SVG, brand-coloured
    public let isDark: Bool          // brand colour too dark for the dark board: the app tints it
}

public enum BoardTech {
    /// Every canonical id, sorted — for the tool description.
    public static let knownIDs: [String]
    /// A canonical id for an id or alias, case-insensitively; nil when unknown.
    public static func canonical(_ raw: String) -> String?
    public static func info(_ id: String) -> BoardTechInfo?
    /// What a component is drawn with: its `tech` when known, else an exact (case-insensitive)
    /// name match to a known id or alias. Never writes anything.
    public static func resolve(_ component: BoardComponent) -> BoardTechInfo?
    /// An agent's logo for a component named like an agent (claude, codex, cursor, antigravity, agy).
    public static func agent(for component: BoardComponent) -> AgentKind?
}
```

**The ids, aliases and display names** are exactly the table in spec §1. `BoardTech` stores them as
a static array of `(id, displayName, aliases)`.

**`agent(for:)`:**
- it matches `component.tech`, or else the name, against `claude`, `codex`, `cursor`, `antigravity`
  and `agy` (→ `.agy`);
- `resolve` returns nil for those, since the app draws `AgentLogoView`;
- `agent(for:)` is what the app checks first.

**Generating `BoardTechLogos.swift`** (run once; commit only its output):
1. In the session scratchpad, not the repo, run `npm pack simple-icons@16.32.0`, extract it, and
   read `package/icons/<slug>.svg` and `package/data/simple-icons.json` (for `hex`).
2. For each id in the table (the id is the Simple Icons slug):
   - take the single `<path d="…">`;
   - rewrite its arc commands with explicit separators, using the normaliser below, because CoreSVG
     misreads packed arc flags;
   - emit `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="24" height="24"><path fill="#HEX" d="…"/></svg>`.
3. Mark `isDark` when the colour's relative luminance is below 0.08, e.g. `000000`, `231F20`, `181717`.
4. Write a Swift file: a header comment (generated from simple-icons 16.32.0, CC0 1.0, the
   generator's steps, and "brand marks belong to their owners"), then one
   `static let logos: [String: (svg: String, isDark: Bool)]` literal.
   - Use `##"…"##` raw strings; check no SVG contains `"##`.
   - Mark it `nonisolated(unsafe)` only if the compiler demands it for a tuple dictionary. Prefer a
     small `struct Logo: Sendable` in place of the tuple.

The arc normaliser (Python, used by the generator):

```python
import re
NUM = re.compile(r'[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?')
def normalize(d):
    out, i, cmd, n = [], 0, None, 0
    while i < len(d):
        ch = d[i]
        if ch.isalpha():
            cmd, n = ch, 0; out.append(ch); i += 1; continue
        if ch in ' ,\t\n\r':
            i += 1; continue
        if cmd and cmd.lower() == 'a' and n % 7 in (3, 4):
            assert ch in '01', d[i:i+20]
            out.append(ch); i += 1; n += 1; continue
        m = NUM.match(d, i); assert m, d[i:i+20]
        out.append(m.group(0)); i = m.end(); n += 1
    s = ''
    for tok in out:
        s += tok if (tok.isalpha() or not s or s[-1].isalpha()) else ' ' + tok
    return s
```

- [ ] **Step 1: Write the failing tests.** Create `Tests/LinkCKitTests/BoardTechTests.swift`:

```swift
import AppKit
import XCTest
@testable import LinkCKit

final class BoardTechTests: XCTestCase {
    func testAliasesResolveToCanonicalIDs() {
        XCTAssertEqual(BoardTech.canonical("Postgres"), "postgresql")
        XCTAssertEqual(BoardTech.canonical("k8s"), "kubernetes")
        XCTAssertEqual(BoardTech.canonical("node"), "nodedotjs")
        XCTAssertEqual(BoardTech.canonical("redis"), "redis")
        XCTAssertNil(BoardTech.canonical("aws"))
    }

    func testEveryKnownLogoLoadsAsA24PointSVG() throws {
        XCTAssertEqual(BoardTech.knownIDs.count, 47)
        for id in BoardTech.knownIDs {
            let info = try XCTUnwrap(BoardTech.info(id), id)
            let image = try XCTUnwrap(NSImage(data: Data(info.svg.utf8)), "\(id) does not load")
            XCTAssertTrue(image.isValid, id)
            XCTAssertTrue(image.representations.contains { String(describing: type(of: $0)).contains("SVG") }, id)
            XCTAssertEqual(image.size, NSSize(width: 24, height: 24), id)
            XCTAssertFalse(info.displayName.isEmpty, id)
        }
    }

    func testDarkBrandsAreFlagged() {
        XCTAssertEqual(BoardTech.info("github")?.isDark, true)
        XCTAssertEqual(BoardTech.info("redis")?.isDark, false)
    }

    func testResolveUsesTechThenAnExactName() {
        XCTAssertEqual(BoardTech.resolve(BoardComponent(name: "db", kind: .database, tech: "pg"))?.id, "postgresql")
        XCTAssertEqual(BoardTech.resolve(BoardComponent(name: "Redis", kind: .cache))?.id, "redis")
        XCTAssertNil(BoardTech.resolve(BoardComponent(name: "redis-worker", kind: .service)), "exact names only")
        XCTAssertNil(BoardTech.resolve(BoardComponent(name: "db", kind: .database, tech: "oracle")), "unknown tech draws the kind")
    }

    func testAgentNamesUseTheAgentLogos() {
        XCTAssertEqual(BoardTech.agent(for: BoardComponent(name: "claude", kind: .service)), .claude)
        XCTAssertEqual(BoardTech.agent(for: BoardComponent(name: "x", kind: .service, tech: "agy")), .agy)
        XCTAssertNil(BoardTech.resolve(BoardComponent(name: "codex", kind: .service)))
    }
}
```

- [ ] **Step 2: Run them and watch them fail** (stubs first).

- [ ] **Step 3: Generate the logos file and implement `BoardTech`.** Then add the known ids to the
  MCP `steps` description: `"tech": a known technology id or alias — ` followed by
  `BoardTech.knownIDs` joined with ", ". Add a test in `MCPServerBoardTests` that the tool list's
  description contains `postgresql`.

  Also check with `CORESVG_VERBOSE=1 swift test --filter BoardTechTests 2>&1 | grep -i coresvg`: it
  must print nothing. Put the result in the report.

- [ ] **Step 4: Run it and see it pass.** Run the full suite too.

- [ ] **Step 5: Commit:** `feat(board): a catalog of technology logos, and how a component finds its own`

---

### Task 3: `BoardLayout`: arrange a map by flow

**Files:**
- Create: `Sources/LinkCKit/Board/BoardLayout.swift`, `Tests/LinkCKitTests/BoardLayoutTests.swift`
- Modify:
  - `Sources/LinkCKit/Board/BoardGeometry.swift`: `componentSize` becomes `BoardPoint(x: 176, y: 84)`.
  - `Sources/LinkCKit/Board/BoardModel+Space.swift`: `laidOut` also separates overlapping components.

**Interfaces:**
- Produces: `public enum BoardLayout { public static func arranged(_ map: BoardMap) -> BoardMap }`.
  It is pure, nonisolated and deterministic, and changes positions and frame rects only.

**Constants:**

```swift
static let columnGapInFrame = 136
static let columnGapBetweenClusters = 184
static let rowStep = 132
static let framePadding = 24
static let frameTitleBand = 34
static let origin = BoardPoint(x: 40, y: 40)
static let notesGap = 48
```

The row gap is `rowStep - componentSize.y` = 48. Clusters of the same rank are separated vertically
by `rowStep`.

**Algorithm:**
1. **Clusters.** Each `map.frames` entry, keyed by label, plus a virtual cluster for
   `place == notPlaced` components, if any. A component whose `place` names no frame counts as
   Not placed.
2. **Cluster graph.**
   - There is a directed edge C→D when some component in C uses one in D, with C ≠ D.
   - Break cycles with a DFS over clusters in lowercased-label order (the virtual cluster sorts
     last): an edge to a node on the current DFS stack is reversed for ranking only.
   - `rank(C)` = the longest path from a source, in the acyclic graph.
3. **Inside a cluster.**
   - Take the internal edges and break cycles the same way, over lowercased names.
   - `column(c)` = the longest path from an internal source.
   - Order each column by name, then run 4 barycentre passes (left to right, then right to left,
     twice). Each component's key is the mean row index of its internal neighbours in the adjacent
     column. Components with none keep their index. The sort is stable, with the name as tiebreak.
4. **Cluster size.** With `cols` columns and `rows` = the tallest column:
   - `w = 2·framePadding + cols·176 + (cols−1)·columnGapInFrame`;
   - `h = frameTitleBand + rows·84 + (rows−1)·48 + framePadding`.
5. **Placing ranks.**
   - Each rank's x = the previous rank's x + the previous rank's widest cluster +
     `columnGapBetweenClusters`, starting at `origin.x`.
   - Within a rank, clusters are ordered by barycentre: the mean y-centre of the clusters in lower
     ranks they connect to, falling back to the label.
   - They are stacked from `origin.y`, separated by `rowStep`.
6. **Components and frames.**
   - A component sits at `(clusterX + framePadding + col·(176 + columnGapInFrame), clusterY + frameTitleBand + row·rowStep)`.
   - Each frame's rect becomes its cluster rect. The virtual cluster has no frame.
7. **Notes and texts.**
   - Notes form one column at x = the diagram's maxX + `notesGap`, stacked from `origin.y` with a
     24 pt gap, in file order.
   - Texts keep their positions. A text that overlaps any box, frame or note moves by
     `BoardGeometry.elementDrop`.
8. Snap every coordinate to the grid.

**`laidOut` separates overlaps.** After its existing work, any component whose box overlaps an
earlier component's box (in name order) moves by `BoardGeometry.elementDrop`, keeping its frame by
containment. This keeps existing boards valid after the size change. It runs in memory only, as
before.

- [ ] **Step 1: Write the failing tests.** Create `Tests/LinkCKitTests/BoardLayoutTests.swift`:

```swift
import XCTest
@testable import LinkCKit

final class BoardLayoutTests: XCTestCase {
    private func linkCMap() throws -> BoardMap {
        // linkC's own architecture, as drawn on 2026-09-24.
        try BoardMap.decode(Data("""
        { "version": 2, "places": {
          "linkC app": { "panel": {"kind":"service","uses":{"coordinator":"drives","board":"shows","usage":"usage rows","oracle-cloud":"Cloud section","supabase":""}},
                         "coordinator": {"kind":"service","uses":{"terminals":"spawns sessions","inbox":"relays","app-support":"saves state","notifications":"alerts"}},
                         "terminals": {"kind":"service","uses":{"claude":"hosts","codex":"hosts","cursor":"hosts","antigravity":"hosts"}},
                         "hook-server": {"kind":"service","uses":{"coordinator":"session state"}},
                         "board": {"kind":"service","uses":{"system-map":"reads, writes, watches","tool-servers":"what's running"}},
                         "usage": {"kind":"service","uses":{"transcripts":"reads"}},
                         "tool-servers": {"kind":"service","uses":{"docker":"docker compose"}} },
          "Agents": { "claude": {"kind":"service","uses":{"linkc-mcp":"tools","hook-server":"hook events"}},
                      "codex": {"kind":"service","uses":{"linkc-mcp":"tools"}},
                      "cursor": {"kind":"service","uses":{"linkc-mcp":"tools"}},
                      "antigravity": {"kind":"service","uses":{"linkc-mcp":"tools"}},
                      "linkc-mcp": {"kind":"service","uses":{"inbox":"messages, tasks","blackboard":"heartbeats, notes","system-map":"edits the Board"}} },
          "Project folder": { "inbox": {"kind":"queue"}, "blackboard": {"kind":"storage"}, "system-map": {"kind":"storage"} },
          "This Mac": { "app-support": {"kind":"storage"}, "transcripts": {"kind":"storage"}, "notifications": {"kind":"external"}, "docker": {"kind":"host","tech":"docker"} },
          "Cloud": { "oracle-cloud": {"kind":"external"}, "supabase": {"kind":"external","tech":"supabase"} },
          "Not placed": {} },
          "notes": ["one", "two"] }
        """.utf8))
    }

    private func rect(_ m: BoardMap, _ name: String) throws -> BoardRect {
        BoardGeometry.rect(ofComponentAt: try XCTUnwrap(m.components.first { $0.name == name }?.at, name))
    }

    func testTheSameMapAlwaysGetsTheSameLayout() throws {
        let m = try linkCMap()
        XCTAssertEqual(BoardLayout.arranged(m), BoardLayout.arranged(m))
        XCTAssertEqual(BoardLayout.arranged(BoardLayout.arranged(m)), BoardLayout.arranged(m), "arranging is idempotent")
    }

    func testNoBoxesOverlapAndEveryComponentIsInsideItsFrame() throws {
        let m = BoardLayout.arranged(try linkCMap())
        let boxes = m.components.compactMap { $0.at.map(BoardGeometry.rect(ofComponentAt:)) } + m.notes.compactMap { $0.at.map(BoardGeometry.rect(ofNoteAt:)) }
        XCTAssertEqual(boxes.count, m.components.count + m.notes.count, "everything placed")
        for i in boxes.indices { for j in boxes.indices where j > i { XCTAssertFalse(boxes[i].intersects(boxes[j])) } }
        for c in m.components where c.place != BoardMap.notPlaced {
            let frame = try XCTUnwrap(m.frames.first { $0.label == c.place }?.rect)
            XCTAssertTrue(BoardGeometry.interior(of: frame).contains(try rect(m, c.name)), c.name)
        }
        let frames = m.frames.compactMap(\.rect)
        for i in frames.indices { for j in frames.indices where j > i { XCTAssertFalse(frames[i].intersects(frames[j])) } }
    }

    func testFramesFlowLeftToRightByTheirArrows() throws {
        let m = BoardLayout.arranged(try linkCMap())
        func x(_ label: String) throws -> Int { try XCTUnwrap(m.frames.first { $0.label == label }?.rect?.x) }
        XCTAssertLessThan(try x("linkC app"), try x("Agents"))
        XCTAssertLessThan(try x("Agents"), try x("Project folder"))
        XCTAssertEqual(try x("Agents"), try x("This Mac"), "same rank stacks vertically")
    }

    func testInsideAFrameComponentsFlowByTheirArrows() throws {
        let m = BoardLayout.arranged(try linkCMap())
        XCTAssertLessThan(try rect(m, "panel").x, try rect(m, "coordinator").x)
        XCTAssertLessThan(try rect(m, "coordinator").x, try rect(m, "terminals").x)
        XCTAssertLessThan(try rect(m, "claude").x, try rect(m, "linkc-mcp").x)
    }

    func testNotesGoInAColumnToTheRight() throws {
        let m = BoardLayout.arranged(try linkCMap())
        let maxX = m.frames.compactMap(\.rect).map(\.maxX).max() ?? 0
        for note in m.notes { XCTAssertGreaterThanOrEqual(try XCTUnwrap(note.at).x, maxX) }
    }

    func testACycleDoesNotHangAndNotPlacedIsItsOwnCluster() throws {
        var m = BoardMap()
        m.components = [BoardComponent(name: "a", kind: .service, uses: ["b": ""]),
                        BoardComponent(name: "b", kind: .service, uses: ["a": ""])]
        let arranged = BoardLayout.arranged(m)
        XCTAssertNotNil(arranged.components.first?.at)
        XCTAssertTrue(arranged.frames.isEmpty)
    }

    func testLaidOutSeparatesOverlappingComponents() {
        var m = BoardMap()
        m.components = [BoardComponent(name: "a", kind: .service, at: BoardPoint(x: 0, y: 0)),
                        BoardComponent(name: "b", kind: .service, at: BoardPoint(x: 40, y: 16))]
        let fixed = BoardModel.laidOut(m)
        let a = BoardGeometry.rect(ofComponentAt: fixed.components[0].at!), b = BoardGeometry.rect(ofComponentAt: fixed.components[1].at!)
        XCTAssertFalse(a.intersects(b))
    }
}
```

  **Existing tests.** Changing `componentSize` shifts numbers that existing tests (geometry,
  placement, edit) assert. Update each to the new size where the test pins a *measurement*, not a
  rule, and list every one in the report. Never weaken a rule: no overlap, containment, and the like.

- [ ] **Step 2: Run them and watch them fail** (stubs first).

- [ ] **Step 3: Implement.** The algorithm above, the size change, and the `laidOut` addition.

- [ ] **Step 4: Run it and see it pass.** Run the full suite too.

- [ ] **Step 5: Commit:** `feat(board): BoardLayout arranges a map by flow, deterministically`

---

### Task 4: `BoardRouter`: orthogonal routes around boxes and foreign frames

**Files:**
- Create: `Sources/LinkCKit/Board/BoardRouter.swift`, `Tests/LinkCKitTests/BoardRouterTests.swift`

**Interfaces:**

```swift
public struct BoardRoute: Equatable, Sendable {
    public var points: [BoardPoint]      // first point on the source's side, last on the target's
    public var bundle: String?           // "out:<source>|<label>" or "in:<target>|<label>" when shared
}

public enum BoardRouter {
    public static let clearance = 12
    public static let laneGap = 8
    public static func routes(for map: BoardMap) -> [BoardModel.ArrowKey: BoardRoute]
}
```

**Algorithm:**
1. **Arrows.**
   - Every `uses` entry whose two ends are both positioned components.
   - Keyed by `ArrowKey(from:to:)` with the real names.
   - Processed in order of `(from.lowercased(), to.lowercased())`.
2. **Bundles.**
   - Arrows with the same source and the same non-empty label form an out-bundle, if there are 2 or
     more.
   - Otherwise, arrows with the same target and the same non-empty label form an in-bundle.
   - A bundle shares its port on that end and its first (out) or last (in) segment.
3. **Obstacles for an arrow.**
   - Every component box and note box except its two ends, inflated by `clearance`.
   - Every frame rect whose label is neither end's `place`, inflated by `clearance`.
4. **Sides and ports.**
   - Compare the centres. If `|dx| >= |dy|`, exit through the source's right side (or left) and
     enter the target's left (or right). Otherwise use bottom and top.
   - Port = the side's midpoint. Stubs extend `clearance` outwards; the route runs between the stub
     ends.
5. **Straight case.** If the two facing sides overlap along the other axis, and a straight segment
   at the middle of the overlap hits no obstacle, the route is that single segment. Both ports then
   sit on that line, overriding the midpoint.
6. **Otherwise, A\* on a sparse orthogonal grid, culled.**
   - Window: the bounding box of both stub ends, expanded by 240 pt. Only obstacles intersecting the
     window take part.
   - Grid coordinates:
     - xs = every obstacle's minX and maxX, the two stub ends' x, and the midpoints between
       consecutive distinct xs;
     - ys the same way.
   - Nodes are the grid points not strictly inside an obstacle. Edges join consecutive nodes along
     a row or column when the segment between them crosses no obstacle's interior.
   - Cost = length + 40 per change of direction + 0.3 × the length that runs within 4 pt of an
     already-routed segment of another bundle.
   - If no path is found, double the window, up to 3 times. Then fall back to a path around the
     outside of the whole diagram's bounding box, which always exists.
7. **Simplify** collinear points and drop zero-length segments.
8. **Nudging.**
   - After all arrows, group segments by channel: horizontal segments with the same y and
     overlapping x ranges, and vertical ones likewise.
   - In a group with k distinct bundles or arrows, spread them `laneGap` apart, centred on the
     channel, in a stable order.
   - Only apply an offset that keeps the segment clear of obstacles. Where it doesn't, keep the
     original.
   - Keep each route connected by moving the neighbouring segments' shared endpoints.
9. **Backward arrows** (target left of source) need no special case: they fall out of steps 4–6.

- [ ] **Step 1: Write the failing tests.** Create `Tests/LinkCKitTests/BoardRouterTests.swift`:

```swift
import XCTest
@testable import LinkCKit

final class BoardRouterTests: XCTestCase {
    private func segments(_ r: BoardRoute) -> [(BoardPoint, BoardPoint)] { Array(zip(r.points, r.points.dropFirst())) }

    /// A segment crosses a rect's interior (touching the border is allowed).
    private func crosses(_ a: BoardPoint, _ b: BoardPoint, _ r: BoardRect) -> Bool {
        let minX = min(a.x, b.x), maxX = max(a.x, b.x), minY = min(a.y, b.y), maxY = max(a.y, b.y)
        return minX < r.maxX && maxX > r.minX && minY < r.maxY && maxY > r.minY
            && (a.x == b.x ? (a.x > r.minX && a.x < r.maxX) : (a.y > r.minY && a.y < r.maxY))
    }

    private func arranged() throws -> BoardMap {
        BoardLayout.arranged(try BoardMap.decode(Data("""
        { "version": 2, "places": {
          "App": { "api": {"kind":"service","uses":{"db":"reads","cache":"reads","jobs":"enqueues"}}, "worker": {"kind":"service","uses":{"jobs":"consumes","db":"writes"}} },
          "Data": { "db": {"kind":"database"}, "cache": {"kind":"cache"}, "jobs": {"kind":"queue","uses":{"api":"callbacks"}} },
          "Not placed": {} } }
        """.utf8)))
    }

    func testNoRouteCrossesAComponentOrAForeignFrame() throws {
        let m = try arranged()
        let routes = BoardRouter.routes(for: m)
        XCTAssertEqual(routes.count, 6)
        for (key, route) in routes {
            for c in m.components where c.name != key.from && c.name != key.to {
                let box = BoardGeometry.rect(ofComponentAt: c.at!)
                for (a, b) in segments(route) { XCTAssertFalse(crosses(a, b, box), "\(key) crosses \(c.name)") }
            }
            let own = Set(m.components.filter { $0.name == key.from || $0.name == key.to }.map(\.place))
            for f in m.frames where !own.contains(f.label) {
                for (a, b) in segments(route) { XCTAssertFalse(crosses(a, b, f.rect!), "\(key) crosses frame \(f.label)") }
            }
            for (a, b) in segments(route) { XCTAssertTrue(a.x == b.x || a.y == b.y, "orthogonal") }
        }
    }

    func testSameRowNeighboursGetOneStraightSegment() {
        var m = BoardMap()
        m.components = [BoardComponent(name: "a", kind: .service, uses: ["b": "x"], at: BoardPoint(x: 0, y: 0)),
                        BoardComponent(name: "b", kind: .service, at: BoardPoint(x: 400, y: 0))]
        let route = BoardRouter.routes(for: m)[BoardModel.ArrowKey(from: "a", to: "b")]
        XCTAssertEqual(route?.points.count, 2)
    }

    func testABundleSharesItsPort() throws {
        var m = BoardMap()
        m.components = [BoardComponent(name: "hub", kind: .service, uses: ["a": "hosts", "b": "hosts", "c": "hosts"], at: BoardPoint(x: 0, y: 200)),
                        BoardComponent(name: "a", kind: .service, at: BoardPoint(x: 480, y: 0)),
                        BoardComponent(name: "b", kind: .service, at: BoardPoint(x: 480, y: 200)),
                        BoardComponent(name: "c", kind: .service, at: BoardPoint(x: 480, y: 400))]
        let routes = BoardRouter.routes(for: m)
        let firsts = Set(["a", "b", "c"].compactMap { routes[BoardModel.ArrowKey(from: "hub", to: $0)]?.points.first })
        XCTAssertEqual(firsts.count, 1, "one shared port")
        XCTAssertEqual(Set(["a", "b", "c"].compactMap { routes[BoardModel.ArrowKey(from: "hub", to: $0)]?.bundle }).count, 1)
    }

    func testParallelArrowsInOneCorridorGetSeparateLanes() {
        var m = BoardMap()
        m.components = [BoardComponent(name: "a1", kind: .service, uses: ["b1": "", "b2": ""], at: BoardPoint(x: 0, y: 0)),
                        BoardComponent(name: "a2", kind: .service, uses: ["b1": ""], at: BoardPoint(x: 0, y: 132)),
                        BoardComponent(name: "b1", kind: .service, at: BoardPoint(x: 600, y: 264)),
                        BoardComponent(name: "b2", kind: .service, at: BoardPoint(x: 600, y: 396))]
        let routes = BoardRouter.routes(for: m)
        var vertical: [Int: Int] = [:]
        for route in routes.values { for (a, b) in segments(route) where a.x == b.x && abs(a.y - b.y) > 40 { vertical[a.x, default: 0] += 1 } }
        XCTAssertTrue(vertical.values.allSatisfy { $0 == 1 }, "no two long vertical runs share an x: \(vertical)")
    }

    func testAHandDraggedOffGridBoardStillRoutesClear() {
        var m = BoardMap()
        m.components = [BoardComponent(name: "a", kind: .service, uses: ["d": ""], at: BoardPoint(x: 13, y: 7)),
                        BoardComponent(name: "wall1", kind: .service, at: BoardPoint(x: 230, y: -40)),
                        BoardComponent(name: "wall2", kind: .service, at: BoardPoint(x: 230, y: 60)),
                        BoardComponent(name: "d", kind: .service, at: BoardPoint(x: 470, y: 29))]
        let route = BoardRouter.routes(for: m)[BoardModel.ArrowKey(from: "a", to: "d")]!
        for wall in ["wall1", "wall2"] {
            let box = BoardGeometry.rect(ofComponentAt: m.components.first { $0.name == wall }!.at!)
            for (p, q) in segments(route) { XCTAssertFalse(crosses(p, q, box), wall) }
        }
    }

    func testTheSameMapRoutesTheSameWay() throws {
        let m = try arranged()
        XCTAssertEqual(BoardRouter.routes(for: m), BoardRouter.routes(for: m))
    }

    func testTwoHundredComponentsRouteWithinBudget() {
        var m = BoardMap()
        for i in 0..<200 {
            let uses = i + 1 < 200 ? ["c\(i + 1)": ""] : [:]
            var extra = uses
            if i + 7 < 200 && i % 2 == 0 { extra["c\(i + 7)"] = "" }
            m.components.append(BoardComponent(name: "c\(i)", kind: .service, uses: extra, at: BoardPoint(x: (i % 20) * 312, y: (i / 20) * 132)))
        }
        let start = Date()
        let routes = BoardRouter.routes(for: m)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThanOrEqual(routes.count, 290)
        XCTAssertLessThan(elapsed, 1.5, "debug-build guard; report the measured time")
    }
}
```

- [ ] **Step 2: Run them and watch them fail** (stubs first).

- [ ] **Step 3: Implement** the algorithm. Report the measured time of the budget test.

- [ ] **Step 4: Run it and see it pass.** Run the full suite too.

- [ ] **Step 5: Commit:** `feat(board): BoardRouter routes arrows around boxes and foreign frames`

---

### Task 5: `BoardLabels`: label pills that never overlap

**Files:**
- Create: `Sources/LinkCKit/Board/BoardLabels.swift`, `Tests/LinkCKitTests/BoardLabelsTests.swift`

**Interfaces:**

```swift
public enum BoardLabels {
    public static let height = 18
    /// The pill's width for a label: 10 pt text estimated at 5.8 pt per character, plus 14 pt of padding.
    public static func width(of label: String) -> Int
    /// Where each labelled arrow's pill goes; an arrow with no room is absent.
    public static func placed(routes: [BoardModel.ArrowKey: BoardRoute], labels: [BoardModel.ArrowKey: String],
                              obstacles: [BoardRect]) -> [BoardModel.ArrowKey: BoardRect]
    /// The obstacles for a map: every component and note box, and each frame's title band.
    public static func obstacles(for map: BoardMap) -> [BoardRect]
}
```

**Rules:**
- **Order.** Bundles first, one label each, taken from the bundle's lowest `ArrowKey`. Then the
  remaining arrows by route length, longest first, with ties by key.
- **Candidates for a route:**
  1. horizontal segments longer than the pill + 8, longest first; on each, positions from the
     centre outwards in 10 pt steps;
  2. then vertical segments longer than 30, with the pill centred on the line, positions from the
     centre outwards in 8 pt steps.
- A bundle uses only its shared segment.
- A position is accepted only if the pill overlaps no obstacle and no already-placed pill.
- Pills are snapped to whole points.

- [ ] **Step 1: Write the failing tests.** Create `Tests/LinkCKitTests/BoardLabelsTests.swift`:

```swift
import XCTest
@testable import LinkCKit

final class BoardLabelsTests: XCTestCase {
    private func arranged() throws -> BoardMap {
        BoardLayout.arranged(try BoardMap.decode(Data("""
        { "version": 2, "places": {
          "App": { "api": {"kind":"service","uses":{"db":"reads and writes","cache":"session cache","jobs":"enqueues"}},
                   "hub": {"kind":"service","uses":{"w1":"hosts","w2":"hosts","w3":"hosts"}} },
          "Data": { "db": {"kind":"database"}, "cache": {"kind":"cache"}, "jobs": {"kind":"queue"} },
          "Workers": { "w1": {"kind":"service"}, "w2": {"kind":"service"}, "w3": {"kind":"service"} },
          "Not placed": {} } }
        """.utf8)))
    }

    private func labels(_ m: BoardMap) -> [BoardModel.ArrowKey: String] {
        var out: [BoardModel.ArrowKey: String] = [:]
        for c in m.components { for (t, l) in c.uses where !l.isEmpty { out[BoardModel.ArrowKey(from: c.name, to: t)] = l } }
        return out
    }

    func testNoPillOverlapsABoxAFrameTitleOrAnotherPill() throws {
        let m = try arranged()
        let obstacles = BoardLabels.obstacles(for: m)
        let placed = BoardLabels.placed(routes: BoardRouter.routes(for: m), labels: labels(m), obstacles: obstacles)
        XCTAssertFalse(placed.isEmpty)
        let pills = Array(placed.values)
        for p in pills { for o in obstacles { XCTAssertFalse(p.intersects(o)) } }
        for i in pills.indices { for j in pills.indices where j > i { XCTAssertFalse(pills[i].intersects(pills[j])) } }
    }

    func testABundleIsLabelledOnce() throws {
        let m = try arranged()
        let placed = BoardLabels.placed(routes: BoardRouter.routes(for: m), labels: labels(m), obstacles: BoardLabels.obstacles(for: m))
        XCTAssertEqual(placed.keys.filter { $0.from == "hub" }.count, 1)
    }

    func testNoRoomMeansNotPlaced() {
        var m = BoardMap()
        m.components = [BoardComponent(name: "a", kind: .service, uses: ["b": "a label far too long to fit in this gap"], at: BoardPoint(x: 0, y: 0)),
                        BoardComponent(name: "b", kind: .service, at: BoardPoint(x: 200, y: 0))]
        let placed = BoardLabels.placed(routes: BoardRouter.routes(for: m), labels: labels(m), obstacles: BoardLabels.obstacles(for: m))
        XCTAssertTrue(placed.isEmpty)
    }

    func testTheSameInputPlacesTheSameWay() throws {
        let m = try arranged()
        let routes = BoardRouter.routes(for: m)
        XCTAssertEqual(BoardLabels.placed(routes: routes, labels: labels(m), obstacles: BoardLabels.obstacles(for: m)),
                       BoardLabels.placed(routes: routes, labels: labels(m), obstacles: BoardLabels.obstacles(for: m)))
    }
}
```

- [ ] **Step 2: Run them and watch them fail** (stubs first).

- [ ] **Step 3: Implement** the rules above.

- [ ] **Step 4: Run it and see it pass.** Run the full suite too.

- [ ] **Step 5: Commit:** `feat(board): BoardLabels places arrow labels where they never overlap`

---

### Task 6: The model and the MCP tool use the engine

**Files:**
- Modify:
  - `Sources/LinkCKit/Board/BoardModel.swift`: routes and labels computed off the main actor, and `tidyUp()`.
  - `Sources/LinkCKit/MCP/MCPServer.swift`: arrange before saving.
  - `Sources/LinkCKit/Board/BoardGeometry.swift`: delete `route(from:to:obstacles:)` if nothing uses it.
- Test: `BoardModelTests`, `MCPServerBoardTests`

**Interfaces:**
- `public private(set) var routes: [ArrowKey: BoardRoute]`: the type changes from `[BoardPoint]`.
- `public private(set) var labelRects: [ArrowKey: BoardRect]`
- `@discardableResult func recomputeRoutes() -> Task<Void, Never>` (internal, so tests can await it).
  It snapshots the map, runs `BoardRouter.routes` then `BoardLabels.placed` in `Task.detached`, and
  assigns both on the main actor only if no newer recompute has started (a generation counter).
- `public func tidyUp()`: one `edit { map = BoardLayout.arranged(map) }`. It is refused while locked,
  as every edit is, and changes nothing (no undo step) when the map is already arranged.
- MCP `editBoard`: after `BoardEdit.apply`, it runs `BoardLayout.arranged` on the result, then saves.
  The retry-once path does the same.

- [ ] **Step 1: Write the failing tests.** Add to `BoardModelTests`, using its helpers:

```swift
    func testRoutesAndLabelsAreComputedOffTheMainActor() async throws {
        let board = fresh()
        let a = try XCTUnwrap(board.addComponent(kind: .service, at: BoardPoint(x: 0, y: 0)))
        let b = try XCTUnwrap(board.addComponent(kind: .database, at: BoardPoint(x: 480, y: 0)))
        _ = board.addArrow(from: a, to: b)
        board.setArrowLabel(ArrowKey(from: a, to: b), to: "reads")
        await board.recomputeRoutes().value
        XCTAssertNotNil(board.routes[ArrowKey(from: a, to: b)])
        XCTAssertNotNil(board.labelRects[ArrowKey(from: a, to: b)])
    }

    func testTidyUpIsOneUndoStepAndArranges() throws {
        let board = fresh()
        _ = board.addComponent(kind: .service, at: BoardPoint(x: 900, y: 900))
        _ = board.addComponent(kind: .service, at: BoardPoint(x: 0, y: 0))
        let before = board.map
        board.tidyUp()
        XCTAssertEqual(board.map, BoardLayout.arranged(before))
        board.undo()
        XCTAssertEqual(board.map, before)
        board.redo()
        board.tidyUp()
        XCTAssertEqual(board.canRedo, false)
    }
```

  Add to `MCPServerBoardTests`:

```swift
    func testAnAgentEditLeavesTheMapArranged() throws {
        _ = try call(server(), "linkc_edit_board", ["steps": [["place": "App"], ["add": "api", "in": "App"], ["add": "db", "kind": "database"], ["connect": "api", "to": "db"]]])
        let onDisk = try XCTUnwrap(try BoardMapStore(workspacePath: tempDir.path).load()).map
        XCTAssertEqual(onDisk, BoardLayout.arranged(onDisk))
    }
```

  Where `ArrowKey` needs qualifying in the test file, write `BoardModel.ArrowKey`. Update existing
  tests that read `routes[...]` as `[BoardPoint]` to read `.points`.

- [ ] **Step 2: Run them and watch them fail.**

- [ ] **Step 3: Implement.**
  - `afterMapChange`, `mapLoaded` and `diskChanged` call the new `recomputeRoutes()`.
  - Update every app-target reader of `board.routes` (`BoardCanvas.swift`) to `.points`, so the app
    still builds. Task 7 redraws them.

- [ ] **Step 4: Run it and see it pass.** Run the full suite too.

- [ ] **Step 5: Commit:** `feat(board): the Board routes and labels off the main actor; tidy up; agent edits arrive arranged`

---

### Task 7: Drawing: shapes, logos, routes, label pills, hover, Tidy up

**Files:**
- Modify:
  - `Sources/linkc/Board/BoardElements.swift`: `ComponentBox` draws the kind's shape.
  - `Sources/linkc/Board/BoardCanvas.swift`: routes, pills, hover dimming, drag preview.
  - `Sources/linkc/Board/BoardTools.swift`: the Tidy up button.
- Create: `Sources/linkc/Board/TechLogoView.swift`

**Components (`ComponentBox`):**
- The size is `BoardGeometry.componentSize` (176 × 84).
- It draws the kind's shape as a SwiftUI `Path`, filled with `Theme.boardBox` and stroked with
  `Theme.boardBoxStroke`, following the spec §1 table. Use the mockup's proportions (a cylinder
  rim of 11 pt, a pipe inset of 12, a bucket taper of 8, and so on). The "planned" state is a dashed
  stroke and no fill, as now. "Selected" is an accent stroke along the same outline. "Missing" is
  0.5 opacity. "Present" is the green dot, top right.
- Icon at 24 pt:
  - `BoardTech.agent(for:)` → `AgentLogoView`;
  - else `BoardTech.resolve` → `TechLogoView`;
  - else the kind's SF Symbol glyph, as now.
- Name: 13.5 pt semibold.
- Sub-line: 8.5 pt semibold, secondary. It reads `KIND · <display name>`; else
  `KIND · <reachedBy>`, truncated; else `KIND`.
- The help tooltip stays.

**`TechLogoView`** mirrors `AgentLogoView`:
- it loads each `BoardTechInfo.svg` once into a cached `NSImage`;
- `isDark` → template rendering tinted `Theme.textPrimary`;
- a logo that fails to load is `fatalError` with the id.

**Arrows (in `drawArrows`):**
- Stroke `route.points` with 7 pt rounded corners, the arrowhead at the end, and 1.3 pt (1.8 when
  highlighted).
- A planned target stays dashed.
- Replace the old midpoint label code: draw each `board.labelRects` pill as a rounded 9 pt rect,
  filled `Theme.boardBackground` and stroked 0.12 white, with the label centred in 10 pt.

**Hover and select** (canvas state: `hovered` component and `hoveredArrow`):
- The *focus* is the hovered component, or else a single selected component.
- With a focus:
  - its arrows are drawn in `Theme.accent` at 1.8 pt, and their pills show, including labels with
    no `labelRects` entry, drawn at the midpoint of their longest segment;
  - other arrows are drawn at 0.12 opacity, with their pills hidden;
  - components not connected to the focus are drawn at 0.3 opacity.
- Hovering an arrow shows its label, if it's hidden, and highlights that arrow.
- Hit-test arrows against their segments within 5 pt, only while the pointer moves over empty
  canvas.
- These are view state only; no model writes.

**Drag preview:** while dragging, an arrow touching a moving element is drawn as a straight dashed
line between the live box centres. `livePoints` becomes that. No router call happens during the
drag; the model re-routes on release.

**Tidy up:** a toolbar button (`wand.and.stars`, "Tidy up") after the tools. It calls
`board.tidyUp()` and is disabled while `!board.canEdit` or the map is empty. If `canEdit` isn't
visible to the app, expose `public var isLocked: Bool` on the model.

- [ ] **Step 1: Build the views and wiring as above.**

- [ ] **Step 2: Verify.** Build, check for warnings, and run the full suite. In the report, list the
  hand checks:
  - the shapes and logos at 25%, 100% and 200% zoom;
  - hover dimming;
  - the arrow-hover label;
  - Tidy up and ⌘Z;
  - the drag preview;
  - agent edits arriving arranged.

- [ ] **Step 3: Commit:** `feat(board): shapes per kind, logos, routed arrows, label pills and hover focus`

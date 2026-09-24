# Agent Board Tools Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Agents read and edit a project's Board through two MCP tools, and the open Board follows
`system-map.json` live. What changed glows briefly, ⌘Z undoes an outside change, and a simultaneous
edit merges instead of locking.

**Architecture:** Everything with a rule is pure and lives in LinkCKit, behind tests:
- `BoardEdit`: steps to map;
- `BoardMerge`: a three-way merge by element;
- `BoardModel.diskChanged()`: taking an outside change;
- `BoardFileWatcher`: a kqueue watch.

The MCP server calls `BoardEdit`. The app only starts the watcher and draws the glow. The Board's
placement helpers become `nonisolated`, so the MCP server, which is not on the main actor, runs
exactly the Board's code.

**Tech Stack:** Swift 6, macOS 14, Foundation/Dispatch, XCTest. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-09-23-agent-board-tools-design.md`

## Global Constraints

- Swift 6 / macOS 14 deployment target. **No new packages or dependencies.**
- TDD for everything in LinkCKit. Watch each new test fail on an assertion before implementing; a
  compile error doesn't count, so add a stub first if needed. The app target has no UI harness:
  build it, and read your change carefully.
- **Fail loud:**
  - no `try?` on file I/O or decoding;
  - no swallowed `false`;
  - no silent fallbacks.
  - A refused step names its step number and why.
- One implementation of every rule. The MCP tool and the Board share `BoardModel`'s placement
  helpers; never copy them.
- No view body writes observable state. No debug prints, commented-out code or scratch files left
  behind. Delete what becomes dead.
- **Commits:**
  - One-line `feat(board): …` / `fix(board): …` / `refactor(board): …` messages.
  - Stage files by name; never `git add -A` or `git add .`.
  - The untracked `system-map.json` at the repository root belongs to the user. Never stage,
    modify or delete it.
  - No message may contain "claude" in any case.
  - No trailers of any kind (no Co-Authored-By, no session links, no "Generated with").
  - Check with `git log -1 --format=%B | grep -ic claude` (must print 0).
- **Verify every task:**
  - `swift build 2>&1 | tail -3` is clean;
  - `swift build 2>&1 | grep -i warning` prints nothing;
  - `swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1` shows 0 failures. The baseline
    is 1178 tests, 5 skipped, 0 failures.

---

### Task 1: The Board's placement helpers, usable off the main actor

**Files:**
- Modify: `Sources/LinkCKit/Board/BoardModel.swift`, `Sources/LinkCKit/Board/BoardModel+Space.swift`
- Test: `Tests/LinkCKitTests/BoardPlacementTests.swift` (new)

**Interfaces:**
- Produces, all `nonisolated static` on `BoardModel`:
  - `elementRects(_:excluding:)`
  - `frameRects(_:excluding:)`
  - `index(of:in:)`
  - `uniqueName(_:taken:separator:)`
  - `roundedUpToGrid(_:)`
  - `laidOut(_:)` and its private helpers
  - `localDocker`
  - `noRoomInLocalDocker`
- New helpers, also `nonisolated static`:
  - `placeComponent(_ component: BoardComponent, inFrame label: String, into map: inout BoardMap) -> Bool`:
    it appends the component inside the frame (growing it if needed), and returns false if the
    frame has no room and can't grow. In that case it places the component outside, filed by
    the containment rule, as "Add what's running" does today.
  - `appendFrame(label: String, size: BoardPoint, into map: inout BoardMap)`: a new frame to the
    right of everything.
  - `placeLoose(_ component: BoardComponent, into map: inout BoardMap)`: a Not-placed component
    to the right of everything, never overlapping.

- [ ] **Step 1: Write the failing tests.** Create `Tests/LinkCKitTests/BoardPlacementTests.swift`:

```swift
import XCTest
@testable import LinkCKit

/// The Board's placement rules, called the way the MCP tool calls them: off the main actor.
final class BoardPlacementTests: XCTestCase {
    private func rects(_ map: BoardMap) -> [BoardRect] {
        map.components.compactMap { $0.at.map(BoardGeometry.rect(ofComponentAt:)) }
            + map.notes.compactMap { $0.at.map(BoardGeometry.rect(ofNoteAt:)) }
    }

    private func assertNoOverlaps(_ map: BoardMap, file: StaticString = #filePath, line: UInt = #line) {
        let all = rects(map)
        for i in all.indices { for j in all.indices where j > i {
            XCTAssertFalse(all[i].intersects(all[j]), "\(all[i]) overlaps \(all[j])", file: file, line: line)
        } }
    }

    func testAComponentPlacedInAFrameLandsInsideItClearOfItsNotes() throws {
        var map = BoardMap()
        map.frames = [BoardFrame(label: "Local docker", rect: BoardRect(x: 0, y: 0, w: 344, h: 200))]
        map.notes = [BoardNote(text: "keep", at: BoardPoint(x: 8, y: 8))]
        let placed = BoardModel.placeComponent(BoardComponent(name: "redis", kind: .cache), inFrame: "Local docker", into: &map)
        XCTAssertTrue(placed)
        let redis = try XCTUnwrap(map.components.first)
        XCTAssertEqual(redis.place, "Local docker")
        let frame = try XCTUnwrap(map.frames.first?.rect)
        XCTAssertTrue(BoardGeometry.interior(of: frame).contains(BoardGeometry.rect(ofComponentAt: try XCTUnwrap(redis.at))))
        assertNoOverlaps(map)
    }

    func testAFullFrameGrowsToTakeTheComponent() throws {
        var map = BoardMap()
        map.frames = [BoardFrame(label: "Tight", rect: BoardRect(x: 0, y: 0, w: 176, h: 80))]
        map.components = [BoardComponent(name: "a", kind: .service, place: "Tight", at: BoardPoint(x: 8, y: 8))]
        XCTAssertTrue(BoardModel.placeComponent(BoardComponent(name: "b", kind: .service), inFrame: "Tight", into: &map))
        let frame = try XCTUnwrap(map.frames.first?.rect)
        XCTAssertGreaterThan(frame.w * frame.h, 176 * 80, "the frame grew")
        XCTAssertEqual(map.components.map(\.place), ["Tight", "Tight"])
        assertNoOverlaps(map)
    }

    func testANewFrameAndALooseComponentGoToTheRightOfEverything() throws {
        var map = BoardMap()
        map.components = [BoardComponent(name: "api", kind: .service, at: BoardPoint(x: 400, y: 0))]
        BoardModel.appendFrame(label: "Oracle box", size: BoardGeometry.frameMinSize, into: &map)
        let frame = try XCTUnwrap(map.frames.first?.rect)
        XCTAssertGreaterThanOrEqual(frame.x, 400 + BoardGeometry.componentSize.x)
        BoardModel.placeLoose(BoardComponent(name: "cdn", kind: .external), into: &map)
        let cdn = try XCTUnwrap(map.components.last?.at)
        XCTAssertGreaterThanOrEqual(cdn.x, frame.maxX)
        XCTAssertEqual(map.components.last?.place, BoardMap.notPlaced)
        assertNoOverlaps(map)
    }
}
```

- [ ] **Step 2: Run it and watch it fail.** Add stubs for the three new helpers, each doing
  nothing. Then run `swift test --filter BoardPlacementTests`: the assertions should fail.
  Calling these from a nonisolated `XCTestCase` also proves the helpers are `nonisolated`. If a
  helper is not, it is a compile error; fix that first.

- [ ] **Step 3: Implement.**
  - **Mark the helpers `nonisolated`:** mark the listed statics `nonisolated static`, including
    `laidOut` and every private static helper it calls in `BoardModel+Space.swift`. For the
    static lets, write `nonisolated static let localDocker` and
    `nonisolated static let noRoomInLocalDocker`. Each is a pure function of its arguments.
  - **Split `place(_ suggestions:into:)`** into the three new helpers:
    - `appendFrame` is its "no Local docker frame yet" block, generalised to a label and a size.
    - `placeComponent` is its per-suggestion loop body, generalised to any frame label: the
      seed, the members and foreign obstacles, `nearestFreeSpot`, `grow`, and the overflow
      filed by containment. It returns whether the component landed inside.
    - `placeLoose` is the overflow drop: seed at `(max content maxX + 48, 0)`, then
      `elementDrop` against every element and frame, place `notPlaced` (or the frame
      containing it).

    `place(_ suggestions:into:)` keeps its dedupe and its sizing of a new Local docker frame, and
    then calls these helpers, so "Add what's running" behaves exactly as before.
  - **Keep the existing tests green unchanged.**

- [ ] **Step 4: Run the tests and see them pass.** Run the new file and the full suite; every
  existing Board test stays green.

- [ ] **Step 5: Commit:** `refactor(board): the Board's placement helpers work off the main actor`

---

### Task 2: `BoardEdit`: steps to map

**Files:**
- Create: `Sources/LinkCKit/Board/BoardEdit.swift`, `Tests/LinkCKitTests/BoardEditTests.swift`

**Interfaces:**
- Consumes: Task 1's helpers.
- Produces:

```swift
public struct BoardComponentFields: Equatable, Sendable {
    public var kind: ComponentKind?
    public var does: String?        // "" clears
    public var reachedBy: String?   // "" clears
    public var runs: String?        // "" clears
    public var planned: Bool?
}

public enum BoardEditStep: Equatable, Sendable {
    case add(String, BoardComponentFields, place: String?)
    case update(String, BoardComponentFields, place: String?, rename: String?)
    case remove(String)
    case connect(String, to: String, label: String?)
    case disconnect(String, to: String)
    case addPlace(String)
    case renamePlace(String, to: String)
    case removePlace(String)
    case note(String)
    case removeNote(String)
    case system(String)
}

public struct BoardEditRefusal: Error, Equatable, CustomStringConvertible {
    public let step: Int          // 1-based
    public let reason: String
    public var description: String { "step \(step): \(reason)" }
}

public enum BoardEdit {
    public static let maxSteps = 50
    /// Decodes the tool's `steps` argument. Throws `BoardEditRefusal` for a malformed step.
    public static func steps(from json: Any?) throws -> [BoardEditStep]
    /// Applies every step to a copy; the first refusal throws and nothing is returned.
    /// Returns the new map and one summary line per step.
    public static func apply(_ steps: [BoardEditStep], to map: BoardMap) throws -> (map: BoardMap, lines: [String])
}
```

**Decoding rules for `steps(from:)`:**
- `json` must be an array of 1…`maxSteps` objects.
- Each object has exactly one verb key: `add`, `update`, `remove`, `connect`, `disconnect`,
  `place`, `remove_place`, `note`, `remove_note` or `system`.
- `place` with `rename` is `renamePlace`; `place` alone is `addPlace`.
- Known fields are type-checked:
  - strings: `kind`, `does`, `reached_by`, `runs`, `in`, `rename`, `to`, `label`;
  - bool: `planned`.
- An unknown key in a step is refused. That covers a typo'd field; an unknown verb has no verb
  key, and names two verbs is also refused.
- `kind: ""` is refused.
- Messages include the step number, e.g. `step 2: "planned" must be true or false`.

**Apply rules:**
1. First, `var map = BoardModel.laidOut(map)`, so everything in the file has a position before
   placement.
2. Names, places and arrow ends match case-insensitively.
3. Every name and label is trimmed and must be non-empty.
4. `"Not placed"` is reserved for `place`/`rename`, but allowed as `in`, meaning "take it out of
   its frame".
5. `add`:
   - refused if the name exists;
   - `kind` defaults to `.service`; `planned` defaults to false;
   - `in` must name an existing place (after earlier steps), else the step is refused with the
     list of places;
   - with a place, `placeComponent`; otherwise `placeLoose`.
6. `update`:
   - refused if the name is missing, with the list of components;
   - fields given replace; `""` clears `does`/`reachedBy`/`runs`;
   - `in` moves the component: take it out, then `placeComponent` or `placeLoose` at its new place;
   - `rename` carries arrows exactly as `BoardModel.updateComponent` does.
7. `remove`: the component and every arrow to or from it.
8. `connect`:
   - both ends must exist, and must differ;
   - it sets `uses[realTargetName] = label ?? existingLabel ?? ""`, so connecting again relabels.
9. `disconnect`: refused if there is no such arrow.
10. `addPlace`: refused if the label exists; `appendFrame(label:size: BoardGeometry.frameMinSize)`.
11. `renamePlace`: the same rules as `BoardModel.renameFrame`; components follow.
12. `removePlace`: frame gone, its components become `notPlaced` and keep their positions.
13. `note`: append `BoardNote(text:)`, positioned with `placeLoose`'s rule for a note-sized rect.
    Use `BoardGeometry.rect(ofNoteAt:)` and `elementDrop`; don't add a separate note placer
    unless you need one.
14. `removeNote`: exact text match, refused if none.
15. `system`: trimmed; `""` clears.
16. **Refusal messages list what exists**, e.g. `no component "apii" — components: api, postgres,
    redis`, or `no place "Dockr" — places: Local docker, Oracle box`. List names sorted
    case-insensitively; when empty, say `(none)`.
17. **Summary lines**, one per step. An add reads `added <name> (<kind>)`, with `planned, ` inside
    the brackets when planned, and ` in <place>` when it has one. For example:
    - `added redis (planned, cache) in Local docker`
    - `added cdn (service)`
    - `updated api`
    - `renamed api → gateway`
    - `removed redis`
    - `api → redis "session cache"`
    - `api → redis` (no label)
    - `disconnected api → redis`
    - `added place Oracle box`
    - `renamed place A → B`
    - `removed place A`
    - `added a note`
    - `removed a note`
    - `set the summary`

- [ ] **Step 1: Write the failing tests.** Create `Tests/LinkCKitTests/BoardEditTests.swift`:

```swift
import XCTest
@testable import LinkCKit

final class BoardEditTests: XCTestCase {
    /// June, laid out: api and postgres in Local docker; june-audio not placed.
    private func june() throws -> BoardMap {
        try BoardMap.decode(Data("""
        { "version": 2, "places": {
            "Local docker": { "api": { "kind": "service", "uses": { "postgres": "" } },
                              "postgres": { "kind": "database" } },
            "Not placed": { "june-audio": { "kind": "host" } } },
          "notes": ["Stream uploads."],
          "layout": { "components": { "api": [48, 48], "postgres": [232, 48], "june-audio": [600, 48] },
                      "frames": { "Local docker": [40, 40, 360, 200] }, "notes": [[600, 200]] } }
        """.utf8))
    }

    private func apply(_ json: Any, to map: BoardMap) throws -> (map: BoardMap, lines: [String]) {
        try BoardEdit.apply(try BoardEdit.steps(from: json), to: map)
    }

    private func refusal(_ json: Any, on map: BoardMap) -> BoardEditRefusal? {
        do { _ = try apply(json, to: map); return nil } catch let error as BoardEditRefusal { return error } catch {
            XCTFail("unexpected \(error)"); return nil
        }
    }

    private func assertNoOverlaps(_ map: BoardMap, file: StaticString = #filePath, line: UInt = #line) {
        let all = map.components.compactMap { $0.at.map(BoardGeometry.rect(ofComponentAt:)) }
            + map.notes.compactMap { $0.at.map(BoardGeometry.rect(ofNoteAt:)) }
        for i in all.indices { for j in all.indices where j > i {
            XCTAssertFalse(all[i].intersects(all[j]), "\(all[i]) overlaps \(all[j])", file: file, line: line)
        } }
    }

    func testAddPlacesAComponentInsideTheNamedFrame() throws {
        let result = try apply([["add": "redis", "kind": "cache", "in": "local docker", "does": "session cache", "planned": true]], to: june())
        let redis = try XCTUnwrap(result.map.components.first { $0.name == "redis" })
        XCTAssertEqual(redis.kind, .cache)
        XCTAssertEqual(redis.place, "Local docker", "places match regardless of case")
        XCTAssertTrue(redis.planned)
        XCTAssertEqual(redis.does, "session cache")
        let frame = try XCTUnwrap(result.map.frames.first { $0.label == "Local docker" }?.rect)
        XCTAssertTrue(BoardGeometry.interior(of: frame).contains(BoardGeometry.rect(ofComponentAt: try XCTUnwrap(redis.at))))
        assertNoOverlaps(result.map)
        XCTAssertEqual(result.lines, ["added redis (planned, cache) in Local docker"])
    }

    func testAddWithNoPlaceGoesToTheRightOfEverything() throws {
        let result = try apply([["add": "cdn"]], to: june())
        let cdn = try XCTUnwrap(result.map.components.first { $0.name == "cdn" })
        XCTAssertEqual(cdn.kind, .service)
        XCTAssertEqual(cdn.place, BoardMap.notPlaced)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(cdn.at).x, 600 + BoardGeometry.componentSize.x)
        assertNoOverlaps(result.map)
    }

    func testAnUnknownPlaceIsRefusedWithThePlacesThatExist() throws {
        let refused = refusal([["add": "redis", "in": "Dockr"]], on: try june())
        XCTAssertEqual(refused?.description, #"step 1: no place "Dockr" — places: Local docker"#)
    }

    func testAPlaceCreatedEarlierInTheCallCanBeUsed() throws {
        let result = try apply([["place": "Oracle box"], ["update": "june-audio", "in": "Oracle box"]], to: june())
        let audio = try XCTUnwrap(result.map.components.first { $0.name == "june-audio" })
        XCTAssertEqual(audio.place, "Oracle box")
        let frame = try XCTUnwrap(result.map.frames.first { $0.label == "Oracle box" }?.rect)
        XCTAssertTrue(BoardGeometry.interior(of: frame).contains(BoardGeometry.rect(ofComponentAt: try XCTUnwrap(audio.at))))
        assertNoOverlaps(result.map)
    }

    func testUpdatingAMissingNameIsRefusedWithTheNamesThatExist() throws {
        XCTAssertEqual(refusal([["update": "apii", "does": "x"]], on: try june())?.description,
                       #"step 1: no component "apii" — components: api, june-audio, postgres"#)
    }

    func testAllOrNothing() throws {
        let map = try june()
        let refused = refusal([["add": "redis"], ["connect": "api", "to": "redis"], ["remove": "nope"]], on: map)
        XCTAssertEqual(refused?.step, 3)
        // The caller's map is a value; the only way to "write" is the returned map, and none came back.
    }

    func testRenameCarriesArrows() throws {
        let result = try apply([["update": "postgres", "rename": "db"]], to: june())
        XCTAssertEqual(result.map.components.first { $0.name == "api" }?.uses, ["db": ""])
        XCTAssertEqual(result.lines, ["renamed postgres → db"])
    }

    func testConnectAddsThenRelabels() throws {
        var result = try apply([["connect": "june-audio", "to": "API"]], to: june())
        XCTAssertEqual(result.map.components.first { $0.name == "june-audio" }?.uses, ["api": ""])
        result = try apply([["connect": "api", "to": "postgres", "label": "reads and writes"]], to: result.map)
        XCTAssertEqual(result.map.components.first { $0.name == "api" }?.uses, ["postgres": "reads and writes"])
        XCTAssertEqual(result.lines, [#"api → postgres "reads and writes""#])
    }

    func testAnArrowToItselfIsRefused() throws {
        XCTAssertNotNil(refusal([["connect": "api", "to": "api"]], on: try june()))
    }

    func testRemoveTakesItsArrows() throws {
        let result = try apply([["remove": "postgres"]], to: june())
        XCTAssertNil(result.map.components.first { $0.name == "postgres" })
        XCTAssertEqual(result.map.components.first { $0.name == "api" }?.uses, [:])
    }

    func testRemovingAPlaceKeepsItsComponentsWhereTheyAre() throws {
        let before = try june()
        let result = try apply([["remove_place": "Local docker"]], to: before)
        XCTAssertTrue(result.map.frames.isEmpty)
        let api = try XCTUnwrap(result.map.components.first { $0.name == "api" })
        XCTAssertEqual(api.place, BoardMap.notPlaced)
        XCTAssertEqual(api.at, BoardPoint(x: 48, y: 48))
    }

    func testNotesAndTheSummary() throws {
        let result = try apply([["note": "Redis is only for sessions."], ["remove_note": "Stream uploads."], ["system": "June — audio journaling"]], to: june())
        XCTAssertEqual(result.map.notes.map(\.text), ["Redis is only for sessions."])
        XCTAssertNotNil(result.map.notes.first?.at)
        XCTAssertEqual(result.map.system, "June — audio journaling")
        assertNoOverlaps(result.map)
    }

    func testMalformedStepsAreRefused() throws {
        XCTAssertEqual(refusal([["add": "x", "planned": "yes"]], on: .empty)?.description, #"step 1: "planned" must be true or false"#)
        XCTAssertNotNil(refusal([["ad": "x"]], on: .empty), "no verb")
        XCTAssertNotNil(refusal([["add": "x", "remove": "y"]], on: .empty), "two verbs")
        XCTAssertNotNil(refusal([["add": "x", "kidn": "cache"]], on: .empty), "an unknown field")
        XCTAssertNotNil(refusal([["add": "x", "kind": ""]], on: .empty))
        XCTAssertNotNil(refusal([["add": "  "]], on: .empty))
        XCTAssertNotNil(refusal([["place": "not placed"]], on: .empty), "reserved")
        XCTAssertThrowsError(try BoardEdit.steps(from: [] as [Any]))
        XCTAssertThrowsError(try BoardEdit.steps(from: Array(repeating: ["note": "n"], count: 51)))
        XCTAssertThrowsError(try BoardEdit.steps(from: "add redis"))
    }

    func testAnEmptyMapStartsFromNothing() throws {
        let result = try apply([["place": "Local docker"], ["add": "api", "in": "Local docker"], ["add": "db", "kind": "database", "in": "Local docker"], ["connect": "api", "to": "db"]], to: .empty)
        XCTAssertEqual(Set(result.map.components.map(\.place)), ["Local docker"])
        assertNoOverlaps(result.map)
    }
}
```

- [ ] **Step 2: Run it and watch it fail.** First add stubs so it compiles: the types, and
  functions that throw or return the input. Run `swift test --filter BoardEditTests`.

- [ ] **Step 3: Implement `BoardEdit.swift`** following the decoding and apply rules above. Every
  placement goes through Task 1's helpers.

- [ ] **Step 4: Run it and see it pass.** Run the full suite too.

- [ ] **Step 5: Commit:** `feat(board): BoardEdit turns a list of steps into a map, by the Board's rules`

---

### Task 3: The MCP tools

**Files:**
- Modify:
  - `Sources/LinkCKit/MCP/MCPServer.swift`: tool list, handlers, `readOnlyTools`, the project-context line.
  - `Sources/LinkCKit/Board/BoardMap.swift`: `architectureJSON()`.
- Test: `Tests/LinkCKitTests/MCPServerBoardTests.swift` (new)

**Interfaces:**
- Consumes: `BoardEdit`, `BoardMapStore`, `BoardReport.sanitized`.
- Produces:
  - `public func architectureJSON() throws -> String` on `BoardMap`: `encoded()` without its
    `layout` key, written by `BoardMapJSON` in the same order.
  - The tools `linkc_get_board` (read-only) and `linkc_edit_board`.

**Tool definitions** (add to the `tools/list` array, matching the existing entries' shape):
- `linkc_get_board`:
  - description: "Read this project's Board — its architecture (system, places, components, notes) as JSON, exactly as `system-map.json` holds it minus layout. Use the exact names it shows with linkc_edit_board."
  - input schema: an empty object.
- `linkc_edit_board`:
  - description: "Change this project's Board with a list of steps, applied in order, all or nothing. Verbs: add, update, remove, connect, disconnect, place, remove_place, note, remove_note, system. linkC places everything on the canvas; the user sees it live. When you add or change infrastructure (a service, database, cache, queue, host…), reflect it on the Board."
  - input schema: `steps`, an array of objects, required, with a description giving the
    `add`/`connect` examples from spec §1.

**Handlers:**
- **`linkc_get_board`:**
  - Load `BoardMapStore(workspacePath: workspaceRoot)`.
  - No map → `This project has no map yet — linkc_edit_board creates one.`
  - A map → its `architectureJSON()` + `\n\n` + `Verbs: add, update, remove, connect, disconnect, place, remove_place, note, remove_note, system. Kinds: service, database, cache, queue, storage, host, external (any other kind is kept and drawn as a service).`
  - A load error → `isError`, with the text sanitized by `BoardReport.sanitized`.
- **`linkc_edit_board`:**
  1. Decode the steps.
  2. Load: a missing file gives `.empty` with expected bytes nil.
  3. `apply`.
  4. `save(expecting:)`.
  5. On `BoardMapStoreError.changedOnDisk`, reload, re-apply and save once more. A second
     collision → `isError` "the map kept changing while this edit was saved — try again".
  6. On success, reply with the summary lines joined by newlines + `\nBoard updated.`.
  7. A `BoardEditRefusal` → `isError` with its description. A load error → `isError`, sanitized.

  The existing identified-caller guard covers it: add `linkc_get_board` to `readOnlyTools`, but
  not `linkc_edit_board`.
- **Project context:** in `linkc_get_project_context`, after `text += BoardReport.markdown(for: loaded.map)`,
  append `"Read with `linkc_get_board`; change with `linkc_edit_board`.\n\n"`. When there's no map,
  append `"## System\n_No map yet — `linkc_edit_board` starts one._\n\n"`.

- [ ] **Step 1: Write the failing tests.** Create `Tests/LinkCKitTests/MCPServerBoardTests.swift`:

```swift
import XCTest
@testable import LinkCKit

final class MCPServerBoardTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-mcp-board-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: tempDir)
    }

    private func server() -> MCPServer {
        MCPServer(workspaceRoot: tempDir.path, environment: ["LINKC_AGENT": "codex"], ancestorResolver: { _ in nil }, sessionResolver: { nil })
    }

    private func call(_ server: MCPServer, _ name: String, _ args: [String: Any] = [:]) throws -> (text: String, isError: Bool) {
        let req: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": args]]
        let res = try XCTUnwrap(server.handleMessage(try JSONSerialization.data(withJSONObject: req)))
        let json = try JSONSerialization.jsonObject(with: res) as? [String: Any]
        let result = json?["result"] as? [String: Any]
        let text = ((result?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        return (text, result?["isError"] as? Bool ?? false)
    }

    private var mapURL: URL { tempDir.appendingPathComponent("system-map.json") }

    func testGetBoardWithNoMapSaysEditCreatesOne() throws {
        let read = try call(server(), "linkc_get_board")
        XCTAssertFalse(read.isError)
        XCTAssertTrue(read.text.contains("no map yet"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mapURL.path), "reading never writes")
    }

    func testEditCreatesTheMapAndGetReadsItBackWithoutLayout() throws {
        let s = server()
        let edit = try call(s, "linkc_edit_board", ["steps": [["place": "Local docker"], ["add": "redis", "kind": "cache", "in": "Local docker"]]])
        XCTAssertFalse(edit.isError, edit.text)
        XCTAssertTrue(edit.text.hasSuffix("Board updated."))
        XCTAssertTrue(edit.text.contains("added redis (cache) in Local docker"))
        let read = try call(s, "linkc_get_board")
        XCTAssertTrue(read.text.contains("\"redis\""))
        XCTAssertFalse(read.text.contains("\"layout\""), "agents never see coordinates")
        XCTAssertTrue(read.text.contains("Verbs: add, update"))
        let onDisk = try XCTUnwrap(try BoardMapStore(workspacePath: tempDir.path).load())
        XCTAssertNotNil(onDisk.map.components.first?.at, "the file carries the placement")
    }

    func testARefusedEditWritesNothing() throws {
        let edit = try call(server(), "linkc_edit_board", ["steps": [["add": "a"], ["connect": "a", "to": "ghost"]]])
        XCTAssertTrue(edit.isError)
        XCTAssertTrue(edit.text.hasPrefix("step 2:"), edit.text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: mapURL.path))
    }

    func testAnUnreadableMapIsRefusedAndLeftAlone() throws {
        let broken = Data("{ not json".utf8)
        try broken.write(to: mapURL)
        XCTAssertTrue(try call(server(), "linkc_get_board").isError)
        XCTAssertTrue(try call(server(), "linkc_edit_board", ["steps": [["add": "a"]]]).isError)
        XCTAssertEqual(try Data(contentsOf: mapURL), broken)
    }

    func testAnUnidentifiedCallerCanReadButNotEdit() throws {
        let s = MCPServer(workspaceRoot: tempDir.path, environment: [:], ancestorResolver: { _ in nil }, sessionResolver: { nil })
        XCTAssertFalse(try call(s, "linkc_get_board").isError)
        XCTAssertTrue(try call(s, "linkc_edit_board", ["steps": [["add": "a"]]]).isError)
    }

    func testProjectContextPointsAtTheBoardTools() throws {
        _ = try call(server(), "linkc_edit_board", ["steps": [["add": "api"]]])
        XCTAssertTrue(try call(server(), "linkc_get_project_context").text.contains("linkc_edit_board"))
    }

    func testBothToolsAreListed() throws {
        let req: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/list"]
        let res = try XCTUnwrap(server().handleMessage(try JSONSerialization.data(withJSONObject: req)))
        let tools = (((try JSONSerialization.jsonObject(with: res) as? [String: Any])?["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
        let names = Set(tools.compactMap { $0["name"] as? String })
        XCTAssertTrue(names.isSuperset(of: ["linkc_get_board", "linkc_edit_board"]))
    }
}
```

  **The retry-once path:** there is no seam between the handler's load and its save, so a
  collision can't be forced in a test through `handleMessage`. Put the load–apply–save–retry
  logic in a small internal static function:

```swift
static func editBoard(store: BoardMapStore, steps: [BoardEditStep], beforeSave: () throws -> Void = {}) throws -> [String]
```

  The handler calls it, and a test passes a `beforeSave` that writes the file on the first call
  only. Assert that the edit still lands, and that a `beforeSave` which writes every time produces
  the "kept changing" error. Add these two tests to the file.

- [ ] **Step 2: Run them and watch them fail.** Run `swift test --filter MCPServerBoardTests`.

- [ ] **Step 3: Implement.** The handlers, tool entries, `architectureJSON()` and `editBoard`, as
  specified. Also update the two existing project-context tests in `MCPServerTests.swift` if they
  pin the exact text.

- [ ] **Step 4: Run it and see it pass.** Run the full suite too.

- [ ] **Step 5: Commit:** `feat(board): linkc_get_board and linkc_edit_board let agents read and change the Board`

---

### Task 4: `BoardMerge`: a three-way merge by element

**Files:**
- Create: `Sources/LinkCKit/Board/BoardMerge.swift`, `Tests/LinkCKitTests/BoardMergeTests.swift`

**Interfaces:**
- Produces: `public enum BoardMerge { public static func merge(base: BoardMap, mine: BoardMap, theirs: BoardMap) -> BoardMap }`

**Rules:** `pick(b, m, t) = m != b ? m : t`. That is, whoever changed it wins, and mine wins a tie.
- **`system`:** `pick`.
- **Components, keyed by lowercased name:**
  - If mine equals base, take theirs; nil means absent.
  - If theirs equals base, take mine.
  - If both differ:
    - mine deleted it → absent;
    - theirs deleted it → mine;
    - otherwise merge field by field with `pick`. For `uses`, merge per target key with `pick`.
      If base is absent (both added it), take mine.
  - Order: theirs' order, then mine-only additions in mine's order.
- **Frames, keyed by lowercased label:** the same, on the whole `BoardFrame`.
- **Notes:** identity is the text, because each decode mints new UUIDs.
  - Result = theirs' notes, minus texts mine removed (in base, not in mine), plus notes mine
    added (not in base), keeping mine's positions.
  - A note in all three takes `at` by `pick`, and keeps mine's `id`.
  - Count duplicates correctly: treat texts as a multiset.
- **Texts:** identity is `(text, style)`; the same approach, with `at` and `width` by `pick`.
- **`extras` / `layoutExtras`:** theirs. The Board never edits them.
- **Afterwards:** components whose `place` names no frame are fixed by `laidOut`, which the model
  runs after a merge. The merge itself does not lay out.

- [ ] **Step 1: Write the failing tests.** Create `Tests/LinkCKitTests/BoardMergeTests.swift`:

```swift
import XCTest
@testable import LinkCKit

final class BoardMergeTests: XCTestCase {
    private func map(_ components: [BoardComponent], frames: [BoardFrame] = [], notes: [String] = [], system: String? = nil) -> BoardMap {
        var m = BoardMap(system: system)
        m.components = components
        m.frames = frames
        m.notes = notes.enumerated().map { BoardNote(text: $0.element, at: BoardPoint(x: 0, y: $0.offset * 200)) }
        return m
    }
    private func c(_ name: String, does: String? = nil, at: BoardPoint? = BoardPoint(x: 0, y: 0), uses: [String: String] = [:]) -> BoardComponent {
        BoardComponent(name: name, kind: .service, does: does, uses: uses, at: at)
    }

    func testOnlyTheirsChanged() {
        let base = map([c("api")]), mine = base, theirs = map([c("api", does: "http"), c("redis")])
        XCTAssertEqual(BoardMerge.merge(base: base, mine: mine, theirs: theirs).components.map(\.name), ["api", "redis"])
        XCTAssertEqual(BoardMerge.merge(base: base, mine: mine, theirs: theirs).components.first?.does, "http")
    }

    func testOnlyMineChanged() {
        let base = map([c("api")]), mine = map([c("api", at: BoardPoint(x: 400, y: 0))]), theirs = base
        XCTAssertEqual(BoardMerge.merge(base: base, mine: mine, theirs: theirs).components.first?.at, BoardPoint(x: 400, y: 0))
    }

    func testDifferentElementsBothSurvive() {
        let base = map([c("api"), c("db")])
        let mine = map([c("api", at: BoardPoint(x: 400, y: 0)), c("db")])
        let theirs = map([c("api"), c("db", does: "postgres"), c("redis")])
        let merged = BoardMerge.merge(base: base, mine: mine, theirs: theirs)
        XCTAssertEqual(merged.components.first { $0.name == "api" }?.at, BoardPoint(x: 400, y: 0))
        XCTAssertEqual(merged.components.first { $0.name == "db" }?.does, "postgres")
        XCTAssertNotNil(merged.components.first { $0.name == "redis" })
    }

    func testTheSameElementFieldByFieldMineWinsATie() {
        let base = map([c("api", does: "a")])
        let mine = map([c("api", does: "mine", at: BoardPoint(x: 400, y: 0))])
        let theirs = map([c("api", does: "theirs", uses: ["db": "reads"])])
        let api = BoardMerge.merge(base: base, mine: mine, theirs: theirs).components.first
        XCTAssertEqual(api?.does, "mine")
        XCTAssertEqual(api?.at, BoardPoint(x: 400, y: 0))
        XCTAssertEqual(api?.uses, ["db": "reads"], "an arrow only theirs added survives")
    }

    func testDeletionsCountAsChanges() {
        let base = map([c("api"), c("db")])
        XCTAssertNil(BoardMerge.merge(base: base, mine: map([c("api")]), theirs: map([c("api"), c("db", does: "x")]))
            .components.first { $0.name == "db" }, "mine deleted, theirs edited: mine wins")
        XCTAssertEqual(BoardMerge.merge(base: base, mine: map([c("api"), c("db", does: "x")]), theirs: map([c("api")]))
            .components.first { $0.name == "db" }?.does, "x", "theirs deleted, mine edited: mine wins")
        XCTAssertNil(BoardMerge.merge(base: base, mine: base, theirs: map([c("api")])).components.first { $0.name == "db" })
    }

    func testNotesMatchByText() {
        let base = map([], notes: ["a", "b"])
        let mine = map([], notes: ["a", "b", "mine"])
        let theirs = map([], notes: ["a", "theirs"])
        XCTAssertEqual(Set(BoardMerge.merge(base: base, mine: mine, theirs: theirs).notes.map(\.text)), ["a", "theirs", "mine"])
    }

    func testFramesAndSystem() {
        let frame = BoardFrame(label: "Local docker", rect: BoardRect(x: 0, y: 0, w: 320, h: 200))
        let base = map([], frames: [frame], system: "old")
        var moved = frame; moved.rect = BoardRect(x: 400, y: 0, w: 320, h: 200)
        let mine = map([], frames: [moved], system: "old")
        let theirs = map([], frames: [frame, BoardFrame(label: "Oracle", rect: BoardRect(x: 0, y: 400, w: 320, h: 200))], system: "new")
        let merged = BoardMerge.merge(base: base, mine: mine, theirs: theirs)
        XCTAssertEqual(merged.frames.first { $0.label == "Local docker" }?.rect?.x, 400)
        XCTAssertNotNil(merged.frames.first { $0.label == "Oracle" })
        XCTAssertEqual(merged.system, "new")
    }
}
```

- [ ] **Step 2: Run them and watch them fail.** Stub `merge` to return `mine`; run
  `swift test --filter BoardMergeTests`.

- [ ] **Step 3: Implement** following the rules.

- [ ] **Step 4: Run them and see them pass.** Run the full suite too.

- [ ] **Step 5: Commit:** `feat(board): BoardMerge merges two versions of the map element by element`

---

### Task 5: The Board takes outside changes

**Files:**
- Modify: `Sources/LinkCKit/Board/BoardModel.swift`
- Test: `Tests/LinkCKitTests/BoardModelTests.swift` (new tests under `// MARK: Outside changes`)

**Interfaces:**
- Consumes: `BoardMerge`, `BoardModel.laidOut`.
- Produces:
  - `public struct OutsideChange: Equatable, Sendable { public let id: UUID; public let elements: Set<Element> }`,
    nested in `BoardModel`.
  - `public private(set) var outsideChange: OutsideChange?`
  - `public func diskChanged()`: the watcher's entry point.
  - `public var fileURL: URL { store.fileURL }`

**Behaviour:**
- **The base.** Keep a `baseMap: BoardMap`: the decoded map of `diskBytes`. Set it wherever
  `diskBytes` is set: `read`, `write`, and `diskChanged`. It is `.empty` when there's no file.
- **`diskChanged()`:**
  1. `store.load()`. On a throw, `state = .failed(message)`; the Board locks, as today; return.
  2. If the bytes equal `diskBytes` (nil equals nil), return. That is the Board's own write.
  3. Let `theirs` be `loaded?.map ?? .empty`, and `before = map`.
  4. If `hasUnwrittenEdits`, set
     `map = laidOut(BoardMerge.merge(base: baseMap, mine: map, theirs: theirs))`; the Board keeps
     its pending write, which now saves the merge. Otherwise, `map = laidOut(theirs)`.
  5. Set `diskBytes = loaded?.bytes` and `baseMap = theirs`.
  6. Update the state:
     - `.failed` → `.loaded` or `.empty` (recovered): a fresh start, as a load is. Undo, redo and
       selection are cleared, and there is **no undo step**;
     - `.empty` + a file → `.loaded`;
     - a file deleted → `.empty`, if nothing is pending.
  7. Otherwise, push `before` onto the undo stack as one step, and clear redo.
  8. Set `outsideChange = OutsideChange(id: UUID(), elements: changed(from: before, to: map))`.
     `changed` returns:
     - components new, or different by value, by name;
     - the source component of any new or relabelled arrow;
     - frames new, or different, by label;
     - notes whose text is new.
  9. Filter the selection, recompute the routes and reconcile, as `afterMapChange` does. If
     `hasUnwrittenEdits`, `scheduleWrite()`.
- **`write()` no longer locks on a collision.** On `BoardMapStoreError.changedOnDisk`:
  1. Call `diskChanged()`, which merges because the edit is still unwritten.
  2. Try the save once more.
  3. A second `changedOnDisk` sets `changedOnDisk = true`, the existing lock. Document it as the
     last resort, for a file that keeps changing under the save.
- **`reload()`** also sets `baseMap`. `load()`'s keep-everything shortcut is unchanged.
- **Undo of an outside change** pops `before`. `hasUnwrittenEdits` becomes true through
  `afterMapChange`, so the write puts `before` back on disk, expecting the outside bytes. That
  reverts the agent's change.

- [ ] **Step 1: Write the failing tests.** Add them to `BoardModelTests.swift`. Use its existing
  `model()`, `fresh()`, `store` and `Gate` helpers:

```swift
    // MARK: Outside changes

    private func writeOutside(_ json: String) throws {
        try Data(json.utf8).write(to: store.fileURL, options: .atomic)
    }

    private let outsideMap = #"{ "version": 2, "system": "theirs", "places": { "Not placed": { "redis": { "kind": "cache" } } } }"#

    func testItsOwnWriteIsIgnored() throws {
        let board = fresh()
        board.setSystem("mine")
        board.saveNow()
        board.diskChanged()
        XCTAssertNil(board.outsideChange)
        XCTAssertEqual(board.map.system, "mine")
    }

    func testAnOutsideChangeIsTakenAsOneUndoStep() throws {
        let board = fresh()
        board.setSystem("mine")
        board.saveNow()
        try writeOutside(outsideMap)
        board.diskChanged()
        XCTAssertEqual(board.map.system, "theirs")
        XCTAssertNotNil(board.map.components.first { $0.name == "redis" }?.at, "laid out")
        XCTAssertEqual(board.outsideChange?.elements.contains(.component("redis")), true)
        board.undo()
        XCTAssertEqual(board.map.system, "mine")
        board.saveNow()
        XCTAssertEqual(try XCTUnwrap(try store.load()).map.system, "mine", "undo writes the old map back")
    }

    func testAnOutsideChangeMergesWithAnEditNotYetWritten() throws {
        let board = fresh()
        board.setSystem("base")
        board.saveNow()
        _ = board.addComponent(kind: .database, at: BoardPoint(x: 0, y: 0))   // pending
        try writeOutside(outsideMap)
        board.diskChanged()
        XCTAssertEqual(board.map.system, "theirs", "their change is taken")
        XCTAssertNotNil(board.map.components.first { $0.name == "new-database" }, "my pending edit survives")
        XCTAssertNotNil(board.map.components.first { $0.name == "redis" })
        board.saveNow()
        let onDisk = try XCTUnwrap(try store.load()).map
        XCTAssertEqual(Set(onDisk.components.map(\.name)), ["new-database", "redis"])
        XCTAssertFalse(board.changedOnDisk)
    }

    func testASaveThatFindsTheFileChangedMergesInsteadOfLocking() throws {
        let board = fresh()
        board.setSystem("base")
        board.saveNow()
        _ = board.addComponent(kind: .database, at: BoardPoint(x: 0, y: 0))
        try writeOutside(outsideMap)   // the watcher has not fired yet
        board.saveNow()
        XCTAssertFalse(board.changedOnDisk)
        XCTAssertEqual(Set(try XCTUnwrap(try store.load()).map.components.map(\.name)), ["new-database", "redis"])
    }

    func testAnUnreadableFileLocksAndAFixedOneRecovers() throws {
        let board = fresh()
        board.setSystem("base")
        board.saveNow()
        try Data("<<<<<<< HEAD".utf8).write(to: store.fileURL)
        board.diskChanged()
        guard case .failed = board.state else { return XCTFail("an unreadable file locks") }
        try writeOutside(outsideMap)
        board.diskChanged()
        XCTAssertEqual(board.state, .loaded, "a readable file again unlocks it")
        XCTAssertEqual(board.map.system, "theirs")
        XCTAssertFalse(board.canUndo, "recovering is not an undo step")
    }

    func testAMapCreatedOutsideShowsOnAnEmptyBoard() throws {
        let board = model()
        board.load()
        XCTAssertEqual(board.state, .empty)
        try writeOutside(outsideMap)
        board.diskChanged()
        XCTAssertEqual(board.state, .loaded)
        XCTAssertEqual(board.map.system, "theirs")
    }
```

  Adjust the helpers' names to the file's real ones if they differ, and don't change what each
  test asserts. `testUndoAndRedoWalkTheEdits` and the other existing tests must stay green. Any
  existing test that asserted a save collision *locks* the Board now pins the old rule. Update it
  to the merge rule, and say so in the report.

- [ ] **Step 2: Run them and watch them fail.** Stub `diskChanged()` and `outsideChange`, then run
  `swift test --filter BoardModelTests`.

- [ ] **Step 3: Implement** the behaviour above.

- [ ] **Step 4: Run them and see them pass.** Run the full suite too.

- [ ] **Step 5: Commit:** `feat(board): the Board takes outside changes as one undo step, merging with a pending edit`

---

### Task 6: Watching the file, and the glow

**Files:**
- Create: `Sources/LinkCKit/Board/BoardFileWatcher.swift`, `Tests/LinkCKitTests/BoardFileWatcherTests.swift`
- Modify: `Sources/linkc/Board/BoardPane.swift`, `Sources/linkc/Board/BoardCanvas.swift` (and `BoardElements.swift` if the glow overlay belongs there)

**Interfaces:**
- Produces:

```swift
/// Calls `onChange` on the main queue whenever `fileURL` may have changed: its folder's entries
/// change (an atomic save renames into it), or the file itself is written, extended, renamed or
/// deleted (an in-place save). Event-driven through kqueue; nothing is polled. `onChange` can
/// fire more than once per save: callers compare bytes. `stop()` ends it; so does deinit.
public final class BoardFileWatcher {
    public init(fileURL: URL, onChange: @escaping @MainActor () -> Void) throws
    public func stop()
}
```

  Use `open(path, O_EVTONLY)` with `DispatchSource.makeFileSystemObjectSource`:
  - One source on the folder, with `.write`.
  - One on the file when it exists: `.write`, `.extend`, `.delete`, `.rename`, `.attrib`.
    Re-open it after `.delete`/`.rename`, and whenever a folder event finds it (re)created.
  - Close the file descriptors in each source's cancel handler.
  - `init` throws when the folder cannot be opened, carrying errno's message.

- [ ] **Step 1: Write the failing tests.** Create `Tests/LinkCKitTests/BoardFileWatcherTests.swift`:

```swift
import XCTest
@testable import LinkCKit

@MainActor
final class BoardFileWatcherTests: XCTestCase {
    nonisolated(unsafe) private var folder: URL!
    private var file: URL { folder.appendingPathComponent("system-map.json") }

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    private func expectChange(_ description: String, after change: () throws -> Void) throws {
        let fired = expectation(description: description)
        fired.assertForOverFulfill = false
        let watcher = try BoardFileWatcher(fileURL: file) { fired.fulfill() }
        defer { watcher.stop() }
        try change()
        wait(for: [fired], timeout: 2)
    }

    func testCreatingTheFileFires() throws {
        try expectChange("created") { try Data("{}".utf8).write(to: file) }
    }

    func testAnAtomicSaveFires() throws {
        try Data("{}".utf8).write(to: file)
        try expectChange("atomic") { try Data("{ }".utf8).write(to: file, options: .atomic) }
    }

    func testAnInPlaceWriteFires() throws {
        try Data("{}".utf8).write(to: file)
        try expectChange("in place") {
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(" ".utf8))
            try handle.close()
        }
    }

    func testAMissingFolderThrows() {
        XCTAssertThrowsError(try BoardFileWatcher(fileURL: folder.appendingPathComponent("nope/system-map.json")) {})
    }
}
```

- [ ] **Step 2: Run them and watch them fail.** Stub a watcher that never fires; run
  `swift test --filter BoardFileWatcherTests`.

- [ ] **Step 3: Implement `BoardFileWatcher`.** Then run the tests and see them pass.

- [ ] **Step 4: Wire it in the app.**
  - **`BoardPane.swift`:**
    - Hold `@State private var watcher: BoardFileWatcher?`.
    - In `.onAppear`, after the existing load and reconcile, start
      `try BoardFileWatcher(fileURL: board.fileURL) { board.diskChanged() }`. If it throws, show
      it: pass the message to the Board's visible banner. Add
      `public func liveUpdatesFailed(_ message: String)` to `BoardModel`, setting `writeFailure`
      to "Live updates are off: \(message)". Never swallow it.
    - In `.onDisappear`, `watcher?.stop(); watcher = nil` before the existing `saveNow`.
  - **The glow, `BoardCanvas.swift`:**
    - Hold `@State private var glowing: Set<BoardModel.Element> = []` and
      `@State private var glowOpacity = 0.0`.
    - `.onChange(of: board.outsideChange?.id)`: set `glowing = board.outsideChange?.elements ?? []`
      and `glowOpacity = 1`, then on the next runloop turn
      `withAnimation(.easeOut(duration: 2)) { glowOpacity = 0 }`.
    - Components, notes and frames whose element is in `glowing` draw a `Theme.accent` rounded
      outline at `glowOpacity`, the box's own corner radius, and 2 pt.
    - When `glowOpacity` reaches 0, clear `glowing`: in the animation's completion on macOS 14,
      or a `Task` sleeping 2 s that only clears if the change id is unchanged.
    - Only state changes in `onChange` handlers; no view body writes.
    - Nothing animates while no outside change has happened.

- [ ] **Step 5: Verify.** Build, check for warnings, and run the full suite.

  In the report, list what can only be checked by hand. An agent's `linkc_edit_board` shows on
  the open Board within a moment, glows, and ⌘Z reverts it. A hand edit of the JSON in place
  does the same.

- [ ] **Step 6: Commit:** `feat(board): the open Board follows its file live, and what changed glows`

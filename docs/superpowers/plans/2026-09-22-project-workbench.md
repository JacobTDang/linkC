# Project Workbench Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Each project gets a committed system map (`.linkc/system.json`) that any agent can read, and a board at the top of the project dashboard where you drag components around to edit it.

**Architecture:** Pure value types in LinkCKit carry everything — the file's model and codec, the auto-layout, the reconciler that compares the map against what linkC's container discovery found, a file store, and a main-actor `WorkbenchModel` that owns loading, editing and the debounced save. The app target holds only the band view and its gestures. The MCP tool `linkc_get_project_context` gains a section rendering the map, so linkC-hosted agents see it without reading the file themselves.

**Tech Stack:** Swift 6 (strict concurrency), SwiftPM, macOS 14, SwiftUI, XCTest. No new dependencies — `JSONSerialization` parses and writes the map.

**Spec:** `docs/superpowers/specs/2026-09-22-project-workbench-design.md`

## Global Constraints

- No new dependencies or packages. The map is JSON, parsed with `JSONSerialization`.
- Test-driven: write the failing test first, run it and see it fail, then implement. Mock data only in tests.
- Fail loud: a map that cannot be parsed shows its reason and blocks writing; a failed save surfaces in the band. No swallowed errors, no silent fallback to an empty map.
- The file is `<workspace>/.linkc/system.json`, alongside the `blackboard.json` and `HANDOFF.md` linkC already writes there. Writes are atomic (`Data.write(options: .atomic)`), and the `.linkc` directory is created if missing.
- Keys linkC does not know — per component and at the top level — survive a decode/encode round trip unchanged.
- Component identity is `name`, unique within a file, compared case-insensitively for discovery matching.
- Known kinds, exactly: `database`, `cache`, `queue`, `storage`, `service`, `host`, `external`. Any other value is preserved verbatim and drawn like `service`.
- A component's status is `present` when a discovered thing matches it; otherwise `missing` only when its `runs` text names docker or compose; otherwise `unchecked`. linkC never reports something missing that it had no way to look for.
- linkC never creates infrastructure, never dispatches work, and never writes the map on an agent's behalf.
- Commits: author is the repo's configured git user. Commit messages must NOT contain the word "claude" in any case (this includes paths like `.claude/`), and must carry no `Co-Authored-By`, `Generated with`, or other trailers. Before reporting, run `git log -1 --format=%B | grep -ic claude` and confirm it prints `0`.
- Before committing, run `git diff --cached --stat` and confirm only the intended files are staged.
- Tests: `swift test --filter <TestClass>`; the full suite with `swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1`. Baseline on `main`: 1020 tests, 5 skipped, 0 failures.

---

### Task 1: The map's model and codec

**Files:**
- Create: `Sources/LinkCKit/Workbench/SystemMap.swift`
- Test: `Tests/LinkCKitTests/SystemMapTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `struct GridPoint: Equatable, Sendable { public var x: Int; public var y: Int }`
  - `struct ComponentKind: Equatable, Hashable, Sendable` with `raw: String`, statics `.database .cache .queue .storage .service .host .external`, `static let known: [ComponentKind]`, `var isKnown: Bool`
  - `struct SystemComponent: Equatable, Sendable, Identifiable` — `name`, `kind`, `reachedBy: String?`, `runs: String?`, `usedBy: [String]`, `intended: Bool`, `at: GridPoint?`, plus internal `extras: Data?`
  - `struct SystemMap: Equatable, Sendable` — `version: Int`, `components: [SystemComponent]`, internal `extras: Data?`, `static func decode(_ data: Data) throws -> SystemMap`, `func encoded() throws -> Data`, `static let empty: SystemMap`

- [ ] **Step 1: Write the failing tests**

Create `Tests/LinkCKitTests/SystemMapTests.swift`:

```swift
import XCTest
@testable import LinkCKit

final class SystemMapTests: XCTestCase {
    private let sample = Data("""
    {
      "version": 1,
      "components": [
        { "name": "postgres", "kind": "database", "reached_by": "DATABASE_URL",
          "runs": "docker compose (db)", "used_by": ["api", "worker"], "at": { "x": 0, "y": 0 } },
        { "name": "redis", "kind": "cache", "reached_by": "REDIS_URL", "intended": true },
        { "name": "mystery", "kind": "quantum-flux" }
      ]
    }
    """.utf8)

    func testAFullFileDecodes() throws {
        let map = try SystemMap.decode(sample)
        XCTAssertEqual(map.version, 1)
        XCTAssertEqual(map.components.map(\.name), ["postgres", "redis", "mystery"])

        let postgres = map.components[0]
        XCTAssertEqual(postgres.kind, .database)
        XCTAssertEqual(postgres.reachedBy, "DATABASE_URL")
        XCTAssertEqual(postgres.runs, "docker compose (db)")
        XCTAssertEqual(postgres.usedBy, ["api", "worker"])
        XCTAssertFalse(postgres.intended)
        XCTAssertEqual(postgres.at, GridPoint(x: 0, y: 0))

        XCTAssertTrue(map.components[1].intended)
        XCTAssertNil(map.components[1].at, "a component may carry no position")
    }

    func testAnUnknownKindIsKeptVerbatim() throws {
        let kind = try SystemMap.decode(sample).components[2].kind
        XCTAssertEqual(kind.raw, "quantum-flux")
        XCTAssertFalse(kind.isKnown)
        XCTAssertTrue(ComponentKind.database.isKnown)
        XCTAssertEqual(ComponentKind.known.map(\.raw),
                       ["database", "cache", "queue", "storage", "service", "host", "external"])
    }

    /// A field linkC does not know — a future one, or a note added by hand — must survive an
    /// edit made on the board.
    func testUnknownKeysSurviveARoundTrip() throws {
        let data = Data("""
        { "version": 1, "notes": "hand written", "components": [
            { "name": "api", "kind": "service", "owner": "jacob", "tags": ["public"] } ] }
        """.utf8)
        var map = try SystemMap.decode(data)
        map.components[0].reachedBy = "API_URL"

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try map.encoded()) as? [String: Any])
        XCTAssertEqual(object["notes"] as? String, "hand written")
        let component = try XCTUnwrap((object["components"] as? [[String: Any]])?.first)
        XCTAssertEqual(component["owner"] as? String, "jacob")
        XCTAssertEqual(component["tags"] as? [String], ["public"])
        XCTAssertEqual(component["reached_by"] as? String, "API_URL", "the edit still lands")
    }

    /// Written keys use the file's own spelling, and nothing empty is written.
    func testEncodingWritesTheFilesSpellingAndOmitsEmptyFields() throws {
        let map = SystemMap(version: 1, components: [
            SystemComponent(name: "redis", kind: .cache, reachedBy: "REDIS_URL", intended: true),
        ])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try map.encoded()) as? [String: Any])
        let component = try XCTUnwrap((object["components"] as? [[String: Any]])?.first)
        XCTAssertEqual(component["name"] as? String, "redis")
        XCTAssertEqual(component["reached_by"] as? String, "REDIS_URL")
        XCTAssertEqual(component["intended"] as? Bool, true)
        XCTAssertNil(component["runs"], "an absent field is not written as null")
        XCTAssertNil(component["used_by"], "an empty list is not written")
        XCTAssertNil(component["at"])
    }

    func testAMalformedFileFailsWithAReason() {
        for (json, hint) in [
            ("not json at all", "JSON"),
            (#"{"version": 1}"#, "components"),
            (#"{"version": 1, "components": [{"kind": "cache"}]}"#, "name"),
            (#"{"version": 1, "components": [{"name": "a"}, {"name": "A"}]}"#, "twice"),
        ] {
            XCTAssertThrowsError(try SystemMap.decode(Data(json.utf8)), json) { error in
                XCTAssertTrue("\(error)".contains(hint), "\(error) should mention \(hint)")
            }
        }
    }

    func testAMissingVersionReadsAsVersionOne() throws {
        let map = try SystemMap.decode(Data(#"{"components": []}"#.utf8))
        XCTAssertEqual(map.version, 1)
        XCTAssertTrue(map.components.isEmpty)
    }
}
```

- [ ] **Step 2: Run the tests and see them fail**

Run: `swift test --filter SystemMapTests`
Expected: build failure — `cannot find 'SystemMap' in scope`.

- [ ] **Step 3: Implement**

Create `Sources/LinkCKit/Workbench/SystemMap.swift`:

```swift
import Foundation

/// A tile's place on the board, in whole grid cells — so a drag produces a one-line diff.
public struct GridPoint: Equatable, Sendable {
    public var x: Int
    public var y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
}

/// What a component is. The known values drive the tile's glyph; any other value is kept
/// verbatim and drawn plainly, so a kind linkC has not learned yet never breaks a file.
public struct ComponentKind: Equatable, Hashable, Sendable {
    public let raw: String

    public init(_ raw: String) {
        self.raw = raw
    }

    public static let database = ComponentKind("database")
    public static let cache = ComponentKind("cache")
    public static let queue = ComponentKind("queue")
    public static let storage = ComponentKind("storage")
    public static let service = ComponentKind("service")
    public static let host = ComponentKind("host")
    public static let external = ComponentKind("external")

    public static let known: [ComponentKind] = [
        .database, .cache, .queue, .storage, .service, .host, .external,
    ]

    public var isKnown: Bool { Self.known.contains(self) }
}

/// One part of a project's system, as `.linkc/system.json` describes it.
public struct SystemComponent: Equatable, Sendable, Identifiable {
    public var id: String { name }
    /// Identity. Unique within a file, and what discovery is matched against.
    public var name: String
    public var kind: ComponentKind
    /// How code reaches it: an env var name, a URL, a host.
    public var reachedBy: String?
    /// Where it lives — free text, but naming docker or compose is what makes it checkable.
    public var runs: String?
    /// What talks to it. Entries need not be components.
    public var usedBy: [String]
    /// True while it is only planned.
    public var intended: Bool
    /// Where its tile sits. nil means the board lays it out.
    public var at: GridPoint?
    /// The object this component was decoded from, so keys linkC does not know survive an edit.
    var extras: Data?

    public init(
        name: String, kind: ComponentKind, reachedBy: String? = nil, runs: String? = nil,
        usedBy: [String] = [], intended: Bool = false, at: GridPoint? = nil, extras: Data? = nil
    ) {
        self.name = name
        self.kind = kind
        self.reachedBy = reachedBy
        self.runs = runs
        self.usedBy = usedBy
        self.intended = intended
        self.at = at
        self.extras = extras
    }
}

/// A project's system map: the whole of `.linkc/system.json`.
public struct SystemMap: Equatable, Sendable {
    public var version: Int
    public var components: [SystemComponent]
    /// The object the file was decoded from, so top-level keys linkC does not know survive.
    var extras: Data?

    public init(version: Int = 1, components: [SystemComponent] = [], extras: Data? = nil) {
        self.version = version
        self.components = components
        self.extras = extras
    }

    public static let empty = SystemMap()

    /// Decodes a map, failing loud: an unreadable file must never read as an empty system.
    public static func decode(_ data: Data) throws -> SystemMap {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw LinkCError.parse("system.json is not JSON: \(error.localizedDescription)")
        }
        guard let root = object as? [String: Any] else {
            throw LinkCError.parse("system.json is not a JSON object")
        }
        guard let rawComponents = root["components"] as? [[String: Any]] else {
            throw LinkCError.parse("system.json has no components list")
        }

        var components: [SystemComponent] = []
        var seen: Set<String> = []
        for raw in rawComponents {
            guard let name = raw["name"] as? String, !name.isEmpty else {
                throw LinkCError.parse("a component in system.json has no name")
            }
            let key = name.lowercased()
            guard !seen.contains(key) else {
                throw LinkCError.parse("system.json names \"\(name)\" twice")
            }
            seen.insert(key)

            var at: GridPoint?
            if let point = raw["at"] as? [String: Any],
               let x = point["x"] as? Int, let y = point["y"] as? Int {
                at = GridPoint(x: x, y: y)
            }
            components.append(SystemComponent(
                name: name,
                kind: ComponentKind((raw["kind"] as? String) ?? ComponentKind.service.raw),
                reachedBy: raw["reached_by"] as? String,
                runs: raw["runs"] as? String,
                usedBy: (raw["used_by"] as? [String]) ?? [],
                intended: (raw["intended"] as? Bool) ?? false,
                at: at,
                extras: try? JSONSerialization.data(withJSONObject: raw)))
        }

        var rootExtras = root
        rootExtras.removeValue(forKey: "components")
        return SystemMap(
            version: (root["version"] as? Int) ?? 1,
            components: components,
            extras: try? JSONSerialization.data(withJSONObject: rootExtras))
    }

    /// The file's bytes, keeping every key linkC does not know and omitting empty fields.
    public func encoded() throws -> Data {
        var root = (extras.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        root["version"] = version
        root["components"] = components.map { component in
            var object = (component.extras.flatMap { try? JSONSerialization.jsonObject(with: $0) }
                as? [String: Any]) ?? [:]
            object["name"] = component.name
            object["kind"] = component.kind.raw
            set(&object, "reached_by", component.reachedBy)
            set(&object, "runs", component.runs)
            if component.usedBy.isEmpty { object.removeValue(forKey: "used_by") } else { object["used_by"] = component.usedBy }
            if component.intended { object["intended"] = true } else { object.removeValue(forKey: "intended") }
            if let at = component.at { object["at"] = ["x": at.x, "y": at.y] } else { object.removeValue(forKey: "at") }
            return object
        }

        guard JSONSerialization.isValidJSONObject(root) else {
            throw LinkCError.parse("the system map could not be represented as JSON")
        }
        do {
            return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        } catch {
            throw LinkCError.parse("failed to write the system map: \(error.localizedDescription)")
        }
    }

    /// Writes a value, or removes the key when it is nil or blank — an absent field is absent,
    /// never `null` and never `""`.
    private func set(_ object: inout [String: Any], _ key: String, _ value: String?) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty { object.removeValue(forKey: key) } else { object[key] = trimmed }
    }
}
```

- [ ] **Step 4: Run the tests and see them pass**

Run: `swift test --filter SystemMapTests`
Expected: `Executed 6 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/LinkCKit/Workbench/SystemMap.swift Tests/LinkCKitTests/SystemMapTests.swift
git diff --cached --stat
git commit -m "feat(workbench): a project's system map, with unknown keys kept"
git log -1 --format=%B | grep -ic claude   # must print 0
```

---

### Task 2: Reading and writing the file

**Files:**
- Create: `Sources/LinkCKit/Workbench/SystemMapStore.swift`
- Test: `Tests/LinkCKitTests/SystemMapStoreTests.swift`

**Interfaces:**
- Consumes: `SystemMap`, `SystemComponent` (Task 1).
- Produces: `struct SystemMapStore: Sendable` — `init(workspacePath: String)`, `let fileURL: URL`, `func load() throws -> SystemMap?` (nil when no file exists), `func save(_ map: SystemMap) throws`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/LinkCKitTests/SystemMapStoreTests.swift`:

```swift
import XCTest
@testable import LinkCKit

final class SystemMapStoreTests: XCTestCase {
    nonisolated(unsafe) private var workspace: URL!

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-workbench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: workspace)
    }

    func testTheFileSitsBesideTheOtherProjectFiles() {
        let store = SystemMapStore(workspacePath: workspace.path)
        XCTAssertEqual(store.fileURL.lastPathComponent, "system.json")
        XCTAssertEqual(store.fileURL.deletingLastPathComponent().lastPathComponent, ".linkc")
    }

    func testAProjectWithNoMapLoadsNothing() throws {
        XCTAssertNil(try SystemMapStore(workspacePath: workspace.path).load())
    }

    func testSavingCreatesTheDirectoryAndLoadingReadsItBack() throws {
        let store = SystemMapStore(workspacePath: workspace.path)
        let map = SystemMap(components: [
            SystemComponent(name: "postgres", kind: .database, reachedBy: "DATABASE_URL",
                            at: GridPoint(x: 1, y: 2)),
        ])
        try store.save(map)

        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.path))
        let loaded = try XCTUnwrap(try store.load())
        XCTAssertEqual(loaded.components.map(\.name), ["postgres"])
        XCTAssertEqual(loaded.components[0].at, GridPoint(x: 1, y: 2))
    }

    /// An unreadable map must fail loud — reading it as an empty system would invite an
    /// edit that overwrites whatever the file really held.
    func testAnUnreadableFileThrowsRatherThanReadingAsEmpty() throws {
        let store = SystemMapStore(workspacePath: workspace.path)
        try FileManager.default.createDirectory(
            at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ nope".utf8).write(to: store.fileURL)

        XCTAssertThrowsError(try store.load())
    }

    func testSavingReplacesAnEarlierMap() throws {
        let store = SystemMapStore(workspacePath: workspace.path)
        try store.save(SystemMap(components: [SystemComponent(name: "a", kind: .service)]))
        try store.save(SystemMap(components: [SystemComponent(name: "b", kind: .cache)]))
        XCTAssertEqual(try store.load()?.components.map(\.name), ["b"])
    }
}
```

- [ ] **Step 2: Run the tests and see them fail**

Run: `swift test --filter SystemMapStoreTests`
Expected: build failure — `cannot find 'SystemMapStore' in scope`.

- [ ] **Step 3: Implement**

Create `Sources/LinkCKit/Workbench/SystemMapStore.swift`:

```swift
import Foundation

/// Reads and writes a project's `.linkc/system.json`, beside the blackboard and handoff files
/// linkC already keeps there. Values in, values out: no caching, no state.
public struct SystemMapStore: Sendable {
    public let fileURL: URL

    public init(workspacePath: String) {
        let workspace = URL(fileURLWithPath: (workspacePath as NSString).standardizingPath, isDirectory: true)
        fileURL = workspace
            .appendingPathComponent(".linkc", isDirectory: true)
            .appendingPathComponent("system.json")
    }

    /// The project's map, or nil when it has none. Throws when a file exists but cannot be
    /// read — an unreadable map must never read as an empty system.
    public func load() throws -> SystemMap? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw LinkCError.parse("could not read \(fileURL.path): \(error.localizedDescription)")
        }
        return try SystemMap.decode(data)
    }

    public func save(_ map: SystemMap) throws {
        let data = try map.encoded()
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw LinkCError.process("could not write \(fileURL.path): \(error.localizedDescription)")
        }
    }
}
```

- [ ] **Step 4: Run the tests and see them pass**

Run: `swift test --filter SystemMapStoreTests`
Expected: `Executed 5 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/LinkCKit/Workbench/SystemMapStore.swift Tests/LinkCKitTests/SystemMapStoreTests.swift
git diff --cached --stat
git commit -m "feat(workbench): read and write the map file"
git log -1 --format=%B | grep -ic claude   # must print 0
```

---

### Task 3: Laying out tiles that carry no position

**Files:**
- Create: `Sources/LinkCKit/Workbench/WorkbenchLayout.swift`
- Test: `Tests/LinkCKitTests/WorkbenchLayoutTests.swift`

**Interfaces:**
- Consumes: `SystemMap`, `SystemComponent`, `GridPoint` (Task 1).
- Produces: `enum WorkbenchLayout` — `static let columns = 5`, `static func positions(for components: [SystemComponent]) -> [String: GridPoint]`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/LinkCKitTests/WorkbenchLayoutTests.swift`:

```swift
import XCTest
@testable import LinkCKit

final class WorkbenchLayoutTests: XCTestCase {
    private func component(_ name: String, at: GridPoint? = nil) -> SystemComponent {
        SystemComponent(name: name, kind: .service, at: at)
    }

    func testAPositionedComponentKeepsItsPlace() {
        let positions = WorkbenchLayout.positions(for: [component("api", at: GridPoint(x: 3, y: 1))])
        XCTAssertEqual(positions["api"], GridPoint(x: 3, y: 1))
    }

    /// Two machines opening the same unpositioned map must draw the same board.
    func testUnpositionedComponentsFillTheGridInNameOrder() {
        let names = ["worker", "api", "postgres"]
        let positions = WorkbenchLayout.positions(for: names.map { component($0) })
        XCTAssertEqual(positions["api"], GridPoint(x: 0, y: 0))
        XCTAssertEqual(positions["postgres"], GridPoint(x: 1, y: 0))
        XCTAssertEqual(positions["worker"], GridPoint(x: 2, y: 0))

        let shuffled = WorkbenchLayout.positions(for: names.reversed().map { component($0) })
        XCTAssertEqual(positions, shuffled, "order in the file must not change the layout")
    }

    func testTheGridWrapsAfterItsColumns() {
        let names = (1...(WorkbenchLayout.columns + 2)).map { String(format: "c%02d", $0) }
        let positions = WorkbenchLayout.positions(for: names.map { component($0) })
        XCTAssertEqual(positions[names[WorkbenchLayout.columns]], GridPoint(x: 0, y: 1))
        XCTAssertEqual(positions[names[WorkbenchLayout.columns + 1]], GridPoint(x: 1, y: 1))
    }

    /// A free cell is one no positioned tile already holds.
    func testAnUnpositionedComponentNeverLandsOnAPositionedOne() {
        let positions = WorkbenchLayout.positions(for: [
            component("pinned", at: GridPoint(x: 0, y: 0)),
            component("floating"),
        ])
        XCTAssertEqual(positions["pinned"], GridPoint(x: 0, y: 0))
        XCTAssertEqual(positions["floating"], GridPoint(x: 1, y: 0))
    }

    func testAnEmptyMapLaysOutToNothing() {
        XCTAssertTrue(WorkbenchLayout.positions(for: []).isEmpty)
    }
}
```

- [ ] **Step 2: Run the tests and see them fail**

Run: `swift test --filter WorkbenchLayoutTests`
Expected: build failure — `cannot find 'WorkbenchLayout' in scope`.

- [ ] **Step 3: Implement**

Create `Sources/LinkCKit/Workbench/WorkbenchLayout.swift`:

```swift
import Foundation

/// Where each tile sits. A component that carries a position keeps it; the rest fill the free
/// cells in name order, so the same map lays out the same way on every machine.
public enum WorkbenchLayout {
    /// Cells across before the grid wraps.
    public static let columns = 5

    public static func positions(for components: [SystemComponent]) -> [String: GridPoint] {
        var positions: [String: GridPoint] = [:]
        var taken: Set<String> = []
        for component in components {
            guard let at = component.at else { continue }
            positions[component.name] = at
            taken.insert("\(at.x),\(at.y)")
        }

        var cell = 0
        for component in components.filter({ $0.at == nil }).sorted(by: { $0.name < $1.name }) {
            while taken.contains("\(cell % columns),\(cell / columns)") { cell += 1 }
            let point = GridPoint(x: cell % columns, y: cell / columns)
            positions[component.name] = point
            taken.insert("\(point.x),\(point.y)")
            cell += 1
        }
        return positions
    }
}
```

- [ ] **Step 4: Run the tests and see them pass**

Run: `swift test --filter WorkbenchLayoutTests`
Expected: `Executed 5 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/LinkCKit/Workbench/WorkbenchLayout.swift Tests/LinkCKitTests/WorkbenchLayoutTests.swift
git diff --cached --stat
git commit -m "feat(workbench): lay out tiles that carry no position"
git log -1 --format=%B | grep -ic claude   # must print 0
```

---

### Task 4: Comparing the map against what is running

**Files:**
- Create: `Sources/LinkCKit/Workbench/SystemReconciler.swift`
- Test: `Tests/LinkCKitTests/SystemReconcilerTests.swift`

**Interfaces:**
- Consumes: `SystemMap`, `SystemComponent`, `ComponentKind` (Task 1).
- Produces:
  - `struct DiscoveredThing: Equatable, Sendable` — `name: String`, `image: String?`, `detail: String`
  - `enum ComponentStatus: Equatable, Sendable { case present, missing, unchecked }`
  - `struct MapSuggestion: Equatable, Sendable, Identifiable` — `name`, `kind`, `detail`
  - `enum SystemReconciler` — `struct Reconciliation: Equatable, Sendable { statuses: [String: ComponentStatus]; suggestions: [MapSuggestion] }`, `static func reconcile(map: SystemMap, discovered: [DiscoveredThing]) -> Reconciliation`, `static func kind(forImage image: String?) -> ComponentKind`

- [ ] **Step 1: Write the failing tests**

Create `Tests/LinkCKitTests/SystemReconcilerTests.swift`:

```swift
import XCTest
@testable import LinkCKit

final class SystemReconcilerTests: XCTestCase {
    private func thing(_ name: String, image: String? = nil) -> DiscoveredThing {
        DiscoveredThing(name: name, image: image, detail: "container \(name)")
    }

    private func status(_ map: SystemMap, _ discovered: [DiscoveredThing], _ name: String) -> ComponentStatus? {
        SystemReconciler.reconcile(map: map, discovered: discovered).statuses[name]
    }

    func testAComponentThatMatchesSomethingRunningIsPresent() {
        let map = SystemMap(components: [
            SystemComponent(name: "postgres", kind: .database, runs: "docker compose (db)"),
        ])
        XCTAssertEqual(status(map, [thing("postgres")], "postgres"), .present)
    }

    func testMatchingIgnoresCase() {
        let map = SystemMap(components: [SystemComponent(name: "Postgres", kind: .database, runs: "docker")])
        XCTAssertEqual(status(map, [thing("postgres")], "Postgres"), .present)
    }

    func testAComponentIsMatchedByWhatItsRunsTextNames() {
        let map = SystemMap(components: [
            SystemComponent(name: "primary store", kind: .database, runs: "docker compose (db)"),
        ])
        XCTAssertEqual(status(map, [thing("db")], "primary store"), .present)
    }

    /// Only a component that says it runs where linkC can look may be reported missing.
    func testAComponentThatRunsInDockerButIsNotThereIsMissing() {
        let map = SystemMap(components: [
            SystemComponent(name: "redis", kind: .cache, runs: "docker compose (redis)"),
        ])
        XCTAssertEqual(status(map, [], "redis"), .missing)
    }

    /// Absence of evidence is not absence: linkC cannot see an Oracle box or a Supabase project.
    func testAComponentLinkCCannotCheckIsUnchecked() {
        let map = SystemMap(components: [
            SystemComponent(name: "june-audio", kind: .host, runs: "Oracle box"),
            SystemComponent(name: "sprout", kind: .database, runs: nil),
        ])
        XCTAssertEqual(status(map, [], "june-audio"), .unchecked)
        XCTAssertEqual(status(map, [], "sprout"), .unchecked)
    }

    /// A component that is only planned is never reported as missing.
    func testAnIntendedComponentIsNeverMissing() {
        let map = SystemMap(components: [
            SystemComponent(name: "redis", kind: .cache, runs: "docker compose (redis)", intended: true),
        ])
        XCTAssertEqual(status(map, [], "redis"), .unchecked)
    }

    func testSomethingRunningThatTheMapDoesNotNameIsSuggested() {
        let map = SystemMap(components: [SystemComponent(name: "api", kind: .service, runs: "docker")])
        let result = SystemReconciler.reconcile(
            map: map, discovered: [thing("api"), thing("minio", image: "minio/minio:latest")])

        XCTAssertEqual(result.suggestions.map(\.name), ["minio"])
        XCTAssertEqual(result.suggestions.first?.kind, .storage)
        XCTAssertEqual(result.suggestions.first?.detail, "container minio")
    }

    func testTheProposedKindComesFromTheImage() {
        let cases: [(String?, ComponentKind)] = [
            ("postgres:16", .database), ("mysql", .database), ("mariadb:11", .database),
            ("redis:7-alpine", .cache), ("memcached", .cache),
            ("rabbitmq:3-management", .queue), ("nats:latest", .queue), ("bitnami/kafka", .queue),
            ("minio/minio", .storage),
            ("ghcr.io/jacob/june-api:sha-9f2", .service), (nil, .service),
        ]
        for (image, expected) in cases {
            XCTAssertEqual(SystemReconciler.kind(forImage: image), expected, image ?? "nil")
        }
    }

    func testAnEmptyMapSuggestsEverythingRunning() {
        let result = SystemReconciler.reconcile(map: .empty, discovered: [thing("a"), thing("b")])
        XCTAssertEqual(result.suggestions.map(\.name), ["a", "b"])
        XCTAssertTrue(result.statuses.isEmpty)
    }
}
```

- [ ] **Step 2: Run the tests and see them fail**

Run: `swift test --filter SystemReconcilerTests`
Expected: build failure — `cannot find 'DiscoveredThing' in scope`.

- [ ] **Step 3: Implement**

Create `Sources/LinkCKit/Workbench/SystemReconciler.swift`:

```swift
import Foundation

/// Something linkC found running, reduced to what the map can be compared against.
public struct DiscoveredThing: Equatable, Sendable {
    /// The compose service name when there is one, else the container's name.
    public let name: String
    /// The image it runs, when known — what a proposed kind is guessed from.
    public let image: String?
    /// One line for the tooltip and the suggestion row.
    public let detail: String

    public init(name: String, image: String?, detail: String) {
        self.name = name
        self.image = image
        self.detail = detail
    }
}

/// What linkC can say about a component right now.
public enum ComponentStatus: Equatable, Sendable {
    /// Something running matches it.
    case present
    /// It says it runs where linkC can look, and it is not there.
    case missing
    /// linkC has no way to look for it — never drawn as absent.
    case unchecked
}

/// Something running that the map does not name.
public struct MapSuggestion: Equatable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let kind: ComponentKind
    public let detail: String

    public init(name: String, kind: ComponentKind, detail: String) {
        self.name = name
        self.kind = kind
        self.detail = detail
    }
}

/// Compares a map against what discovery found. Pure: discovery results come in as values, and
/// nothing here reads a file or runs a process.
public enum SystemReconciler {
    public struct Reconciliation: Equatable, Sendable {
        public let statuses: [String: ComponentStatus]
        public let suggestions: [MapSuggestion]

        public init(statuses: [String: ComponentStatus], suggestions: [MapSuggestion]) {
            self.statuses = statuses
            self.suggestions = suggestions
        }
    }

    public static func reconcile(map: SystemMap, discovered: [DiscoveredThing]) -> Reconciliation {
        var statuses: [String: ComponentStatus] = [:]
        var matched: Set<String> = []

        for component in map.components {
            let match = discovered.first { thing in
                let name = thing.name.lowercased()
                if component.name.lowercased() == name { return true }
                return namesInRuns(component.runs).contains(name)
            }
            if let match {
                statuses[component.name] = .present
                matched.insert(match.name.lowercased())
            } else if component.intended {
                // A plan is not a claim that something exists, so it can never be missing.
                statuses[component.name] = .unchecked
            } else {
                statuses[component.name] = isCheckable(component) ? .missing : .unchecked
            }
        }

        let suggestions = discovered
            .filter { !matched.contains($0.name.lowercased()) }
            .map { MapSuggestion(name: $0.name, kind: kind(forImage: $0.image), detail: $0.detail) }
        return Reconciliation(statuses: statuses, suggestions: suggestions)
    }

    /// A kind proposed from an image name, for something the map does not name yet.
    public static func kind(forImage image: String?) -> ComponentKind {
        guard let image = image?.lowercased() else { return .service }
        // The repository's last path component, without its tag: "ghcr.io/x/redis:7" -> "redis".
        let repository = image.split(separator: "/").last.map(String.init) ?? image
        let name = repository.split(separator: ":").first.map(String.init) ?? repository
        switch name {
        case "postgres", "postgresql", "mysql", "mariadb": return .database
        case "redis", "memcached", "valkey": return .cache
        case "rabbitmq", "nats", "kafka": return .queue
        case "minio": return .storage
        default: return .service
        }
    }

    /// linkC may only report something missing when the map says it runs where linkC looks.
    private static func isCheckable(_ component: SystemComponent) -> Bool {
        let runs = (component.runs ?? "").lowercased()
        return runs.contains("docker") || runs.contains("compose")
    }

    /// The names inside a `runs` text: "docker compose (db)" names "db".
    private static func namesInRuns(_ runs: String?) -> Set<String> {
        guard let runs else { return [] }
        var names: Set<String> = []
        var current = ""
        var depth = 0
        for character in runs {
            switch character {
            case "(", "[":
                depth += 1
                current = ""
            case ")", "]":
                if depth > 0, !current.isEmpty {
                    names.insert(current.trimmingCharacters(in: .whitespaces).lowercased())
                }
                depth = max(0, depth - 1)
                current = ""
            default:
                if depth > 0 { current.append(character) }
            }
        }
        return names
    }
}
```

- [ ] **Step 4: Run the tests and see them pass**

Run: `swift test --filter SystemReconcilerTests`
Expected: `Executed 9 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/LinkCKit/Workbench/SystemReconciler.swift Tests/LinkCKitTests/SystemReconcilerTests.swift
git diff --cached --stat
git commit -m "feat(workbench): compare the map against what is running"
git log -1 --format=%B | grep -ic claude   # must print 0
```

---

### Task 5: The model the board talks to

**Files:**
- Create: `Sources/LinkCKit/Workbench/WorkbenchModel.swift`
- Test: `Tests/LinkCKitTests/WorkbenchModelTests.swift`

**Interfaces:**
- Consumes: `SystemMap`, `SystemMapStore`, `WorkbenchLayout`, `SystemReconciler`, `DiscoveredThing`, `ComponentStatus`, `MapSuggestion` (Tasks 1–4).
- Produces: `@MainActor @Observable public final class WorkbenchModel` —
  - `enum State: Equatable, Sendable { case empty, loaded, failed(String) }`
  - `public private(set) var state`, `map`, `statuses`, `suggestions`, `positions`
  - `init(store: SystemMapStore, settle: Duration = .milliseconds(600), sleep: @escaping @Sendable (Duration) async -> Void = ...)`
  - `func load()`, `func reconcile(with: [DiscoveredThing])`, `func startMap()`, `func add(_: SystemComponent)`, `func update(_ name: String, to: SystemComponent)`, `func remove(_ name: String)`, `func move(_ name: String, to: GridPoint)`, `func saveNow()`

Note on the debounce: mirror `Sources/LinkCKit/App/FlashMessage.swift` — an injected `sleep` and a generation counter, so a test drives the clock by hand rather than waiting.

- [ ] **Step 1: Write the failing tests**

Create `Tests/LinkCKitTests/WorkbenchModelTests.swift`:

```swift
import XCTest
@testable import LinkCKit

/// A clock the test releases by hand: each `sleep` waits until `release()` is called.
private actor Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume()
    }

    var waiting: Int { waiters.count }
}

@MainActor
final class WorkbenchModelTests: XCTestCase {
    nonisolated(unsafe) private var workspace: URL!

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-workbench-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: workspace)
    }

    private func makeModel(gate: Gate) -> WorkbenchModel {
        WorkbenchModel(
            store: SystemMapStore(workspacePath: workspace.path),
            settle: .milliseconds(600),
            sleep: { _ in await gate.wait() })
    }

    private func settle(_ gate: Gate, waiting count: Int) async {
        for _ in 0..<200 where await gate.waiting < count { await Task.yield() }
    }

    private func settleUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { await Task.yield() }
    }

    func testAProjectWithNoMapLoadsEmpty() {
        let model = makeModel(gate: Gate())
        model.load()
        XCTAssertEqual(model.state, .empty)
        XCTAssertTrue(model.map.components.isEmpty)
    }

    func testAnUnreadableMapFailsLoudAndRefusesToWrite() throws {
        let store = SystemMapStore(workspacePath: workspace.path)
        try FileManager.default.createDirectory(
            at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("{ nope".utf8)
        try bytes.write(to: store.fileURL)

        let model = makeModel(gate: Gate())
        model.load()

        guard case .failed(let reason) = model.state else {
            return XCTFail("expected a failed state, got \(model.state)")
        }
        XCTAssertFalse(reason.isEmpty)

        model.add(SystemComponent(name: "redis", kind: .cache))
        model.saveNow()
        XCTAssertEqual(try Data(contentsOf: store.fileURL), bytes, "a map linkC could not read must never be overwritten")
    }

    func testAnEditIsWrittenOnceAfterTheSettle() async throws {
        let gate = Gate()
        let model = makeModel(gate: gate)
        model.load()
        model.startMap()

        model.add(SystemComponent(name: "postgres", kind: .database))
        model.move("postgres", to: GridPoint(x: 2, y: 1))
        await settle(gate, waiting: 2)

        let store = SystemMapStore(workspacePath: workspace.path)
        XCTAssertNil(try store.load()?.components.first?.at, "nothing is written before the settle")

        // Two edits scheduled two writes; the first is stale by the time its clock runs out and
        // must write nothing, so only the second one lands.
        await gate.release()
        await gate.release()
        await settleUntil { (try? store.load())??.components.first?.at != nil }
        let saved = try XCTUnwrap(try store.load())
        XCTAssertEqual(saved.components.map(\.name), ["postgres"])
        XCTAssertEqual(saved.components[0].at, GridPoint(x: 2, y: 1))
    }

    func testEditsChangeTheMapInMemoryRightAway() {
        let model = makeModel(gate: Gate())
        model.load()
        model.startMap()

        model.add(SystemComponent(name: "redis", kind: .cache, intended: true))
        XCTAssertEqual(model.map.components.map(\.name), ["redis"])
        XCTAssertNotNil(model.positions["redis"], "a new tile has a place on the board at once")

        var edited = model.map.components[0]
        edited.reachedBy = "REDIS_URL"
        edited.intended = false
        model.update("redis", to: edited)
        XCTAssertEqual(model.map.components[0].reachedBy, "REDIS_URL")
        XCTAssertFalse(model.map.components[0].intended)

        model.remove("redis")
        XCTAssertTrue(model.map.components.isEmpty)
    }

    func testAddingAComponentUnderAnExistingNameIsRefusedWithoutLockingTheBoard() {
        let model = makeModel(gate: Gate())
        model.load()
        model.startMap()
        model.add(SystemComponent(name: "redis", kind: .cache))
        model.add(SystemComponent(name: "REDIS", kind: .database))

        XCTAssertEqual(model.map.components.count, 1, "names identify components, whatever their case")
        XCTAssertEqual(model.state, .loaded, "a refused name is not a broken file")
        XCTAssertEqual(model.refusal?.lowercased().contains("redis"), true)

        model.add(SystemComponent(name: "postgres", kind: .database))
        XCTAssertEqual(model.map.components.count, 2, "the next edit still works")
        XCTAssertNil(model.refusal, "the refusal clears once something lands")
    }

    func testReconcileFillsStatusesAndSuggestions() {
        let model = makeModel(gate: Gate())
        model.load()
        model.startMap()
        model.add(SystemComponent(name: "postgres", kind: .database, runs: "docker compose (db)"))

        model.reconcile(with: [DiscoveredThing(name: "minio", image: "minio/minio", detail: "container minio")])

        XCTAssertEqual(model.statuses["postgres"], .missing)
        XCTAssertEqual(model.suggestions.map(\.name), ["minio"])
    }

    func testAFailedSaveIsSurfaced() throws {
        let store = SystemMapStore(workspacePath: workspace.path)
        // A file where the .linkc directory must go: creating the directory cannot succeed.
        try Data().write(to: store.fileURL.deletingLastPathComponent())

        let model = makeModel(gate: Gate())
        model.load()
        model.startMap()
        model.add(SystemComponent(name: "redis", kind: .cache))
        model.saveNow()

        guard case .failed = model.state else {
            return XCTFail("a save that failed must not look like a save that worked")
        }
    }
}
```

- [ ] **Step 2: Run the tests and see them fail**

Run: `swift test --filter WorkbenchModelTests`
Expected: build failure — `cannot find 'WorkbenchModel' in scope`.

- [ ] **Step 3: Implement**

Create `Sources/LinkCKit/Workbench/WorkbenchModel.swift`:

```swift
import Foundation

/// What the board shows and edits: the loaded map, where its tiles sit, what linkC found when it
/// last looked, and the pending write. The band holds no logic of its own.
@MainActor
@Observable
public final class WorkbenchModel {
    public enum State: Equatable, Sendable {
        /// The project has no map yet.
        case empty
        case loaded
        /// The map could not be read, or an edit could not be written. Nothing is written while
        /// this holds: a file linkC could not read must never be overwritten.
        case failed(String)
    }

    public private(set) var state: State = .empty
    public private(set) var map: SystemMap = .empty
    public private(set) var statuses: [String: ComponentStatus] = [:]
    public private(set) var suggestions: [MapSuggestion] = []
    public private(set) var positions: [String: GridPoint] = [:]
    /// The last edit linkC would not make — a name already in use. Transient, and cleared by the
    /// next edit that lands: a mistyped name must not lock the board the way a broken file does.
    public private(set) var refusal: String?

    @ObservationIgnored private let store: SystemMapStore
    @ObservationIgnored private let settle: Duration
    @ObservationIgnored private let sleep: @Sendable (Duration) async -> Void
    @ObservationIgnored private var generation = 0

    public init(
        store: SystemMapStore,
        settle: Duration = .milliseconds(600),
        sleep: @escaping @Sendable (Duration) async -> Void = { duration in try? await Task.sleep(for: duration) }
    ) {
        self.store = store
        self.settle = settle
        self.sleep = sleep
    }

    /// Reads the project's map. A project with none is `empty`, not an error.
    public func load() {
        do {
            if let loaded = try store.load() {
                map = loaded
                state = .loaded
            } else {
                map = .empty
                state = .empty
            }
        } catch {
            map = .empty
            state = .failed(message(for: error))
        }
        relayout()
    }

    /// Starts a map for a project that has none. The first edit writes the file.
    public func startMap() {
        guard state == .empty else { return }
        map = .empty
        state = .loaded
    }

    public func reconcile(with discovered: [DiscoveredThing]) {
        let result = SystemReconciler.reconcile(map: map, discovered: discovered)
        statuses = result.statuses
        suggestions = result.suggestions
    }

    public func add(_ component: SystemComponent) {
        guard canEdit else { return }
        refusal = nil
        guard !map.components.contains(where: { $0.name.lowercased() == component.name.lowercased() }) else {
            refusal = "this project's map already names \"\(component.name)\""
            return
        }
        map.components.append(component)
        edited()
    }

    public func update(_ name: String, to component: SystemComponent) {
        guard canEdit, let index = indexOf(name) else { return }
        refusal = nil
        let clash = map.components.enumerated().contains { other in
            other.offset != index && other.element.name.lowercased() == component.name.lowercased()
        }
        guard !clash else {
            refusal = "this project's map already names \"\(component.name)\""
            return
        }
        map.components[index] = component
        edited()
    }

    public func remove(_ name: String) {
        guard canEdit, let index = indexOf(name) else { return }
        map.components.remove(at: index)
        edited()
    }

    public func move(_ name: String, to point: GridPoint) {
        guard canEdit, let index = indexOf(name) else { return }
        map.components[index].at = point
        edited()
    }

    /// Writes now rather than after the settle — for a sheet closing, and for tests.
    public func saveNow() {
        generation += 1
        write()
    }

    // MARK: - Internals

    private var canEdit: Bool {
        if case .failed = state { return false }
        return true
    }

    private func indexOf(_ name: String) -> Int? {
        map.components.firstIndex { $0.name.lowercased() == name.lowercased() }
    }

    private func edited() {
        relayout()
        scheduleWrite()
    }

    private func relayout() {
        positions = WorkbenchLayout.positions(for: map.components)
    }

    /// One write per burst of edits: a drag is one file change, not fifty.
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
        guard canEdit else { return }
        do {
            try store.save(map)
        } catch {
            state = .failed(message(for: error))
        }
    }

    private func message(for error: Error) -> String {
        if let error = error as? LinkCError { return error.localizedDescription }
        return String(describing: error)
    }
}
```

- [ ] **Step 4: Run the tests and see them pass**

Run: `swift test --filter WorkbenchModelTests`
Expected: `Executed 7 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/LinkCKit/Workbench/WorkbenchModel.swift Tests/LinkCKitTests/WorkbenchModelTests.swift
git diff --cached --stat
git commit -m "feat(workbench): hold the map, its layout and one write per burst"
git log -1 --format=%B | grep -ic claude   # must print 0
```

---

### Task 6: Hand the map to agents over MCP

**Files:**
- Modify: `Sources/LinkCKit/MCP/MCPServer.swift` (the `linkc_get_project_context` tool description and its `case`)
- Create: `Sources/LinkCKit/Workbench/SystemMapReport.swift`
- Test: `Tests/LinkCKitTests/SystemMapReportTests.swift`

**Interfaces:**
- Consumes: `SystemMap`, `SystemComponent`, `ComponentStatus` (Tasks 1, 4).
- Produces: `enum SystemMapReport` — `static func markdown(for map: SystemMap, statuses: [String: ComponentStatus]) -> String`.

The `case "linkc_get_project_context":` handler builds a markdown string. Append the map section to it, reading the file through `SystemMapStore(workspacePath: board.projectPath)`. A map that cannot be read says so in the text rather than being skipped.

- [ ] **Step 1: Write the failing tests**

Create `Tests/LinkCKitTests/SystemMapReportTests.swift`:

```swift
import XCTest
@testable import LinkCKit

final class SystemMapReportTests: XCTestCase {
    private let map = SystemMap(components: [
        SystemComponent(name: "postgres", kind: .database, reachedBy: "DATABASE_URL",
                        runs: "docker compose (db)", usedBy: ["api", "worker"]),
        SystemComponent(name: "redis", kind: .cache, reachedBy: "REDIS_URL", intended: true),
        SystemComponent(name: "june-audio", kind: .host, reachedBy: "https://audio.example/mp3"),
    ])

    func testEveryComponentIsListedWithHowItIsReached() {
        let text = SystemMapReport.markdown(for: map, statuses: [:])
        XCTAssertTrue(text.contains("## System"), text)
        XCTAssertTrue(text.contains("postgres"))
        XCTAssertTrue(text.contains("database"))
        XCTAssertTrue(text.contains("DATABASE_URL"))
        XCTAssertTrue(text.contains("docker compose (db)"))
        XCTAssertTrue(text.contains("api, worker"))
        XCTAssertTrue(text.contains("https://audio.example/mp3"))
    }

    /// An agent must not treat something planned as something it can use.
    func testAnIntendedComponentSaysItDoesNotExistYet() throws {
        let line = try XCTUnwrap(
            SystemMapReport.markdown(for: map, statuses: [:])
                .split(separator: "\n").first { $0.contains("redis") })
        XCTAssertTrue(line.lowercased().contains("intended"), String(line))
    }

    func testAStatusIsReportedOnlyWhenLinkCKnowsOne() throws {
        let text = SystemMapReport.markdown(
            for: map, statuses: ["postgres": .present, "june-audio": .unchecked])
        let lines = text.split(separator: "\n")
        let postgres = try XCTUnwrap(lines.first { $0.contains("postgres") })
        let audio = try XCTUnwrap(lines.first { $0.contains("june-audio") })
        XCTAssertTrue(postgres.lowercased().contains("running"), String(postgres))
        XCTAssertFalse(audio.lowercased().contains("running"), String(audio))
        XCTAssertFalse(audio.lowercased().contains("missing"), String(audio))
    }

    func testAMissingComponentSaysSo() throws {
        let line = try XCTUnwrap(
            SystemMapReport.markdown(for: map, statuses: ["postgres": .missing])
                .split(separator: "\n").first { $0.contains("postgres") })
        XCTAssertTrue(line.lowercased().contains("not running"), String(line))
    }

    func testAnEmptyMapReportsNothing() {
        XCTAssertTrue(SystemMapReport.markdown(for: .empty, statuses: [:]).isEmpty)
    }
}
```

- [ ] **Step 2: Run the tests and see them fail**

Run: `swift test --filter SystemMapReportTests`
Expected: build failure — `cannot find 'SystemMapReport' in scope`.

- [ ] **Step 3: Implement the report**

Create `Sources/LinkCKit/Workbench/SystemMapReport.swift`:

```swift
import Foundation

/// The map as an agent reads it, in the same markdown the project-context tool already returns.
public enum SystemMapReport {
    /// "" when the map names nothing — an empty section is noise in a tool result.
    public static func markdown(for map: SystemMap, statuses: [String: ComponentStatus]) -> String {
        guard !map.components.isEmpty else { return "" }
        var text = "## System\n"
        for component in map.components {
            var parts: [String] = [component.kind.raw]
            if let reachedBy = component.reachedBy, !reachedBy.isEmpty { parts.append("reached by \(reachedBy)") }
            if let runs = component.runs, !runs.isEmpty { parts.append("runs \(runs)") }
            if !component.usedBy.isEmpty { parts.append("used by \(component.usedBy.joined(separator: ", "))") }
            if component.intended {
                parts.append("INTENDED — does not exist yet")
            } else {
                switch statuses[component.name] {
                case .present: parts.append("running now")
                case .missing: parts.append("NOT running")
                case .unchecked, nil: break
                }
            }
            text += "- **\(component.name)** — \(parts.joined(separator: " · "))\n"
        }
        return text + "\n"
    }
}
```

- [ ] **Step 4: Run the tests and see them pass**

Run: `swift test --filter SystemMapReportTests`
Expected: `Executed 5 tests, with 0 failures`.

- [ ] **Step 5: Add the section to the tool**

In `Sources/LinkCKit/MCP/MCPServer.swift`, update the tool's description (around line 216) to mention the map:

```swift
    "description": "Get this project's system map — its components, how each is reached, and what exists versus what is only intended — plus all peer agents active in this workspace, their goals, claimed files, and shared notes.",
```

Then, in `case "linkc_get_project_context":`, directly before `return toolResultResponse(id: id, text: text)`, add:

```swift
    // The project's own map of its components, when it keeps one. A map that cannot be read
    // says so: an agent must not be told a project has no components when it has a broken file.
    do {
        if let map = try SystemMapStore(workspacePath: board.projectPath).load() {
            text += SystemMapReport.markdown(for: map, statuses: [:])
        }
    } catch {
        text += "## System\n_The system map could not be read: \(error.localizedDescription)_\n\n"
    }
```

- [ ] **Step 6: Run the MCP tests**

Run: `swift test --filter MCPServer`
Expected: every existing MCP test still passes.

- [ ] **Step 7: Commit**

```bash
git add Sources/LinkCKit/Workbench/SystemMapReport.swift Tests/LinkCKitTests/SystemMapReportTests.swift Sources/LinkCKit/MCP/MCPServer.swift
git diff --cached --stat
git commit -m "feat(mcp): report the project's system map in its context tool"
git log -1 --format=%B | grep -ic claude   # must print 0
```

---

### Task 7: Remember whether a project's band is open

**Files:**
- Modify: `Sources/LinkCKit/Preferences/SidebarState.swift`
- Test: `Tests/LinkCKitTests/SidebarStateTests.swift`

**Interfaces:**
- Consumes: the existing `SidebarState` persistence (one JSON blob under the `sidebarState` key).
- Produces: `func isWorkbenchOpen(_ path: String) -> Bool` (default true) and `func setWorkbenchOpen(_ path: String, _ open: Bool)`.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/LinkCKitTests/SidebarStateTests.swift`, following the file's existing pattern for building a state on a throwaway `UserDefaults`:

```swift
    func testAProjectsBandStartsOpenAndRemembersBeingClosed() {
        let defaults = makeDefaults()
        let state = SidebarState(defaults: defaults)
        XCTAssertTrue(state.isWorkbenchOpen("/p"), "a project's board starts open")

        state.setWorkbenchOpen("/p", false)
        XCTAssertFalse(state.isWorkbenchOpen("/p"))
        XCTAssertTrue(state.isWorkbenchOpen("/other"), "closing one project's board leaves the rest alone")

        XCTAssertFalse(SidebarState(defaults: defaults).isWorkbenchOpen("/p"), "the choice survives a relaunch")
    }
```

(If the existing tests build their `UserDefaults` inline rather than through a helper, match whatever they do — do not add a helper just for this test.)

- [ ] **Step 2: Run the tests and see them fail**

Run: `swift test --filter SidebarStateTests`
Expected: build failure — `value of type 'SidebarState' has no member 'isWorkbenchOpen'`.

- [ ] **Step 3: Implement**

In `Sources/LinkCKit/Preferences/SidebarState.swift`: add `var workbenchClosed: [String: Bool]?` to the private `Stored` struct (optional, so a blob written before this change still decodes), read it in the initializer as `stored.workbenchClosed ?? [:]` into a new `private var workbenchClosed: [String: Bool] = [:]`, write it in `save()` alongside the existing fields, and add:

```swift
    /// Whether a project's system board is open. Open by default: a project you have never
    /// touched shows its board rather than hiding it.
    public func isWorkbenchOpen(_ path: String) -> Bool {
        workbenchClosed[path] != true
    }

    public func setWorkbenchOpen(_ path: String, _ open: Bool) {
        if open { workbenchClosed.removeValue(forKey: path) } else { workbenchClosed[path] = true }
        save()
    }
```

- [ ] **Step 4: Run the tests and see them pass**

Run: `swift test --filter SidebarStateTests`
Expected: every test passes, including the existing ones.

- [ ] **Step 5: Commit**

```bash
git add Sources/LinkCKit/Preferences/SidebarState.swift Tests/LinkCKitTests/SidebarStateTests.swift
git diff --cached --stat
git commit -m "feat(workbench): remember whether a project's board is open"
git log -1 --format=%B | grep -ic claude   # must print 0
```

---

### Task 8: The board

**Files:**
- Create: `Sources/linkc/WorkbenchBand.swift`
- Modify: `Sources/linkc/ProjectDashboardSheet.swift` (mount the band; grow the sheet)
- Modify: `Sources/linkc/LinkCApp.swift` (build the discovery list the band reconciles against)

**Interfaces:**
- Consumes: `WorkbenchModel`, `SystemComponent`, `ComponentKind`, `ComponentStatus`, `MapSuggestion`, `GridPoint`, `SystemMapStore`, `WorkbenchLayout.columns`, `SidebarState.isWorkbenchOpen/setWorkbenchOpen` (Tasks 1–7).
- Produces: `struct WorkbenchBand: View` — `init(workspacePath: String, model: AppModel)`; and on `AppModel`, `func discoveredThings(in workspacePath: String) -> [DiscoveredThing]`.

There is no SwiftUI test harness in this repo, which is why every rule already lives in `WorkbenchModel`. This task adds no tests; it wires tested pieces to a view.

- [ ] **Step 1: Build the discovery list**

In `Sources/linkc/LinkCApp.swift`, next to the other project helpers on `AppModel`:

```swift
    /// What linkC can see running for a project, reduced to what the system map is compared
    /// against: the containers of a compose project rooted at this folder, and the services of a
    /// stack linkC already knows for it. Nothing here runs a process — it reads what the tool
    /// server service last found.
    func discoveredThings(in workspacePath: String) -> [DiscoveredThing] {
        let folder = (workspacePath as NSString).standardizingPath
        var things: [DiscoveredThing] = []
        var seen: Set<String> = []

        for project in toolServers?.projects ?? [] {
            guard let dir = project.workingDir,
                  (dir as NSString).standardizingPath == folder else { continue }
            for container in project.containers where container.state == .running {
                let name = container.composeService ?? container.name
                guard seen.insert(name.lowercased()).inserted else { continue }
                things.append(DiscoveredThing(
                    name: name, image: container.image,
                    detail: "container \(container.name) · \(container.image)"))
            }
        }

        for stack in toolServers?.knownStacks.stacks ?? []
        where (stack.workingDir as NSString).standardizingPath == folder {
            for service in stack.services {
                guard seen.insert(service.lowercased()).inserted else { continue }
                things.append(DiscoveredThing(
                    name: service, image: nil, detail: "compose service in \(stack.name)"))
            }
        }
        return things
    }
```

- [ ] **Step 2: Write the band**

Create `Sources/linkc/WorkbenchBand.swift`:

```swift
import SwiftUI
import LinkCKit

/// A project's system board: its components as tiles you drag, and what linkC found running
/// that the map does not name. Every rule lives in `WorkbenchModel`; this draws it.
struct WorkbenchBand: View {
    let workspacePath: String
    let model: AppModel

    @State private var workbench: WorkbenchModel
    @State private var editing: SystemComponent?
    @State private var showingSuggestions = false

    private static let cell = CGSize(width: 132, height: 46)
    private static let gap: CGFloat = 8

    init(workspacePath: String, model: AppModel) {
        self.workspacePath = workspacePath
        self.model = model
        _workbench = State(wrappedValue: WorkbenchModel(store: SystemMapStore(workspacePath: workspacePath)))
    }

    private var isOpen: Bool { model.sidebarState.isWorkbenchOpen(workspacePath) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if isOpen {
                content
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .task {
            workbench.load()
            workbench.reconcile(with: model.discoveredThings(in: workspacePath))
        }
        .onDisappear { workbench.saveNow() }
        .popover(item: $editing) { component in
            ComponentEditor(component: component, workbench: workbench) { editing = nil }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                model.sidebarState.setWorkbenchOpen(workspacePath, !isOpen)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                    Text("SYSTEM")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.8)
                }
                .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 6)

            if !workbench.suggestions.isEmpty {
                Button { showingSuggestions = true } label: {
                    Text("\(workbench.suggestions.count) running, not on the map")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showingSuggestions) { suggestionList }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if case .failed(let reason) = workbench.state {
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.statusError)
                .lineLimit(2)
        } else if workbench.map.components.isEmpty {
            HStack(spacing: 8) {
                Text("No system map for this project yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                Button("Start one") {
                    workbench.startMap()
                    add(kind: .service)
                }
                .font(.system(size: 11))
            }
            .frame(height: 60, alignment: .leading)
        } else {
            board
            if let refusal = workbench.refusal {
                Text(refusal)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)
            }
            palette
        }
    }

    private var board: some View {
        ZStack(alignment: .topLeading) {
            ForEach(workbench.map.components) { component in
                let point = workbench.positions[component.name] ?? GridPoint(x: 0, y: 0)
                ComponentTile(
                    component: component,
                    status: workbench.statuses[component.name],
                    onEdit: { editing = component },
                    onRemove: { workbench.remove(component.name) },
                    onDrop: { translation in
                        workbench.move(component.name, to: GridPoint(
                            x: max(0, point.x + Int((translation.width / (Self.cell.width + Self.gap)).rounded())),
                            y: max(0, point.y + Int((translation.height / (Self.cell.height + Self.gap)).rounded()))))
                    })
                .frame(width: Self.cell.width, height: Self.cell.height)
                .offset(
                    x: CGFloat(point.x) * (Self.cell.width + Self.gap),
                    y: CGFloat(point.y) * (Self.cell.height + Self.gap))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: boardHeight, alignment: .topLeading)
    }

    private var boardHeight: CGFloat {
        let rows = (workbench.positions.values.map(\.y).max() ?? 0) + 1
        return CGFloat(min(rows, 3)) * (Self.cell.height + Self.gap)
    }

    private var palette: some View {
        HStack(spacing: 6) {
            ForEach(ComponentKind.known, id: \.raw) { kind in
                Button { add(kind: kind) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: glyph(for: kind)).font(.system(size: 9))
                        Text(kind.raw).font(.system(size: 10))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Theme.hover))
                    .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Add a \(kind.raw) you mean to build")
            }
        }
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(workbench.suggestions) { suggestion in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(suggestion.name).font(.system(size: 11, weight: .medium))
                        Text(suggestion.detail).font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                    }
                    Spacer(minLength: 12)
                    Button("Add") {
                        workbench.add(SystemComponent(name: suggestion.name, kind: suggestion.kind))
                        workbench.reconcile(with: model.discoveredThings(in: workspacePath))
                    }
                    .font(.system(size: 11))
                }
            }
        }
        .padding(12)
        .frame(width: 320)
    }

    /// A component you add by hand starts intended: you are describing something you mean to
    /// build, and it becomes present when discovery finds it.
    private func add(kind: ComponentKind) {
        var name = "new-\(kind.raw)"
        var suffix = 2
        while workbench.map.components.contains(where: { $0.name.lowercased() == name.lowercased() }) {
            name = "new-\(kind.raw)-\(suffix)"
            suffix += 1
        }
        let component = SystemComponent(name: name, kind: kind, intended: true)
        workbench.add(component)
        editing = component
    }

    fileprivate static func glyphName(for kind: ComponentKind) -> String {
        switch kind {
        case .database: return "cylinder.split.1x2"
        case .cache: return "bolt.horizontal"
        case .queue: return "tray.full"
        case .storage: return "externaldrive"
        case .host: return "server.rack"
        case .external: return "cloud"
        default: return "shippingbox"
        }
    }

    private func glyph(for kind: ComponentKind) -> String { Self.glyphName(for: kind) }
}

/// One component. Solid when it is real, outlined when it is only intended, dimmed when linkC
/// looked for it and did not find it.
private struct ComponentTile: View {
    let component: SystemComponent
    let status: ComponentStatus?
    let onEdit: () -> Void
    let onRemove: () -> Void
    let onDrop: (CGSize) -> Void

    @State private var drag: CGSize = .zero

    private var isMissing: Bool { status == .missing && !component.intended }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: WorkbenchBand.glyphName(for: component.kind))
                .font(.system(size: 11))
                .foregroundStyle(isMissing ? Theme.textTertiary : Theme.textSecondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(component.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isMissing ? Theme.textTertiary : Theme.textPrimary)
                    .lineLimit(1)
                if let reachedBy = component.reachedBy, !reachedBy.isEmpty {
                    Text(reachedBy)
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 2)
            if status == .present {
                Circle().fill(Theme.statusRunning).frame(width: 5, height: 5)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.rowRadius)
                .fill(component.intended ? Color.clear : Theme.hover))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.rowRadius)
                .strokeBorder(
                    component.intended ? Theme.textTertiary : .clear,
                    style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
        .opacity(isMissing ? 0.55 : 1)
        .offset(drag)
        .gesture(
            DragGesture()
                .onChanged { drag = $0.translation }
                .onEnded { value in
                    drag = .zero
                    onDrop(value.translation)
                })
        .onTapGesture(count: 2, perform: onEdit)
        .contextMenu {
            Button("Edit…", action: onEdit)
            Button("Remove", role: .destructive, action: onRemove)
        }
        .help(helpText)
    }

    private var helpText: String {
        var parts: [String] = [component.kind.raw]
        if let runs = component.runs, !runs.isEmpty { parts.append("runs \(runs)") }
        if !component.usedBy.isEmpty { parts.append("used by \(component.usedBy.joined(separator: ", "))") }
        switch status {
        case .present: parts.append("running now")
        case .missing: parts.append("linkC looked for this and did not find it")
        case .unchecked, nil: parts.append("linkC cannot check this one")
        }
        if component.intended { parts.append("intended — does not exist yet") }
        return parts.joined(separator: " · ")
    }
}

/// Editing one component's fields.
private struct ComponentEditor: View {
    @State var component: SystemComponent
    let workbench: WorkbenchModel
    let onClose: () -> Void

    @State private var usedByText: String = ""

    private let original: String

    init(component: SystemComponent, workbench: WorkbenchModel, onClose: @escaping () -> Void) {
        _component = State(wrappedValue: component)
        self.workbench = workbench
        self.onClose = onClose
        original = component.name
        _usedByText = State(wrappedValue: component.usedBy.joined(separator: ", "))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("name", text: $component.name)
            Picker("kind", selection: Binding(
                get: { component.kind.raw },
                set: { component.kind = ComponentKind($0) })) {
                    ForEach(ComponentKind.known, id: \.raw) { Text($0.raw).tag($0.raw) }
                }
            TextField("reached by", text: Binding(
                get: { component.reachedBy ?? "" }, set: { component.reachedBy = $0 }))
            TextField("runs", text: Binding(
                get: { component.runs ?? "" }, set: { component.runs = $0 }))
            TextField("used by (comma separated)", text: $usedByText)
            Toggle("intended — does not exist yet", isOn: $component.intended)
            HStack {
                Spacer()
                Button("Done") {
                    component.usedBy = usedByText
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    workbench.update(original, to: component)
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 11))
        .padding(12)
        .frame(width: 300)
    }
}
```

- [ ] **Step 3: Mount it in the sheet**

In `Sources/linkc/ProjectDashboardSheet.swift`, inside the outer `VStack`, after the header `VStack` closes and before `Divider()`:

```swift
            WorkbenchBand(workspacePath: workspacePath, model: model)
            Divider()
```

and grow the sheet so the board has room — change `.frame(width: 600, height: 520)` to:

```swift
        .frame(width: 720, height: 620)
```

- [ ] **Step 4: Build and check the whole suite**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`

Run: `swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1`
Expected: every test passes; the count is the baseline plus the tests this plan added.

- [ ] **Step 5: Commit**

```bash
git add Sources/linkc/WorkbenchBand.swift Sources/linkc/ProjectDashboardSheet.swift Sources/linkc/LinkCApp.swift
git diff --cached --stat
git commit -m "feat(workbench): a board at the top of each project"
git log -1 --format=%B | grep -ic claude   # must print 0
```

---

### Final verification (controller, not a subagent)

- [ ] Revert-proof each task's core line — the decoder's unknown-key round trip, the store's refusal to read a broken file as empty, the layout's determinism, the reconciler's missing-versus-unchecked rule, the model's debounce, the MCP section — breaking it turns its tests red, restoring it turns them green.
- [ ] `./build-app.sh` ends with `==> Done:`, then open a project's dashboard in the running app: start a map, add a component, drag it, confirm `.linkc/system.json` holds the position, and confirm `git status` shows exactly that one file.
- [ ] Run a linkC-hosted agent's `linkc_get_project_context` in a project that has a map, and confirm the System section lists the components.
- [ ] Break the map file by hand and confirm the band shows the reason and refuses to overwrite it.

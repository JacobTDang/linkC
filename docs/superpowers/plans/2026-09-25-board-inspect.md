# Board inspect — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task by task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** dense Boards, such as a RISC-V datapath or a protocol map, become readable, with:
- hover cards;
- a click-pinned docked inspector;
- All / Data / Control lenses and Focus;
- calmer lines (planned shown on boxes only, solid buses);
- one collision-free pill per arrow carrying its width;
- spread arrow ends on a shared side.

**Architecture:**
- **Pure LinkCKit pieces, test-first:**
  - `BoardLens` (and `BoardViewport.lens`), `BoardInspection` (card contents), `BoardFocus` (visible sets) and `BoardHitTest` (the nearest arrow);
  - `BoardLabels.pillText` feeding the existing placer;
  - end spreading in `BoardRouter`.
- **The app's Board canvas** draws and wires them:
  - calmer lines, no forced pills, the lens and its chips;
  - then hover cards, the docked inspector, Focus, Esc, and the double-click editor.

**Tech Stack:** Swift 6, macOS 14, SwiftUI Canvas, XCTest.

Spec: `docs/superpowers/specs/2026-09-25-board-inspect-design.md`.

## Global Constraints

- **Where to work:** the worktree `/Users/jacobdang/Projects/linkC/.worktrees/board-inspect`, branch `feat/board-inspect`. Never touch `/Users/jacobdang/Projects/linkC` itself or any other `.worktrees` folder.
- **Where the logic lives:** in LinkCKit, unit-tested. The `linkc` app target only draws and wires. No SwiftUI view body writes model state.
- **Test-first** for all LinkCKit behaviour: stub, see red on an assertion (never a compile error), implement, see green.
- **Deterministic:** the same map gives the same routes, pills, cards and hit results. Ties break by the arrow key, lowercased (`from`, then `to`).
- **Fail loud:** no swallowed errors. Log with format arguments only.
- **Values, verbatim from the spec:**
  - the hover card appears after **150 ms**, while the highlight is immediate;
  - the hit tolerance is **6 pt on screen**;
  - the inspector is **260 pt** wide;
  - arrows outside the lens draw at **10 %** opacity;
  - spread ends use a band of **±16 pt** on a left or right side and **±48 pt** on a top or bottom side, at least **12 pt** apart where the band allows;
  - the pill text is the label, **two spaces**, then the width;
  - the lens values are `all`, `data` (bus and plain) and `control` (control and conditional).
- **Build:** `swift build 2>&1 | tail -1`. `swift build --build-tests 2>&1 | grep -E "warning:"` must print nothing.
- **Suite:** `swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1` must report 0 failures. Main is at 1451 tests.
- **Commits:**
  - one per task, with a one-line message starting `feat(board): `;
  - stage files by name;
  - no trailers of any kind;
  - "claude" never appears in a message, in any case.

---

### Task 1: The lens, inspection cards, focus sets and the arrow hit-test

**Files:**
- Create: `Sources/LinkCKit/Board/BoardLens.swift`, `Sources/LinkCKit/Board/BoardInspection.swift`, `Sources/LinkCKit/Board/BoardFocus.swift` and `Sources/LinkCKit/Board/BoardHitTest.swift`
- Modify: `Sources/LinkCKit/Board/BoardViewport.swift` (a `lens` field, with Codable that tolerates old data)
- Test: create `Tests/LinkCKitTests/BoardLensTests.swift`, `BoardInspectionTests.swift`, `BoardFocusTests.swift` and `BoardHitTestTests.swift`

**Interfaces (produces):**
- `public enum BoardLens: String, Codable, Sendable, CaseIterable { case all, data, control; func includes(_ style: BoardArrowStyle) -> Bool }`
- `BoardViewport.lens: BoardLens`, with the init parameter `lens: BoardLens = .all`
- `public enum BoardInspection`, with:
  - `struct Row { signal, bits, other, style, isControl }`;
  - `struct Part { name, kind: ComponentKind, planned, does, inputs: [Row], outputs: [Row] }`;
  - `struct Arrow { from, to, label, bits, style, plannedEnds: [String] }`;
  - `static func part(_:in:) -> Part?` and `static func arrow(_:in:) -> Arrow?`.
- `public enum BoardFocus { struct Visible { parts: Set<String>; arrows: Set<BoardModel.ArrowKey> }; static func visible(aroundPart:in:) -> Visible; static func visible(aroundArrow:in:) -> Visible }`
- `public enum BoardHitTest { static func arrow(atX:y:routes:tolerance:including:) -> BoardModel.ArrowKey? }`

- [ ] **Step 1: Stub all four types and the viewport field** so the tests compile:
  - `includes` returns `true`;
  - `part` and `arrow` return nil;
  - `visible` returns empty sets;
  - `arrow(atX:…)` returns nil;
  - `BoardViewport` gets `public var lens: BoardLens = .all`, but no custom Codable yet.

- [ ] **Step 2: Write the failing tests.**

`Tests/LinkCKitTests/BoardLensTests.swift`:
```swift
import XCTest
@testable import LinkCKit

final class BoardLensTests: XCTestCase {
    func testEachLensKeepsItsStyles() {
        XCTAssertTrue(BoardArrowStyle.allCases.allSatisfy { BoardLens.all.includes($0) })
        XCTAssertEqual(BoardArrowStyle.allCases.filter { BoardLens.data.includes($0) }, [.plain, .bus])
        XCTAssertEqual(BoardArrowStyle.allCases.filter { BoardLens.control.includes($0) }, [.conditional, .control])
    }

    func testAViewportSavedBeforeLensesDecodesAsAll() throws {
        let saved = #"{"originX": 10, "originY": -20, "zoom": 0.5}"#
        let viewport = try JSONDecoder().decode(BoardViewport.self, from: Data(saved.utf8))
        XCTAssertEqual(viewport.lens, .all)
        XCTAssertEqual(viewport.zoom, 0.5)
    }

    func testTheLensRoundTrips() throws {
        let viewport = BoardViewport(originX: 1, originY: 2, zoom: 1, lens: .control)
        let decoded = try JSONDecoder().decode(BoardViewport.self, from: JSONEncoder().encode(viewport))
        XCTAssertEqual(decoded, viewport)
    }
}
```

`Tests/LinkCKitTests/BoardInspectionTests.swift`:
```swift
import XCTest
@testable import LinkCKit

final class BoardInspectionTests: XCTestCase {
    /// Shaped like the RISC-V Register File: three buses in, a control signal in, three buses out.
    private func map() -> BoardMap {
        var m = BoardMap()
        m.components = [
            BoardComponent(name: "Instruction Memory", kind: .ram,
                           uses: ["Register File": BoardArrow(label: "rs1, rs2, rd", style: .bus, bits: 15)]),
            BoardComponent(name: "Control Unit", kind: .control, uses: ["Register File": BoardArrow(label: "RegWrite", style: .control)]),
            BoardComponent(name: "Writeback Mux", kind: .mux, uses: ["Register File": BoardArrow(label: "write data", style: .bus, bits: 32)]),
            BoardComponent(name: "Register File", kind: .register, does: "32 x 32-bit, two read ports, one write port", planned: true,
                           uses: ["ALU": BoardArrow(label: "rs1 data", style: .bus, bits: 32),
                                  "Data Memory": BoardArrow(label: "store data", style: .bus, bits: 32),
                                  "ALU Operand Mux": BoardArrow(label: "", style: .bus, bits: 32)]),
            BoardComponent(name: "ALU", kind: .alu),
            BoardComponent(name: "ALU Operand Mux", kind: .mux),
            BoardComponent(name: "Data Memory", kind: .ram, planned: true),
        ]
        return m
    }

    func testAPartListsItsInputsAndOutputsInOrder() throws {
        let part = try XCTUnwrap(BoardInspection.part("Register File", in: map()))
        XCTAssertEqual(part.kind, .register)
        XCTAssertTrue(part.planned)
        XCTAssertEqual(part.does, "32 x 32-bit, two read ports, one write port")
        XCTAssertEqual(part.inputs.map(\.other), ["Control Unit", "Instruction Memory", "Writeback Mux"])
        XCTAssertEqual(part.inputs.map(\.signal), ["RegWrite", "rs1, rs2, rd", "write data"])
        XCTAssertEqual(part.inputs.map(\.bits), [nil, 15, 32])
        XCTAssertEqual(part.inputs.map(\.isControl), [true, false, false])
        XCTAssertEqual(part.outputs.map(\.other), ["ALU", "ALU Operand Mux", "Data Memory"])
        XCTAssertEqual(part.outputs.map(\.signal), ["rs1 data", "ALU Operand Mux", "store data"],
                       "an arrow with no label is named after its other end")
    }

    func testAnArrowCardNamesItsEndsAndItsPlannedEnds() throws {
        let card = try XCTUnwrap(BoardInspection.arrow(BoardModel.ArrowKey(from: "Register File", to: "Data Memory"), in: map()))
        XCTAssertEqual(card.from, "Register File")
        XCTAssertEqual(card.to, "Data Memory")
        XCTAssertEqual(card.label, "store data")
        XCTAssertEqual(card.bits, 32)
        XCTAssertEqual(card.style, .bus)
        XCTAssertEqual(card.plannedEnds, ["Register File", "Data Memory"])
    }

    func testAnUnknownPartOrArrowHasNoCard() {
        XCTAssertNil(BoardInspection.part("Nope", in: map()))
        XCTAssertNil(BoardInspection.arrow(BoardModel.ArrowKey(from: "ALU", to: "Nope"), in: map()))
    }
}
```

`Tests/LinkCKitTests/BoardFocusTests.swift`:
```swift
import XCTest
@testable import LinkCKit

final class BoardFocusTests: XCTestCase {
    private func map() -> BoardMap {
        var m = BoardMap()
        m.components = [
            BoardComponent(name: "A", kind: .service, uses: ["B": "calls"]),
            BoardComponent(name: "B", kind: .service, uses: ["C": "calls"]),
            BoardComponent(name: "C", kind: .service),
            BoardComponent(name: "D", kind: .service, uses: ["B": "reads"]),
            BoardComponent(name: "E", kind: .service, uses: ["C": "writes"]),
        ]
        return m
    }

    func testAPartKeepsItselfAndItsDirectNeighboursBothWays() {
        let visible = BoardFocus.visible(aroundPart: "B", in: map())
        XCTAssertEqual(visible.parts, ["A", "B", "C", "D"])
        XCTAssertEqual(visible.arrows, [.init(from: "A", to: "B"), .init(from: "B", to: "C"), .init(from: "D", to: "B")])
    }

    func testAnArrowKeepsOnlyItsTwoEnds() {
        let visible = BoardFocus.visible(aroundArrow: .init(from: "E", to: "C"), in: map())
        XCTAssertEqual(visible.parts, ["E", "C"])
        XCTAssertEqual(visible.arrows, [.init(from: "E", to: "C")])
    }
}
```

`Tests/LinkCKitTests/BoardHitTestTests.swift`:
```swift
import XCTest
@testable import LinkCKit

final class BoardHitTestTests: XCTestCase {
    private let routes: [BoardModel.ArrowKey: BoardRoute] = [
        .init(from: "a", to: "b"): BoardRoute(points: [BoardPoint(x: 0, y: 0), BoardPoint(x: 100, y: 0)], bundle: nil),
        .init(from: "c", to: "d"): BoardRoute(points: [BoardPoint(x: 0, y: 10), BoardPoint(x: 100, y: 10)], bundle: nil),
        .init(from: "e", to: "f"): BoardRoute(points: [BoardPoint(x: 50, y: -50), BoardPoint(x: 50, y: 50)], bundle: nil),
    ]

    func testTheNearestArrowWithinTheToleranceWins() {
        XCTAssertEqual(BoardHitTest.arrow(atX: 20, y: 3, routes: routes, tolerance: 6), .init(from: "a", to: "b"))
        XCTAssertEqual(BoardHitTest.arrow(atX: 20, y: 7, routes: routes, tolerance: 6), .init(from: "c", to: "d"))
    }

    func testNothingBeyondTheTolerance() {
        XCTAssertNil(BoardHitTest.arrow(atX: 20, y: 30, routes: routes, tolerance: 6))
    }

    func testATieBreaksByTheArrowKey() {
        // (50, 5) is 5 from a→b, 5 from c→d and 0 from e→f. e→f is nearest.
        XCTAssertEqual(BoardHitTest.arrow(atX: 50, y: 5, routes: routes, tolerance: 6), .init(from: "e", to: "f"))
        // (20, 5) is exactly 5 from a→b and from c→d. The key order picks a→b.
        XCTAssertEqual(BoardHitTest.arrow(atX: 20, y: 5, routes: routes, tolerance: 6), .init(from: "a", to: "b"))
    }

    func testTheFilterExcludesArrows() {
        XCTAssertEqual(BoardHitTest.arrow(atX: 20, y: 3, routes: routes, tolerance: 6,
                                          including: { $0.from != "a" }), .init(from: "c", to: "d"))
    }
}
```

- [ ] **Step 3: Run and see them fail.**

Run: `swift test --filter "BoardLensTests|BoardInspectionTests|BoardFocusTests|BoardHitTestTests" 2>&1 | grep -E "error: -\[|Executed [0-9]+ test" | tail -20`
Expected: FAIL on assertions. Keep the red lines.

- [ ] **Step 4: Implement.**

`BoardLens.swift`:
```swift
import Foundation

/// Which arrows the Board shows at full strength. The others fade and ignore hover, and every
/// part stays visible.
public enum BoardLens: String, Codable, Sendable, CaseIterable {
    case all, data, control

    public func includes(_ style: BoardArrowStyle) -> Bool {
        switch self {
        case .all: return true
        case .data: return style == .bus || style == .plain
        case .control: return style == .control || style == .conditional
        }
    }
}
```

`BoardViewport.swift`:
- Add `public var lens: BoardLens` to the struct, and the parameter `lens: BoardLens = .all` to its `init` (assign it).
- Add an explicit Codable, keeping today's keys:
```swift
extension BoardViewport {
    private enum CodingKeys: String, CodingKey { case originX, originY, zoom, lens }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            originX: try container.decode(Double.self, forKey: .originX),
            originY: try container.decode(Double.self, forKey: .originY),
            zoom: try container.decode(Double.self, forKey: .zoom),
            lens: try container.decodeIfPresent(BoardLens.self, forKey: .lens) ?? .all)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(originX, forKey: .originX)
        try container.encode(originY, forKey: .originY)
        try container.encode(zoom, forKey: .zoom)
        try container.encode(lens, forKey: .lens)
    }
}
```
If the struct declares `Codable` in its own declaration, keep the conformance there and move these members into it, so there is exactly one conformance.

`BoardInspection.swift`:
```swift
import Foundation

/// What a hover card and the docked inspector show for an arrow or a part, read from the map.
/// Rows order by the other end's name, lowercased, so a card never reshuffles.
public enum BoardInspection {
    public struct Row: Equatable, Sendable {
        /// The arrow's label, or the other end's name when it has none.
        public let signal: String
        public let bits: Int?
        public let other: String
        public let style: BoardArrowStyle
        public var isControl: Bool { style == .control || style == .conditional }
    }

    public struct Part: Equatable, Sendable {
        public let name: String
        public let kind: ComponentKind
        public let planned: Bool
        public let does: String?
        public let inputs: [Row]
        public let outputs: [Row]
    }

    public struct Arrow: Equatable, Sendable {
        public let from: String
        public let to: String
        public let label: String
        public let bits: Int?
        public let style: BoardArrowStyle
        /// The ends whose status is planned, source first.
        public let plannedEnds: [String]
    }

    public static func part(_ name: String, in map: BoardMap) -> Part? {
        let key = name.lowercased()
        guard let part = map.components.first(where: { $0.name.lowercased() == key }) else { return nil }
        let outputs = part.uses.map { target, arrow in
            Row(signal: arrow.label.isEmpty ? target : arrow.label, bits: arrow.bits, other: target, style: arrow.style)
        }
        var inputs: [Row] = []
        for source in map.components {
            for (target, arrow) in source.uses where target.lowercased() == key {
                inputs.append(Row(signal: arrow.label.isEmpty ? source.name : arrow.label, bits: arrow.bits, other: source.name, style: arrow.style))
            }
        }
        let order: (Row, Row) -> Bool = { ($0.other.lowercased(), $0.signal) < ($1.other.lowercased(), $1.signal) }
        return Part(name: part.name, kind: part.kind, planned: part.planned, does: part.does,
                    inputs: inputs.sorted(by: order), outputs: outputs.sorted(by: order))
    }

    public static func arrow(_ key: BoardModel.ArrowKey, in map: BoardMap) -> Arrow? {
        guard let source = map.components.first(where: { $0.name.lowercased() == key.from.lowercased() }),
              let (target, arrow) = source.uses.first(where: { $0.key.lowercased() == key.to.lowercased() })
        else { return nil }
        let targetPart = map.components.first { $0.name.lowercased() == target.lowercased() }
        var planned: [String] = []
        if source.planned { planned.append(source.name) }
        if targetPart?.planned == true { planned.append(targetPart!.name) }
        return Arrow(from: source.name, to: targetPart?.name ?? target, label: arrow.label, bits: arrow.bits,
                     style: arrow.style, plannedEnds: planned)
    }
}
```
(If `source.uses.first(where:)` yields a `(key:, value:)` tuple that won't destructure in a `guard let`, bind it and read `.key`/`.value`. Don't force-unwrap `targetPart`: use `if let`.)

`BoardFocus.swift`:
```swift
import Foundation

/// What Focus keeps visible: a pinned part with its direct neighbours both ways, or a pinned
/// arrow with its two ends.
public enum BoardFocus {
    public struct Visible: Equatable, Sendable {
        public let parts: Set<String>
        public let arrows: Set<BoardModel.ArrowKey>
    }

    public static func visible(aroundPart name: String, in map: BoardMap) -> Visible {
        let key = name.lowercased()
        var parts: Set<String> = []
        var arrows: Set<BoardModel.ArrowKey> = []
        for component in map.components {
            for target in component.uses.keys {
                let touches = component.name.lowercased() == key || target.lowercased() == key
                guard touches else { continue }
                arrows.insert(BoardModel.ArrowKey(from: component.name, to: target))
                parts.insert(component.name)
                parts.insert(map.components.first { $0.name.lowercased() == target.lowercased() }?.name ?? target)
            }
            if component.name.lowercased() == key { parts.insert(component.name) }
        }
        return Visible(parts: parts, arrows: arrows)
    }

    public static func visible(aroundArrow key: BoardModel.ArrowKey, in map: BoardMap) -> Visible {
        let name: (String) -> String = { raw in map.components.first { $0.name.lowercased() == raw.lowercased() }?.name ?? raw }
        return Visible(parts: [name(key.from), name(key.to)], arrows: [key])
    }
}
```

`BoardHitTest.swift`:
```swift
import Foundation

/// Which arrow a pointer is over: the one whose route passes nearest, within `tolerance`, in
/// board units. The caller divides its screen tolerance by the zoom. Ties break by the arrow key.
public enum BoardHitTest {
    public static func arrow(
        atX x: Double, y: Double, routes: [BoardModel.ArrowKey: BoardRoute], tolerance: Double,
        including include: (BoardModel.ArrowKey) -> Bool = { _ in true }
    ) -> BoardModel.ArrowKey? {
        var best: (key: BoardModel.ArrowKey, distance: Double)?
        let keys = routes.keys.sorted { ($0.from.lowercased(), $0.to.lowercased()) < ($1.from.lowercased(), $1.to.lowercased()) }
        for key in keys where include(key) {
            guard let points = routes[key]?.points, points.count >= 2 else { continue }
            let distance = zip(points, points.dropFirst()).map { distanceFrom(x, y, toSegment: $0, $1) }.min() ?? .infinity
            guard distance <= tolerance else { continue }
            if best == nil || distance < best!.distance { best = (key, distance) }
        }
        return best?.key
    }

    static func distanceFrom(_ x: Double, _ y: Double, toSegment a: BoardPoint, _ b: BoardPoint) -> Double {
        let ax = Double(a.x), ay = Double(a.y), bx = Double(b.x), by = Double(b.y)
        let dx = bx - ax, dy = by - ay
        let lengthSquared = dx * dx + dy * dy
        let t = lengthSquared == 0 ? 0 : max(0, min(1, ((x - ax) * dx + (y - ay) * dy) / lengthSquared))
        let px = ax + t * dx, py = ay + t * dy
        return ((x - px) * (x - px) + (y - py) * (y - py)).squareRoot()
    }
}
```

- [ ] **Step 5: Run and see them pass,** then run the warnings check and the full suite (the existing `BoardViewportTests` must stay green).
- [ ] **Step 6: Commit.**
```bash
git add Sources/LinkCKit/Board/BoardLens.swift Sources/LinkCKit/Board/BoardInspection.swift Sources/LinkCKit/Board/BoardFocus.swift Sources/LinkCKit/Board/BoardHitTest.swift Sources/LinkCKit/Board/BoardViewport.swift Tests/LinkCKitTests/BoardLensTests.swift Tests/LinkCKitTests/BoardInspectionTests.swift Tests/LinkCKitTests/BoardFocusTests.swift Tests/LinkCKitTests/BoardHitTestTests.swift
git commit -m "feat(board): lenses, inspection cards, focus sets and an arrow hit-test"
```

---

### Task 2: One pill per arrow with its width, and spread arrow ends

**Files:**
- Modify: `Sources/LinkCKit/Board/BoardLabels.swift` (`pillText(for:)`)
- Modify: `Sources/LinkCKit/Board/BoardModel.swift` (`routesAndLabels`, around l.727-740, builds the placer's text with `pillText`)
- Modify: `Sources/LinkCKit/Board/BoardRouter.swift` (end spreading)
- Test: `Tests/LinkCKitTests/BoardLabelsTests.swift` and `Tests/LinkCKitTests/BoardRouterTests.swift`

**Interfaces (produces):**
- `BoardLabels.pillText(for arrow: BoardArrow) -> String?` returns:
  - `"<label>  <bits>"` when there's a label and a width;
  - `"<bits>"` when there's a width only;
  - `"<label>"` when there's a label only;
  - `nil` otherwise.
- `BoardModel.routesAndLabels(for:)`: `labelRects` now has a rect for every arrow with pill text, including buses without a label.
- `BoardRouter.routes(for:)`: unchanged signature. Ends spread as described below.

- [ ] **Step 1: Stub** `pillText(for:)` to return `arrow.label.isEmpty ? nil : arrow.label`.

- [ ] **Step 2: Write the failing tests.** Append to `BoardLabelsTests`:
```swift
    func testThePillCarriesTheWidth() {
        XCTAssertEqual(BoardLabels.pillText(for: BoardArrow(label: "rs1 data", style: .bus, bits: 32)), "rs1 data  32")
        XCTAssertEqual(BoardLabels.pillText(for: BoardArrow(label: "", style: .bus, bits: 32)), "32")
        XCTAssertEqual(BoardLabels.pillText(for: BoardArrow(label: "RegWrite", style: .control)), "RegWrite")
        XCTAssertNil(BoardLabels.pillText(for: BoardArrow(label: "", style: .plain)))
    }

    func testAnUnlabelledBusGetsAPlacedPill() throws {
        var m = BoardMap()
        m.components = [BoardComponent(name: "a", kind: .register, uses: ["b": BoardArrow(label: "", style: .bus, bits: 32)], at: BoardPoint(x: 0, y: 0)),
                        BoardComponent(name: "b", kind: .alu, at: BoardPoint(x: 500, y: 0))]
        let placed = try XCTUnwrap(BoardModel.routesAndLabels(for: m, isCancelled: { false }))
        let rect = try XCTUnwrap(placed.labelRects[.init(from: "a", to: "b")])
        XCTAssertEqual(rect.w, BoardLabels.width(of: "32"))
    }
```
Append to `BoardRouterTests`:
```swift
    /// The ALU case from the RISC-V Board: two differently labelled buses into one side.
    private func twoIntoOneSide() -> BoardMap {
        var m = BoardMap()
        m.components = [
            BoardComponent(name: "rf", kind: .register, uses: ["alu": BoardArrow(label: "rs1 data", style: .bus, bits: 32)], at: BoardPoint(x: 0, y: 0)),
            BoardComponent(name: "fwd", kind: .mux, uses: ["alu": BoardArrow(label: "operand A", style: .bus, bits: 32)], at: BoardPoint(x: 0, y: 300)),
            BoardComponent(name: "alu", kind: .alu, at: BoardPoint(x: 500, y: 150)),
        ]
        return m
    }

    func testUnbundledArrowsIntoOneSideGetTheirOwnEnds() throws {
        let routes = BoardRouter.routes(for: twoIntoOneSide())
        let top = try XCTUnwrap(routes[.init(from: "rf", to: "alu")]?.points.last)
        let bottom = try XCTUnwrap(routes[.init(from: "fwd", to: "alu")]?.points.last)
        XCTAssertEqual(top.x, bottom.x, "both land on the ALU's left side")
        XCTAssertGreaterThanOrEqual(abs(top.y - bottom.y), 12, "they no longer share one point")
        XCTAssertLessThan(top.y, bottom.y, "ordered by their sources: rf above fwd")
    }

    func testSpreadEndsStayDeterministic() {
        XCTAssertEqual(BoardRouter.routes(for: twoIntoOneSide()), BoardRouter.routes(for: twoIntoOneSide()))
    }
```
(If `BoardRoute` isn't `Equatable`, compare `.mapValues(\.points)`.)

- [ ] **Step 3: Run and see them fail** (`--filter "BoardLabelsTests|BoardRouterTests"`). Keep the red lines.

- [ ] **Step 4: Implement.**

`pillText(for:)`:
```swift
    /// What an arrow's pill says: its label, then its width after two spaces. A bus with no label
    /// shows its width alone, and an arrow with neither has no pill.
    public static func pillText(for arrow: BoardArrow) -> String? {
        let width = arrow.bits.map(String.init)
        switch (arrow.label.isEmpty, width) {
        case (false, let width?): return arrow.label + "  " + width
        case (false, nil): return arrow.label
        case (true, let width?): return width
        case (true, nil): return nil
        }
    }
```
In `BoardModel.routesAndLabels`, build the placer's labels from `BoardLabels.pillText(for: arrow)` in place of `arrow.label`, skipping nil. The router still bundles by `arrow.label`: don't change `BoardRouter`'s own label map.

**Spreading, in `BoardRouter.routes(for:)`:**
- **A pre-pass before the main loop.** For every non-self arrow key, decide its source side and target side exactly as the main loop does today:
  - a bundle's anchor side comes from `outAnchors`/`inAnchors` for its bundled end, and `sides(from:to:)` for the other end;
  - an unbundled arrow gets both from `sides(from:to:)`.
- **Grouping.** Group the ends by (box name lowercased, side). Each unbundled arrow end is one participant. Each bundle counts once, as one participant at its anchor, for its bundled end.
- **Ordering.** Order each group's participants by the other end's centre along the side's axis: y for a left or right side, x for a top or bottom side. For a bundle, use the mean centre that `bundles` already computes (expose it with the anchor). Break ties by `arrowId` (or the bundle id).
- **Slots.**
  - A group of one keeps `sidePort` (the midpoint).
  - A group of n > 1 gets slots spread evenly across the band (±16 on a left or right side, ±48 on a top or bottom side): offset_i = −band + (i + 0.5) × (2 × band / n).
  - With too many ends to keep 12 pt apart inside the band, keep the even spread anyway. Never extend past the band.
  - A bundle's anchor becomes its slot point.
- **The main loop** uses these ports in place of `sidePort(...)` (and bundle anchors use their slot).
- **`straightCase`** must respect the ports. Give it the two ports. For a left↔right pair, use the target port's y if it's inside the overlap [lo, hi] and the source's group has one end (it can move to match). Otherwise use the source port's y if it's inside and the target's group has one end. Otherwise use the midpoint as today, but only when both groups have one end. Otherwise return nil so A* routes it. Do the same for top↔bottom with x.
- **`nudge` and every existing router test** must keep passing. Any existing test that asserted a shared midpoint for different-label arrows into one side must now assert distinct points. Report each test you changed and why.

- [ ] **Step 5: Run and see them pass.** Run `BoardLabelsTests`, `BoardRouterTests`, `BoardModelTests` and `BoardLayoutTests`, then the warnings check and the full suite.
- [ ] **Step 6: Commit.**
```bash
git add Sources/LinkCKit/Board/BoardLabels.swift Sources/LinkCKit/Board/BoardModel.swift Sources/LinkCKit/Board/BoardRouter.swift Tests/LinkCKitTests/BoardLabelsTests.swift Tests/LinkCKitTests/BoardRouterTests.swift
git commit -m "feat(board): one pill per arrow with its width, and spread ends on a shared side"
```

---

### Task 3: Calmer lines, pills that are never forced, and the lens

**Files:**
- Modify: `Sources/linkc/Board/BoardCanvas.swift`
- Possibly: `Sources/linkc/Board/BoardElements.swift`, or wherever `BoardShape` is defined (per-height trimming)

**Behaviour** (read `drawArrows`, around l.477-529, `drawPill`, around l.710, `drawBusMark`, around l.684, and `fallbackLabelCenter`, around l.727):
1. **No dash for planned ends.** Drop the `planned ||` term from the dash choice. Dashes: `[5, 4]` for control and conditional only, and `[4, 4]` for the arrow-drawing preview only. The planned state still shows on the component box outline.
2. **The bus slash mark** draws without its number: remove the bits text from `drawBusMark`, and keep the slash.
3. **Pills:**
   - Draw a pill only where `board.labelRects[key]` exists. Delete the forced paths (`fallbackLabelCenter` under focus and under hover) and the helper if it becomes unused.
   - The pill shows `arrow.label`, then two spaces and the width in **bold** when `arrow.bits` is set. With no label, it shows the width alone, in bold.
   - A bundle's pill still draws once.
4. **The lens:**
   - Add `@State private var lens: BoardLens` to the canvas, loaded from and saved with the Board viewport, the same way the viewport persists (`sidebarState.boardViewport(for:)` / `setBoardViewport`). Save it when it changes.
   - An arrow whose style isn't in the lens draws at 10 % opacity, with no pill and no bus mark.
5. **The lens chips,** at the top left of the canvas overlay (the `.loaded` overlay `ZStack`, around l.341):
   - a segmented **All / Data / Control** in the toolbar's visual style (`BoardToolbar` in `BoardTools.swift`);
   - a **◎ Focus** button, disabled for now. Task 4 enables it.
   - The chips mustn't overlap the "What is this project?" header row. Put them below it, or in the same row on the left, whichever keeps the header readable.
6. **Per-height trimming:**
   - Arrow ends currently trim by `BoardShape.insets(for:)`, a constant per side measured at mid-height. Replace the end trimming with a function that walks inward from the end point, along the last segment's direction, in 0.5 pt steps up to 40 pt, until the point lies inside the kind's outline path. Use that inset.
   - Cache the result by (kind raw, side, offset from the side's midpoint), keeping the cache in the canvas's `@ObservationIgnored` state or in a static.
   - Rectangles give 0, as today.
   - Check by reading the code that at the midpoint the result matches today's constant inset for the notched ALU, the mux and demux trapezoids, the control ellipse and the adder circle. Report any kind that differs.

No LinkCKit changes and no new tests; this is drawing. Build after each item, and keep the full suite green.
- [ ] **Commit:** `feat(board): calmer lines, pills that are never forced, and All / Data / Control lenses`

---

### Task 4: Hover cards, the docked inspector, Focus, and click-to-pin

**Files:**
- Modify: `Sources/linkc/Board/BoardCanvas.swift`
- Create: `Sources/linkc/Board/BoardInspector.swift` (the card views and the docked panel)

**Behaviour:**
1. **Hover.**
   - Keep today's immediate highlight (`hoveredArrow`, `hovered`).
   - Swap the arrow hit-test for `BoardHitTest.arrow(atX:y:routes:tolerance:including:)`, with the pointer converted by `viewport.toCanvas`, a tolerance of 6 / zoom, and `including` limited to arrows inside the lens (arrows outside the lens ignore hover). Use it for hover and for the click selection (`backgroundTapped`), replacing the unordered `arrow(near:)`. Delete `arrow(near:)` if it becomes unused.
   - After the same item has been hovered for 150 ms, show a **hover card** near the pointer, clamped inside the canvas. A `Task` sleep keyed on the item is fine. Cancel it when the item changes.
   - The card renders `BoardInspection.arrow` or `BoardInspection.part`:
     - **An arrow's card:** *From → To*, then *label · 32-bit bus* (or the style's name), then *Planned: …* when `plannedEnds` isn't empty.
     - **A part's card:**
       - the name;
       - the kind caption (use the existing `defaultSubLine(for:)`, else `kind.raw.uppercased()`), plus *· PLANNED*;
       - the `does` text;
       - the **IN** and **OUT** sections: each row shows the signal, the width in bold (or a blank), and `← other` or `→ other`. Control rows use `Theme.boardGold`.
   - Style the card as in the approved mockup: a dark #232327-style fill, a hairline border, 10 pt radius, 12 pt text. Use `Theme` tokens, adding a card fill token if needed.
2. **Click to pin.**
   - A single click on an arrow or a part selects it, as today, and **pins** it. The docked inspector opens: a 260 pt panel at the right edge of the Board, full height, outside the zoomed content so it doesn't pan or zoom. It shows the same content as the card.
   - The inspector's header has **Edit…**. For a part, it opens the existing `ComponentInspector` popover. For an arrow, it opens the existing `ArrowEditor`. It also has ✕ to close.
   - Clicking another item switches the inspector, and clicking empty canvas closes it.
   - **Esc** closes it; if Focus is on, Esc leaves Focus first.
   - A single click no longer opens `ComponentInspector` directly. A **double-click** on a part opens it, as a double-click opens an arrow's editor.
   - Shift-click still extends the selection, and the inspector shows the last clicked item.
3. **Focus.**
   - The ◎ Focus chip is enabled while something is pinned. Turning it on hides everything outside `BoardFocus.visible(...)` for the pinned item: parts and arrows are simply not drawn, not dimmed.
   - Turning it off, Esc, or unpinning restores everything. Focus isn't saved.
4. **Constraints:**
   - No view body writes model state. Hover and pin state live in `@State`, in the canvas.
   - The card never covers the pointer's item: offset it by 14 pt.
   - Nothing here changes the map file.

Build after each item, and keep the full suite green.
- [ ] **Commit:** `feat(board): hover cards, a docked inspector, Focus, and click to pin`

---

## Hand checks (the running app, on `~/Projects/rars-mcp/system-map.json`)

- **Lines:** no bus draws dashed; only control and conditional lines do.
- **The ALU:** the two left inputs land on separate points, their pills don't overlap, and no stacked width numbers appear near Instruction Memory.
- **Hover:** hovering a bus shows *From → To · label · 32-bit bus* after a beat. Hovering Register File shows the IN and OUT rows.
- **The inspector:** click Register File and it docks at the right. Edit… opens the edit popover, a double-click also opens it, and Esc closes the inspector.
- **Lenses:** Data fades the gold control lines, Control fades the buses, and the lens survives closing and reopening the Board.
- **Focus:** pin the ALU and turn on Focus. Only the ALU, its neighbours and their arrows remain.

# Board Palettes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the AI-agents and computer-architecture palettes (22 kinds, each with its own shape),
arrow styles (conditional, control, and bus with a bit width), and 22 AI brand logos to the Board.

**Architecture:** `ComponentKind` gains the kinds and their groups. `BoardComponent.uses` becomes
`[String: BoardArrow]` (label, style, bits); the file keeps plain arrows as strings. `BoardEdit`, the
model and the MCP tool learn `style`/`bits` and the default rule. `BoardTech` gains lobe-icons AI
logos. The app draws the new shapes, the arrow styles and a style picker.

**Tech Stack:** Swift 6, macOS 14, SwiftUI/AppKit, XCTest. No new dependencies. The logos are
lobe-icons SVG data (MIT), embedded as text.

**Spec:** `docs/superpowers/specs/2026-09-24-board-palettes-design.md`

**Mockup (the look to match):** `.superpowers/brainstorm/42945-1790255802/content/palettes.html`. Its
generator, with the exact shape geometry in `ai()` and `hw()`, is
`/private/tmp/claude-501/-Users-jacobdang-Projects-linkC/7a21e37b-5c7b-428e-aaa2-ed81d1d7512a/scratchpad/si/gen_palettes.py`.

## Global Constraints

- Swift 6 / macOS 14 deployment target. **No new packages or dependencies.** Logo SVG data is
  vendored as generated Swift source.
- TDD for everything in LinkCKit: each test is seen failing on an assertion before implementing. The
  app target has no UI harness: build it, read your change carefully, and list the hand checks.
- **Fail loud:** no `try?` on decoding; no silent fallbacks. A bad style or bits value is refused with
  a reason.
- **The file stays diff-friendly:** a plain arrow is still written as a string, and existing files
  must round-trip byte-identical.
- **Power:** no per-frame work. Styles are drawing data only.
- No view body writes observable state. No debug prints, commented-out code or scratch files. Delete
  what becomes dead.
- **Commits:**
  - One-line `feat(board): …` / `fix(board): …` messages.
  - Stage by name; never `git add -A`.
  - Never touch the untracked `system-map.json`.
  - No "claude" in any case in messages.
  - No trailers of any kind.
- **Verify every task:**
  - `swift build 2>&1 | tail -3` is clean;
  - `swift build 2>&1 | grep -i warning` prints nothing;
  - `swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1` shows 0 failures. The baseline is
    1323 tests, 5 skipped, 0 failures.

---

### Task 1: Kinds, `BoardArrow`, and the file

**Files:**
- Modify:
  - `Sources/LinkCKit/Board/ComponentKind.swift`: the 22 kinds and the groups.
  - `Sources/LinkCKit/Board/BoardMap.swift`: `BoardArrow`, `BoardArrowStyle`, `uses`, decode and encode.
  - `BoardMerge.swift`, `BoardReport.swift`, `BoardEdit.swift`, `BoardModel.swift`, `BoardLayout.swift`,
    `BoardRouter.swift`: compile against the new type. Add no new behaviour here, except the report's
    style text.
  - `Sources/linkc/Board/BoardCanvas.swift` and `BoardTools.swift`: `.label` where a `String` is needed,
    just enough to build.
- Test: `ComponentKindTests` (new), `BoardMapTests`, `BoardMergeTests`, `BoardReportTests`.

**Interfaces:**

```swift
public enum BoardArrowStyle: String, Sendable, CaseIterable { case plain, conditional, control, bus }

public struct BoardArrow: Equatable, Sendable, ExpressibleByStringLiteral {
    public var label: String
    public var style: BoardArrowStyle
    public var bits: Int?          // only with .bus, 1...4096
    public init(label: String = "", style: BoardArrowStyle = .plain, bits: Int? = nil)
    public init(stringLiteral value: String)   // a plain arrow
}

// BoardComponent
public var uses: [String: BoardArrow]

// ComponentKind
public static let agent, model, tool, mcp, router, start, end, vectorStore, memory, prompt, state, human: ComponentKind
public static let alu, mux, demux, register, ram, control, adder, decoder, clock, bus: ComponentKind
public struct Group: Sendable { public let title: String; public let kinds: [ComponentKind] }
public static let groups: [Group]   // "System", "AI agents", "Hardware", in that order
// `known` stays the flat union, in group order.
```

The raw values are exactly the spec's ids: `vector-store` for `vectorStore`, the rest as named.

**File rules:**
- **Decoding:** a `uses` value is either a string (a plain arrow with that label), or an object with
  keys `label`? (string), `style`? (string, one of the four) and `bits`? (integer).
- **Refused:**
  - an unknown key in the object, a wrong type, or an unknown style;
  - `bits` without `style: "bus"`;
  - `bits` outside 1…4096.

  The message names the component and the target.
- **Encoding:** a `.plain` arrow is written as its label string. Any other style is written as an
  object with sorted keys: `bits` (bus only), `label` (only when non-empty), and `style`.
- **The report** appends ` (conditional)`, ` (control)` or ` (bus, 32-bit)` after an arrow's label
  text.

- [ ] **Step 1: Write the failing tests.**

```swift
// Tests/LinkCKitTests/ComponentKindTests.swift
import XCTest
@testable import LinkCKit

final class ComponentKindTests: XCTestCase {
    func testTheGroupsCoverEveryKnownKindOnce() {
        let grouped = ComponentKind.groups.flatMap(\.kinds)
        XCTAssertEqual(grouped.count, Set(grouped).count)
        XCTAssertEqual(Set(grouped), Set(ComponentKind.known))
        XCTAssertEqual(ComponentKind.groups.map(\.title), ["System", "AI agents", "Hardware"])
        XCTAssertEqual(ComponentKind.groups.map(\.kinds.count), [7, 12, 10])
    }

    func testNewKindsAreKnownAndKeepTheirIDs() {
        XCTAssertTrue(ComponentKind("vector-store").isKnown)
        XCTAssertEqual(ComponentKind.vectorStore.raw, "vector-store")
        XCTAssertTrue(ComponentKind("alu").isKnown)
        XCTAssertFalse(ComponentKind("flux-capacitor").isKnown)
    }
}

// BoardMapTests
func testPlainArrowsStayStringsAndStyledOnesRoundTrip() throws {
    let source = Data(#"{"version":2,"places":{"Not placed":{"a":{"kind":"router","uses":{"b":{"label":"done","style":"conditional"},"c":"reads","d":{"style":"bus","bits":32}}},"b":{"kind":"end"},"c":{"kind":"tool"},"d":{"kind":"alu"}}}}"#.utf8)
    let map = try BoardMap.decode(source)
    let a = try XCTUnwrap(map.components.first { $0.name == "a" })
    XCTAssertEqual(a.uses["b"], BoardArrow(label: "done", style: .conditional))
    XCTAssertEqual(a.uses["c"], "reads")
    XCTAssertEqual(a.uses["d"], BoardArrow(style: .bus, bits: 32))
    let text = String(decoding: try map.encoded(), as: UTF8.self)
    XCTAssertTrue(text.contains(#""c": "reads""#), "plain stays a string")
    XCTAssertTrue(text.contains(#""style": "conditional""#))
    XCTAssertTrue(text.contains(#""bits": 32"#))
    XCTAssertEqual(try BoardMap.decode(try map.encoded()), map)
}

func testBadArrowStylesAreRefused() {
    for bad in [#"{"style":"wavy"}"#, #"{"bits":8}"#, #"{"style":"bus","bits":0}"#, #"{"style":"bus","bits":5000}"#, #"{"label":3}"#, #"{"colour":"red"}"#] {
        let json = #"{"version":2,"places":{"Not placed":{"a":{"kind":"service","uses":{"b":"# + bad + #"}},"b":{"kind":"service"}}}}"#
        XCTAssertThrowsError(try BoardMap.decode(Data(json.utf8)), bad)
    }
}

func testExistingFilesRoundTripByteIdentical() throws {
    let once = try BoardMap.decode(Data(#"{"version":2,"places":{"Not placed":{"a":{"kind":"service","uses":{"b":"x"}},"b":{"kind":"service"}}}}"#.utf8)).encoded()
    XCTAssertEqual(try BoardMap.decode(once).encoded(), once)
}

// BoardMergeTests
func testAnArrowsStyleMergesAsOneValue() {
    let base = map([BoardComponent(name: "r", kind: .router, uses: ["x": "go"]), BoardComponent(name: "x", kind: .end)])
    var mine = base; mine.components[0].uses["x"] = BoardArrow(label: "go", style: .conditional)
    XCTAssertEqual(BoardMerge.merge(base: base, mine: mine, theirs: base).components[0].uses["x"]?.style, .conditional)
}

// BoardReportTests
func testTheReportNamesArrowStyles() {
    var m = BoardMap()
    m.components = [BoardComponent(name: "cpu", kind: .register, uses: ["alu": BoardArrow(style: .bus, bits: 32)]), BoardComponent(name: "alu", kind: .alu)]
    XCTAssertTrue(BoardReport.markdown(for: m).contains("bus, 32-bit"))
}
```

  Adapt the helper names to each file's real ones, and keep the assertions.

- [ ] **Step 2: Run them and watch them fail.** Add stubs first: the types, unused.

- [ ] **Step 3: Implement.** Change `uses`, and follow the compiler to every site. Where a site needs
  the label, read `.label`. The router and labels read labels only.

- [ ] **Step 4: Run it and see it pass.** Run the full suite too. Thanks to `ExpressibleByStringLiteral`,
  existing tests that write `uses: ["b": "x"]` compile unchanged. Fix only the ones that read a label
  as a `String`, and list them in the report.

- [ ] **Step 5: Commit:** `feat(board): new kinds in three groups, and arrows that carry a style`

---

### Task 2: Styles for agents and the Board, and the default rule

**Files:**
- Modify:
  - `Sources/LinkCKit/Board/BoardEdit.swift`: `connect` takes `style`/`bits`; the default rule.
  - `Sources/LinkCKit/Board/BoardModel.swift`: `addArrow` applies the default rule; `setArrowStyle`.
  - `Sources/LinkCKit/MCP/MCPServer.swift`: the `steps` description.
- Test: `BoardEditTests`, `BoardModelTests`, `MCPServerBoardTests`

**Rules:**
- **The default rule:** one static helper,
  `BoardArrowStyle.default(from source: ComponentKind) -> BoardArrowStyle`, returns `.conditional`
  for `.router`, `.control` for `.control`, and `.plain` for anything else.
- **`BoardEdit` `connect`:**
  - It accepts `"style"` (one of the four raw values) and `"bits"` (integer; only with bus; 1…4096).
  - With no style given: a *new* arrow takes the default rule, and an *existing* arrow keeps its
    style. With a style given, that style is set.
  - Connecting an existing arrow again replaces its label when `label` is given, and its style/bits
    when `style` is given.
  - The summary line appends the style when not plain: `r → end "done" (conditional)`,
    `regs → alu (bus, 32-bit)`.
- **`BoardModel`:**
  - `addArrow(from:to:)` creates the arrow with the default rule.
  - New: `public func setArrowStyle(_ arrow: ArrowKey, to style: BoardArrowStyle, bits: Int?)`. It is
    one edit, refuses bits outside 1…4096 or bits on a non-bus style, and is a no-op when unchanged.
- **MCP:**
  - The description's `connect` line becomes
    `connect: {"connect": from, "to": to, "label"?, "style"?: plain|conditional|control|bus, "bits"?: 1-4096 (bus only)}`.
  - Add the line: `A new arrow from a router defaults to conditional, from a control unit to control.`
  - `linkc_get_board` already shows the object form through `architectureJSON()`.

- [ ] **Step 1: Write the failing tests.**

```swift
// BoardEditTests
func testConnectCarriesAStyleAndBits() throws {
    let base = try apply([["add": "regs", "kind": "register"], ["add": "alu", "kind": "alu"]], to: .empty).map
    let result = try apply([["connect": "regs", "to": "alu", "style": "bus", "bits": 32]], to: base)
    XCTAssertEqual(result.map.components.first { $0.name == "regs" }?.uses["alu"], BoardArrow(style: .bus, bits: 32))
    XCTAssertEqual(result.lines, ["regs → alu (bus, 32-bit)"])
}

func testArrowsFromARouterOrAControlUnitDefaultToTheirStyle() throws {
    let base = try apply([["add": "route", "kind": "router"], ["add": "done", "kind": "end"], ["add": "cu", "kind": "control"], ["add": "mux", "kind": "mux"]], to: .empty).map
    var result = try apply([["connect": "route", "to": "done", "label": "done"], ["connect": "cu", "to": "mux", "label": "ALUSrc"]], to: base)
    XCTAssertEqual(result.map.components.first { $0.name == "route" }?.uses["done"]?.style, .conditional)
    XCTAssertEqual(result.map.components.first { $0.name == "cu" }?.uses["mux"]?.style, .control)
    result = try apply([["connect": "route", "to": "done", "style": "plain"]], to: result.map)
    XCTAssertEqual(result.map.components.first { $0.name == "route" }?.uses["done"], BoardArrow(label: "done"), "an explicit style wins, the label stays")
}

func testBadStylesAreRefusedWithTheStep() throws {
    let base = try apply([["add": "a"], ["add": "b"]], to: .empty).map
    XCTAssertEqual(refusal([["connect": "a", "to": "b", "style": "wavy"]], on: base)?.step, 1)
    XCTAssertNotNil(refusal([["connect": "a", "to": "b", "bits": 8]], on: base), "bits need bus")
    XCTAssertNotNil(refusal([["connect": "a", "to": "b", "style": "bus", "bits": 0]], on: base))
}

func testRenameAndRemoveCarryStyledArrows() throws {
    var m = try apply([["add": "r", "kind": "router"], ["add": "x", "kind": "end"], ["connect": "r", "to": "x", "label": "done"]], to: .empty).map
    m = try apply([["update": "x", "rename": "finish"]], to: m).map
    XCTAssertEqual(m.components.first { $0.name == "r" }?.uses["finish"]?.style, .conditional)
    m = try apply([["remove": "finish"]], to: m).map
    XCTAssertEqual(m.components.first { $0.name == "r" }?.uses, [:])
}

// BoardModelTests
func testAddArrowAppliesTheDefaultRuleAndSetArrowStyleIsOneUndoStep() throws {
    let board = fresh()
    let r = try XCTUnwrap(board.addComponent(kind: .router, at: BoardPoint(x: 0, y: 0)))
    let e = try XCTUnwrap(board.addComponent(kind: .end, at: BoardPoint(x: 480, y: 0)))
    XCTAssertTrue(board.addArrow(from: r, to: e))
    XCTAssertEqual(board.map.components.first { $0.name == r }?.uses[e]?.style, .conditional)
    board.setArrowStyle(ArrowKey(from: r, to: e), to: .bus, bits: 64)
    XCTAssertEqual(board.map.components.first { $0.name == r }?.uses[e], BoardArrow(style: .bus, bits: 64))
    board.undo()
    XCTAssertEqual(board.map.components.first { $0.name == r }?.uses[e]?.style, .conditional)
}

// MCPServerBoardTests
func testTheEditToolDescribesStyles() throws {
    // Read the tools/list description the same way the existing description test does.
    // Assert it contains "conditional", "bus" and "defaults to conditional".
}
```

  The MCP test body follows the existing description test in `MCPServerBoardTests`; copy its way of
  reading the `steps` description.

- [ ] **Step 2: Run them and watch them fail.**

- [ ] **Step 3: Implement.**

- [ ] **Step 4: Run it and see it pass.** Run the full suite too.

- [ ] **Step 5: Commit:** `feat(board): agents and the Board set arrow styles; routers and control units default theirs`

---

### Task 3: The AI brand logos

**Files:**
- Modify:
  - `Sources/LinkCKit/Board/BoardTech.swift`: the 22 ids, aliases and display names from spec §3.
  - `Sources/LinkCKit/Board/BoardTechLogos.swift`: regenerated to include them.
  - `Sources/LinkCKit/MCP/MCPServer.swift`: the known-ids list already reads `BoardTech.knownIDs`, so check it.
- Test: `BoardTechTests`

**Generating:**
- In the session scratchpad, `npm pack @lobehub/icons-static-svg@1.95.1`.
- For each id, use `icons/<id>-color.svg` when it exists, else `icons/<id>.svg`.
- Unlike Simple Icons, these files can have several `<path>` elements, `fill="currentColor"`, masks,
  gradients or `<defs>`. Keep each file whole:
  - rewrite every path's `d` with the arc normaliser from `docs/superpowers/plans/2026-09-24-board-diagram-engine.md`, Task 2;
  - set `width="24" height="24"`;
  - remove `style`, `class` and `<title>`.
- For monochrome files that use `currentColor`, mark `isDark = true` (the app tints them).
- Add the lobe source and MIT notice to the generated file's header, beside the Simple Icons note, and
  describe the generator for both sources.
- The generator stays in the scratchpad; commit only the output.

- [ ] **Step 1: Write the failing tests.**

```swift
func testTheAIBrandsLoad() throws {
    for id in ["openai", "anthropic", "gemini", "mistral", "meta", "deepseek", "ollama", "huggingface", "langchain", "langgraph",
               "llamaindex", "crewai", "groq", "perplexity", "cohere", "qwen", "xai", "mcp", "openrouter", "vertexai", "bedrock", "azure"] {
        let info = try XCTUnwrap(BoardTech.info(id), id)
        let image = try XCTUnwrap(NSImage(data: Data(info.svg.utf8)), id)
        XCTAssertTrue(image.isValid, id)
        XCTAssertEqual(image.size, NSSize(width: 24, height: 24), id)
    }
    XCTAssertEqual(BoardTech.knownIDs.count, 69)
    XCTAssertEqual(BoardTech.canonical("gpt"), "openai")
    XCTAssertEqual(BoardTech.canonical("grok"), "xai")
    XCTAssertEqual(BoardTech.canonical("llama"), "meta")
}
```

  Also update `testEveryKnownLogoLoadsAsA24PointSVG`'s count from 47 to 69, and name that change.
  Run `CORESVG_VERBOSE=1` on the tests; it must print no CoreSVG warnings.

- [ ] **Steps 2–5:** red, implement, green, then commit: `feat(board): AI brand logos for models, frameworks and MCP`

---

### Task 4: The new shapes and the grouped menu

**Files:**
- Modify:
  - `Sources/linkc/Board/BoardElements.swift`: 22 shapes, their insets, and sub-lines.
  - `Sources/linkc/Board/BoardTools.swift`: the grouped Component menu.
  - `Sources/linkc/Theme.swift`: only the tokens the mockup's colours need that don't exist yet
    (gold, violet, green, the hardware stroke).

**Build the shapes** exactly as the mockup's `ai()` and `hw()` functions draw them, in the 176 × 84
footprint:
- per spec §1's table;
- with per-kind insets measured on the rendered outline at the arrow's height, as the diagram-engine
  fix did;
- the running dot, handles and glow on the outline;
- the sub-line rule from spec §1, with the name centred for the kinds marked —.

The planned, selected and missing states follow the existing shapes' treatment on each outline.

**Verify** by rendering every new shape to a PNG with `ImageRenderer`, in the session scratchpad.
Look at them against the mockup, then delete the files.

**The menu:** the Component menu shows three sections, titled from `ComponentKind.groups`, each
listing its kinds with a glyph. The last-used kind is remembered, as now.

- [ ] **Step 1: Build.** Then run the build, the warnings check and the full suite.

- [ ] **Step 2: Report** the render check and the hand checks.

- [ ] **Step 3: Commit:** `feat(board): shapes for the AI-agent and hardware kinds, and a grouped component menu`

---

### Task 5: How styled arrows look, and the style picker

**Files:**
- Modify: `Sources/linkc/Board/BoardCanvas.swift` (drawing), the arrow label editor in
  `BoardTools.swift`/`BoardCanvas.swift`, and `Sources/linkc/Theme.swift` (`boardConditional`, and the
  bus colour, if missing).

**Drawing**, per spec §2:
- **Conditional and control:** dashed 5/4 in `Theme.boardConditional`, with a gold arrowhead and gold
  pill text.
- **Bus:**
  - drawn 2.6 pt thick in the bus colour;
  - the slash mark (a 14 pt line at 45°) and the bit width, in 9 pt bold, about 30 pt along the first
    segment, never inside a box;
  - no pill without a label.
- **Focus and hover** override the colours with the accent, as today.

**The style picker:**
- The arrow label editor (double-click an arrow) gains a compact segmented picker: plain,
  conditional, control, bus. With bus selected, it also shows a bits field (a stepper or a number
  field, 1…4096, default 32).
- Committing calls `board.setArrowStyle`, alongside the existing `setArrowLabel`. Each change is one
  undo step.

- [ ] **Step 1: Build.** Then run the build, the warnings check and the full suite.

- [ ] **Step 2: Hand checks** (list them in the report):
  - a router's arrows come out dashed gold;
  - the bus slash and width;
  - the picker, and its undo;
  - an agent building the mockup's LangGraph example and datapath example with `linkc_edit_board`.

- [ ] **Step 3: Commit:** `feat(board): conditional, control and bus arrows, and a style picker`

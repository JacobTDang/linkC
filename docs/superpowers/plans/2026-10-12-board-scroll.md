# Board Scrolling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Arrow keys pan the Board, and a horizontal scroll bar slides it sideways.

**Architecture:** Pure rules in LinkCKit (key map, arrow pan on `BoardViewport`, `BoardScrollbar` geometry) with unit tests; the app target reads the arrow key codes, performs the pan, and draws a small SwiftUI scroll bar at the canvas's bottom edge.

**Tech Stack:** Swift 6, SwiftUI + AppKit, macOS 14, XCTest (`swift test`).

## Global Constraints
- Spec: `docs/superpowers/specs/2026-10-12-board-scroll-design.md`.
- Arrow step 48 screen points; ⇧ page 0.8 of the visible width/height; scroll bar margin 48 screen points.
- ⌘↑ stays `.goUp`; arrows with ⌘/⌃/⌥ are not the Board's; arrows belong to a text field while one is being edited.
- No side effects in SwiftUI view bodies. Fail loud (no swallowed errors or silent fallbacks). Swift 6 strict concurrency; `swift build --build-tests` with 0 warnings. No new dependencies.
- Commits: no trailers of any kind; never mention Claude, Anthropic or AI; `./scripts/check-commits.sh origin/main..HEAD` clean.

---

### Task 1: Arrow pans and scroll bar geometry (LinkCKit)

**Files:**
- Modify: `Sources/LinkCKit/Board/BoardKeys.swift`
- Modify: `Sources/LinkCKit/Board/BoardViewport.swift`
- Create: `Sources/LinkCKit/Board/BoardScrollbar.swift`
- Test: `Tests/LinkCKitTests/BoardKeysTests.swift`, `Tests/LinkCKitTests/BoardViewportTests.swift`, create `Tests/LinkCKitTests/BoardScrollbarTests.swift`

**Interfaces:**
- Produces: `KeyPress.Key.down/.left/.right`; `public struct BoardPan: Equatable, Sendable { enum Direction { left, right, up, down }; let direction; let page: Bool; init(_ direction:, page: Bool = false) }`; `BoardCommand.pan(BoardPan)`; `BoardViewport.arrowStep = 48`, `BoardViewport.arrowPage = 0.8`, `BoardViewport.panned(_ pan: BoardPan, width: Double, height: Double) -> BoardViewport`; `BoardScrollbar` with `minX`, `span`, `thumbStart`, `thumbLength`, `static func horizontal(viewport:content:width:margin: = 48) -> BoardScrollbar?`, `func originX(thumbStart: Double) -> Double`, `func originX(centredOn: Double) -> Double`.

- [ ] **Step 1: Write the failing key-map tests** (append to `BoardKeysTests`)

```swift
    func testArrowsPanAStepAndShiftArrowsAPage() {
        let arrows: [(KeyPress.Key, BoardPan.Direction)] = [(.left, .left), (.right, .right), (.up, .up), (.down, .down)]
        for (key, direction) in arrows {
            XCTAssertEqual(BoardKeyMap.command(for: KeyPress(key), isEditingText: false), .pan(BoardPan(direction)), "\(key)")
            XCTAssertEqual(BoardKeyMap.command(for: KeyPress(key, shift: true), isEditingText: false),
                           .pan(BoardPan(direction, page: true)), "⇧\(key)")
        }
    }

    func testCommandUpStillGoesUpAndOtherModifiedArrowsAreNotTheBoards() {
        XCTAssertEqual(BoardKeyMap.command(for: KeyPress(.up, command: true), isEditingText: false), .goUp)
        for key in [KeyPress.Key.left, .right, .up, .down] {
            XCTAssertNil(BoardKeyMap.command(for: KeyPress(key, control: true), isEditingText: false), "⌃\(key)")
            XCTAssertNil(BoardKeyMap.command(for: KeyPress(key, option: true), isEditingText: false), "⌥\(key)")
        }
        for key in [KeyPress.Key.left, .right, .down] {
            XCTAssertNil(BoardKeyMap.command(for: KeyPress(key, command: true), isEditingText: false), "⌘\(key)")
        }
    }

    func testArrowsBelongToAFieldBeingEdited() {
        for key in [KeyPress.Key.left, .right, .up, .down] {
            XCTAssertNil(BoardKeyMap.command(for: KeyPress(key), isEditingText: true), "\(key)")
        }
    }
```

- [ ] **Step 2: Write the failing viewport tests** (append to `BoardViewportTests`)

```swift
    /// → shows what is further right: the origin moves right by the step in canvas points.
    func testArrowPansAStepInEachDirectionAtAnyZoom() {
        let viewport = BoardViewport(originX: 100, originY: 50, zoom: 2)
        let step = BoardViewport.arrowStep / 2
        XCTAssertEqual(viewport.panned(BoardPan(.right), width: 800, height: 400).originX, 100 + step)
        XCTAssertEqual(viewport.panned(BoardPan(.left), width: 800, height: 400).originX, 100 - step)
        XCTAssertEqual(viewport.panned(BoardPan(.down), width: 800, height: 400).originY, 50 + step)
        XCTAssertEqual(viewport.panned(BoardPan(.up), width: 800, height: 400).originY, 50 - step)
        XCTAssertEqual(viewport.panned(BoardPan(.right), width: 800, height: 400).originY, 50, "a sideways pan keeps the height")
    }

    /// ⇧ pans by most of the visible width (← →) or height (↑ ↓).
    func testShiftArrowPansAPage() {
        let viewport = BoardViewport(originX: 0, originY: 0, zoom: 2)
        XCTAssertEqual(viewport.panned(BoardPan(.right, page: true), width: 800, height: 400).originX, 0.8 * 800 / 2, accuracy: 0.001)
        XCTAssertEqual(viewport.panned(BoardPan(.up, page: true), width: 800, height: 400).originY, -0.8 * 400 / 2, accuracy: 0.001)
    }
```

- [ ] **Step 3: Write the failing scroll bar tests** (`Tests/LinkCKitTests/BoardScrollbarTests.swift`)

```swift
import XCTest
@testable import LinkCKit

final class BoardScrollbarTests: XCTestCase {
    private let content = BoardRect(x: 0, y: 0, w: 2000, h: 300)

    func testNoContentOrContentThatFitsHasNoBar() {
        let viewport = BoardViewport(originX: -100, originY: 0, zoom: 1)
        XCTAssertNil(BoardScrollbar.horizontal(viewport: viewport, content: nil, width: 800))
        let small = BoardRect(x: 0, y: 0, w: 500, h: 100)
        XCTAssertNil(BoardScrollbar.horizontal(viewport: viewport, content: small, width: 800, margin: 48),
                     "the view (-100…700) already covers the content with its margin (-48…548)")
    }

    /// The track spans the content plus the margin; the thumb is the visible part.
    func testThumbIsTheVisiblePartOfTheContentSpan() throws {
        let viewport = BoardViewport(originX: 452, originY: 0, zoom: 1)
        let bar = try XCTUnwrap(BoardScrollbar.horizontal(viewport: viewport, content: content, width: 800, margin: 48))
        XCTAssertEqual(bar.minX, -48)
        XCTAssertEqual(bar.span, 2096)
        XCTAssertEqual(bar.thumbStart, 500.0 / 2096, accuracy: 1e-9)
        XCTAssertEqual(bar.thumbLength, 800.0 / 2096, accuracy: 1e-9)
    }

    /// The margin is screen points: at zoom 2 it is 24 canvas points; the visible width halves too.
    func testZoomChangesTheMarginAndTheThumb() throws {
        let viewport = BoardViewport(originX: 0, originY: 0, zoom: 2)
        let bar = try XCTUnwrap(BoardScrollbar.horizontal(viewport: viewport, content: content, width: 800, margin: 48))
        XCTAssertEqual(bar.minX, -24)
        XCTAssertEqual(bar.span, 2048)
        XCTAssertEqual(bar.thumbLength, 400.0 / 2048, accuracy: 1e-9)
    }

    /// A view panned past the content stretches the track to include it, so the thumb is always on the track.
    func testAViewBeyondTheContentStretchesTheTrack() throws {
        let viewport = BoardViewport(originX: 3000, originY: 0, zoom: 1)
        let bar = try XCTUnwrap(BoardScrollbar.horizontal(viewport: viewport, content: content, width: 800, margin: 48))
        XCTAssertEqual(bar.minX, -48)
        XCTAssertEqual(bar.span, 3848)
        XCTAssertEqual(bar.thumbStart + bar.thumbLength, 1, accuracy: 1e-9)
    }

    func testThumbStartMapsBackToTheOriginAndStaysOnTheTrack() throws {
        let viewport = BoardViewport(originX: 452, originY: 0, zoom: 1)
        let bar = try XCTUnwrap(BoardScrollbar.horizontal(viewport: viewport, content: content, width: 800, margin: 48))
        XCTAssertEqual(bar.originX(thumbStart: bar.thumbStart), 452, accuracy: 1e-9)
        XCTAssertEqual(bar.originX(thumbStart: -0.5), -48, accuracy: 1e-9, "dragged past the left end")
        XCTAssertEqual(bar.originX(thumbStart: 2), -48 + 2096 - 800, accuracy: 1e-9, "dragged past the right end")
    }

    func testCentringOnATrackSpot() throws {
        let viewport = BoardViewport(originX: -48, originY: 0, zoom: 1)
        let bar = try XCTUnwrap(BoardScrollbar.horizontal(viewport: viewport, content: content, width: 800, margin: 48))
        XCTAssertEqual(bar.originX(centredOn: 0.5), -48 + 1048 - 400, accuracy: 1e-9)
        XCTAssertEqual(bar.originX(centredOn: 0), -48, accuracy: 1e-9, "kept on the track")
    }
}
```

- [ ] **Step 4: Run the tests to see them fail**

Run: `swift test --filter 'BoardKeysTests|BoardViewportTests|BoardScrollbarTests'`
Expected: compile errors (`BoardPan`, `.left`, `panned(_:width:height:)`, `BoardScrollbar` don't exist).

- [ ] **Step 5: Implement**

`BoardKeys.swift`: add `case down, left, right` after `case up`. Add after `BoardCommand`:

```swift
/// An arrow key's pan: which way the view moves, and whether by a page (⇧) or a step.
public struct BoardPan: Equatable, Sendable {
    public enum Direction: Equatable, Sendable { case left, right, up, down }
    public let direction: Direction
    public let page: Bool

    public init(_ direction: Direction, page: Bool = false) {
        self.direction = direction
        self.page = page
    }
}
```

Add `case pan(BoardPan)` to `BoardCommand`. In `BoardKeyMap.command(for:isEditingText:)`:

```swift
        case .up:
            if press.command, !press.control, !press.option, !press.shift {
                return .goUp
            }
            return pan(.up, press)
        case .down: return pan(.down, press)
        case .left: return pan(.left, press)
        case .right: return pan(.right, press)
```

and in `BoardKeyMap`:

```swift
    /// An arrow pans; ⇧ makes it a page. With ⌘, ⌃ or ⌥ it is not the Board's.
    private static func pan(_ direction: BoardPan.Direction, _ press: KeyPress) -> BoardCommand? {
        guard !press.command, !press.control, !press.option else { return nil }
        return .pan(BoardPan(direction, page: press.shift))
    }
```

`BoardViewport.swift`, after `panned(byScreenDX:dy:)`:

```swift
    /// An arrow key's pan, in screen points.
    public static let arrowStep = 48.0
    /// A ⇧-arrow pan, as a share of the visible width or height.
    public static let arrowPage = 0.8

    /// The view moved the way an arrow points: → shows what is further right. A step is
    /// `arrowStep` screen points; a page is `arrowPage` of the canvas's `width` (← →) or `height` (↑ ↓).
    public func panned(_ pan: BoardPan, width: Double, height: Double) -> BoardViewport {
        let across = pan.direction == .left || pan.direction == .right
        let distance = pan.page ? Self.arrowPage * (across ? width : height) : Self.arrowStep
        switch pan.direction {
        case .left: return panned(byScreenDX: distance, dy: 0)
        case .right: return panned(byScreenDX: -distance, dy: 0)
        case .up: return panned(byScreenDX: 0, dy: distance)
        case .down: return panned(byScreenDX: 0, dy: -distance)
        }
    }
```

`BoardScrollbar.swift`:

```swift
import Foundation

/// The Board's horizontal scroll bar, as fractions of its track. The track spans the board's
/// content, `margin` screen points wider either side, joined with what is on screen — so it always
/// covers where the view is. The thumb is the visible part.
public struct BoardScrollbar: Equatable, Sendable {
    /// The canvas x at the track's left end, and the canvas width the track spans.
    public let minX: Double
    public let span: Double
    /// The thumb as fractions of the track.
    public let thumbStart: Double
    public let thumbLength: Double

    /// Nil when there is no content, or the view already shows all of it across.
    public static func horizontal(viewport: BoardViewport, content: BoardRect?, width: Double, margin: Double = 48) -> BoardScrollbar? {
        guard let content, width > 0 else { return nil }
        let visibleWidth = width / viewport.zoom
        let pad = margin / viewport.zoom
        let minX = min(viewport.originX, Double(content.x) - pad)
        let maxX = max(viewport.originX + visibleWidth, Double(content.x + content.w) + pad)
        let span = maxX - minX
        guard span - visibleWidth > 0.5 else { return nil }
        return BoardScrollbar(minX: minX, span: span,
                              thumbStart: (viewport.originX - minX) / span, thumbLength: visibleWidth / span)
    }

    /// The view's `originX` that puts the thumb's left end at `start` along the track, kept on it.
    public func originX(thumbStart start: Double) -> Double {
        minX + min(max(start, 0), 1 - thumbLength) * span
    }

    /// The view's `originX` that centres the view on `fraction` of the track, kept on it.
    public func originX(centredOn fraction: Double) -> Double {
        originX(thumbStart: fraction - thumbLength / 2)
    }
}
```

`BoardScrollbar` needs a memberwise init; the struct's synthesized one is internal, which the static func uses — fine.

- [ ] **Step 6: Run the tests to see them pass**

Run: `swift test --filter 'BoardKeysTests|BoardViewportTests|BoardScrollbarTests'`
Expected: all pass. Then `swift build --build-tests 2>&1 | grep -cE "warning:|error:"` → `0`. (Adding `BoardCommand.pan` makes the app's `perform(_:)` switch non-exhaustive — add a temporary `case .pan: break` there ONLY if the build needs it to compile, and say so; Task 2 replaces it.)

- [ ] **Step 7: Commit**

```bash
git add Sources/LinkCKit/Board Tests/LinkCKitTests Sources/linkc/Board/BoardCanvas.swift
git commit -m "feat(board): arrow keys pan the Board; horizontal scroll bar geometry"
```

---

### Task 2: Wire the arrows and draw the scroll bar (app target)

**Files:**
- Modify: `Sources/linkc/Board/BoardInput.swift` (`press(from:)`)
- Modify: `Sources/linkc/Board/BoardCanvas.swift` (`perform(_:)`, the canvas `ZStack` in `body`)
- Create: `Sources/linkc/Board/BoardScrollBar.swift`

**Interfaces:**
- Consumes: everything Task 1 produces; `board.contentBounds: BoardRect?`; the canvas's `@State size: CGSize` and `@State viewport: BoardViewport`.

- [ ] **Step 1: Read the arrow key codes.** In `BoardInput.press(from:)`, beside `case 126: key = .up`:

```swift
        case 125: key = .down
        case 123: key = .left
        case 124: key = .right
```

- [ ] **Step 2: Perform the pan.** In `BoardCanvas.perform(_:)` (replace any temporary `case .pan: break`):

```swift
        case .pan(let pan):
            viewport = viewport.panned(pan, width: Double(size.width), height: Double(size.height))
```

- [ ] **Step 3: The scroll bar view** (`Sources/linkc/Board/BoardScrollBar.swift`)

```swift
import LinkCKit
import SwiftUI

/// The Board's horizontal scroll bar along the canvas's bottom edge: a faint thumb that brightens
/// on hover and while dragging. Drag the thumb to slide sideways; click the track to centre the view
/// there and keep dragging from it. Hidden when the view already shows everything across.
struct BoardScrollBar: View {
    @Binding var viewport: BoardViewport
    let content: BoardRect?
    /// The canvas's width in screen points.
    let canvasWidth: CGFloat

    @State private var hovering = false
    /// The bar as it was when the drag began, its thumb's start then, and where the pointer began:
    /// the track keeps that span for the whole drag, so the thumb stays under the pointer.
    @State private var drag: Drag?

    private struct Drag {
        let bar: BoardScrollbar
        let thumbStart: Double
        let startX: CGFloat
    }

    private static let inset: CGFloat = 12
    private static let height: CGFloat = 10

    var body: some View {
        if let bar = BoardScrollbar.horizontal(viewport: viewport, content: content, width: Double(canvasWidth)) {
            GeometryReader { geometry in
                let track = geometry.size.width
                let active = hovering || drag != nil
                Capsule()
                    .fill(Theme.textPrimary.opacity(active ? 0.45 : 0.2))
                    .frame(width: max(24, track * bar.thumbLength), height: active ? 6 : 4)
                    .offset(x: track * bar.thumbStart)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .animation(Theme.hoverEase, value: active)
                    .contentShape(Rectangle())
                    .onHover { hovering = $0 }
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in dragged(value, bar: bar, track: track) }
                        .onEnded { _ in drag = nil })
            }
            .frame(height: Self.height)
            .padding(.horizontal, Self.inset)
            .padding(.bottom, 1)
        }
    }

    private func dragged(_ value: DragGesture.Value, bar: BoardScrollbar, track: CGFloat) {
        guard track > 0 else { return }
        if let drag {
            viewport.originX = drag.bar.originX(thumbStart: drag.thumbStart + Double((value.location.x - drag.startX) / track))
            return
        }
        let fraction = Double(value.startLocation.x / track)
        let onThumb = fraction >= bar.thumbStart && fraction <= bar.thumbStart + bar.thumbLength
        if !onThumb { viewport.originX = bar.originX(centredOn: fraction) }
        guard let now = BoardScrollbar.horizontal(viewport: viewport, content: content, width: Double(canvasWidth)) else { return }
        drag = Drag(bar: now, thumbStart: now.thumbStart, startX: value.startLocation.x)
    }
}
```

Note `viewport.originX` is a `var` on the struct, so the binding writes through. The thumb's minimum width (24 pt) keeps it grabbable; its fraction math stays on `bar.thumbLength`.

- [ ] **Step 4: Place it.** In `BoardCanvas.body`, inside the canvas `ZStack(alignment: .topLeading)` after `hoverCardOverlay`:

```swift
                    BoardScrollBar(viewport: $viewport, content: board.contentBounds, canvasWidth: size.width)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
```

It must not cover the toolbar (`BoardToolbar` keeps 12 pt below it; the bar is 10 pt + 1 pt). The `.frame(maxWidth:maxHeight:alignment:)` wrapper must not swallow canvas clicks above the bar: only the bar's own 10 pt strip may hit-test (the outer frame is layout only — check that a click on the canvas above the bar still selects/drags as before; if the full-size frame intercepts, apply `.allowsHitTesting` only to the strip or position the bar with `.position`/`VStack { Spacer(); bar }` whose `Spacer` doesn't hit-test).

- [ ] **Step 5: Verify**

Run: `swift build --build-tests 2>&1 | grep -cE "warning:|error:"` → `0`; full `swift test` passes.

Manual checks (the app target has no harness): arrows and ⇧-arrows pan; arrows type in a field instead; ⌘↑ goes up a level; the bar appears only when the content is wider than the view; dragging the thumb slides and stays on the track; clicking the track centres there and dragging continues; zooming resizes the thumb; the bar doesn't cover the toolbar; clicks and drags on the canvas above the bar behave as before.

- [ ] **Step 6: Commit**

```bash
git add Sources/linkc/Board
git commit -m "feat(board): pan with the arrow keys and slide sideways with a scroll bar"
```

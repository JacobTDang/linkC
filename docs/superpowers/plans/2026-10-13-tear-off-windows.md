# Tear-off Windows Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A terminal or a project's whole Split grid can be pulled out of the menu-bar panel into its own normal macOS window, and later brought back.

**Architecture:**
- **LinkCKit (pure, tested):**
  - the torn-off windows (`TornOff`) and the host rule (which window, if any, holds a terminal's single live view);
  - their persistence in `SidebarState`;
  - a coordinator method that opens a session without selecting it.
- **App target:**
  - `AppModel` operations;
  - panel views that show a note where a terminal lives elsewhere;
  - a `TornOffWindows` controller with one `NSWindow` per item, hosting the existing `TerminalContainer` / `SplitPane`;
  - an AppKit drag source on tab chips that reports a drag let go outside the panel.

**Tech Stack:** Swift 6, SwiftUI + AppKit, macOS 14, XCTest (`swift test`).

## Global Constraints
- Spec: `docs/superpowers/specs/2026-10-13-tear-off-windows-design.md` governs.
- **One live view per terminal.** Each session has exactly one live terminal view, moved between hosts, never duplicated. The host rule decides the host:
  1. a window showing that terminal alone;
  2. else a window showing an active split that holds it live;
  3. else the panel.
- **Window defaults.** Default window sizes: terminal 720 × 460, grid 960 × 600, clamped onto the screen under the drop point.
- **Activation.** linkC is `.regular` (Dock and ⌘-Tab) while at least one torn-off window is open. Otherwise it is `.accessory`.
- **Window input.** Clicking or typing in a torn-off window never changes the panel's selection.
- **Ending a window.** Closing a window or **Bring back** returns it to the panel. Nothing stops a session.
- **Code rules.**
  - No side effects in SwiftUI view bodies.
  - Fail loud: no swallowed errors or silent fallbacks.
  - Swift 6 strict concurrency.
  - `swift build --build-tests` with 0 warnings.
  - No new dependencies.
- **Commits.** No trailers of any kind. Never mention Claude, Anthropic or AI. `./scripts/check-commits.sh origin/main..HEAD` must be clean.
- **Never launch the built app.** The user's running linkC owns the hook server and restores sessions; a second instance would interfere. App-target behaviour is checked by build, the full suite, and reading.

---

### Task 1: TornOff model and host rule (LinkCKit)

**Files:**
- Create: `Sources/LinkCKit/Terminal/TornOff.swift`
- Test: create `Tests/LinkCKitTests/TornOffTests.swift`

**Interfaces:**
- Produces:
  - `public enum TornOffItem: Hashable, Codable, Sendable { case terminal(String); case split(String) }`
  - `public struct TornOffFrame: Equatable, Codable, Sendable { x, y, w, h: Double }`
  - `public struct TornOffWindow: Equatable, Codable, Sendable { item, frame }`
  - `public struct TornOff: Equatable, Sendable` with:
    - `windows: [TornOffWindow]`
    - `init(windows:)`
    - `isEmpty`
    - `contains(_:)`
    - `frame(of:)`
    - `adding(_:frame:)`
    - `removing(_:)`
    - `framing(_:to:)`
    - `host(of:splits:liveIDs:) -> TornOffItem?`
    - `pruned(liveTerminals:activeSplits:) -> (kept: TornOff, closed: [TornOffItem])`

- [ ] **Step 1: Write the failing tests** (`Tests/LinkCKitTests/TornOffTests.swift`)

```swift
import XCTest
@testable import LinkCKit

final class TornOffTests: XCTestCase {
    private let frame = TornOffFrame(x: 10, y: 20, w: 720, h: 460)

    func testAddingKeepsOrderAndNeverDuplicates() {
        let other = TornOffFrame(x: 0, y: 0, w: 1, h: 1)
        let torn = TornOff().adding(.terminal("A"), frame: frame).adding(.split("/p"), frame: frame)
            .adding(.terminal("A"), frame: other)
        XCTAssertEqual(torn.windows.map(\.item), [.terminal("A"), .split("/p")])
        XCTAssertEqual(torn.frame(of: .terminal("A")), frame, "an item already open keeps its frame")
    }

    func testRemovingAndFraming() {
        let moved = TornOffFrame(x: 5, y: 5, w: 800, h: 500)
        let torn = TornOff().adding(.terminal("A"), frame: frame).adding(.terminal("B"), frame: frame)
        XCTAssertEqual(torn.removing(.terminal("A")).windows.map(\.item), [.terminal("B")])
        XCTAssertEqual(torn.framing(.terminal("B"), to: moved).frame(of: .terminal("B")), moved)
        XCTAssertEqual(torn.framing(.terminal("Z"), to: moved), torn, "framing an item that isn't open changes nothing")
        XCTAssertTrue(TornOff().isEmpty)
    }

    /// A terminal window wins over a split window holding the same terminal; an inactive split holds
    /// nothing; anything else lives in the panel (nil).
    func testTheHostRule() {
        let splits = ["/p": ProjectSplit(members: ["A", "B", "C"]), "/q": ProjectSplit(members: ["X", "Y"])]
        let live: [String: Set<String>] = ["/p": ["A", "B", "C"], "/q": ["X"]]
        let torn = TornOff().adding(.split("/p"), frame: frame).adding(.terminal("B"), frame: frame)
            .adding(.split("/q"), frame: frame)
        let host = { (id: String) in torn.host(of: id, splits: splits) { live[$0] ?? [] } }
        XCTAssertEqual(host("A"), .split("/p"))
        XCTAssertEqual(host("B"), .terminal("B"), "its own window wins over the grid's")
        XCTAssertNil(host("X"), "a split with one live pane is not active: X stays in the panel")
        XCTAssertNil(host("Z"))
    }

    func testAMemberThatIsNotLiveHasNoGridHost() {
        let splits = ["/p": ProjectSplit(members: ["A", "B", "C"])]
        let torn = TornOff().adding(.split("/p"), frame: frame)
        XCTAssertNil(torn.host(of: "C", splits: splits) { _ in ["A", "B"] })
    }

    func testPruningClosesWhatIsGone() {
        let torn = TornOff().adding(.terminal("A"), frame: frame).adding(.terminal("GONE"), frame: frame)
            .adding(.split("/p"), frame: frame).adding(.split("/dead"), frame: frame)
        let result = torn.pruned(liveTerminals: ["A"], activeSplits: ["/p"])
        XCTAssertEqual(result.kept.windows.map(\.item), [.terminal("A"), .split("/p")])
        XCTAssertEqual(result.closed, [.terminal("GONE"), .split("/dead")])
    }

    func testItemsRoundTripThroughJSON() throws {
        let torn = TornOff().adding(.terminal("A"), frame: frame).adding(.split("/p q"), frame: frame)
        let data = try JSONEncoder().encode(torn.windows)
        XCTAssertEqual(try JSONDecoder().decode([TornOffWindow].self, from: data), torn.windows)
    }
}
```

- [ ] **Step 2: Run to see it fail**

Run: `swift test --filter TornOffTests`. It should fail with compile errors: `TornOff` etc. don't exist yet.

- [ ] **Step 3: Implement** (`Sources/LinkCKit/Terminal/TornOff.swift`)

```swift
import Foundation

/// What a torn-off window shows: one terminal (a session or shell terminal id), or a project's split
/// grid (by canonical project path).
public enum TornOffItem: Hashable, Codable, Sendable {
    case terminal(String)
    case split(String)
}

/// A window's frame in screen points (AppKit's bottom-left origin).
public struct TornOffFrame: Equatable, Codable, Sendable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }
}

public struct TornOffWindow: Equatable, Codable, Sendable {
    public let item: TornOffItem
    public var frame: TornOffFrame

    public init(item: TornOffItem, frame: TornOffFrame) {
        self.item = item
        self.frame = frame
    }
}

/// The torn-off windows, in the order they opened, and the host rule: each terminal has one live view,
/// held by its own window if it has one, else by a window showing an active split that holds it live,
/// else by the panel.
public struct TornOff: Equatable, Sendable {
    public private(set) var windows: [TornOffWindow]

    public init(windows: [TornOffWindow] = []) {
        self.windows = windows
    }

    public var isEmpty: Bool { windows.isEmpty }

    public func contains(_ item: TornOffItem) -> Bool {
        windows.contains { $0.item == item }
    }

    public func frame(of item: TornOffItem) -> TornOffFrame? {
        windows.first { $0.item == item }?.frame
    }

    /// `item` opened at `frame`. One already open stays as it is.
    public func adding(_ item: TornOffItem, frame: TornOffFrame) -> TornOff {
        guard !contains(item) else { return self }
        return TornOff(windows: windows + [TornOffWindow(item: item, frame: frame)])
    }

    public func removing(_ item: TornOffItem) -> TornOff {
        TornOff(windows: windows.filter { $0.item != item })
    }

    /// `item`'s window moved or resized to `frame`. An item that isn't open changes nothing.
    public func framing(_ item: TornOffItem, to frame: TornOffFrame) -> TornOff {
        TornOff(windows: windows.map { $0.item == item ? TornOffWindow(item: item, frame: frame) : $0 })
    }

    /// The window that holds terminal `id`'s live view, or nil for the panel. `splits` are the stored
    /// splits by canonical project path; `liveIDs` gives a project's live terminals.
    public func host(of id: String, splits: [String: ProjectSplit], liveIDs: (String) -> Set<String>) -> TornOffItem? {
        if contains(.terminal(id)) { return .terminal(id) }
        for window in windows {
            guard case .split(let project) = window.item, let split = splits[project],
                  split.members.contains(id) else { continue }
            let live = liveIDs(project)
            if live.contains(id), split.isActive(liveIDs: live) { return window.item }
        }
        return nil
    }

    /// What stays open: terminals still live, splits still active. `closed` is what went, in order.
    public func pruned(liveTerminals: Set<String>, activeSplits: Set<String>) -> (kept: TornOff, closed: [TornOffItem]) {
        var kept: [TornOffWindow] = []
        var closed: [TornOffItem] = []
        for window in windows {
            let stays: Bool
            switch window.item {
            case .terminal(let id): stays = liveTerminals.contains(id)
            case .split(let project): stays = activeSplits.contains(project)
            }
            if stays { kept.append(window) } else { closed.append(window.item) }
        }
        return (TornOff(windows: kept), closed)
    }
}
```

- [ ] **Step 4: Run to see it pass**

Run: `swift test --filter TornOffTests`. All should pass. Then `swift build --build-tests 2>&1 | grep -cE "warning:|error:"` should print `0`.

- [ ] **Step 5: Commit**

```bash
git add Sources/LinkCKit/Terminal/TornOff.swift Tests/LinkCKitTests/TornOffTests.swift
git commit -m "feat(windows): torn-off windows and the rule for which one holds a terminal"
```

---

### Task 2: Persist torn-off windows in SidebarState (LinkCKit)

**Files:**
- Modify: `Sources/LinkCKit/Preferences/SidebarState.swift`
- Test: `Tests/LinkCKitTests/SidebarStateTests.swift`

**Interfaces:**
- Consumes: Task 1's `TornOff`, `TornOffWindow`.
- Produces:
  - `public var tornOff: TornOff { get }`
  - `public func setTornOff(_ tornOff: TornOff)`, which saves only when it changes.

Follow the file's existing lenient pattern for `splits`, entry by entry, as closely as you can.
- `Stored` gains `var windows: StoredWindows?`.
- `StoredWindows` holds `entries: Result<[WindowEntry], Error>`, with `WindowEntry { let window: Result<TornOffWindow, Error> }`.
- Each unreadable entry is logged with `NSLog("[linkC] a stored torn-off window is unreadable — dropped: %@", …)`.
- A wrong-type `windows` field is logged and all of it is dropped.
- Any drop sets the `changed` flag, so the file is rewritten without it.
- `save()` writes `windows: tornOff.isEmpty ? nil : StoredWindows(tornOff.windows)`.

- [ ] **Step 1: Write the failing tests** (append to `SidebarStateTests`, using its existing helpers such as `defaults`, `storedObject()`)

```swift
    func testTornOffWindowsRoundTrip() {
        let frame = TornOffFrame(x: 1, y: 2, w: 720, h: 460)
        let state = SidebarState(defaults: defaults)
        state.setTornOff(TornOff().adding(.terminal("A"), frame: frame).adding(.split("/p"), frame: frame))
        XCTAssertEqual(SidebarState(defaults: defaults).tornOff.windows.map(\.item), [.terminal("A"), .split("/p")])
        XCTAssertEqual(SidebarState(defaults: defaults).tornOff.frame(of: .terminal("A")), frame)
    }

    func testAFileWithoutWindowsLoadsNone() {
        let json = #"{"projectOrder":["/a"],"expandOverrides":{},"openSections":[]}"#
        defaults.set(Data(json.utf8), forKey: SidebarState.key)
        XCTAssertTrue(SidebarState(defaults: defaults).tornOff.isEmpty)
    }

    /// One unreadable entry costs only itself, and the file is rewritten without it.
    func testAnUnreadableWindowEntryIsDroppedAndRewritten() throws {
        let good = #"{"item":{"terminal":{"_0":"A"}},"frame":{"x":1,"y":2,"w":3,"h":4}}"#
        let json = #"{"projectOrder":["/a"],"expandOverrides":{},"openSections":[],"windows":[\#(good),{"item":42}]}"#
        defaults.set(Data(json.utf8), forKey: SidebarState.key)
        let state = SidebarState(defaults: defaults)
        XCTAssertEqual(state.tornOff.windows.map(\.item), [.terminal("A")])
        XCTAssertEqual(state.projectOrder, ["/a"], "the rest of the state still loads")
        XCTAssertEqual((try storedObject()["windows"] as? [Any])?.count, 1, "the bad entry is rewritten out of the file")
    }
```

The `good` JSON must match Swift's synthesized `Codable` for `TornOffItem.terminal(String)`, which encodes as `{"terminal":{"_0":"A"}}`. If your test shows otherwise, build the fixture by encoding a real `TornOffWindow` with `JSONEncoder` instead of hand-writing it.

- [ ] **Step 2: Run to see it fail.** `swift test --filter SidebarStateTests`
- [ ] **Step 3: Implement** in `SidebarState.swift`, following the `splits` pattern as described above.
- [ ] **Step 4: Run to see it pass**, check 0 warnings, and revert-proof the drop/rewrite test. To revert-proof: remove the `changed` contribution, watch the test fail with an assertion, then restore it from a backup copy, not with `git checkout`.
- [ ] **Step 5: Commit** `feat(windows): keep torn-off windows across relaunch`

---

### Task 3: Open a session without selecting it (LinkCKit)

**Files:**
- Modify: `Sources/LinkCKit/App/AppCoordinator.swift` (`focusSession` ~964)
- Test: `Tests/LinkCKitTests/AppCoordinatorIntegrationTests.swift`

**Interfaces:**
- Produces: `public func acknowledgeSession(_ id: String)`, which opens the session the way clicking its tab does, without selecting it:
  - adopts the worker;
  - activates the app;
  - moves a non-Claude session from needs-you to ready.
- `focusSession(_:)` becomes `terminals.select(id); onSessionFocused?(id); acknowledgeSession(id)`, with identical behaviour.

- [ ] **Step 1: Failing test.** Mirror the existing adoption tests (~1270–1300) and the needs-you to ready test (~1030). Create a worker session and a non-Claude session in `.needsYou`, then call `acknowledgeSession` on each. Assert:
  - the worker is adopted, in both the store and the manifest;
  - the non-Claude session is `.ready`;
  - `terminals.selectedId` did not change;
  - `onSessionFocused` was not called.
- [ ] **Step 2: Run to see it fail.**
- [ ] **Step 3: Implement.** Extract the three side effects from `focusSession` into `acknowledgeSession`, then have `focusSession` call it.
- [ ] **Step 4: Run** the new test plus the existing `focusSession` / adoption / needs-you tests. Check 0 warnings.
- [ ] **Step 5: Commit** `refactor(coordinator): open a session without selecting it`

---

### Task 4: AppModel — torn-off state, host rule, and split operations by project (app target)

**Files:**
- Modify: `Sources/linkc/LinkCApp.swift`
- Modify: `Sources/linkc/AppModel+Sidebar.swift`
- Modify call sites in `Sources/linkc/SplitPane.swift` and `Sources/linkc/TerminalDropTarget.swift` (signatures only)

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces, on `AppModel`:
  - `var tornOff: TornOff { sidebarState.tornOff }`
  - `func host(of id: String) -> TornOffItem?`. Short-circuit to nil when `tornOff.isEmpty`; otherwise call `tornOff.host(of:splits: storedSplits(), liveIDs: splittableIDs(in:))`.
  - `func tearOff(_ item: TornOffItem, at point: CGPoint?)`:
    - Refuse with `lastError` if the terminal isn't live: "That terminal has ended, so it can't open in a window." Likewise if the split isn't active: "This split needs two running terminals to open in a window."
    - If it is already open, call `raise(item, focusing: nil)` and return.
    - Otherwise compute the frame: 720×460 for a terminal, 960×600 for a split. Centre it on `point` (screen coordinates, bottom-left origin). When `point` is nil, place it 24 pt right of the panel's frame. Clamp it to that screen's `visibleFrame`.
    - Then call `sidebarState.setTornOff(tornOff.adding(item, frame:))`.
  - `func bringBack(_ item: TornOffItem)`, which removes the item. The window controller closes its window.
  - `func setFrame(_ item: TornOffItem, _ frame: TornOffFrame)`
  - `@ObservationIgnored var onRaiseWindow: ((TornOffItem) -> Void)?`, set by the window controller.
  - `func raise(_ item: TornOffItem, focusing id: String?)`. For a split, it first sets the split's focus to `id`; then it calls `onRaiseWindow?(item)`.
  - `var keyWindowItem: TornOffItem?`, set by the controller when a torn-off window becomes or stops being key.
  - `var keyWindowSessionId: String?`: the terminal for a `.terminal` key window, or that split's `focusedLive` member for a `.split` key window.
- Split operations take the project explicitly, so a torn-off grid works without touching the panel:
  - `focusInSplit(_ id: String, in project: String)`
  - `pickSplitPane(_ id: String, in project: String)`
  - `clickSplitPane(_ id: String, in project: String)`
  - `removeFromSplit(_ id: String, in project: String)`
  - `dropTerminal(_ id: String, onto target: String, edge: SplitEdge, in project: String)`

  When `project` is the panel's showing split (`splitProject == project`), behaviour is exactly as today. Otherwise (a torn-off grid):
  - focus only sets the split's focus;
  - pick does that plus `coordinator?.acknowledgeSession(id)`;
  - click does pick plus `makeFirstResponder`;
  - remove updates or clears the stored split without touching the panel's selection;
  - drop stores the new split without calling `showSplit`.

  The panel callers pass `splitProject` or `currentProject` as before. Keep the existing refusal messages.

- [ ] **Step 1: Implement the members above.**
  - `storedSplits()` already exists from the open-split work.
  - `showSelection(opening:)`: after its current logic, if `opened == selectedId` and `host(of: selectedId)` is a window, call `raise(thatWindow, focusing: selectedId)`. The panel shows the note (Task 5).
  - `onScreenSessionId`: return nil when the selected id's host is a window.
  - In `start()`, the `isWatching` closure also returns true when `NSApp.isActive && self.keyWindowSessionId == id`.
  - `markOnScreenSeen`: also mark `keyWindowSessionId`'s session seen when the app is active.
  - Add `pruneTornOff()` beside `pruneSplits()` in `sampleSidebar()`, with the same guard (`coordinator != nil, shells != nil`):
    - live terminals = session ids ∪ shell row ids;
    - active splits = `projectsWithSplits` whose split `isActive(liveIDs: splittableIDs(in:))`;
    - log each closed item;
    - write only on change.
  - Also call `pruneTornOff()` once in `start()` after `restoreActiveShells()`, so stale windows never open.
- [ ] **Step 2: Update call sites** in `SplitPane.swift` and `TerminalDropTarget.swift` to pass the project. `SplitPane` already has `project`. Give `terminalDropTarget(model:target:)` a `project: String?` parameter: the panel's `TerminalPane` passes `model.currentProject`, `SplitCell` passes its pane's project.
- [ ] **Step 3: Verify.** Run `swift build --build-tests 2>&1 | grep -cE "warning:|error:"`, which should print 0, then the full `swift test` once. Read every changed path against the spec, and list in the report how each existing panel path keeps today's behaviour.
- [ ] **Step 4: Commit** `feat(windows): the model's torn-off windows, and split operations that name their project`

---

### Task 5: Panel notes where a terminal lives in a window (app target)

**Files:**
- Modify: `Sources/linkc/PanelView.swift` (`RightPane` split route, `TerminalPane`)
- Modify: `Sources/linkc/SplitPane.swift`
- Create: `Sources/linkc/WindowedNote.swift`

**Interfaces:**
- Consumes: Task 4's `host(of:)`, `raise`, `bringBack`, `tornOff`.
- Produces:
  - `struct WindowedNote: View { model; item: TornOffItem; compact: Bool }`. It shows "Open in its own window" with **Show window** (`model.raise(item, focusing: nil)`) and **Bring back** (`model.bringBack(item)`). It uses quiet, minimal styling: `Theme.textTertiary`, 11–12 pt, no fill. `compact` is for a grid cell.
  - `SplitPane(model:project:host:)`, where `host: TornOffItem?` is the window this grid is drawn in, and nil for the panel.

- [ ] **Step 1: Panel `TerminalPane`.** When the selected id's `host(of:)` is a window:
  - show `WindowedNote(item: that)` instead of the terminal;
  - pass `session: nil` to `TerminalContainer` so it never takes the view;
  - turn the drop target off (target nil).
- [ ] **Step 2: Panel Split route.** When `tornOff.contains(.split(project))`, show `WindowedNote(item: .split(project))` instead of `SplitPane`.
- [ ] **Step 3: `SplitCell`.** Each cell compares `model.host(of: id)` with its grid's `host`. If they differ, the terminal lives elsewhere:
  - show a compact `WindowedNote` for that host in place of the terminal;
  - pass `session: nil`;
  - keep the title row (with ×) and its drag.
- [ ] **Step 4: Verify.**
  - Build: 0 warnings. Run the full suite.
  - In the report, walk through these cases:
    - a full-size terminal torn off;
    - the panel's showing split torn off;
    - a member of the panel's split torn off alone;
    - a member of a torn-off split opened from the panel.
- [ ] **Step 5: Commit** `feat(windows): the panel shows a note where a terminal lives in its own window`

---

### Task 6: TornOffWindows controller (app target)

**Files:**
- Create: `Sources/linkc/TornOffWindows.swift`
- Modify: `Sources/linkc/LinkCApp.swift` (`AppDelegate`: create the controller after the model starts, beside `StatusPanelController`)

**Interfaces:**
- Consumes:
  - `model.tornOff`, `setFrame`, `bringBack`, `onRaiseWindow`, `keyWindowItem`;
  - `TerminalContainer`, `TerminalStyle.apply(to:)`, `SplitPane(model:project:host:)`;
  - the `Theme` glass, as used by `StatusPanelController`'s background.
- Produces: `@MainActor final class TornOffWindows: NSObject, NSWindowDelegate`.

Behaviour:
- **Observe and diff.** Watch `model.tornOff` the way `StatusPanelController.observeModel()` watches the model, with `withObservationTracking` re-armed on change. Diff the open windows against `tornOff.windows`:
  - open one window per new item at its saved frame;
  - close windows whose item is gone. A programmatic close must not call `bringBack` again: keep a flag or remove the delegate first.
- **Window setup.** Each window is a `NSWindow` with:
  - `styleMask [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]`;
  - `titlebarAppearsTransparent = true`;
  - `title` = the session's title, or "<project folder name> — Split";
  - `isReleasedWhenClosed = false`;
  - `collectionBehavior = [.fullScreenPrimary]`;
  - `minSize` = 360×240.
- **Content.** An `NSHostingView` of `TornOffView(model:item:)`, over an `NSVisualEffectView` like the panel's glass.
  - `TornOffView`, `.terminal(id)`: show `TerminalContainer(session: id's session, takesFocus: true, onClick: { acknowledge })`, but only when `model.host(of: id) == item`; otherwise show `WindowedNote`. Use the same padding and `Theme.terminalRadius` clip as the panel, and `TerminalStyle.apply(to:)` on appear and when the session changes. For `onClick`, hop to the main actor and call `coordinator.acknowledgeSession`, through a model method such as `model.acknowledge(id)`.
  - `TornOffView`, `.split(project)`: `SplitPane(model: model, project: project, host: item)`.
- **Delegate.**
  - `windowWillClose`: for a user close, call `model.bringBack(item)`.
  - `windowDidMove` / `windowDidEndLiveResize`: call `model.setFrame(item, frame)`.
  - `windowDidBecomeKey`: set `model.keyWindowItem = item`.
  - `windowDidResignKey`: set it to nil, if it is still this item.
- **Raise.** `model.onRaiseWindow = { item in window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }`.
- **Activation policy.** After each diff:
  - `NSApp.setActivationPolicy(windows.isEmpty ? .accessory : .regular)`, only when it changes;
  - when going `.regular` because a window was just opened by the user, `NSApp.activate(ignoringOtherApps: true)`.
- **Live view.** The panel keeps working. A window's `TerminalContainer` takes the terminal view through `TerminalHostView.show`, which re-attaches a view another host had. That is why the host rule gates every host.
- **Relaunch.** The controller is created after `model.start()` has run `pruneTornOff()`, so windows that open at launch are only the live ones.

- [ ] **Step 1: Implement.**
- [ ] **Step 2: Verify.**
  - Build with 0 warnings, then run the full suite.
  - In the report, walk through how each spec behaviour maps to code:
    - open;
    - close (button and ⌘W, via SwiftUI's default Window menu);
    - frames saved;
    - raise;
    - Dock toggle;
    - relaunch;
    - session ends;
    - typing.
  - Check that ⌘C, ⌘V and ⌘W reach a window: linkC's SwiftUI `App` provides the default Edit and Window menus. Say what you found.
- [ ] **Step 3: Commit** `feat(windows): torn-off terminals and grids open in their own windows`

---

### Task 7: Tear off from the tab strip — drag out and the chip menu (app target)

**Files:**
- Create: `Sources/linkc/DragOutSource.swift`
- Modify: `Sources/linkc/Board/ProjectTabStrip.swift` (`TabChip`, `TerminalChipDrag`)

**Interfaces:**
- Consumes:
  - `model.tearOff(_:at:)`, `model.bringBack`, `model.tornOff`;
  - `LinkCTerminalDrag` (`Sources/linkc/Sidebar.swift`) and `UTType.linkcTerminal`.
- Produces: `struct DragOutSource: NSViewRepresentable` with:
  - `payload: NSPasteboardItem`;
  - `onClick: () -> Void`;
  - `onDraggedOut: (CGPoint) -> Void`.

  It is an `NSView` that handles mouse-down, drag and up:
  - **A click** (mouse-up with under 3 pt of movement): `onClick`.
  - **A drag:** `beginDraggingSession(with: [NSDraggingItem(pasteboardWriter: payload)], event:, source: self)`, with an image of the view's bounds as the drag image.
  - **`sourceOperationMaskFor`:** `[.copy, .move]` within the app, `[]` outside.
  - **`draggingSession(_:endedAt:operation:)`:** when the operation is empty and `endedAt`, in screen coordinates, is outside the view's window frame, call `onDraggedOut(endedAt)`.

Chips:
- **Payloads.**
  - Session and terminal chips: data `JSONEncoder().encode(LinkCTerminalDrag(id: tab.id))` for type `NSPasteboard.PasteboardType(UTType.linkcTerminal.identifier)`. The panel's split drops, the strip and the sidebar keep accepting it. Check that `LinkCTerminalDrag`'s `CodableRepresentation` decodes plain `JSONEncoder` output; it uses JSON by default.
  - The Split chip: type `com.linkc.split-tab`, which nothing accepts, so only a drag out does anything.
- **Layout.** Restructure `TabChip` so that:
  - `DragOutSource` sits underneath and handles click and drag for `.agent`/`.terminal`/`.split` chips;
  - the icon and title don't hit-test, so clicks reach the source;
  - the close × stays a SwiftUI button above it and keeps working;
  - hover keeps working, through `.onHover` on the outer view.
  - Board and app chips keep today's plain tap.
- **Context menu** on `.agent`/`.terminal`/`.split` chips: **Open in Window** (`model.tearOff(item, at: nil)`), or **Bring back** when `model.tornOff.contains(item)`.
- **Window mark.** A torn-off chip shows a small `macwindow` glyph (9 pt, `Theme.textTertiary`) after its title.

- [ ] **Step 1: Implement `DragOutSource` and the chip changes.**
- [ ] **Step 2: Verify.**
  - Build with 0 warnings, then run the full suite.
  - In the report, explain, from the code and from AppKit and SwiftUI documentation:
    - why a click still selects;
    - why × still closes;
    - why a chip dropped on a split pane edge or the sidebar still lands;
    - why a release outside the panel tears off;
    - why a release inside the panel that nothing accepts does nothing.
- [ ] **Step 3: Commit** `feat(windows): drag a tab out of the panel, or use its menu, to open it in a window`

---

## Manual checks (after all tasks, by the user)
- Drag a chip out to open a window; **Open in Window** from the menu also works.
- The Dock icon appears and goes away.
- Typing goes to the window; ⌘C, ⌘V and ⌘W work.
- The panel shows the note; **Bring back** and the close button both return the terminal to the panel.
- A sidebar click and a notification click raise the window.
- In a torn-off grid, drag, drop, × and focus all work, and the panel's selection never changes.
- A session ending closes its window.
- Windows come back after a relaunch.

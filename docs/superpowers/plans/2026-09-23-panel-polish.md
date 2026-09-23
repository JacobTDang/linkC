# Panel Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the sidebar Board row; make the panel movable only by its top; replace the agent colour squares with real logos; show a working session's live action in its tab and sidebar row.

**Architecture:** Pure rules and data live in LinkCKit and are tested:
- the logo SVG text (`AgentKind.logo`);
- when an action replaces a name (`ShownActivity`);
- the row and tab models carrying it.

The app target only draws, through three new shared views: `WindowDragHandle`, `AgentLogoView`
and `ActivityLabel`. The window-drag workaround (`WindowDragGate`, `.selectableText()`) is deleted.

**Tech Stack:** Swift 6, macOS 14, SwiftUI + AppKit, XCTest. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-09-23-panel-polish-design.md`

## Global Constraints

- Swift 6 / macOS 14 deployment target. **No new packages or dependencies.**
- TDD for everything in LinkCKit. Watch each new test fail on an assertion before implementing;
  a compile error doesn't count, so add a stub first if needed. The app target has no SwiftUI
  test harness: build it, and read your change carefully.
- **Fail loud:**
  - no `try?` swallowing;
  - no silent fallbacks;
  - an embedded logo that fails to load is a programmer error, and traps with a message.
- No view body writes observable state.
- No debug prints, commented-out code or scratch files left behind. Delete what becomes dead.
- Match the surrounding code: its `Theme` tokens, naming, and comment density.
- **Commits:**
  - One-line `feat(panel): …` / `fix(panel): …` / `refactor(panel): …` messages.
  - Stage files by name; never `git add -A` or `git add .`.
  - The untracked `system-map.json` at the repository root belongs to the user. Never stage,
    modify or delete it.
  - No message may contain "claude" in any case.
  - No trailers of any kind (no Co-Authored-By, no session links, no "Generated with").
  - Check with `git log -1 --format=%B | grep -ic claude` (must print 0).
- **Verify every task:**
  - `swift build 2>&1 | tail -3` is clean;
  - `swift build 2>&1 | grep -i warning` prints nothing;
  - `swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1` shows 0 failures. The
    baseline is 1176 tests, 5 skipped, 0 failures.
- Logos: sources are the prepared files in `.superpowers/panel-polish/logos/`. Arc commands are
  already rewritten, so CoreSVG draws them without warnings. Embed them verbatim, apart from the
  one width/height edit Task 2 specifies.

---

### Task 1: No Board row; the window moves only by its top

**Files:**
- Create: `Sources/linkc/WindowDragHandle.swift`
- Modify:
  - `Sources/linkc/StatusPanelController.swift`
  - `Sources/linkc/Sidebar.swift`
  - `Sources/linkc/PanelView.swift`
  - `Sources/linkc/Board/ProjectTabStrip.swift`
  - `Sources/linkc/SidebarInfra.swift`
  - `Sources/linkc/AgentViews.swift`
  - `Sources/linkc/Screens/SkillsScreen.swift`
  - `Sources/linkc/Screens/ToolServersScreen.swift`
- Delete:
  - `Sources/linkc/SelectableText.swift`
  - `Sources/LinkCKit/App/WindowDragGate.swift`
  - `Tests/LinkCKitTests/WindowDragGateTests.swift`

**Interfaces:**
- Produces: `struct WindowDragHandle: NSViewRepresentable`, used as a `.background` behind top rows.

- [ ] **Step 1: Remove the Board row.**

  In `Sidebar.swift`, `ProjectsSection.body`, delete the `BoardRow(...) { model.showBoard(project.path) }` block. Delete the `private struct BoardRow` and its doc comment. Keep the session row's `&& model.boardProject == nil`: no row is selected while a Board shows.

- [ ] **Step 2: Add the drag handle.** Create `Sources/linkc/WindowDragHandle.swift`:

```swift
import AppKit
import SwiftUI

/// The only places a drag moves the panel. Put it behind a top row (`.background`): where the
/// row's own controls sit, they get the click; in the empty space around them, this does, and
/// hands the drag to the window server — so the panel moves exactly as a title bar would.
struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}
```

- [ ] **Step 3: Stop the body from moving the window.** In `StatusPanelController.swift`:
  - Make `PanelHostingView` plain. It keeps no gate and only overrides
    `override var mouseDownCanMoveWindow: Bool { false }`. Its init becomes the inherited
    `init(rootView:)`, so delete the custom inits and the `fatalError` init that forbade it. Keep
    the `required init?(coder:)` if the compiler demands it. Rewrite its doc comment in one
    line: the body never moves the window; `WindowDragHandle` does, behind the top rows.
  - Set `panel.isMovableByWindowBackground = false`. Update the trailing comment: drag the top
    to move, edges and corners to resize.
  - Delete `dragGate`, the `.environment(\.setWindowDraggable)` modifier, and `dragGate.reset()`
    in `hide()`, with the comment above it.
  - Fix the class doc comment that says "Movable (drag the body)".

- [ ] **Step 4: Delete the gate machinery.**
  - Delete `Sources/linkc/SelectableText.swift`, `Sources/LinkCKit/App/WindowDragGate.swift` and
    `Tests/LinkCKitTests/WindowDragGateTests.swift`.
  - Replace every `.selectableText()` with `.textSelection(.enabled)`. Find them all with
    `grep -rn "selectableText()" Sources`; there are 9 sites in `SidebarInfra.swift`,
    `AgentViews.swift`, `SkillsScreen.swift`, `ToolServersScreen.swift` and `PanelView.swift`.
  - In `PanelView.swift`'s `TerminalPane`, delete the `@Environment(\.setWindowDraggable)`
    property, the `isHoveringTerminal` state, and the `.onHover` / `.onDisappear` / `.onChange`
    blocks on `TerminalContainer` that only toggled dragging. Keep the `.clipShape`.
  - `grep -rn "setWindowDraggable\|WindowDragGate\|selectableText" Sources Tests` must print
    nothing.

- [ ] **Step 5: Put the handle behind every top row.**
  - `Sidebar.swift` `BrandRow`: add `.background(WindowDragHandle())` after its paddings, so the
    whole row, including its padding, is draggable where `LauncherMenu` isn't.
  - `ProjectTabStrip.swift`: add `.background(WindowDragHandle())` to the strip's outer `HStack`,
    after `.padding(.top, 8)` and before the hairline background. The empty space between and
    after the tabs lies inside the `ScrollView`, and an `NSScrollView` takes the click itself.
    So also put `WindowDragHandle()` behind the tab chips inside the scroll content:
    `.background(WindowDragHandle())` on the inner `HStack(spacing: 2)`, and give that `HStack`
    `.frame(minWidth: geometry.size.width, alignment: .leading)` so it covers the empty width.
    The chips keep their own taps.
  - `PanelView.swift` `RightPane`: in the `activeScreen` branch and the `EmptyStateView` branch,
    add `.background(alignment: .top) { WindowDragHandle().frame(height: 36) }` to the branch's
    view. The top band of a screen, and of the launcher, then drags where nothing interactive
    sits.

- [ ] **Step 6: Verify.** Run the build, the warnings check and the full suite. The suite loses
  the deleted `WindowDragGateTests`, so the count drops by that file's tests. Record the new
  baseline in the report.

- [ ] **Step 7: Commit:** `refactor(panel): the window moves only by its top, and the Board row is gone`

---

### Task 2: Agent logos

**Files:**
- Create: `Sources/LinkCKit/Core/AgentLogo.swift`, `Tests/LinkCKitTests/AgentLogoTests.swift`, `Sources/linkc/AgentLogoView.swift`
- Modify:
  - `Sources/linkc/Sidebar.swift`: session row, Earlier row, usage row; delete `AgentMark`.
  - `Sources/linkc/Board/ProjectTabStrip.swift`: `TabChip`.
  - `Sources/linkc/SessionHeaderStrip.swift`
  - `Sources/linkc/ProjectDashboardSheet.swift`

**Interfaces:**
- Produces:
  - `public struct AgentLogo { public let svg: String; public let isTemplate: Bool }`
  - `extension AgentKind { public var logo: AgentLogo? }`, which is nil only for `.shell`
  - `struct AgentLogoView: View { let agent: AgentKind; var size: CGFloat = 12 }`

- [ ] **Step 1: Write the failing test.** Create `Tests/LinkCKitTests/AgentLogoTests.swift`:

```swift
import AppKit
import XCTest
@testable import LinkCKit

final class AgentLogoTests: XCTestCase {
    /// Every agent but a plain shell has a logo, and each one loads as a real SVG image at the
    /// icons' 24-point grid — a broken embed fails here, not as a blank square in the panel.
    func testEveryAgentButShellHasALogoThatLoads() throws {
        for kind in AgentKind.allCases {
            guard kind != .shell else {
                XCTAssertNil(kind.logo, "a plain shell keeps its terminal symbol")
                continue
            }
            let logo = try XCTUnwrap(kind.logo, "\(kind) has no logo")
            let image = try XCTUnwrap(NSImage(data: Data(logo.svg.utf8)), "\(kind)'s logo does not load")
            XCTAssertTrue(image.isValid, "\(kind)")
            XCTAssertTrue(image.representations.contains { String(describing: type(of: $0)).contains("SVG") },
                          "\(kind)'s logo must load as SVG, not a bitmap")
            XCTAssertEqual(image.size, NSSize(width: 24, height: 24), "\(kind)'s logo keeps the 24-point grid")
        }
    }

    /// Only Cursor's mark is one colour (the file draws in `currentColor`); the rest are drawn as
    /// they are.
    func testOnlyCursorIsTintedByTheApp() {
        XCTAssertEqual(AgentKind.allCases.filter { $0.logo?.isTemplate == true }, [.cursor])
    }
}
```

- [ ] **Step 2: Run it and watch it fail.** First add a stub so it compiles: `AgentLogo` with
  `svg`/`isTemplate`, and `AgentKind.logo` returning nil. Then run
  `swift test --filter AgentLogoTests`. It should fail on "has no logo".

- [ ] **Step 3: Implement `Sources/LinkCKit/Core/AgentLogo.swift`.**

```swift
import Foundation

/// An agent's logo as SVG text. The app draws it with `NSImage(data:)` (CoreSVG), so no
/// asset catalog or package is needed.
///
/// The marks are from @lobehub/icons-static-svg 1.95.1 — https://github.com/lobehub/lobe-icons —
/// with each path's arc commands rewritten with explicit separators (CoreSVG misreads packed arc
/// flags such as `012.285` and draws a line instead) and the size set to the icons' 24-point grid.
/// The marks themselves belong to their owners.
///
/// MIT License — Copyright (c) 2023 LobeHub
///
/// Permission is hereby granted, free of charge, to any person obtaining a copy of this software
/// and associated documentation files (the "Software"), to deal in the Software without
/// restriction, including without limitation the rights to use, copy, modify, merge, publish,
/// distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the
/// Software is furnished to do so, subject to the following conditions:
///
/// The above copyright notice and this permission notice shall be included in all copies or
/// substantial portions of the Software.
///
/// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING
/// BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
/// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
/// DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
/// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
public struct AgentLogo: Equatable, Sendable {
    public let svg: String
    /// Drawn in one colour chosen by the app (the file uses `currentColor`), rather than as-is.
    public let isTemplate: Bool
}

extension AgentKind {
    /// The agent's logo; nil for a plain shell, which keeps its terminal symbol.
    public var logo: AgentLogo? {
        switch self {
        case .claude: return AgentLogo(svg: Self.claudeSVG, isTemplate: false)
        case .codex: return AgentLogo(svg: Self.codexSVG, isTemplate: false)
        case .cursor: return AgentLogo(svg: Self.cursorSVG, isTemplate: true)
        case .agy: return AgentLogo(svg: Self.antigravitySVG, isTemplate: false)
        case .shell: return nil
        }
    }
}
```

  Then add the four `private static let …SVG` constants in the same file, one per logo, as raw
  string literals delimited with **two** hashes (`##"…"##`). The files contain `"#` (as in
  `fill="#fff"`), which would end a one-hash raw string; none contains `"##`. Take them from:
  - `.superpowers/panel-polish/logos/claude-color.svg` → `claudeSVG`
  - `…/codex-color.svg` → `codexSVG`
  - `…/cursor.svg` → `cursorSVG`
  - `…/antigravity-color.svg` → `antigravitySVG`

  Make exactly one edit to each: replace `height="1em"` with `height="24"` and `width="1em"`
  with `width="24"`, so the image has the grid's size. Change nothing else.

- [ ] **Step 4: Run the tests and see them pass.** Use `swift test --filter AgentLogoTests`. Record
  the red line and the green line in the report.

- [ ] **Step 5: Add `Sources/linkc/AgentLogoView.swift`.**

```swift
import AppKit
import SwiftUI
import LinkCKit

/// An agent's logo, drawn from its embedded SVG; a plain shell's terminal symbol. Each logo is
/// loaded once. A logo that fails to load is a broken embed — `AgentLogoTests` guards it — so it
/// traps rather than showing a blank.
struct AgentLogoView: View {
    let agent: AgentKind
    var size: CGFloat = 12

    var body: some View {
        Group {
            if let logo = agent.logo {
                Image(nsImage: AgentLogoImages.image(for: agent, logo: logo))
                    .renderingMode(logo.isTemplate ? .template : .original)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(Theme.textPrimary)
            } else {
                Image(systemName: "terminal")
                    .font(.system(size: size * 0.75))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(width: size, height: size)
    }
}

@MainActor
private enum AgentLogoImages {
    private static var cache: [AgentKind: NSImage] = [:]

    static func image(for agent: AgentKind, logo: AgentLogo) -> NSImage {
        if let cached = cache[agent] { return cached }
        guard let image = NSImage(data: Data(logo.svg.utf8)), image.isValid else {
            preconditionFailure("the embedded \(agent.displayName) logo does not load as SVG")
        }
        image.isTemplate = logo.isTemplate
        cache[agent] = image
        return image
    }
}
```

- [ ] **Step 6: Replace every square with `AgentLogoView`.**
  - `Sidebar.swift` `SessionRow`: `AgentMark(agent: row.agentKind)` → `AgentLogoView(agent: row.agentKind)`.
  - `Sidebar.swift` `EarlierSessionRow`: `AgentMark(agent: session.agentKind, dimmed: true)` → `AgentLogoView(agent: session.agentKind).opacity(0.6)`.
  - `Sidebar.swift` `UsageRowView`: replace the `RoundedRectangle(cornerRadius: 2).fill(...).frame(width: 7, height: 7)` with `AgentLogoView(agent: row.agent).opacity(row.isStale ? 0.5 : 1)`.
  - Delete `private struct AgentMark` and its doc comment.
  - `ProjectTabStrip.swift` `TabChip`, `case .agent(let kind):` → `AgentLogoView(agent: kind)`.
  - `SessionHeaderStrip.swift`: replace the `RoundedRectangle … .fill(Theme.agentColor(session.agentKind)) … .frame(width: 7, height: 7)` with `AgentLogoView(agent: session.agentKind)`.
  - `ProjectDashboardSheet.swift`: replace the `RoundedRectangle … .fill(Theme.agentColor(dossier.agent)) …` with `AgentLogoView(agent: dossier.agent)`.
  - Then run `grep -rn "RoundedRectangle(cornerRadius: 2)" Sources/linkc`. Nothing should remain that draws an agent colour. `Theme.agentColor` stays, because `AgentPill` uses it.

- [ ] **Step 7: Verify.** Run the build, the warnings check and the full suite.

- [ ] **Step 8: Commit:** `feat(panel): each agent's real logo in place of the colour square`

---

### Task 3: A working session's action in its tab and sidebar row

**Files:**
- Create: `Sources/LinkCKit/Core/ShownActivity.swift`, `Tests/LinkCKitTests/ShownActivityTests.swift`, `Sources/linkc/ActivityLabel.swift`
- Modify:
  - `Sources/LinkCKit/Core/SidebarModel.swift`
  - `Sources/LinkCKit/Board/ProjectTabs.swift`
  - `Tests/LinkCKitTests/SidebarModelTests.swift`
  - `Tests/LinkCKitTests/ProjectTabsTests.swift`
  - `Sources/linkc/AppModel+Sidebar.swift`
  - `Sources/linkc/LinkCApp.swift` (`projectTabs`)
  - `Sources/linkc/Sidebar.swift` (`SidebarRow`, `SessionRow`)
  - `Sources/linkc/Board/ProjectTabStrip.swift`
  - `Sources/linkc/SessionHeaderStrip.swift`

**Interfaces:**
- Consumes: `AppModel.currentActivity(_ session: Session) -> String?`, unchanged.
- Produces:
  - `public struct ShownActivity { text: String; isWorking: Bool; init?(activity: String?, state: SessionState); static func applies(to state: SessionState) -> Bool }`
  - `SidebarModel.Input(…, activity: String? = nil)` and `SidebarSessionRow.activity: ShownActivity?`
  - `ProjectTabs.tabs(…, activities: [String: String] = [:])` and `ProjectTab.activity: ShownActivity?`
  - `struct ActivityLabel: View { let text: String; let isWorking: Bool; var size: CGFloat = 11 }`

- [ ] **Step 1: Write the failing tests.** Create `Tests/LinkCKitTests/ShownActivityTests.swift`:

```swift
import XCTest
@testable import LinkCKit

final class ShownActivityTests: XCTestCase {
    func testAWorkingSessionShowsItsActionAndShimmers() throws {
        let shown = try XCTUnwrap(ShownActivity(activity: "Read the panel's drag gate", state: .working))
        XCTAssertEqual(shown.text, "Read the panel's drag gate")
        XCTAssertTrue(shown.isWorking)
    }

    func testAPermissionWaitShowsItsLineWithoutTheShimmer() throws {
        let shown = try XCTUnwrap(ShownActivity(activity: "Permission required", state: .waitingPermission))
        XCTAssertFalse(shown.isWorking)
    }

    func testEveryOtherStateShowsTheName() {
        for state in SessionState.allCases where state != .working && state != .waitingPermission {
            XCTAssertNil(ShownActivity(activity: "$ swift test", state: state), "\(state) shows the name")
        }
    }

    func testNoActionShowsTheName() {
        XCTAssertNil(ShownActivity(activity: nil, state: .working))
        XCTAssertNil(ShownActivity(activity: "", state: .working))
        XCTAssertNil(ShownActivity(activity: "  \n", state: .working))
    }

    func testTheTextIsTrimmed() {
        XCTAssertEqual(ShownActivity(activity: "  ▸ Final fix wave \n", state: .working)?.text, "▸ Final fix wave")
    }
}
```

  Add to `SidebarModelTests`:

```swift
    func testAWorkingRowCarriesItsActionAndAnIdleOneDoesNot() {
        var working = Session(id: "w", cwd: "/p/a", title: "a", agentKind: .claude)
        working.state = .working
        var idle = Session(id: "i", cwd: "/p/a", title: "a", agentKind: .claude)
        idle.state = .finished
        let status = SessionRowStatus(text: "", tone: .quiet)
        let rows = SidebarModel.projects(
            inputs: [
                SidebarModel.Input(session: working, title: "w", status: status, hasRunningSubagents: false, activity: "$ swift test"),
                SidebarModel.Input(session: idle, title: "i", status: status, hasRunningSubagents: false, activity: "$ swift test"),
            ],
            order: [], expandOverrides: [:], selectedId: nil
        )[0].sessions
        XCTAssertEqual(rows.map(\.activity?.text), ["$ swift test", nil])
    }
```

  Add to `ProjectTabsTests`:

```swift
    func testAWorkingTabCarriesItsActionAndAnIdleOneDoesNot() {
        let tabs = ProjectTabs.tabs(
            project: "/p", sessions: [session("a", "/p", .working), session("b", "/p", .ready)], shells: [],
            titles: [:], activities: ["a": "Read the panel's drag gate", "b": "$ ls"])
        XCTAssertEqual(tabs.map(\.activity?.text), [nil, "Read the panel's drag gate", nil])
    }
```

  If `Session.state` is not settable as written, use whichever initializer the existing tests use
  to set a state; `ProjectTabsTests`' `session(_:_:_:)` helper shows one.

- [ ] **Step 2: Run them and watch them fail.** First add stubs so they compile:
  - `ShownActivity` with an `init?` that returns nil;
  - the new `activity` parameters and fields, left unused.

  Run `swift test --filter "ShownActivityTests|SidebarModelTests|ProjectTabsTests"`. The new
  tests should fail on assertions.

- [ ] **Step 3: Implement `Sources/LinkCKit/Core/ShownActivity.swift`.**

```swift
import Foundation

/// What a session's tab or sidebar row reads in place of its name: its current action, while it
/// is working or waiting on a permission. Any other state, or no action to show, reads as the name.
public struct ShownActivity: Equatable, Sendable {
    public let text: String
    /// Working, not waiting on a permission: the line shimmers.
    public let isWorking: Bool

    public init?(activity: String?, state: SessionState) {
        let text = activity?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard Self.applies(to: state), !text.isEmpty else { return nil }
        self.text = text
        self.isWorking = state == .working
    }

    /// Whether a session in `state` shows an action at all — so callers skip reading one otherwise.
    public static func applies(to state: SessionState) -> Bool {
        state == .working || state == .waitingPermission
    }
}
```

  Then wire the models:
  - **`SidebarModel.Input`:** add `public let activity: String?`, with init parameter
    `activity: String? = nil` last.
  - **`SidebarSessionRow`:** add `public let activity: ShownActivity?`, with init parameter
    `activity: ShownActivity? = nil` last. In `projects(…)`, build it as
    `activity: ShownActivity(activity: $0.activity, state: $0.session.state)`.
  - **`ProjectTab`:** add `public let activity: ShownActivity?`, with init parameter
    `activity: ShownActivity? = nil` last.
  - **`ProjectTabs.tabs`:** add a final parameter `activities: [String: String] = [:]`. Pass
    `activity: ShownActivity(activity: activities[session.id], state: session.state)` for agent
    tabs. The Board and terminal tabs get none.

- [ ] **Step 4: Run the tests and see them pass.** Record the red and green lines.

- [ ] **Step 5: Feed the live action in from the app.**
  - **`AppModel+Sidebar.swift` `sidebarProjects(now:)`:** pass
    `activity: ShownActivity.applies(to: session.state) ? currentActivity(session) : nil`.
    Idle sessions skip the terminal read.
  - **`LinkCApp.swift` `projectTabs`:** build `activities` for the project's sessions the same
    way:
    ```swift
    var activities: [String: String] = [:]
    for session in sessions where ShownActivity.applies(to: session.state) {
        activities[session.id] = currentActivity(session)
    }
    ```
    Pass it to `ProjectTabs.tabs(…, activities: activities)`.

- [ ] **Step 6: One view for the line.** Create `Sources/linkc/ActivityLabel.swift`:

```swift
import SwiftUI

/// A session's current action — its icon, the text, and a shimmer while it works. The header,
/// the tab strip and the sidebar rows all draw it this way.
struct ActivityLabel: View {
    let text: String
    let isWorking: Bool
    var size: CGFloat = 11

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: activityIcon(for: text))
                .font(.system(size: size - 2))
                .foregroundStyle(isWorking ? Theme.accent : Theme.textTertiary)
            Text(text)
                .font(.system(size: size))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .smoothShimmer(isWorking: isWorking)
        }
    }
}
```

  Wire it in:
  - **`SessionHeaderStrip.swift`:** replace the inline `Image(systemName: activityIcon(for: activity))`
    + `Text(activity)…smoothShimmer` pair inside the existing `TimelineView` with
    `ActivityLabel(text: activity, isWorking: session.state == .working)`. Keep the surrounding
    `HStack` and `Spacer`, the `TimelineView` and its condition. The header's behaviour is
    unchanged.
  - **`Sidebar.swift` `SidebarRow`:** add `var activity: ShownActivity? = nil` after `help`. In
    the body, where `Text(title)` is, show `ActivityLabel(text: activity.text,
    isWorking: activity.isWorking, size: 12)` when `activity` is set, and the existing `Text(title)`
    otherwise. `.help(help ?? title)` stays, so hovering still shows the name. `SessionRow`
    passes `activity: row.activity`.
  - **`ProjectTabStrip.swift` `TabChip`:** where `Text(tab.title)` is, show
    `ActivityLabel(text: activity.text, isWorking: activity.isWorking, size: 11.5)` when
    `tab.activity` is set, else the title as now. The chip's existing `.help(tab.title)` keeps
    the name on hover.
  - **The strip's timer (power rule):** a terminal-read action is not observable, so the strip
    re-reads once a second, but only while one of its sessions is working.
    - In `ProjectTabStrip.body`, compute `let anyWorking = model.projectTabs.contains(where: \.isWorking)`.
    - Wrap the outer `HStack`'s *contents* in
      `TimelineView(.periodic(from: .now, by: anyWorking ? 1 : 3600)) { _ in … }`, reading
      `model.projectTabs` and `model.selectedTabID` inside the closure.
    - Keep the outer modifiers where they are: paddings, backgrounds, `WindowReader`,
      `.onAppear`/`.onDisappear`, `.confirmationDialog`. That way the key monitor and dialog
      state are never torn down.
    - One timeline type either way, so switching the interval never changes view identity.
  - **The sidebar:** nothing to add. `ProjectsSection` already sits inside the sidebar's
    1-second `TimelineView` and calls `sidebarProjects(now:)` every tick.

- [ ] **Step 7: Verify.** Run the build, the warnings check and the full suite.

- [ ] **Step 8: Commit:** `feat(panel): a working session's action shows in its tab and sidebar row`

# Project Terminals Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Open a terminal inside a project, list terminals under their project, and file a terminal
under a project by dragging it there.

**Architecture:** One pure membership rule in LinkCKit, `TerminalFiling`, decides which project a
terminal belongs to. `SidebarState` persists explicit filings. `SidebarModel` and `ProjectTabs` both
use the rule. The app adds the menu items, the rows under projects, and drag and drop.

**Tech Stack:** Swift 6, macOS 14, SwiftUI (`draggable` / `dropDestination`), XCTest. No new
dependencies.

**Spec:** `docs/superpowers/specs/2026-09-24-project-terminals-design.md`

## Global Constraints

- Swift 6 / macOS 14. No new dependencies.
- TDD for LinkCKit: each test is seen failing on an assertion first. The app target has no UI
  harness: build it, read the change carefully, and list the hand checks.
- **Fail loud:** a drop with an unknown payload is ignored with no state change, and logged. Filing
  a terminal id that doesn't exist is refused.
- No view body writes observable state. No debug artifacts.
- **Commits:**
  - One-line `feat(sidebar): …` messages.
  - Stage by name.
  - Never touch the untracked `system-map.json`.
  - No "claude" in any case in messages.
  - No trailers of any kind.
- **Verify:**
  - `swift build 2>&1 | tail -3` is clean;
  - `swift build 2>&1 | grep -i warning` prints nothing;
  - the full suite passes with 0 failures. Record the baseline at the start.

---

### Task 1: The rule, the filings, and the models

**Files:**
- Create: `Sources/LinkCKit/Core/TerminalFiling.swift`, `Tests/LinkCKitTests/TerminalFilingTests.swift`
- Modify:
  - `Sources/LinkCKit/Preferences/SidebarState.swift`: `terminalProjects`, `file`/`unfile`, pruning;
  - `Sources/LinkCKit/Core/SidebarModel.swift`: terminals under projects, and projects made only of
    filed terminals;
  - `Sources/LinkCKit/Board/ProjectTabs.swift`: use the rule.
- Tests: `SidebarStateTests`, `SidebarModelTests`, `ProjectTabsTests`

**Interfaces:**

```swift
public enum TerminalFiling {
    /// The project a terminal belongs to: its filing, else a project whose folder is its folder, else nil.
    /// Paths compare standardized, as the rest of the sidebar compares them.
    public static func project(forTerminal id: String, cwd: String, filed: [String: String], projects: Set<String>) -> String?
}

// SidebarState
public private(set) var terminalProjects: [String: String]   // terminal id → standardized project path
public func file(terminal id: String, under project: String)
public func unfile(terminal id: String)
public func pruneTerminals(keeping ids: Set<String>)
```

- `terminalProjects` is persisted in `Stored`, like `boardViewports`, and decodes as empty from older
  saved state.
- **`SidebarModel.projects(…)`** gains a `shells: [ShellRow]` input and a `filed: [String: String]`
  input.
  - `SidebarProject` gains `terminals: [ShellRow]`, in shell order.
  - The known projects are the session projects plus every filed project path.
  - A project with only filed terminals gets its name from the folder's last component, and a quiet
    dot.
  - Projects are ordered by the existing rule.
  - Also return, or expose through a second function, the unfiled terminals for the Terminals
    section.
- **`ProjectTabs.tabs`** gains `filed: [String: String]` and uses `TerminalFiling.project` for
  shells, where it now compares cwd.

- [ ] **Step 1: Write the failing tests.**

```swift
// TerminalFilingTests
func testFiledThenMatchingFolderThenNone() {
    let projects: Set<String> = ["/p/june", "/p/linkc"]
    XCTAssertEqual(TerminalFiling.project(forTerminal: "t1", cwd: "/Users/j/school", filed: ["t1": "/p/june"], projects: projects), "/p/june")
    XCTAssertEqual(TerminalFiling.project(forTerminal: "t2", cwd: "/p/linkc/", filed: [:], projects: projects), "/p/linkc")
    XCTAssertNil(TerminalFiling.project(forTerminal: "t3", cwd: "/Users/j/school", filed: [:], projects: projects))
    XCTAssertEqual(TerminalFiling.project(forTerminal: "t4", cwd: "/p/linkc", filed: ["t4": "/p/june"], projects: projects), "/p/june", "a filing beats the folder")
}

// SidebarStateTests (use the file's temp-suite helper)
func testFilingsPersistAndPrune() {
    // file t1 under /p/june → reload a new SidebarState from the same suite → terminalProjects["t1"] == "/p/june";
    // unfile t1 → gone; file t1 and t2, pruneTerminals(keeping: ["t2"]) → only t2 remains.
}

// SidebarModelTests
func testTerminalsListUnderTheirProjectAndAFiledOnlyProjectShows() {
    // sessions in /p/linkc; shells: s1 cwd /p/linkc (matches), s2 cwd /Users/j/school filed under /p/june, s3 cwd /tmp (unfiled).
    // Projects: /p/linkc lists [s1]; /p/june exists (only s2) with a quiet dot and lists [s2]; unfiled == [s3].
}

// ProjectTabsTests
func testAFiledTerminalIsATabOfItsProject() {
    // project /p/june, a shell with cwd /Users/j/school filed under /p/june → it appears after the agent tabs.
}
```

  Fill the bodies in with each file's patterns. The comments state exactly what to assert.

- [ ] **Steps 2–5:** red, implement, green, then commit: `feat(sidebar): terminals belong to projects, by filing or by folder`

---

### Task 2: Menus, rows, dragging

**Files:**
- Modify:
  - `Sources/linkc/Sidebar.swift`: rows under projects, the Terminals section, drag and drop, and
    the ProjectRow menu;
  - `Sources/linkc/Board/ProjectTabStrip.swift`: the ＋ menu;
  - `Sources/linkc/LinkCApp.swift`:
    - `newTerminal(in project:)`;
    - pass `shells` and `filed` into `sidebarProjects` and `projectTabs`;
    - `currentProject` uses the rule;
    - prune filings;
    - relaunch keeps the filing.

**Rules:**
- **`AppModel.newTerminal(in project: String)`:**
  - `shells.launch(cwd: project)`, then `sidebarState.file(terminal: newID, under: project)`;
  - select it and show it, like `newShellTerminal` after its panel;
  - errors go to `lastError`.

  `launch` must return the new id. If it doesn't today, have it return the row, and check its callers.
- **Menus:** both ＋ menus get a divider, then **New terminal**, which calls `newTerminal(in:)`.
- **Sidebar:**
  - An expanded project lists `project.terminals` with `ShellSidebarRow` after its sessions, with
    the same indent as session rows.
  - The Terminals section lists only the unfiled terminals, and is hidden when there are none,
    matching how the other sections hide.
- **Dragging:**
  - `ShellSidebarRow` gets `.draggable("linkc-terminal:\(row.id)")`.
  - `ProjectRow` gets a `.dropDestination(for: String.self)`. It accepts only payloads with the
    prefix and an existing terminal id, files the terminal, and returns true. It highlights the row
    (`Theme.hover` plus an accent hairline) while it's a valid target.
  - The Terminals `SectionLabel` gets a drop destination that unfiles. Render it even when empty
    while a terminal drag is in progress, if feasible; otherwise document that unfiling is also on
    the row's context menu.
  - Add a context-menu item on a filed terminal row, **Move out of \<project\>**, which unfiles it.
    That makes unfiling reachable without dragging.
- **`currentProject`:** for a selected shell, it is `TerminalFiling.project(…) ?? standardized cwd`.
- **Pruning:** when shells are dismissed, and on start, prune filings to the existing shell ids.
- **Relaunch:** if `relaunchShell` gives the terminal a new id, move its filing to the new id.

- [ ] **Step 1: Build.** Then run the build, the warnings check and the full suite.

- [ ] **Step 2: Hand checks** (list them in the report):
  - New terminal from the project ＋ and the tab strip ＋: it opens in the folder, sits under the
    project, and is selected.
  - Drag "school" onto a project: it moves there, and shows in that project's tab strip.
  - Drag it onto Terminals, or use the context menu: it moves back.
  - Board ⌘1 from a filed terminal.
  - Relaunch keeps the filing.
  - Quit and reopen: filings survive.

- [ ] **Step 3: Commit:** `feat(sidebar): open a terminal in a project, and drag terminals onto projects`

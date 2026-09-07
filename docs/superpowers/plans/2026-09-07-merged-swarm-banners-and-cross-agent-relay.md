# Merged Swarm Banners & Cross-Agent Relay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Merge multi-agent sessions operating in the same workspace into a unified two-tier sidebar banner with stacked mini-lanes for live activity, 1-click agent switching, a quick "Add Teammate" action, and automated cross-agent context handoff via `.linkc/HANDOFF.md`.

**Architecture:** A pure `ProjectGroup` aggregation model in `LinkCKit/Core` groups active sessions by standardized workspace path and resolves the unified urgency bucket (`.needsYou` > `.active` > `.idle`). A `HandoffComposer` generates markdown handoffs capturing prior agent kind, git status changes, and recent terminal scrollback. `SessionList.swift` renders single sessions and multi-agent groups with Tier 1 interactive agent pills (`[CODEX] [CLAUDE]`) and Tier 2 Option 2 stacked mini-lanes with live shimmer animations.

**Tech Stack:** Swift 6 (`.v6` strict concurrency), SwiftUI, Foundation, ProcessRunner, AppKit, XCTest.

## Global Constraints
- Target platform: macOS 14+ (arm64/x86_64).
- Strict Swift 6 concurrency (`.v6`) with 0 warnings.
- All existing 436 tests must continue to pass without regressions.
- Strictly NO mention of the forbidden word "gemini" anywhere in code, comments, plans, or commit messages.
- Preserve the clean two-tier layout without redundant status dots; use Option 2 (stacked mini-lanes) for multi-agent activity.
- Do not kill running user sessions unexpectedly during development or testing.

---

### Task 1: `ProjectGroup` Model & Urgency Resolution (`LinkCKit/Core`)

**Files:**
- Create: `Sources/LinkCKit/Core/ProjectGroup.swift`
- Test: `Tests/LinkCKitTests/ProjectGroupTests.swift`

**Interfaces:**
- Consumes: `Session`, `SessionState`, `AgentKind`
- Produces:
  - `struct ProjectGroup: Sendable, Identifiable, Equatable`:
    - `var id: String { workspacePath }`
    - `let workspacePath: String`
    - `let title: String`
    - `var sessions: [Session]`
    - `var bucket: SessionState.Bucket` (computed: `.needsYou` if any session needs attention, `.active` if any is working, else `.idle`)
    - `static func group(sessions: [Session]) -> [ProjectGroup]` (aggregates sessions by standardized cwd preserving encounter order)

- [ ] **Step 1: Write failing tests for `ProjectGroup`**
  Create `Tests/LinkCKitTests/ProjectGroupTests.swift` with test cases:
  - Empty sessions returns empty groups.
  - Multiple sessions with different cwds create distinct groups.
  - Multiple sessions with identical cwd (including unstandardized paths like `/path/to/./dir` vs `/path/to/dir`) are merged into a single `ProjectGroup`.
  - Urgency bucket precedence:
    - Session A (.idle) + Session B (.working) -> group bucket is `.active`.
    - Session A (.working) + Session B (.waitingPermission) -> group bucket is `.needsYou`.
    - Session A (.idle) + Session B (.idle) -> group bucket is `.idle`.
  - Group title defaults to first session's title or path basename.

- [ ] **Step 2: Run test to verify failure**
  Run: `swift test --filter ProjectGroupTests`
  Expected: FAIL with "cannot find type 'ProjectGroup' in scope"

- [ ] **Step 3: Implement `ProjectGroup`**
  Create `Sources/LinkCKit/Core/ProjectGroup.swift` with full Sendable & Equatable conformance and grouping logic.

- [ ] **Step 4: Run test to verify pass**
  Run: `swift test --filter ProjectGroupTests`
  Expected: PASS

- [ ] **Step 5: Commit**
  ```bash
  git add Sources/LinkCKit/Core/ProjectGroup.swift Tests/LinkCKitTests/ProjectGroupTests.swift
  git commit -m "feat(core): add ProjectGroup model with urgency precedence and workspace aggregation"
  ```

---

### Task 2: Cross-Agent `HandoffComposer` (`LinkCKit/Blackboard`)

**Files:**
- Create: `Sources/LinkCKit/Blackboard/HandoffComposer.swift`
- Test: `Tests/LinkCKitTests/HandoffComposerTests.swift`

**Interfaces:**
- Consumes: `AgentKind`, `Session`
- Produces:
  - `struct HandoffComposer: Sendable`:
    - `static func compose(workspacePath: String, sourceAgent: AgentKind?, lastGoal: String?, gitSummary: String?, recentTerminalOutput: String?, timestamp: Date = Date()) -> String`
    - `static func writeHandoff(workspacePath: String, content: String) throws -> URL`
    - `static func writeHandoffSync(workspacePath: String, sourceAgent: AgentKind?, lastGoal: String?, gitSummary: String?, recentTerminalOutput: String?) throws -> URL`

- [ ] **Step 1: Write failing tests for `HandoffComposer`**
  Create `Tests/LinkCKitTests/HandoffComposerTests.swift` testing:
  - Generation of markdown text includes `# Project Handoff Memo`, source agent badge/name, goal, git diff summary, and terminal output code fence.
  - Missing or nil fields degrade gracefully to informative placeholders (e.g. `(None recorded)`).
  - Writing handoff file creates `.linkc/HANDOFF.md` inside a temporary workspace directory and writes atomically.
  - Safe overwrite of existing `.linkc/HANDOFF.md` without data loss or corruption.

- [ ] **Step 2: Run test to verify failure**
  Run: `swift test --filter HandoffComposerTests`
  Expected: FAIL with "cannot find 'HandoffComposer' in scope"

- [ ] **Step 3: Implement `HandoffComposer`**
  Create `Sources/LinkCKit/Blackboard/HandoffComposer.swift` using `FileManager` and atomic file writing.

- [ ] **Step 4: Run test to verify pass**
  Run: `swift test --filter HandoffComposerTests`
  Expected: PASS

- [ ] **Step 5: Commit**
  ```bash
  git add Sources/LinkCKit/Blackboard/HandoffComposer.swift Tests/LinkCKitTests/HandoffComposerTests.swift
  git commit -m "feat(blackboard): add HandoffComposer for automated cross-agent context handoff"
  ```

---

### Task 3: AppModel Teammate Spawning & Relay Actions (`LinkCApp.swift`)

**Files:**
- Modify: `Sources/linkc/LinkCApp.swift`
- Test: `Tests/LinkCKitTests/AppCoordinatorIntegrationTests.swift`

**Interfaces:**
- Consumes: `ProjectGroup`, `HandoffComposer`, `AgentKind`
- Produces:
  - `AppModel.spawnTeammate(in workspacePath: String, agent: AgentKind)`:
    - Queries active sessions in `workspacePath` to determine prior agent kind and recent terminal output.
    - Runs `git status -s` asynchronously via `LiveProcessRunner` (with a 2s timeout and graceful fallback if git is unavailable).
    - Calls `HandoffComposer.writeHandoffSync(...)` to write `.linkc/HANDOFF.md`.
    - Spawns the new session with `coordinator.newSession(cwd: workspacePath, agent: agent, mode: .new)` and records recent folder.
  - `AppModel.projectGroups: [ProjectGroup]` computed property aggregating `sessions`.

- [ ] **Step 1: Write failing tests in `AppCoordinatorIntegrationTests.swift`**
  Add test case `testProjectGroupUrgencyResolutionAndTeammateRelay` testing:
  - Verifying multiple sessions in same workspace are grouped together.
  - Verifying handoff file is written when launching teammate into existing workspace.

- [ ] **Step 2: Run test to verify failure**
  Run: `swift test --filter AppCoordinatorIntegrationTests`
  Expected: FAIL

- [ ] **Step 3: Implement `spawnTeammate` and `projectGroups` in `LinkCApp.swift`**
  Implement `spawnTeammate` and helper methods in `AppModel`.

- [ ] **Step 4: Run test to verify pass**
  Run: `swift test --filter AppCoordinatorIntegrationTests`
  Expected: PASS

- [ ] **Step 5: Commit**
  ```bash
  git add Sources/linkc/LinkCApp.swift Tests/LinkCKitTests/AppCoordinatorIntegrationTests.swift
  git commit -m "feat(app): implement spawnTeammate with automated handoff generation"
  ```

---

### Task 4: Merged Swarm Banner UI with Option 2 Stacked Mini-Lanes (`SessionList.swift`)

**Files:**
- Modify: `Sources/linkc/SessionList.swift`
- Modify: `Sources/linkc/AgentPill.swift` (optional: add interactive selection highlight)

**Interfaces:**
- Consumes: `ProjectGroup`, `AgentKind`, `AppModel`
- Produces:
  - `CompactProjectRow: View`:
    - Tier 1:
      - Tappable `AgentPill` for each agent in the project:
        - Tapping focuses that specific agent's terminal (`model.focus(session.id)`).
        - If `session.id == selectedId`, the pill has an active selection outline/glow.
      - Project Title (`group.title`).
      - Quick `+` Add Teammate menu:
        - Options for `Claude Code`, `Antigravity (agy)`, `Cursor Agent`, `Codex`.
        - Selecting an option triggers `model.spawnTeammate(in: group.workspacePath, agent: chosenAgent)`.
      - Stop button: stops all sessions in the group, or individual session if singular.
    - Tier 2 (Option 2 Stacked Mini-Lanes):
      - If 1 session: displays single clean activity row with action icon and shimmer.
      - If 2+ sessions: displays stacked mini-lanes:
        ```
        Codex:  ✨ Thinking...
        Claude: ✻ Sautéing...
        ```
        Each lane uses `session.agentKind.pillText`, action icon, and `.smoothShimmer(isWorking: session.state.bucket == .active)`.
  - Update `liveSections` in `SessionListColumn` to iterate over `ProjectGroup`s rather than lone sessions.

- [ ] **Step 1: Update `liveSections` in `SessionList.swift` to use `ProjectGroup`**
  Refactor `liveSections` and `rows`:
  - `private enum Row: Identifiable { case header(String), case group(ProjectGroup) }`
  - Group projects by urgency bucket: `NEEDS YOU`, `WORKING`, `IDLE`.

- [ ] **Step 2: Implement `CompactProjectRow`**
  Build the SwiftUI component supporting:
  - Multi-pill Tier 1 header with tap-to-select per agent.
  - Contextual `+` Add Teammate menu.
  - Option 2 stacked mini-lanes for live activity.
  - Smooth hover and selection states.

- [ ] **Step 3: Update `HomeCard` to support multi-agent project view**
  Ensure full cards on Home screen also cleanly show multi-agent pills and activity.

- [ ] **Step 4: Verify compilation and tests**
  Run: `swift build` and `swift test`
  Expected: 0 warnings, all tests pass.

- [ ] **Step 5: Commit**
  ```bash
  git add Sources/linkc/SessionList.swift Sources/linkc/AgentPill.swift
  git commit -m "feat(ui): render merged swarm banners with Option 2 stacked mini-lanes and 1-click agent switching"
  ```

---

### Task 5: End-to-End Verification & App Installation

**Files:**
- None (verification & build scripts)

- [ ] **Step 1: Check forbidden word constraint**
  Run: `git diff main | grep -i gemini`
  Expected: No output (0 occurrences).

- [ ] **Step 2: Run complete test suite**
  Run: `swift test`
  Expected: All 436+ tests pass with 0 errors.

- [ ] **Step 3: Build and install app**
  Run: `./build-app.sh --install`
  Expected: Clean build and installation into `/Applications/linkC.app`.

# Real-Time Session Persistence & OpenAI-Style Shimmer Activity Banner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ensure linkC immediately and continuously persists active sessions and tab focus so that closing/leaving the app never loses state, and replace the terminal's top strip with a sleek OpenAI-style activity banner with a continuous text shimmer animation.

**Architecture:** Initialize sessions and shells with `wasActiveOnQuit: true` on launch, flush state to disk on window/focus events, preserve un-ended sessions across manifest reloads, and build `TerminalStatusBar` with `ShimmerHighlightModifier` for real-time model activity feedback.

**Tech Stack:** Swift 6 (`.v6` strict concurrency), SwiftUI, AppKit, XCTest.

## Global Constraints
- Strict Swift 6 concurrency compliance with 0 warnings.
- All existing and new unit tests must pass (`swift test`).
- Absolutely NO mention of "gemini" anywhere (docs, code, commit messages, or chat; use Antigravity / agy instead).
- Commit and push to `origin/main` as we go.

---

### Task 1: Real-Time Session & Shell Persistence

**Files:**
- Modify: `Sources/LinkCKit/App/WorkspaceManifest.swift`
- Modify: `Sources/LinkCKit/Terminal/ShellManifest.swift`
- Modify: `Sources/LinkCKit/App/AppCoordinator.swift`
- Modify: `Sources/LinkCKit/Terminal/ShellCoordinator.swift`
- Modify: `Sources/linkc/LinkCApp.swift`
- Modify: `Sources/linkc/StatusPanelController.swift`
- Test: `Tests/LinkCKitTests/WorkspaceManifestTests.swift`
- Test: `Tests/LinkCKitTests/AppCoordinatorIntegrationTests.swift`

- [ ] **Step 1: Write failing unit tests**
  - Add test in `WorkspaceManifestTests.swift` verifying that active sessions (`wasActiveOnQuit == true`) retain `endedAt == nil` after `WorkspaceManifest.prune`.
  - Add test in `AppCoordinatorIntegrationTests.swift` verifying that newly launched sessions are immediately written to disk with `wasActiveOnQuit == true`.

- [ ] **Step 2: Run tests to verify they fail**
  - Run: `swift test --filter "WorkspaceManifestTests|AppCoordinatorIntegrationTests"`
  - Expected: FAIL

- [ ] **Step 3: Implement real-time persistence**
  - In `WorkspaceManifest.prune` and `ShellManifest.prune`: only stamp `endedAt = now` on entries where `wasActiveOnQuit == false && endedAt == nil`. Active sessions keep `endedAt == nil`.
  - In `AppCoordinator.launch(...)`: upsert `RestorableSession` with `wasActiveOnQuit: true` immediately.
  - In `AppCoordinator.cleanup(sessionId:)`: mark `wasActiveOnQuit = false` and `endedAt = Date()`.
  - In `ShellCoordinator.launch(...)`: upsert `RestorableShell` with `wasActiveOnQuit: true` immediately.
  - In `ShellCoordinator.stop(id:)`: mark `wasActiveOnQuit = false` and `endedAt = Date()`.
  - In `AppModel`: add `flushStateToDisk()` calling `prepareForShutdown()` on coordinators and writing `LinkCLastSelectedSessionId` to `UserDefaults`.
  - In `StatusPanelController.swift`: call `model.flushStateToDisk()` on `windowWillClose`, `panelVisible = false`, or `windowDidResignKey`.
  - In `AppDelegate.swift`: call `model.flushStateToDisk()` on `applicationDidResignActive`.

- [ ] **Step 4: Run tests to verify they pass**
  - Run: `swift test --filter "WorkspaceManifestTests|AppCoordinatorIntegrationTests"`
  - Expected: PASS

- [ ] **Step 5: Commit and push**
  - Run:
    ```bash
    git add Sources/LinkCKit/App/WorkspaceManifest.swift Sources/LinkCKit/Terminal/ShellManifest.swift Sources/LinkCKit/App/AppCoordinator.swift Sources/LinkCKit/Terminal/ShellCoordinator.swift Sources/linkc/LinkCApp.swift Sources/linkc/StatusPanelController.swift Tests/LinkCKitTests/WorkspaceManifestTests.swift Tests/LinkCKitTests/AppCoordinatorIntegrationTests.swift
    git commit -m "feat(persistence): implement real-time continuous session saving on focus loss and launch"
    git push origin main
    ```

---

### Task 2: OpenAI-Style Shimmer Activity Banner (`TerminalStatusBar`)

**Files:**
- Create: `Sources/linkc/ShimmerHighlight.swift`
- Create: `Sources/linkc/TerminalStatusBar.swift`
- Modify: `Sources/linkc/PanelView.swift`
- Test: `Tests/LinkCKitTests/TerminalSessionAgentTests.swift` (or UI tests)

- [ ] **Step 1: Create `ShimmerHighlight.swift`**
  - Implement `ShimmerHighlightModifier` sweeping a linear gradient mask smoothly across text when `isWorking` is true.
  - Add `.shimmerHighlight(isWorking: Bool)` view extension.

- [ ] **Step 2: Create `TerminalStatusBar.swift`**
  - Build `TerminalStatusBar` displaying:
    - Agent pill (`session.agentKind`).
    - Activity text (`activity` or `"Thinking..."` if working) with `.shimmerHighlight(isWorking: session.state.bucket == .active)`.
    - Integrated subagent micro-chips (replacing old `AgentStrip`).
  - Style with subtle dark glass, matching terminal border radius.

- [ ] **Step 3: Integrate into `PanelView.swift`**
  - Replace `AgentStrip` in `TerminalHero` with `TerminalStatusBar`.
  - Cleanly animate appearance/disappearance with `.transition(.opacity)`.

- [ ] **Step 4: Verify build and test suite**
  - Run: `swift test`
  - Expected: PASS (406+ tests passing, 0 warnings).

- [ ] **Step 5: Commit and push**
  - Run:
    ```bash
    git add Sources/linkc/ShimmerHighlight.swift Sources/linkc/TerminalStatusBar.swift Sources/linkc/PanelView.swift
    git commit -m "feat(ui): add OpenAI-style shimmer activity banner above terminal"
    git push origin main
    ```

---

### Task 3: App Bundle Build & End-to-End Verification

**Files:**
- Target: `dist.noindex/linkC.app`
- Script: `./build-app.sh`

- [ ] **Step 1: Run complete unit test suite**
  - Run: `swift test`
  - Expected: 0 failures, 0 warnings.

- [ ] **Step 2: Build release application bundle**
  - Run: `./build-app.sh`
  - Expected: Clean build and code sign.

- [ ] **Step 3: Verify clean working tree and push**
  - Run: `git status && git push origin main`

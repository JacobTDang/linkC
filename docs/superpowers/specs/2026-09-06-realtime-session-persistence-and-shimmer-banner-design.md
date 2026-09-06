# Real-Time Session Persistence & OpenAI-Style Shimmer Activity Banner

## Overview
1. **Real-Time Session Persistence**: Ensure that linkC saves all live sessions, dev terminals, agent kinds, and tab selections in real-time so that leaving the app (closing the panel, switching workspaces, quitting, killing the process, or updating) never loses active terminals or agents.
2. **OpenAI-Style Shimmer Activity Banner**: Replace the clunky agent strip above the terminal with a sleek, modern `TerminalStatusBar` featuring a clean, luminous highlight sweep loop animation over the active model activity (e.g. `$ swift test`, `Editing file...`, `Searching...`, `Thinking...`), matching the OpenAI working/thinking visual aesthetic.

---

## 1. Real-Time Session Persistence

### 1.1 Immediate Active Flag on Launch
- In `AppCoordinator.launch(...)`:
  - When creating `RestorableSession`: initialize with `wasActiveOnQuit: true` and `endedAt: nil`.
  - Immediately upsert to `manifest` (`workspace.json`).
- In `ShellCoordinator.launch(...)`:
  - When creating `RestorableShell`: initialize with `wasActiveOnQuit: true` and `endedAt: nil`.
  - Immediately upsert to `manifest` (`shells.json`).

### 1.2 Explicit Teardown Demarcation
- When a session terminates naturally (`handleTerminated`) or is stopped by the user (`cleanup(sessionId:)`):
  - Mark `wasActiveOnQuit = false` and `endedAt = Date()`.
  - Update `manifest`.
- When a shell terminates (`stop(id:)` or exit):
  - Mark `wasActiveOnQuit = false` and `endedAt = Date()`.
  - Update `manifest`.

### 1.3 Event-Driven State & Focus Flushing
- In `StatusPanelController`:
  - When `windowWillClose`, `panelVisible = false`, or `windowDidResignKey`:
    - Call `model.flushStateToDisk()` which triggers `coordinator.prepareForShutdown()` and `shells.prepareForShutdown()`.
    - Persist the current `selectedId` immediately into `UserDefaults` (`"LinkCLastSelectedSessionId"`).
- In `AppDelegate`:
  - On `applicationDidResignActive`: trigger `model.flushStateToDisk()`.

### 1.4 Manifest Pruning Safety
- In `WorkspaceManifest.prune` and `ShellManifest.prune`:
  - Retain all entries where `wasActiveOnQuit == true || endedAt == nil`.
  - Do NOT stamp `endedAt = now` on entries marked active.

---

## 2. OpenAI-Style Shimmer Activity Banner (`TerminalStatusBar`)

### 2.1 Component Architecture
- Create `Sources/linkc/TerminalStatusBar.swift`:
  - Placed directly above the `TerminalContainer` in `TerminalHero`.
  - Displays:
    1. Active Agent Engine Pill (`Claude`, `Antigravity`, `Codex`, `Cursor`).
    2. Current Activity Label:
       - Displays `model.currentActivity(session)` (e.g. `$ swift test`, `✎ PanelView.swift`).
       - If `activity == nil` and `session.state == .working`: displays `"Thinking..."`.
       - If subagents are actively executing: displays the active subagent role/description.
    3. Luminous Shimmer Loop Animation (`ShimmerHighlight`):
       - A sweeping linear gradient mask from leading to trailing (`[Color.white.opacity(0.35), Color.white, Color.white.opacity(0.35)]`).
       - Animated via continuous phase progression (`.linear(duration: 1.8).repeatForever(autoreverses: false)`).
    4. Embedded Subagent Micro-Chips:
       - If subagents are present, render them cleanly within the status bar, allowing click-to-read without clunky standalone cards.
  - Visual Styling:
    - Subtle translucent dark glass background (`Color.white.opacity(0.04)`), matching `Theme.terminalRadius`.
    - 1px hairline border (`Color.white.opacity(0.06)`).
    - Smooth opacity transition on appearance/dismissal.

---

## 3. Testing & Verification
- Unit Tests:
  - `WorkspaceManifestTests`: verify sessions created with `wasActiveOnQuit = true` survive reload and prune without `endedAt` being stamped.
  - `AppCoordinatorIntegrationTests`: verify real-time flush and restore without requiring full Cocoa termination.
  - `ShimmerHighlightTests` / UI verification: ensure 0 warnings under Swift 6 strict concurrency.
- Full release build and codesign via `./build-app.sh`.

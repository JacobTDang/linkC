# Persistent Session & Terminal Auto-Restore Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Preserve all active terminals, AI agents (Claude, Antigravity, Codex, Cursor), and shell sessions across updates, reinstalls, and app launches so users never lose their workspace context.

**Architecture:** Extend `RestorableSession` and `RestorableShell` to persist `agentKind` and `wasActiveOnQuit`. Snapshot all active sessions atomically before shutdown/update in `~/Library/Application Support/linkC/`, exempt active sessions from folder-deduplication pruning, and automatically revive all active sessions on app launch with their respective agent engines and working directories.

**Tech Stack:** Swift 6 (`.v6` strict concurrency), AppKit, SwiftTerm, XCTest.

## Global Constraints
- Strict Swift 6 concurrency compliance with 0 warnings.
- All existing and new unit tests must pass (`swift test`).
- Absolutely NO mention of "gemini" anywhere (docs, code, commit messages, or chat; use Antigravity / agy instead).
- Commit and push to `origin/multi-agent-detection` as we go.

---

### Task 1: Data Model Expansion & Manifest Retention

**Files:**
- Modify: `Sources/LinkCKit/App/WorkspaceManifest.swift`
- Modify: `Sources/LinkCKit/Terminal/ShellManifest.swift`
- Test: `Tests/LinkCKitTests/WorkspaceManifestTests.swift`
- Test: `Tests/LinkCKitTests/ShellManifestTests.swift`

**Interfaces:**
- Consumes: `AgentKind`
- Produces: `RestorableSession` with `agentKind: AgentKind` and `wasActiveOnQuit: Bool`; `RestorableShell` with `wasActiveOnQuit: Bool` and `detectedAgent: AgentKind?`; updated `WorkspaceManifest.prune` and `ShellManifest.prune` preserving concurrent active sessions in identical folders.

- [ ] **Step 1: Write failing tests in `WorkspaceManifestTests.swift` and `ShellManifestTests.swift`**
  - Add test for `RestorableSession` backwards compatibility when decoding JSON without `agentKind` or `wasActiveOnQuit`.
  - Add test verifying that two sessions in the same folder with `wasActiveOnQuit == true` are BOTH retained by `WorkspaceManifest.prune`.
  - Add test verifying `RestorableShell` retention with `wasActiveOnQuit == true`.

- [ ] **Step 2: Run tests to verify they fail**
  - Run: `swift test --filter WorkspaceManifestTests`
  - Expected: Compilation error or failure due to missing properties.

- [ ] **Step 3: Implement `agentKind` and `wasActiveOnQuit` in `RestorableSession` and `RestorableShell`**
  - Update `RestorableSession` with custom `Decodable` implementation providing fallbacks (`.claude` and `false`).
  - Update `WorkspaceManifest.prune` to preserve all `wasActiveOnQuit` entries regardless of matching `cwd`.
  - Update `RestorableShell` with custom `Decodable` implementation providing fallbacks.
  - Update `ShellManifest.prune` to preserve all `wasActiveOnQuit` entries regardless of matching `cwd`.

- [ ] **Step 4: Run tests to verify they pass**
  - Run: `swift test --filter "WorkspaceManifestTests|ShellManifestTests"`
  - Expected: PASS

- [ ] **Step 5: Commit and push**
  - Run:
    ```bash
    git add Sources/LinkCKit/App/WorkspaceManifest.swift Sources/LinkCKit/Terminal/ShellManifest.swift Tests/LinkCKitTests/WorkspaceManifestTests.swift Tests/LinkCKitTests/ShellManifestTests.swift
    git commit -m "feat(manifest): add agentKind and wasActiveOnQuit to session manifests"
    git push origin multi-agent-detection
    ```

---

### Task 2: Pre-Termination State Snapshot

**Files:**
- Modify: `Sources/LinkCKit/App/AppCoordinator.swift`
- Modify: `Sources/LinkCKit/Terminal/ShellCoordinator.swift`
- Modify: `Sources/linkc/LinkCApp.swift`
- Test: `Tests/LinkCKitTests/AppCoordinatorTests.swift` (or `AppCoordinatorIntegrationTests.swift`)

**Interfaces:**
- Consumes: `TerminalSession.sampleForegroundAgent()`, `SessionStore.sessions`, `ShellStore.rows`
- Produces: `AppCoordinator.prepareForShutdown()`, `ShellCoordinator.prepareForShutdown()`

- [ ] **Step 1: Write failing test in `AppCoordinatorIntegrationTests.swift`**
  - Add test verifying that when `prepareForShutdown()` is called with active sessions, `WorkspaceManifest` contains entries with `wasActiveOnQuit == true` and their correct `agentKind`.

- [ ] **Step 2: Run test to verify it fails**
  - Run: `swift test --filter AppCoordinatorIntegrationTests`
  - Expected: FAIL (`prepareForShutdown` not defined).

- [ ] **Step 3: Implement `prepareForShutdown()` in `AppCoordinator` and `ShellCoordinator`**
  - In `ShellCoordinator`: add `prepareForShutdown()` that iterates over live running shells, marks them with `wasActiveOnQuit = true`, and saves to `ShellManifest`.
  - In `AppCoordinator`: add `prepareForShutdown()` that snapshots all non-ended sessions in `store.sessions`, samples their live agent kinds, upserts them into `WorkspaceManifest` with `wasActiveOnQuit = true`, calls `shells?.prepareForShutdown()`, saves the selected terminal ID into `UserDefaults`, and flushes manifests.
  - In `LinkCApp.swift`: call `coordinator.prepareForShutdown()` in `AppDelegate.applicationWillTerminate` and in `AppModel.installUpdate()`.

- [ ] **Step 4: Run test to verify it passes**
  - Run: `swift test --filter AppCoordinatorIntegrationTests`
  - Expected: PASS

- [ ] **Step 5: Commit and push**
  - Run:
    ```bash
    git add Sources/LinkCKit/App/AppCoordinator.swift Sources/LinkCKit/Terminal/ShellCoordinator.swift Sources/linkc/LinkCApp.swift Tests/LinkCKitTests/AppCoordinatorIntegrationTests.swift
    git commit -m "feat(lifecycle): snapshot active sessions and dev shells before shutdown and update"
    git push origin multi-agent-detection
    ```

---

### Task 3: Automatic Session Relaunch & Tab Focus on Launch

**Files:**
- Modify: `Sources/LinkCKit/App/AppCoordinator.swift`
- Modify: `Sources/LinkCKit/Terminal/ShellCoordinator.swift`
- Modify: `Sources/linkc/LinkCApp.swift`
- Test: `Tests/LinkCKitTests/AppCoordinatorIntegrationTests.swift`

**Interfaces:**
- Consumes: `WorkspaceManifest.entries`, `ShellManifest.entries`, `UserDefaults`
- Produces: `AppCoordinator.autoRestoreActiveSessions()`

- [ ] **Step 1: Write failing test for auto-restoring active sessions**
  - Test that on `start()`, if `manifest` has sessions with `wasActiveOnQuit == true`, `AppCoordinator` relaunches them with their saved `agentKind`, and resets `wasActiveOnQuit`.

- [ ] **Step 2: Run test to verify it fails**
  - Run: `swift test --filter AppCoordinatorIntegrationTests`
  - Expected: FAIL

- [ ] **Step 3: Implement auto-restoration in `AppCoordinator.start()` and `ShellCoordinator.start()`**
  - In `ShellCoordinator`: add `restoreActiveShells()` to relaunch any shells flagged with `wasActiveOnQuit`.
  - In `AppCoordinator`: during `start()`, filter `manifest.entries` for `wasActiveOnQuit == true`. For each, invoke `launch(cwd: r.cwd, title: r.title, agent: r.agentKind, mode: .continueLast, resumeId: r.claudeSessionId)`. If directory is invalid, catch error and leave in `restorableStore` with `wasActiveOnQuit = false`.
  - Invoke `shells?.restoreActiveShells()`.
  - Read `"LastSelectedSessionId"` from `UserDefaults` and select it if running.

- [ ] **Step 4: Run all unit tests to verify they pass**
  - Run: `swift test`
  - Expected: PASS (all tests passing, 0 warnings).

- [ ] **Step 5: Commit and push**
  - Run:
    ```bash
    git add Sources/LinkCKit/App/AppCoordinator.swift Sources/LinkCKit/Terminal/ShellCoordinator.swift Sources/linkc/LinkCApp.swift Tests/LinkCKitTests/AppCoordinatorIntegrationTests.swift
    git commit -m "feat(restore): auto-relaunch active agent sessions and dev shells on launch"
    git push origin multi-agent-detection
    ```

---

### Task 4: App Bundle Build & End-to-End Verification

**Files:**
- Target: `dist.noindex/linkC.app`
- Script: `./build-app.sh`

- [ ] **Step 1: Run complete test suite**
  - Run: `swift test`
  - Expected: All tests pass with 0 failures and 0 warnings.

- [ ] **Step 2: Build and codesign application bundle**
  - Run: `./build-app.sh`
  - Expected: Clean compilation, packaging, and ad-hoc codesigning into `dist.noindex/linkC.app`.

- [ ] **Step 3: Verify git status and push any remaining changes**
  - Run: `git status && git push origin multi-agent-detection`
  - Expected: Working directory clean, origin up to date.

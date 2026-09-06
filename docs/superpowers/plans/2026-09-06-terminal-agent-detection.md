# Terminal Agent Detection & Autonomous Launch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable linkC to launch and identify any of the 4 major AI CLI agents (Claude, Antigravity/`agy`, Cursor, Codex) with `--yolo` bypass permissions by default, and dynamically detect active agents running in any terminal PTY.

**Architecture:** 
1. A centralized `AgentKind` enum and `AgentDescriptor` registry in `LinkCKit/Core` managing paths, launch modes, `--yolo` flags, and brand styling.
2. A Darwin `libproc`-backed `ProcessSnooper` in `LinkCKit/Terminal` that inspects PTY child processes at 1Hz to dynamically update the active `AgentKind`.
3. An `AgentPill` micro-badge rendered in `HomeCard`, `CompactSessionRow`, and `CompactTerminalRow`.
4. An expanded `LauncherMenu` offering 1-click autonomous launch across all agents.

**Tech Stack:** Swift 6, AppKit, SwiftUI, SwiftTerm, Darwin `libproc`, XCTest.

## Global Constraints
- Target platform: macOS 14+ (arm64/x86_64).
- Strict concurrency (`.v6`) with 0 warnings.
- All existing 369 tests in `LinkCKitTests` must continue to pass without regression.
- Darwin process queries must use non-blocking in-kernel APIs (`proc_listpids` / `proc_pidpath`) with `< 0.1ms` execution overhead.

---

### Task 1: Core Domain Models & Agent Registry (`AgentKind`, `AgentDescriptor`)

**Files:**
- Create: `Sources/LinkCKit/Core/AgentKind.swift`
- Test: `Tests/LinkCKitTests/AgentDescriptorTests.swift`

**Interfaces:**
- Produces:
  - `enum AgentKind: String, Sendable, CaseIterable, Codable` (`claude`, `agy`, `cursor`, `codex`, `shell`)
  - `struct AgentDescriptor: Sendable`
  - `AgentDescriptor.descriptor(for: AgentKind) -> AgentDescriptor`
  - `AgentDescriptor.arguments(for: AgentKind, mode: LaunchMode) -> [String]`
  - `AgentDescriptor.resolveExecutable(for: AgentKind) -> String?`

- [ ] **Step 1: Write failing tests for `AgentKind` and `AgentDescriptor`**
  Create `Tests/LinkCKitTests/AgentDescriptorTests.swift` testing:
  - All 5 enum cases produce correct `pillText` (`CLAUDE`, `AGY`, `CURSOR`, `CODEX`, `SHELL`).
  - `arguments(for: .claude, mode: .new)` includes `["--dangerously-skip-permissions"]`.
  - `arguments(for: .agy, mode: .continueLast)` includes `["--dangerously-skip-permissions", "--continue"]`.
  - `arguments(for: .cursor, mode: .new)` includes `["agent", "--yolo"]`.
  - `arguments(for: .codex, mode: .continueLast)` includes `["--dangerously-bypass-approvals-and-sandbox", "resume", "--last"]`.

- [ ] **Step 2: Run tests and verify failure**
  Run `swift test --filter AgentDescriptorTests` and confirm compilation fails (types not found).

- [ ] **Step 3: Implement `AgentKind` and `AgentDescriptor`**
  Create `Sources/LinkCKit/Core/AgentKind.swift` implementing all cases, candidate paths, and argument mappings.

- [ ] **Step 4: Run tests and verify pass**
  Run `swift test --filter AgentDescriptorTests` and confirm all tests pass.

- [ ] **Step 5: Commit**
  `git add Sources/LinkCKit/Core/AgentKind.swift Tests/LinkCKitTests/AgentDescriptorTests.swift && git commit -m "Add AgentKind and AgentDescriptor domain models with --yolo arguments"`

---

### Task 2: Dynamic Process Snooper (`ProcessSnooper`)

**Files:**
- Create: `Sources/LinkCKit/Terminal/ProcessSnooper.swift`
- Test: `Tests/LinkCKitTests/ProcessSnooperTests.swift`

**Interfaces:**
- Consumes: `AgentKind` from Task 1
- Produces:
  - `struct ProcessSnooper: Sendable`
  - `ProcessSnooper.detectAgent(inPath path: String) -> AgentKind?`
  - `ProcessSnooper.detectAgent(inProcessTreeOf ppid: pid_t) -> AgentKind?`

- [ ] **Step 1: Write failing tests for `ProcessSnooper` path parsing**
  Create `Tests/LinkCKitTests/ProcessSnooperTests.swift` testing:
  - `/opt/homebrew/bin/claude` &rarr; `.claude`
  - `/Users/user/.local/bin/agy` &rarr; `.agy`
  - `/Applications/Cursor.app/Contents/Resources/app/bin/cursor` &rarr; `.cursor`
  - `/opt/homebrew/bin/codex` &rarr; `.codex`
  - `/bin/zsh`, `/usr/bin/git`, `/usr/bin/vim` &rarr; `nil`
  - Real process tree inspection on `getpid()` returns expected shell or test runner.

- [ ] **Step 2: Run tests and verify failure**
  Run `swift test --filter ProcessSnooperTests` and confirm compilation fails.

- [ ] **Step 3: Implement `ProcessSnooper` using Darwin `libproc`**
  Create `Sources/LinkCKit/Terminal/ProcessSnooper.swift` calling Darwin `proc_listpids` with `PROC_PPID_ONLY` and `proc_pidpath`.

- [ ] **Step 4: Run tests and verify pass**
  Run `swift test --filter ProcessSnooperTests` and confirm all tests pass.

- [ ] **Step 5: Commit**
  `git add Sources/LinkCKit/Terminal/ProcessSnooper.swift Tests/LinkCKitTests/ProcessSnooperTests.swift && git commit -m "Add ProcessSnooper with Darwin libproc child process inspection"`

---

### Task 3: TerminalSession & Coordinator Agent Integration

**Files:**
- Modify: `Sources/LinkCKit/Terminal/TerminalSession.swift`
- Modify: `Sources/LinkCKit/Terminal/ShellCoordinator.swift`
- Modify: `Sources/LinkCKit/App/AppCoordinator.swift`
- Test: `Tests/LinkCKitTests/TerminalSessionAgentTests.swift`

**Interfaces:**
- Consumes: `AgentKind`, `AgentDescriptor`, `ProcessSnooper`
- Produces:
  - `TerminalSession.agentKind: AgentKind`
  - `TerminalSession.sampleForegroundAgent()`
  - `AppCoordinator.launch(cwd:agent:mode:)`
  - `ShellRow.detectedAgent: AgentKind?`

- [ ] **Step 1: Write failing tests for `TerminalSession` agent tracking**
  Create `Tests/LinkCKitTests/TerminalSessionAgentTests.swift` verifying:
  - Initial `agentKind` defaults to configured value.
  - `sampleForegroundAgent()` checks `childPid` and updates `agentKind`.

- [ ] **Step 2: Run tests and verify failure**
  Run `swift test --filter TerminalSessionAgentTests` and confirm compilation fails.

- [ ] **Step 3: Implement agent support in `TerminalSession`, `ShellCoordinator`, and `AppCoordinator`**
  - Add `agentKind` property and `sampleForegroundAgent()` to `TerminalSession`.
  - Update `AppCoordinator` to allow launching any `AgentKind` via its descriptor.
  - Update `ShellRow` to expose `detectedAgent: AgentKind?`.

- [ ] **Step 4: Run tests and verify pass**
  Run `swift test` and confirm all 369+ tests pass.

- [ ] **Step 5: Commit**
  `git add Sources/LinkCKit/Terminal/TerminalSession.swift Sources/LinkCKit/Terminal/ShellCoordinator.swift Sources/LinkCKit/App/AppCoordinator.swift Tests/LinkCKitTests/TerminalSessionAgentTests.swift && git commit -m "Wire AgentKind and process sampling into TerminalSession and Coordinators"`

---

### Task 4: UI Components & Row Badges (`AgentPill`, `HomeCard`, `CompactSessionRow`, `CompactTerminalRow`)

**Files:**
- Create: `Sources/linkc/AgentPill.swift`
- Modify: `Sources/linkc/SessionList.swift`

**Interfaces:**
- Consumes: `AgentKind`
- Produces: `struct AgentPill: View`

- [ ] **Step 1: Create `AgentPill` component**
  Create `Sources/linkc/AgentPill.swift` rendering compact pill with branded color tokens:
  - Claude: `#D97757`
  - Antigravity: `#7AA2F7`
  - Cursor: `#00E5FF`
  - Codex: `#10A37F`
  - Shell: `#8E8E93`

- [ ] **Step 2: Integrate `AgentPill` into `HomeCard`**
  In `Sources/linkc/SessionList.swift`, render `AgentPill(agent: session.agentKind)` next to `session.title`.

- [ ] **Step 3: Integrate `AgentPill` into `CompactSessionRow` and `CompactTerminalRow`**
  Render `AgentPill` in the sidebar compact view for both sessions and dev terminals with detected agents.

- [ ] **Step 4: Verify build**
  Run `swift build` to confirm UI compiles cleanly.

- [ ] **Step 5: Commit**
  `git add Sources/linkc/AgentPill.swift Sources/linkc/SessionList.swift && git commit -m "Add AgentPill component and badge session and terminal rows"`

---

### Task 5: Expanded Autonomous Launcher Menu (`LauncherMenu`)

**Files:**
- Modify: `Sources/linkc/PanelView.swift`
- Modify: `Sources/linkc/LinkCApp.swift`

**Interfaces:**
- Consumes: `AgentKind`, `LaunchMode`, `AppCoordinator`
- Produces: Expanded `+` menu and `AppModel.newSession(agent:mode:)`

- [ ] **Step 1: Update `AppModel` to support multi-agent launching**
  In `Sources/linkc/LinkCApp.swift`, update `newSession(agent: AgentKind = .claude, mode: LaunchMode)` to look up the executable and arguments for the specified agent.

- [ ] **Step 2: Expand `LauncherMenu` in `PanelView.swift`**
  Add direct 1-click launch items for Claude, Antigravity (`agy`), Cursor Agent, Codex, and Shell (`zsh`), plus submenus for Continue / Resume.

- [ ] **Step 3: Verify build and test suite**
  Run `swift build` and `swift test` to ensure 0 errors and all tests pass.

- [ ] **Step 4: Commit**
  `git add Sources/linkc/PanelView.swift Sources/linkc/LinkCApp.swift && git commit -m "Expand LauncherMenu with 1-click autonomous launch for all agents"`

---

### Task 6: Full Verification & Integration Smoke Test

- [ ] **Step 1: Run complete test suite**
  Run `swift test` and confirm 100% green tests.
- [ ] **Step 2: Build the app bundle**
  Run `./build-app.sh` to ensure app bundle creates cleanly with code signing and resources.
- [ ] **Step 3: Update documentation and ledger**
  Update `.superpowers/sdd/progress.md` with the completed milestone status.
- [ ] **Step 4: Final commit**
  `git commit -am "Complete Milestone 1: Multi-agent detection and autonomous launch"`

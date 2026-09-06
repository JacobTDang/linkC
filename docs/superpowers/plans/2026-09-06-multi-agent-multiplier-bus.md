# Multi-Agent Multiplier Bus & Shared Context Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Provide an inter-agent shared context bus and multiplier system featuring a file-backed project blackboard (`.linkc/blackboard.json`), a universal stdio MCP server (`linkc-mcp`) auto-registered across Claude, Cursor, Antigravity, and Codex, and macOS UI indicators for active swarms and file collision warnings.

**Architecture:** A thread-safe, process-safe `BlackboardStore` manages advisory file claims and shared notes using atomic files and `flock`. A lightweight pure-Swift MCP stdio server (`linkc-mcp`) exposes tools (`broadcast_intent`, `get_project_context`, `check_conflicts`, `post_note`) over JSON-RPC 2.0. `AppCoordinator` monitors active workspaces for multiple agents, calculating collision states and rendering swarm badges and collision banners in linkC.

**Tech Stack:** Swift 6 (`.v6` strict concurrency), Foundation, Darwin `flock`, JSON-RPC 2.0, SwiftUI, XCTest.

## Global Constraints
- Target platform: macOS 14+ (arm64/x86_64).
- Strict Swift 6 concurrency (`.v6`) with 0 warnings.
- All existing 379 tests must continue to pass without regressions.
- No external runtime dependencies (no Python or Node requirements).
- Atomic file operations and file locks must ensure `.linkc/blackboard.json` cannot be corrupted by concurrent writes.

---

### Task 1: Blackboard Domain Models & Concurrency Locking (`LinkCKit/Blackboard`)

**Files:**
- Create: `Sources/LinkCKit/Blackboard/BlackboardModels.swift`
- Create: `Sources/LinkCKit/Blackboard/BlackboardStore.swift`
- Test: `Tests/LinkCKitTests/BlackboardStoreTests.swift`

**Interfaces:**
- Consumes: `AgentKind`
- Produces:
  - `struct Blackboard: Codable, Sendable`
  - `struct AgentRecord: Codable, Sendable, Identifiable`
  - `struct SharedNote: Codable, Sendable, Identifiable`
  - `struct BlackboardEvent: Codable, Sendable`
  - `struct CollisionWarning: Codable, Sendable, Equatable`
  - `final class BlackboardStore: Sendable`:
    - `init(workspaceRoot: String)`
    - `func load() throws -> Blackboard`
    - `func broadcastIntent(agentKind: AgentKind, pid: pid_t, goal: String, files: [String], status: String) throws -> [CollisionWarning]`
    - `func checkConflicts(files: [String], excludingPid: pid_t?) throws -> [CollisionWarning]`
    - `func postNote(authorAgent: AgentKind, title: String, content: String, tags: [String]) throws -> SharedNote`
    - `func getProjectContext() throws -> Blackboard`
    - `func pruneStale(olderThan: TimeInterval) throws`

- [ ] **Step 1: Write failing tests for `BlackboardStore`**
  Create `Tests/LinkCKitTests/BlackboardStoreTests.swift` covering:
  - Initialization of empty blackboard when `.linkc/blackboard.json` does not exist.
  - Broadcasting intent creates an `AgentRecord` with claimed files and updates `updatedAt`.
  - Collision detection: broadcasting overlapping files from distinct PIDs returns `CollisionWarning`.
  - Broadcasting from the same PID updates the record without self-collision.
  - Heartbeat pruning: records with `lastHeartbeat` older than timeout are pruned.
  - Adding shared notes and retrieving them in project context.

- [ ] **Step 2: Run test to verify failure**
  Run `swift test --filter BlackboardStoreTests` and confirm compilation fails (types not found).

- [ ] **Step 3: Implement `BlackboardModels` and `BlackboardStore`**
  - Implement `BlackboardModels.swift` with `Codable` structs.
  - Implement `BlackboardStore.swift` using `flock(fd, LOCK_EX)` for process-safe mutations, atomic rename via temporary file, and ISO8601 date formatting.

- [ ] **Step 4: Run test to verify pass**
  Run `swift test --filter BlackboardStoreTests` and confirm all tests pass.

- [ ] **Step 5: Commit**
  `git add Sources/LinkCKit/Blackboard/ Tests/LinkCKitTests/BlackboardStoreTests.swift && git commit -m "feat: add BlackboardStore and domain models with atomic file locking"`

---

### Task 2: Pure-Swift JSON-RPC 2.0 MCP Protocol & Server (`LinkCKit/MCP`)

**Files:**
- Create: `Sources/LinkCKit/MCP/MCPProtocol.swift`
- Create: `Sources/LinkCKit/MCP/MCPServer.swift`
- Test: `Tests/LinkCKitTests/MCPServerTests.swift`

**Interfaces:**
- Consumes: `BlackboardStore`, `AgentKind`
- Produces:
  - `struct MCPRequest: Codable, Sendable`
  - `struct MCPResponse: Codable, Sendable`
  - `final class MCPServer: Sendable`:
    - `init(workspaceRoot: String)`
    - `func handleMessage(_ data: Data) -> Data?`
    - Handles `initialize`, `notifications/initialized`, `tools/list`, `tools/call`.

- [ ] **Step 1: Write failing tests for `MCPServer`**
  Create `Tests/LinkCKitTests/MCPServerTests.swift` covering:
  - `initialize` returns protocol version `2024-11-05` and server name `linkc-multiplier`.
  - `tools/list` returns all 4 tools: `linkc_broadcast_intent`, `linkc_get_project_context`, `linkc_check_conflicts`, `linkc_post_note`.
  - `tools/call` for `linkc_broadcast_intent` records the intent in `BlackboardStore` and returns collision info.
  - `tools/call` for `linkc_post_note` records a shared note.
  - `tools/call` for `linkc_check_conflicts` correctly flags collisions.

- [ ] **Step 2: Run test to verify failure**
  Run `swift test --filter MCPServerTests` and confirm compilation fails.

- [ ] **Step 3: Implement `MCPProtocol` and `MCPServer`**
  - Define standard JSON-RPC 2.0 message parsing in `MCPProtocol.swift`.
  - Implement request dispatch and JSON serialization in `MCPServer.swift`.

- [ ] **Step 4: Run test to verify pass**
  Run `swift test --filter MCPServerTests` and confirm all tests pass.

- [ ] **Step 5: Commit**
  `git add Sources/LinkCKit/MCP/ Tests/LinkCKitTests/MCPServerTests.swift && git commit -m "feat: implement pure-Swift MCP JSON-RPC 2.0 server for blackboard tools"`

---

### Task 3: Standalone Executable `linkc-mcp` & Multi-Agent Auto-Registration

**Files:**
- Modify: `Package.swift`
- Create: `Sources/linkc-mcp/main.swift`
- Create: `Sources/LinkCKit/MCP/MCPRegistrar.swift`
- Test: `Tests/LinkCKitTests/MCPRegistrarTests.swift`

**Interfaces:**
- Consumes: `MCPServer`, `AgentDescriptor`
- Produces:
  - Executable target `linkc-mcp`
  - `struct MCPRegistrar: Sendable`:
    - `static func registerAll(binaryPath: String) throws`
    - `static func registerClaude(binaryPath: String) throws`
    - `static func registerCursor(binaryPath: String) throws`
    - `static func registerCodex(binaryPath: String) throws`
    - `static func registerAntigravity(binaryPath: String) throws`

- [ ] **Step 1: Write failing tests for `MCPRegistrar`**
  Create `Tests/LinkCKitTests/MCPRegistrarTests.swift` testing registration JSON merging into temporary test configuration files.

- [ ] **Step 2: Run test to verify failure**
  Run `swift test --filter MCPRegistrarTests` and confirm failure.

- [ ] **Step 3: Implement `MCPRegistrar` and `linkc-mcp/main.swift`**
  - Update `Package.swift` to add `linkc-mcp` executable target.
  - Implement `MCPRegistrar.swift` to safely update agent config files.
  - Implement `main.swift` in `Sources/linkc-mcp`:
    - If `--install` argument passed: run `MCPRegistrar.registerAll()` and exit 0.
    - Otherwise: determine current working directory (or ancestor git root), instantiate `MCPServer`, and run standard I/O loop.

- [ ] **Step 4: Run test and build verification**
  Run `swift test --filter MCPRegistrarTests` and `swift build --product linkc-mcp`.

- [ ] **Step 5: Commit**
  `git add Package.swift Sources/linkc-mcp/ Sources/LinkCKit/MCP/MCPRegistrar.swift Tests/LinkCKitTests/MCPRegistrarTests.swift && git commit -m "feat: add linkc-mcp executable and multi-agent configuration registrar"`

---

### Task 4: AppCoordinator Swarm Detection & Collision Tracking

**Files:**
- Modify: `Sources/LinkCKit/App/AppCoordinator.swift`
- Modify: `Sources/LinkCKit/Core/Domain.swift`
- Test: `Tests/LinkCKitTests/AppCoordinatorSwarmTests.swift`

**Interfaces:**
- Consumes: `BlackboardStore`, `Session`, `ShellRow`
- Produces:
  - `struct ProjectSwarm: Sendable, Identifiable`:
    - `var id: String { workspacePath }`
    - `let workspacePath: String`
    - `let activeAgents: [AgentKind]`
    - `let collisions: [CollisionWarning]`
  - `AppCoordinator.swarms: [ProjectSwarm]`
  - `AppCoordinator.sampleSwarms()`

- [ ] **Step 1: Write failing tests for swarm detection**
  Create `Tests/LinkCKitTests/AppCoordinatorSwarmTests.swift` verifying:
  - When 2 sessions share the same `cwd`, a `ProjectSwarm` is recognized.
  - Overlapping file claims in `BlackboardStore` are populated as active collisions.

- [ ] **Step 2: Run test to verify failure**
  Run `swift test --filter AppCoordinatorSwarmTests` and confirm failure.

- [ ] **Step 3: Implement Swarm Tracking in `AppCoordinator`**
  - Add `ProjectSwarm` to `Domain.swift`.
  - Add `sampleSwarms()` to `AppCoordinator` called during the periodic 1Hz refresh.
  - Auto-run `MCPRegistrar.registerAll()` on coordinator startup.

- [ ] **Step 4: Run test to verify pass**
  Run `swift test --filter AppCoordinatorSwarmTests` and confirm all tests pass.

- [ ] **Step 5: Commit**
  `git add Sources/LinkCKit/App/AppCoordinator.swift Sources/LinkCKit/Core/Domain.swift Tests/LinkCKitTests/AppCoordinatorSwarmTests.swift && git commit -m "feat: add ProjectSwarm detection and collision monitoring in AppCoordinator"`

---

### Task 5: LinkC UI Components (SwarmBadge, CollisionBanner, BlackboardSheet)

**Files:**
- Create: `Sources/linkc/SwarmBadge.swift`
- Create: `Sources/linkc/CollisionBanner.swift`
- Create: `Sources/linkc/BlackboardSheet.swift`
- Modify: `Sources/linkc/SessionList.swift`
- Modify: `Sources/linkc/LinkCApp.swift`

**Interfaces:**
- Consumes: `ProjectSwarm`, `CollisionWarning`, `BlackboardStore`
- Produces:
  - `struct SwarmBadge: View`
  - `struct CollisionBanner: View`
  - `struct BlackboardSheet: View`

- [ ] **Step 1: Implement `SwarmBadge` and `CollisionBanner`**
  - `SwarmBadge`: Displays count of active agents (e.g. `2 AGENTS`) with colored mini-dots/pills for each agent.
  - `CollisionBanner`: Prominent amber warning banner alerting user when overlapping files are claimed: `"⚠️ File collision: Both Claude and Cursor claimed SessionList.swift"`.

- [ ] **Step 2: Implement `BlackboardSheet`**
  - Sheet displaying:
    - Active Peer Agents: PID, Agent name, Goal, Claimed files, Heartbeat.
    - Shared Notes: Titles, authors, timestamps, markdown body.

- [ ] **Step 3: Integrate into `SessionList.swift`**
  - Add `SwarmBadge` and `CollisionBanner` to `HomeCard` and `SessionListColumn`.
  - Add tap gesture on `SwarmBadge` to present `BlackboardSheet`.

- [ ] **Step 4: Verify build**
  Run `swift build` and confirm UI compiles cleanly.

- [ ] **Step 5: Commit**
  `git add Sources/linkc/SwarmBadge.swift Sources/linkc/CollisionBanner.swift Sources/linkc/BlackboardSheet.swift Sources/linkc/SessionList.swift Sources/linkc/LinkCApp.swift && git commit -m "feat(ui): add SwarmBadge, CollisionBanner, and BlackboardSheet to session views"`

---

### Task 6: Verification, End-to-End Test, & App Packaging

- [ ] **Step 1: Run complete test suite**
  Run `swift test` and confirm 100% green tests across all suites.
- [ ] **Step 2: End-to-end integration test of `linkc-mcp`**
  Run a sub-process piping `tools/call` for `linkc_broadcast_intent` and verify JSON response.
- [ ] **Step 3: Build release app bundle**
  Update `build-app.sh` to package and sign `linkc-mcp` alongside `linkc`. Run `./build-app.sh` and verify clean build.
- [ ] **Step 4: Update progress ledger**
  Update `.superpowers/sdd/progress.md` with Milestone 2 completion.
- [ ] **Step 5: Final commit**
  `git commit -am "Complete Milestone 2: Multi-agent multiplier bus and shared context"`

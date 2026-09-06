# Multi-Agent Multiplier Bus & Shared Context Design

**Date:** 2026-09-06  
**Status:** Approved  
**Milestone:** 2 (Inter-Agent Multiplier & Shared Context Bus)

---

## 1. Objective

Enable multiple concurrent AI CLI agents (Claude Code, Antigravity/`agy`, Cursor Agent, Codex) operating on the same project repository to:
1. **Share Context & Intent**: Broadcast active goals, planned file modifications, and discoveries without manual file swapping or user intervention.
2. **Prevent Collisions**: Provide advisory conflict warnings and live collision alerts when multiple agents touch the same files simultaneously.
3. **Leave Shared Notes**: Enable cross-agent handoffs, architectural notes, and test summaries stored in a local project blackboard.
4. **Universal Access via MCP**: Expose a zero-dependency Swift Model Context Protocol (MCP) server (`linkc-mcp`) communicating over stdio and automatically registered across all installed agent CLIs.
5. **Real-Time UI Visibility**: Surface project swarms, active peer agents, and collision warnings directly in the linkC macOS desktop interface.

---

## 2. Architecture & Components

```
┌─────────────────────────────────────────────────────────────┐
│                       AI CLI Agents                         │
│   Claude Code    Antigravity (agy)    Cursor Agent    Codex  │
└───────┬──────────────────┬──────────────────┬───────────┬───┘
        │ stdio (JSON-RPC) │                  │           │
        ▼                  ▼                  ▼           ▼
┌─────────────────────────────────────────────────────────────┐
│                    linkc-mcp (Executable)                   │
│  - JSON-RPC 2.0 stdio framing protocol                      │
│  - Auto-resolves workspace root from cwd / parent PID       │
│  - Tools: broadcast_intent, get_context, check_conflicts... │
└──────────────────────────────┬──────────────────────────────┘
                               │ Swift In-Process Calls
                               ▼
┌─────────────────────────────────────────────────────────────┐
│                 LinkCKit / BlackboardStore                  │
│  - Advisory file locking (flock) + atomic rename            │
│  - Conflict calculation & stale heartbeat expiration        │
│  - Reads / writes <cwd>/.linkc/blackboard.json              │
└──────────────────────────────┬──────────────────────────────┘
                               │ Polled / Observed
                               ▼
┌─────────────────────────────────────────────────────────────┐
│                     linkC macOS Desktop App                 │
│  - Swarm indicator: [2 AGENTS] ([CLAUDE] + [AGY])           │
│  - Amber Collision Warning banner                           │
│  - Interactive Blackboard popover (Peers, Goals, Notes)     │
└─────────────────────────────────────────────────────────────┘
```

### Component 1: `BlackboardStore` (`LinkCKit/Blackboard`)
- Manages `<workspaceRoot>/.linkc/blackboard.json`.
- Automatic creation of `.linkc/` directory with `.gitignore` / git exclusion.
- Advisory file locking via Darwin `flock(fd, LOCK_EX)` with temporary file writing and atomic replace via `rename(2)`.
- Models:
  - `Blackboard`: `version`, `projectPath`, `updatedAt`, `activeAgents`, `sharedNotes`, `recentEvents`.
  - `AgentRecord`: `agentId`, `agentKind`, `pid`, `goal`, `claimedFiles`, `lastHeartbeat`, `status`.
  - `SharedNote`: `id`, `authorAgent`, `title`, `content`, `createdAt`, `tags`.
  - `BlackboardEvent`: `timestamp`, `agentKind`, `action`, `details`.
  - `CollisionWarning`: `agentKind`, `pid`, `conflictingFiles`, `goal`.

### Component 2: `linkc-mcp` CLI Executable
- New executable target in `Package.swift` that links `LinkCKit`.
- Reads and responds to JSON-RPC 2.0 requests over `FileHandle.standardInput` and `FileHandle.standardOutput`.
- Implements MCP core protocol:
  - `initialize`: Returns protocol version `2024-11-05`, server metadata (`linkc-multiplier`, version `0.1.0`), and capabilities (`tools`).
  - `notifications/initialized`: Acknowledged.
  - `tools/list`: Declares 4 tools with JSON Schema parameter definitions.
  - `tools/call`: Routes tool execution to `BlackboardStore`.
- Supports self-registration: `linkc-mcp --install` registers itself in:
  - `~/.claude/claude.json`
  - `~/.cursor/mcp.json`
  - `~/.codex/config.toml` (or `mcp.json`)
  - `~/.gemini/antigravity-cli/mcp.json`

### Component 3: linkC App Coordinator & UI Integration
- `AppCoordinator` monitors open sessions and dev terminals.
- When two or more active sessions have matching normalized `cwd` paths, marks the workspace as a **Project Swarm**.
- Reads `<cwd>/.linkc/blackboard.json` to extract current active claims and detect any file collisions.
- Renders:
  - Swarm badge on session rows: `[2 AGENTS]` with color-coded `AgentPill` icons.
  - Warning banner on sessions if overlapping files are claimed.
  - Quick Blackboard popover to view peer agents, active goals, and shared notes.

---

## 3. Data Schema: `.linkc/blackboard.json`

```json
{
  "version": 1,
  "projectPath": "/Users/jacobdang/projects/linkC",
  "updatedAt": "2026-09-06T17:05:00Z",
  "activeAgents": [
    {
      "agentId": "agent-claude-9182",
      "agentKind": "claude",
      "pid": 19283,
      "goal": "Refactoring SessionList to support multi-column layouts",
      "claimedFiles": [
        "Sources/linkc/SessionList.swift",
        "Sources/linkc/AgentPill.swift"
      ],
      "lastHeartbeat": "2026-09-06T17:04:55Z",
      "status": "working"
    }
  ],
  "sharedNotes": [
    {
      "id": "note-1",
      "authorAgent": "claude",
      "title": "AgentPill Colors",
      "content": "Using coral (#D97757) for Claude and soft blue (#7AA2F7) for Antigravity.",
      "createdAt": "2026-09-06T17:02:00Z",
      "tags": ["design", "tokens"]
    }
  ],
  "recentEvents": [
    {
      "timestamp": "2026-09-06T17:04:55Z",
      "agentKind": "claude",
      "action": "claimed_files",
      "details": "Claimed 2 files for SessionList refactor"
    }
  ]
}
```

---

## 4. MCP Tools Specification

### 1. `linkc_broadcast_intent`
- **Parameters:**
  - `goal` (string, required): Active goal / task description.
  - `files` (string array, optional): Relative file paths the agent plans to touch or create.
  - `status` (string, optional): `"planning"`, `"working"`, `"reviewing"`, `"done"`. Default: `"working"`.
- **Output:**
  - `recorded`: `true`
  - `conflicts`: Array of `CollisionWarning` (empty if no collisions).

### 2. `linkc_get_project_context`
- **Parameters:** None.
- **Output:**
  - `projectPath`: Absolute path to workspace root.
  - `activeAgents`: Array of peer agent descriptors (omits dead/stale agents > 15m).
  - `sharedNotes`: Array of shared architectural notes.
  - `recentEvents`: Last 20 actions.

### 3. `linkc_check_conflicts`
- **Parameters:**
  - `files` (string array, required): Relative file paths to check.
- **Output:**
  - `clean`: Boolean (`true` if 0 conflicts).
  - `conflicts`: Array of `CollisionWarning` with conflicting agent details.

### 4. `linkc_post_note`
- **Parameters:**
  - `title` (string, required): Note headline.
  - `content` (string, required): Note body in markdown.
  - `tags` (string array, optional): Categorical tags.
- **Output:**
  - `noteId`: Unique string ID.
  - `createdAt`: ISO 8601 timestamp.

---

## 5. Testing & Verification Strategy

1. **Unit Tests (`LinkCKitTests`)**:
   - `BlackboardStoreTests`:
     - Test atomic serialization & deserialization.
     - Test concurrent file access simulation.
     - Test stale heartbeat expiration (> 15 minutes marked inactive).
     - Test collision detection when overlapping files are claimed by distinct agents.
     - Test note creation and retrieval.
   - `MCPProtocolTests`:
     - Test JSON-RPC 2.0 request parsing and response generation.
     - Test tool registration listing.
     - Test tool execution routing.
2. **End-to-End Integration Test**:
   - Run `linkc-mcp` via stdio pipe:
     - Send `initialize` request & receive response.
     - Call `tools/call` for `linkc_broadcast_intent`.
     - Spawn second process as peer agent, broadcast overlapping files, and verify collision warning returned.
3. **Build & Package**:
   - Run `swift build` ensuring both `linkc` and `linkc-mcp` compile with 0 warnings.
   - Run `swift test` ensuring all tests pass.
   - Run `./build-app.sh` ensuring app bundle and helper executables build and sign cleanly.

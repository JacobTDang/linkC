# Agent Activity & Contributions Dashboard Design

## 1. Overview & Objectives

In multi-agent swarms (e.g. Claude delegating sub-tasks to Cursor Agent, Agy, and Codex), users need clear visibility into what each agent is saying, what tasks are in-flight or completed, and what concrete code contributions each agent has made to the workspace.

This design introduces the **Agent Activity & Contributions Dashboard** to `linkC`:
1. **Global Activity Screen in the Dock**: A dedicated screen in the trailing navigation dock (`bubble.left.and.text.bubble.right` icon) providing a bird's-eye view across all projects and agents with a live chronological activity stream and agent contribution dossiers.
2. **Project Dashboard Sheet**: An enhanced project-level sheet (upgrading `BlackboardSheet`) triggered from the project card or `SwarmBadge`, detailing inter-agent dialogue, claimed files, file collision checks, and deliverables within that specific repository.

---

## 2. Architecture & Data Models

The dashboard leverages existing process-safe storage primitives (`InboxStore`, `BlackboardStore`, and `TerminalSessionManager`) without duplicating storage or creating desynchronized state.

### 2.1 Core Types (`Sources/LinkCKit/Blackboard/DashboardModels.swift`)

```swift
import Foundation

/// The nature of an agent activity event in the swarm.
public enum AgentActivityKind: String, Codable, Sendable {
    case delegatedTask      // A task assignment was dispatched to another agent
    case completedTask      // A task deliverable/output was completed and returned
    case intentBroadcast    // An agent broadcast its active goal and claimed files
    case sharedNote         // An agent recorded a shared note or handoff memo
    case rateLimited        // An agent encountered a rate limit or cooldown
}

/// A unified, chronological event representing inter-agent communication or action.
public struct AgentActivityItem: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let timestamp: Date
    public let workspacePath: String
    public let projectTitle: String
    public let fromAgent: AgentKind
    public let toAgent: AgentKind?
    public let kind: AgentActivityKind
    public let title: String
    public let body: String
    public let claimedFiles: [String]

    public init(
        id: String = UUID().uuidString,
        timestamp: Date = Date(),
        workspacePath: String,
        projectTitle: String,
        fromAgent: AgentKind,
        toAgent: AgentKind? = nil,
        kind: AgentActivityKind,
        title: String,
        body: String,
        claimedFiles: [String] = []
    ) {
        self.id = id
        self.timestamp = timestamp
        self.workspacePath = workspacePath
        self.projectTitle = projectTitle
        self.fromAgent = fromAgent
        self.toAgent = toAgent
        self.kind = kind
        self.title = title
        self.body = body
        self.claimedFiles = claimedFiles
    }
}

/// Cumulative deliverable and workspace impact summary for a single agent.
public struct AgentContributionDossier: Sendable, Identifiable, Equatable {
    public var id: String { "\(workspacePath)-\(agent.rawValue)" }
    public let agent: AgentKind
    public let workspacePath: String
    public let activeSessionId: String?
    public let status: String                   // "working", "idle", "needs_you"
    public let liveActivity: String?            // e.g. "Generating Auth.swift"
    public let completedTasksCount: Int
    public let claimedFiles: [String]
    public let modifiedFiles: [String]          // Detected from workspace git status
    public let lastDeliverable: String?         // Snippet of last completed output
    public let notesAuthoredCount: Int

    public init(
        agent: AgentKind,
        workspacePath: String,
        activeSessionId: String? = nil,
        status: String = "idle",
        liveActivity: String? = nil,
        completedTasksCount: Int = 0,
        claimedFiles: [String] = [],
        modifiedFiles: [String] = [],
        lastDeliverable: String? = nil,
        notesAuthoredCount: Int = 0
    ) {
        self.agent = agent
        self.workspacePath = workspacePath
        self.activeSessionId = activeSessionId
        self.status = status
        self.liveActivity = liveActivity
        self.completedTasksCount = completedTasksCount
        self.claimedFiles = claimedFiles
        self.modifiedFiles = modifiedFiles
        self.lastDeliverable = lastDeliverable
        self.notesAuthoredCount = notesAuthoredCount
    }
}
```

### 2.2 Aggregation Engine (`Sources/LinkCKit/Blackboard/AgentDashboardAggregator.swift`)

`AgentDashboardAggregator` is a stateless, process-safe reader:
- Reads `.linkc/inbox.json` via `InboxStore`:
  - Enqueued / delivered messages → `.delegatedTask` items with `fromAgent` and `toAgent`.
  - Messages with prefix `[Task Completed by ...]` → `.completedTask` items with deliverable text bodies.
  - Limits → `.rateLimited` items.
- Reads `.linkc/blackboard.json` via `BlackboardStore`:
  - `activeAgents` → active goals, file claims, and heartbeats.
  - `sharedNotes` → `.sharedNote` items.
  - `recentEvents` → `.intentBroadcast` items.
- Reads live terminals via `TerminalSessionManager`:
  - Matches active sessions by workspace and agent kind.
  - Pulls `session.liveActivityLine()` (Braille spinners / active status) and session state (`.working`, `.idle`, `.needsYou`).
- Queries git status (`git status -s`):
  - Identifies modified and unstaged/staged files in the repository.

```swift
public struct ProjectDashboardData: Sendable, Equatable {
    public let workspacePath: String
    public let projectTitle: String
    public let activityItems: [AgentActivityItem]
    public let dossiers: [AgentContributionDossier]
    public let sharedNotes: [SharedNote]
    public let collisions: [CollisionWarning]
}

public struct GlobalDashboardData: Sendable, Equatable {
    public let activityItems: [AgentActivityItem]
    public let dossiers: [AgentContributionDossier]
    public let activeProjectCount: Int
}
```

---

## 3. User Interface & Screen Integration

### 3.1 Navigation Dock Integration (`Sources/linkc/Dock.swift`)
- Add `case activity` to `PanelScreen` in `LinkCKit/Core/Domain.swift`.
- In `Dock.swift`, add a Dock button:
  - Icon: `bubble.left.and.text.bubble.right`
  - Label: `"Agent Activity & Contributions"`
  - Action: `model.open(.activity)`

### 3.2 Global Activity Screen (`Sources/linkc/Screens/ActivityScreen.swift`)
- Rendered inside `ScreenHost` in `PanelView.swift`.
- Features:
  - **ScreenHeader**: `"AGENT ACTIVITY & DASHBOARD"`.
  - **Segmented Filter**: `[Timeline, Agent Dossiers]`.
  - **Timeline Mode**:
    - Chronological list of `AgentActivityItem` cards.
    - Header: `AgentPill(fromAgent) → AgentPill(toAgent)` + Action badge + timestamp (`AgeFormat.compact`).
    - Body: Monospaced preview well for task prompt or completed result.
    - Tags: Claimed files rendered as pill capsules.
  - **Agent Dossiers Mode**:
    - Card per agent with status badge (`Working` with `.smoothShimmer`, `Idle`, `Needs You`).
    - Metrics row: `X tasks completed` · `Y files modified` · `Z files claimed`.
    - Modified files list with git modification indicators.
    - "Focus Terminal" button to immediately jump into that agent's session.

### 3.3 Project Dashboard Sheet (`Sources/linkc/ProjectDashboardSheet.swift`)
- Replaces/enhances `BlackboardSheet.swift`.
- Tapping a project card header or `SwarmBadge` opens `ProjectDashboardSheet(workspacePath:)`.
- Features:
  - Project Title & git branch header.
  - Segmented control: `[Dialogue & Tasks, Contributions & Files, Shared Notes]`.
  - Collision Banner if two agents claim overlapping files.
  - Real-time updates with smooth animations.

---

## 4. Concurrency, Refresh & Error Handling

1. **Non-Blocking Execution**:
   - Disk loads (`flock` reads of inbox/blackboard) and `git status -s` queries run asynchronously off the main thread.
   - Updates are posted to `@MainActor` without stalling UI rendering or terminal input typing.
2. **Reactive & Polling Synchronization**:
   - `AppCoordinator` triggers a reactive refresh upon message delivery, task completion notification, or intent broadcast.
   - When the Activity screen or Project Dashboard sheet is open, a 1.5s gentle timer polls for live updates (terminal spinners and git file touch events).
   - Timer deactivates immediately when the screen or sheet is dismissed (`onDisappear`).
3. **Resilience**:
   - Corrupt or missing `.linkc/*.json` files fall back to clean empty states without throwing or crashing.
   - Non-git folders ignore git commands gracefully.
   - Empty state view guides user when no tasks or agents have run yet.

---

## 5. Testing & Verification

1. **Unit Tests (`Tests/LinkCKitTests/AgentDashboardAggregatorTests.swift`)**:
   - Aggregate empty workspaces → returns valid empty dashboard data.
   - Dispatched tasks → parsed to `.delegatedTask` with correct directional pills.
   - Completed tasks with outputs → parsed to `.completedTask` with output preview.
   - Dossier metrics accurately compute completed count, file modifications, and live status.
   - Chronological sorting (newest first).
2. **Navigation Integration Tests (`Tests/LinkCKitTests/AppModelDashboardTests.swift`)**:
   - Verify `PanelScreen.activity` dock selection and state transitions.
3. **Build & Release**:
   - 0 warnings under Swift 6 strict concurrency (`swift build -Xswiftc -warnings-as-errors`).
   - All 544+ unit and integration tests pass (`swift test`).
   - Production bundle compiled, codesigned, and installed via `./build-app.sh --install`.

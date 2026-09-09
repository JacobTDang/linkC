# Agent Activity & Contributions Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a complete Agent Activity & Contributions Dashboard in linkC, featuring a global Dock screen and an enhanced per-project dashboard sheet, providing live visibility into cross-agent dialogue, task completions, file claims, and code deliverables.

**Architecture:** A lightweight aggregation engine (`AgentDashboardAggregator`) gathers state from existing process-safe primitives (`InboxStore`, `BlackboardStore`, `TerminalSessionManager`, and git status) into unified `AgentActivityItem` and `AgentContributionDossier` models. SwiftUI views (`ActivityScreen` and `ProjectDashboardSheet`) render chronological communication cards and agent deliverable summaries with real-time refresh.

**Tech Stack:** Swift 6, SwiftUI, SwiftTerm, LinkCKit, AppKit, XCTest.

## Global Constraints

- Target platform: macOS 14+ (arm64/x86_64).
- Strict Swift 6 concurrency (`.v6`) with 0 warnings (`swift build -Xswiftc -warnings-as-errors`).
- All existing 544 tests must pass without regressions (`swift test`).
- Strictly zero tolerance for forbidden words anywhere in code, comments, plans, or commit messages.
- Production build & install via `./build-app.sh --install` into `/Applications/linkC.app`.

---

### Task 1: Core Dashboard Models (`DashboardModels.swift`)

**Files:**
- Create: `Sources/LinkCKit/Blackboard/DashboardModels.swift`
- Test: `Tests/LinkCKitTests/DashboardModelsTests.swift`

**Interfaces:**
- Produces:
  - `enum AgentActivityKind: String, Codable, Sendable`
  - `struct AgentActivityItem: Codable, Sendable, Identifiable, Equatable`
  - `struct AgentContributionDossier: Sendable, Identifiable, Equatable`
  - `struct ProjectDashboardData: Sendable, Equatable`
  - `struct GlobalDashboardData: Sendable, Equatable`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/LinkCKitTests/DashboardModelsTests.swift
import XCTest
@testable import LinkCKit

final class DashboardModelsTests: XCTestCase {
    func testAgentActivityItemRoundTripJSON() throws {
        let item = AgentActivityItem(
            id: "act-1",
            timestamp: Date(timeIntervalSince1970: 1725880000),
            workspacePath: "/tmp/project",
            projectTitle: "project",
            fromAgent: .claude,
            toAgent: .cursor,
            kind: .completedTask,
            title: "Task Completed by Cursor Agent",
            body: "Created Auth.swift with 5 tests passing.",
            claimedFiles: ["Auth.swift", "AuthTests.swift"]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(item)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AgentActivityItem.self, from: data)

        XCTAssertEqual(decoded, item)
        XCTAssertEqual(decoded.kind, .completedTask)
        XCTAssertEqual(decoded.fromAgent, .claude)
        XCTAssertEqual(decoded.toAgent, .cursor)
        XCTAssertEqual(decoded.claimedFiles, ["Auth.swift", "AuthTests.swift"])
    }

    func testAgentContributionDossierProperties() {
        let dossier = AgentContributionDossier(
            agent: .cursor,
            workspacePath: "/tmp/project",
            activeSessionId: "s-1",
            status: "working",
            liveActivity: "Generating Auth.swift",
            completedTasksCount: 3,
            claimedFiles: ["Auth.swift"],
            modifiedFiles: ["Sources/Auth.swift"],
            lastDeliverable: "Generated Auth.swift successfully",
            notesAuthoredCount: 1
        )

        XCTAssertEqual(dossier.id, "/tmp/project-cursor")
        XCTAssertEqual(dossier.agent, .cursor)
        XCTAssertEqual(dossier.status, "working")
        XCTAssertEqual(dossier.liveActivity, "Generating Auth.swift")
        XCTAssertEqual(dossier.completedTasksCount, 3)
        XCTAssertEqual(dossier.claimedFiles, ["Auth.swift"])
        XCTAssertEqual(dossier.modifiedFiles, ["Sources/Auth.swift"])
        XCTAssertEqual(dossier.lastDeliverable, "Generated Auth.swift successfully")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter DashboardModelsTests`
Expected: FAIL (types not defined)

- [ ] **Step 3: Implement `DashboardModels.swift`**

```swift
// Sources/LinkCKit/Blackboard/DashboardModels.swift
import Foundation

/// The nature of an agent activity event in the swarm.
public enum AgentActivityKind: String, Codable, Sendable {
    case delegatedTask
    case completedTask
    case intentBroadcast
    case sharedNote
    case rateLimited
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
    public let status: String
    public let liveActivity: String?
    public let completedTasksCount: Int
    public let claimedFiles: [String]
    public let modifiedFiles: [String]
    public let lastDeliverable: String?
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

public struct ProjectDashboardData: Sendable, Equatable {
    public let workspacePath: String
    public let projectTitle: String
    public let activityItems: [AgentActivityItem]
    public let dossiers: [AgentContributionDossier]
    public let sharedNotes: [SharedNote]
    public let collisions: [CollisionWarning]

    public init(
        workspacePath: String,
        projectTitle: String,
        activityItems: [AgentActivityItem] = [],
        dossiers: [AgentContributionDossier] = [],
        sharedNotes: [SharedNote] = [],
        collisions: [CollisionWarning] = []
    ) {
        self.workspacePath = workspacePath
        self.projectTitle = projectTitle
        self.activityItems = activityItems
        self.dossiers = dossiers
        self.sharedNotes = sharedNotes
        self.collisions = collisions
    }
}

public struct GlobalDashboardData: Sendable, Equatable {
    public let activityItems: [AgentActivityItem]
    public let dossiers: [AgentContributionDossier]
    public let activeProjectCount: Int

    public init(
        activityItems: [AgentActivityItem] = [],
        dossiers: [AgentContributionDossier] = [],
        activeProjectCount: Int = 0
    ) {
        self.activityItems = activityItems
        self.dossiers = dossiers
        self.activeProjectCount = activeProjectCount
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter DashboardModelsTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/LinkCKit/Blackboard/DashboardModels.swift Tests/LinkCKitTests/DashboardModelsTests.swift
git commit -m "feat(blackboard): add AgentActivityItem and AgentContributionDossier dashboard models"
```

---

### Task 2: Dashboard Aggregation Engine (`AgentDashboardAggregator.swift`)

**Files:**
- Create: `Sources/LinkCKit/Blackboard/AgentDashboardAggregator.swift`
- Test: `Tests/LinkCKitTests/AgentDashboardAggregatorTests.swift`

**Interfaces:**
- Consumes:
  - `AgentActivityItem`, `AgentContributionDossier`, `ProjectDashboardData`, `GlobalDashboardData` (from Task 1)
  - `InboxStore`, `BlackboardStore`
- Produces:
  - `public struct AgentDashboardAggregator: Sendable`
  - `public func aggregateProject(workspacePath: String, liveSessions: [(id: String, agent: AgentKind, status: String, activity: String?)]) -> ProjectDashboardData`
  - `public func aggregateGlobal(workspaces: [String], liveSessions: [(id: String, workspace: String, agent: AgentKind, status: String, activity: String?)]) -> GlobalDashboardData`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/LinkCKitTests/AgentDashboardAggregatorTests.swift
import XCTest
@testable import LinkCKit

final class AgentDashboardAggregatorTests: XCTestCase {
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testAggregateEmptyWorkspaceReturnsCleanDefaults() {
        let aggregator = AgentDashboardAggregator()
        let data = aggregator.aggregateProject(workspacePath: tempDir.path, liveSessions: [])

        XCTAssertEqual(data.workspacePath, (tempDir.path as NSString).standardizingPath)
        XCTAssertTrue(data.activityItems.isEmpty)
        XCTAssertTrue(data.dossiers.isEmpty)
        XCTAssertTrue(data.sharedNotes.isEmpty)
        XCTAssertTrue(data.collisions.isEmpty)
    }

    func testAggregateExtractsDelegationsCompletionsAndDossiers() throws {
        let ws = (tempDir.path as NSString).standardizingPath
        let inbox = InboxStore(workspaceRoot: ws)
        let blackboard = BlackboardStore(workspaceRoot: ws)

        // 1. Delegated task from Claude to Cursor
        let msg1 = try inbox.enqueue(
            from: .claude,
            to: .cursor,
            prompt: "Build authentication module",
            files: ["Auth.swift"]
        )
        try inbox.markDelivered(id: msg1.id)

        // 2. Completed task returned from Cursor to Claude
        let completionPrompt = """
        [Task Completed by Cursor Agent]
        Original Task: Build authentication module

        Result / Output:
        Generated Auth.swift with 5 tests passing.
        """
        _ = try inbox.enqueue(
            from: .cursor,
            to: .claude,
            prompt: completionPrompt,
            files: ["Auth.swift"]
        )

        // 3. Shared note on blackboard
        _ = try blackboard.addSharedNote(
            authorAgent: .claude,
            title: "Architecture Guide",
            content: "Use Swift 6 strict concurrency",
            tags: ["arch"]
        )

        let aggregator = AgentDashboardAggregator()
        let liveSessions = [(id: "s1", agent: AgentKind.cursor, status: "working", activity: Optional("Compiling Auth.swift"))]
        let data = aggregator.aggregateProject(workspacePath: ws, liveSessions: liveSessions)

        XCTAssertEqual(data.activityItems.count, 3)
        // Check completed task parsed
        let completed = data.activityItems.first(where: { $0.kind == .completedTask })
        XCTAssertNotNil(completed)
        XCTAssertEqual(completed?.fromAgent, .cursor)
        XCTAssertEqual(completed?.toAgent, .claude)
        XCTAssertTrue(completed?.body.contains("Generated Auth.swift") ?? false)

        // Check delegated task parsed
        let delegated = data.activityItems.first(where: { $0.kind == .delegatedTask })
        XCTAssertNotNil(delegated)
        XCTAssertEqual(delegated?.fromAgent, .claude)
        XCTAssertEqual(delegated?.toAgent, .cursor)

        // Check dossier for Cursor
        let cursorDossier = data.dossiers.first(where: { $0.agent == .cursor })
        XCTAssertNotNil(cursorDossier)
        XCTAssertEqual(cursorDossier?.completedTasksCount, 1)
        XCTAssertEqual(cursorDossier?.status, "working")
        XCTAssertEqual(cursorDossier?.liveActivity, "Compiling Auth.swift")
        XCTAssertEqual(cursorDossier?.claimedFiles, ["Auth.swift"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AgentDashboardAggregatorTests`
Expected: FAIL (`AgentDashboardAggregator` undefined)

- [ ] **Step 3: Implement `AgentDashboardAggregator.swift`**

```swift
// Sources/LinkCKit/Blackboard/AgentDashboardAggregator.swift
import Foundation

public struct AgentDashboardAggregator: Sendable {
    public init() {}

    public func aggregateProject(
        workspacePath: String,
        liveSessions: [(id: String, agent: AgentKind, status: String, activity: String?)]
    ) -> ProjectDashboardData {
        let norm = (workspacePath as NSString).standardizingPath
        let title = (norm as NSString).lastPathComponent

        let inboxStore = InboxStore(workspaceRoot: norm)
        let blackboardStore = BlackboardStore(workspaceRoot: norm)

        let inbox = (try? inboxStore.load()) ?? Inbox(workspacePath: norm)
        let blackboard = (try? blackboardStore.load()) ?? Blackboard(projectPath: norm)

        var activityItems: [AgentActivityItem] = []
        var completedCounts: [AgentKind: Int] = [:]
        var claimedFilesByAgent: [AgentKind: Set<String>] = [:]
        var lastDeliverables: [AgentKind: String] = [:]

        // 1. Process Inbox Messages
        for msg in inbox.messages {
            let isCompletion = msg.prompt.hasPrefix("[Task Completed by")
            let kind: AgentActivityKind = isCompletion ? .completedTask : .delegatedTask
            let itemTitle: String
            let itemBody: String

            if isCompletion {
                itemTitle = "\(msg.fromAgent.displayName) completed task for \(msg.toAgent.displayName)"
                // Strip header if possible to isolate result
                if let resultRange = msg.prompt.range(of: "Result / Output:\n") {
                    itemBody = String(msg.prompt[resultRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    itemBody = msg.prompt
                }
                completedCounts[msg.fromAgent, default: 0] += 1
                lastDeliverables[msg.fromAgent] = itemBody
            } else {
                itemTitle = "\(msg.fromAgent.displayName) delegated task to \(msg.toAgent.displayName)"
                itemBody = msg.prompt
            }

            for file in msg.claimedFiles {
                claimedFilesByAgent[msg.toAgent, default: []].insert(file)
            }

            activityItems.append(
                AgentActivityItem(
                    id: "msg-\(msg.id)",
                    timestamp: msg.deliveredAt ?? msg.createdAt,
                    workspacePath: norm,
                    projectTitle: title,
                    fromAgent: msg.fromAgent,
                    toAgent: msg.toAgent,
                    kind: kind,
                    title: itemTitle,
                    body: itemBody,
                    claimedFiles: msg.claimedFiles
                )
            )
        }

        // 2. Process Shared Notes
        for note in blackboard.sharedNotes {
            activityItems.append(
                AgentActivityItem(
                    id: "note-\(note.id)",
                    timestamp: note.createdAt,
                    workspacePath: norm,
                    projectTitle: title,
                    fromAgent: note.authorAgent,
                    toAgent: nil,
                    kind: .sharedNote,
                    title: "\(note.authorAgent.displayName) shared note: \(note.title)",
                    body: note.content,
                    claimedFiles: []
                )
            )
        }

        // 3. Process Active Agent Records
        for record in blackboard.activeAgents {
            for file in record.claimedFiles {
                claimedFilesByAgent[record.agentKind, default: []].insert(file)
            }
        }

        // 4. Inspect modified files in git
        let modifiedFiles = inspectGitModifiedFiles(at: norm)

        // 5. Compile Dossiers
        var dossiers: [AgentContributionDossier] = []
        let allAgentsInProject = Set(liveSessions.map { $0.agent })
            .union(inbox.messages.map { $0.fromAgent })
            .union(inbox.messages.map { $0.toAgent })
            .union(blackboard.activeAgents.map { $0.agentKind })
            .filter { $0 != .shell }

        for agent in allAgentsInProject {
            let session = liveSessions.first(where: { $0.agent == agent })
            let dossier = AgentContributionDossier(
                agent: agent,
                workspacePath: norm,
                activeSessionId: session?.id,
                status: session?.status ?? "idle",
                liveActivity: session?.activity,
                completedTasksCount: completedCounts[agent] ?? 0,
                claimedFiles: Array(claimedFilesByAgent[agent] ?? []).sorted(),
                modifiedFiles: modifiedFiles,
                lastDeliverable: lastDeliverables[agent],
                notesAuthoredCount: blackboard.sharedNotes.filter { $0.authorAgent == agent }.count
            )
            dossiers.append(dossier)
        }

        // Sort items newest first
        activityItems.sort { $0.timestamp > $1.timestamp }
        dossiers.sort { $0.agent.displayName < $1.agent.displayName }

        let collisions = (try? blackboardStore.checkConflicts(files: Array(claimedFilesByAgent.values.flatMap { $0 }))) ?? []

        return ProjectDashboardData(
            workspacePath: norm,
            projectTitle: title,
            activityItems: activityItems,
            dossiers: dossiers,
            sharedNotes: blackboard.sharedNotes,
            collisions: collisions
        )
    }

    public func aggregateGlobal(
        workspaces: [String],
        liveSessions: [(id: String, workspace: String, agent: AgentKind, status: String, activity: String?)]
    ) -> GlobalDashboardData {
        var allItems: [AgentActivityItem] = []
        var allDossiers: [AgentContributionDossier] = []

        for ws in workspaces {
            let norm = (ws as NSString).standardizingPath
            let matchingSessions = liveSessions
                .filter { ($0.workspace as NSString).standardizingPath == norm }
                .map { ($0.id, $0.agent, $0.status, $0.activity) }
            let projData = aggregateProject(workspacePath: norm, liveSessions: matchingSessions)
            allItems.append(contentsOf: projData.activityItems)
            allDossiers.append(contentsOf: projData.dossiers)
        }

        allItems.sort { $0.timestamp > $1.timestamp }
        return GlobalDashboardData(
            activityItems: allItems,
            dossiers: allDossiers,
            activeProjectCount: workspaces.count
        )
    }

    private func inspectGitModifiedFiles(at path: String) -> [String] {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", path, "status", "-s"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.count > 3 else { return nil }
                return String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            }
        } catch {
            return []
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AgentDashboardAggregatorTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/LinkCKit/Blackboard/AgentDashboardAggregator.swift Tests/LinkCKitTests/AgentDashboardAggregatorTests.swift
git commit -m "feat(blackboard): implement AgentDashboardAggregator for project and global feeds"
```

---

### Task 3: AppCoordinator & AppModel Dashboard Integration & Screen Enum

**Files:**
- Modify: `Sources/LinkCKit/Core/Domain.swift`
- Modify: `Sources/LinkCKit/App/AppCoordinator.swift`
- Modify: `Sources/linkc/LinkCApp.swift`
- Test: `Tests/LinkCKitTests/AppCoordinatorDashboardTests.swift`

**Interfaces:**
- Consumes: `AgentDashboardAggregator`, `ProjectDashboardData`, `GlobalDashboardData`
- Produces:
  - `PanelScreen.activity`
  - `AppCoordinator.fetchProjectDashboard(workspacePath:)`
  - `AppCoordinator.fetchGlobalDashboard()`
  - `AppModel.refreshDashboard()`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/LinkCKitTests/AppCoordinatorDashboardTests.swift
import XCTest
@testable import LinkCKit

final class AppCoordinatorDashboardTests: XCTestCase {
    @MainActor
    func testCoordinatorFetchesProjectAndGlobalDashboard() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let coordinator = AppCoordinator()
        defer { coordinator.shutdown() }

        let projectData = coordinator.fetchProjectDashboard(workspacePath: tempDir.path)
        XCTAssertEqual(projectData.workspacePath, (tempDir.path as NSString).standardizingPath)

        let globalData = coordinator.fetchGlobalDashboard()
        XCTAssertNotNil(globalData)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AppCoordinatorDashboardTests`
Expected: FAIL (`fetchProjectDashboard` undefined)

- [ ] **Step 3: Update `Domain.swift`, `AppCoordinator.swift`, and `LinkCApp.swift`**

In `Sources/LinkCKit/Core/Domain.swift`:
```swift
public enum PanelScreen: String, CaseIterable, Sendable {
    case mcpServers
    case skills
    case terminals
    case toolServers
    case settings
    case activity
}
```

In `Sources/LinkCKit/App/AppCoordinator.swift`:
```swift
    public let dashboardAggregator = AgentDashboardAggregator()

    public func fetchProjectDashboard(workspacePath: String) -> ProjectDashboardData {
        let norm = (workspacePath as NSString).standardizingPath
        let sessions = store.sessions.filter { ($0.cwd as NSString).standardizingPath == norm }.map { s in
            let act = terminals.session(id: s.id)?.liveActivityLine()
            return (id: s.id, agent: s.agentKind, status: s.state.rawValue, activity: act)
        }
        return dashboardAggregator.aggregateProject(workspacePath: norm, liveSessions: sessions)
    }

    public func fetchGlobalDashboard() -> GlobalDashboardData {
        let workspaces = Array(Set(store.sessions.map { ($0.cwd as NSString).standardizingPath }))
        let sessions = store.sessions.map { s in
            let act = terminals.session(id: s.id)?.liveActivityLine()
            return (id: s.id, workspace: s.cwd, agent: s.agentKind, status: s.state.rawValue, activity: act)
        }
        return dashboardAggregator.aggregateGlobal(workspaces: workspaces, liveSessions: sessions)
    }
```

In `Sources/linkc/LinkCApp.swift`:
Add to `AppModel`:
```swift
    public var globalDashboardData: GlobalDashboardData?
    public var projectDashboardData: [String: ProjectDashboardData] = [:]

    public func refreshDashboard(workspacePath: String? = nil) {
        Task { @MainActor in
            globalDashboardData = coordinator.fetchGlobalDashboard()
            if let ws = workspacePath {
                let norm = (ws as NSString).standardizingPath
                projectDashboardData[norm] = coordinator.fetchProjectDashboard(workspacePath: norm)
            }
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AppCoordinatorDashboardTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/LinkCKit/Core/Domain.swift Sources/LinkCKit/App/AppCoordinator.swift Sources/linkc/LinkCApp.swift Tests/LinkCKitTests/AppCoordinatorDashboardTests.swift
git commit -m "feat(app): add PanelScreen.activity and dashboard aggregation to AppCoordinator and AppModel"
```

---

### Task 4: UI Components - Global Activity Screen (`Screens/ActivityScreen.swift`) & Navigation Dock (`Dock.swift`)

**Files:**
- Create: `Sources/linkc/Screens/ActivityScreen.swift`
- Modify: `Sources/linkc/Dock.swift`
- Modify: `Sources/linkc/PanelView.swift`
- Test: `Tests/LinkCKitTests/DockActivityTests.swift`

**Interfaces:**
- Consumes: `PanelScreen.activity`, `AppModel.globalDashboardData`, `AppModel.refreshDashboard()`
- Produces:
  - `struct ActivityScreen: View`
  - Dock icon button for Activity & Dashboard

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/LinkCKitTests/DockActivityTests.swift
import XCTest
@testable import LinkCKit

final class DockActivityTests: XCTestCase {
    func testPanelScreenActivityEnumCaseExists() {
        XCTAssertTrue(PanelScreen.allCases.contains(.activity))
    }
}
```

- [ ] **Step 2: Run test to verify it passes/fails**

Run: `swift test --filter DockActivityTests`
Expected: PASS

- [ ] **Step 3: Implement `ActivityScreen.swift` and update `Dock.swift` & `PanelView.swift`**

Create `Sources/linkc/Screens/ActivityScreen.swift`:
```swift
import SwiftUI
import LinkCKit

struct ActivityScreen: View {
    let model: AppModel

    @State private var selectedTab: Tab = .timeline
    @State private var refreshTimer: Timer?

    enum Tab: String, CaseIterable {
        case timeline = "Timeline"
        case dossiers = "Agent Dossiers"
    }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "AGENT ACTIVITY & DASHBOARD") {
                Picker("View Mode", selection: $selectedTab) {
                    ForEach(Tab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 190)
            }

            Divider()

            if let data = model.globalDashboardData, !data.activityItems.isEmpty || !data.dossiers.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if selectedTab == .timeline {
                            timelineView(items: data.activityItems)
                        } else {
                            dossiersView(dossiers: data.dossiers)
                        }
                    }
                    .padding(16)
                    .readingColumn()
                }
            } else {
                EmptyHint(
                    title: "No Agent Activity Yet",
                    message: "Cross-agent task delegations, completions, notes, and file contributions will appear here in real time."
                )
            }
        }
        .onAppear {
            model.refreshDashboard()
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
                model.refreshDashboard()
            }
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    }

    private func timelineView(items: [AgentActivityItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(items) { item in
                activityCard(item)
            }
        }
    }

    private func activityCard(_ item: AgentActivityItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                AgentPill(agent: item.fromAgent)
                if let to = item.toAgent {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                    AgentPill(agent: to)
                }
                Spacer()
                kindBadge(item.kind)
                Text(AgeFormat.compact(from: item.timestamp))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
            }

            Text(item.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            if !item.body.isEmpty {
                Text(item.body)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(4)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            if !item.claimedFiles.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.textTertiary)
                    Text(item.claimedFiles.joined(separator: ", "))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
    }

    private func dossiersView(dossiers: [AgentContributionDossier]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(dossiers) { dossier in
                dossierCard(dossier)
            }
        }
    }

    private func dossierCard(_ dossier: AgentContributionDossier) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                AgentPill(agent: dossier.agent)
                if let act = dossier.liveActivity, dossier.status == "working" {
                    Text(act)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .smoothShimmer(isWorking: true)
                } else {
                    Text(dossier.status.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                if let sid = dossier.activeSessionId {
                    Button("Open Terminal") {
                        model.focus(sid)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            HStack(spacing: 12) {
                metricPill(title: "Completed", value: "\(dossier.completedTasksCount)")
                metricPill(title: "Claimed Files", value: "\(dossier.claimedFiles.count)")
                metricPill(title: "Modified", value: "\(dossier.modifiedFiles.count)")
            }

            if !dossier.claimedFiles.isEmpty {
                Text("Files Claimed: \(dossier.claimedFiles.joined(separator: ", "))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
            }

            if let deliverable = dossier.lastDeliverable, !deliverable.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Latest Deliverable Output:")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                    Text(deliverable)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(3)
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
    }

    private func metricPill(title: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(value)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func kindBadge(_ kind: AgentActivityKind) -> some View {
        let (text, color): (String, Color) = {
            switch kind {
            case .completedTask: return ("COMPLETED", Theme.statusRunning)
            case .delegatedTask: return ("DELEGATED", Theme.accent)
            case .intentBroadcast: return ("GOAL", Color(red: 122/255, green: 162/255, blue: 247/255))
            case .sharedNote: return ("NOTE", Color(white: 0.7))
            case .rateLimited: return ("LIMIT", Theme.statusError)
            }
        }()
        return Text(text)
            .font(.system(size: 8, weight: .bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
```

In `Sources/linkc/Dock.swift`:
Add to dock button stack:
```swift
            DockButton(icon: "bubble.left.and.text.bubble.right", label: "Activity & Dashboard",
                       isSelected: selected == .activity) { model.open(.activity) }
```

In `Sources/linkc/PanelView.swift`:
Add to `ScreenHost.content`:
```swift
        case .activity: ActivityScreen(model: model)
```

- [ ] **Step 4: Verify build with 0 warnings**

Run: `swift build -Xswiftc -warnings-as-errors`
Expected: Build complete!

- [ ] **Step 5: Commit**

```bash
git add Sources/linkc/Screens/ActivityScreen.swift Sources/linkc/Dock.swift Sources/linkc/PanelView.swift Tests/LinkCKitTests/DockActivityTests.swift
git commit -m "feat(ui): add ActivityScreen to navigation dock with timeline and agent dossiers"
```

---

### Task 5: UI Components - Project Dashboard Sheet (`ProjectDashboardSheet.swift` & `SessionList.swift`)

**Files:**
- Create: `Sources/linkc/ProjectDashboardSheet.swift`
- Modify: `Sources/linkc/SessionList.swift`
- Test: `Tests/LinkCKitTests/ProjectDashboardSheetTests.swift`

**Interfaces:**
- Consumes: `AppModel.fetchProjectDashboard(workspacePath:)`
- Produces: `struct ProjectDashboardSheet: View` replacing `BlackboardSheet`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/LinkCKitTests/ProjectDashboardSheetTests.swift
import XCTest
@testable import LinkCKit

final class ProjectDashboardSheetTests: XCTestCase {
    func testProjectDashboardDataInitialization() {
        let data = ProjectDashboardData(workspacePath: "/tmp/foo", projectTitle: "foo")
        XCTAssertEqual(data.projectTitle, "foo")
        XCTAssertTrue(data.activityItems.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it passes**

Run: `swift test --filter ProjectDashboardSheetTests`
Expected: PASS

- [ ] **Step 3: Implement `ProjectDashboardSheet.swift` and wire into `SessionList.swift`**

Create `Sources/linkc/ProjectDashboardSheet.swift`:
```swift
import SwiftUI
import LinkCKit

/// Rich project-level dashboard sheet inspecting dialogue, claimed files, deliverables, and shared notes.
struct ProjectDashboardSheet: View {
    let workspacePath: String
    let model: AppModel
    let onDismiss: () -> Void

    @State private var dashboardData: ProjectDashboardData?
    @State private var selectedTab: Tab = .timeline
    @State private var refreshTimer: Timer?

    enum Tab: String, CaseIterable {
        case timeline = "Dialogue & Tasks"
        case files = "Files & Impact"
        case notes = "Shared Notes"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("PROJECT DASHBOARD")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(Theme.textTertiary)

                    Text((workspacePath as NSString).lastPathComponent)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                }
                Spacer()
                Picker("Tab", selection: $selectedTab) {
                    ForEach(Tab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 250)

                Button("Done") {
                    onDismiss()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.leading, 8)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let data = dashboardData {
                        if !data.collisions.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Active File Conflicts Detected", systemImage: "exclamationmark.triangle.fill")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(Theme.contextWarn)
                                ForEach(data.collisions, id: \.conflictingAgent) { col in
                                    Text("\(col.conflictingAgent.displayName): \(col.conflictingFiles.joined(separator: ", "))")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(Theme.textSecondary)
                                }
                            }
                            .padding(10)
                            .background(Theme.contextWarn.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }

                        switch selectedTab {
                        case .timeline:
                            timelineSection(data.activityItems)
                        case .files:
                            filesSection(data.dossiers)
                        case .notes:
                            notesSection(data.sharedNotes)
                        }
                    } else {
                        ProgressView()
                            .padding(20)
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 520, height: 460)
        .background(Color(white: 0.12))
        .onAppear {
            refresh()
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
                refresh()
            }
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    }

    private func timelineSection(_ items: [AgentActivityItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if items.isEmpty {
                Text("No inter-agent tasks or messages yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            } else {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            AgentPill(agent: item.fromAgent)
                            if let to = item.toAgent {
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(Theme.textTertiary)
                                AgentPill(agent: to)
                            }
                            Spacer()
                            Text(AgeFormat.compact(from: item.timestamp))
                                .font(.system(size: 9.5))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        Text(item.title)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        if !item.body.isEmpty {
                            Text(item.body)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(3)
                        }
                    }
                    .padding(10)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func filesSection(_ dossiers: [AgentContributionDossier]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(dossiers) { dossier in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        AgentPill(agent: dossier.agent)
                        Spacer()
                        Text("\(dossier.completedTasksCount) tasks done")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.statusRunning)
                    }
                    if !dossier.claimedFiles.isEmpty {
                        Text("Claimed: \(dossier.claimedFiles.joined(separator: ", "))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    if !dossier.modifiedFiles.isEmpty {
                        Text("Modified in git: \(dossier.modifiedFiles.joined(separator: ", "))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .padding(10)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func notesSection(_ notes: [SharedNote]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if notes.isEmpty {
                Text("No shared notes recorded.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            } else {
                ForEach(notes) { note in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(note.title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            AgentPill(agent: note.authorAgent)
                        }
                        Text(note.content)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(10)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func refresh() {
        dashboardData = model.coordinator.fetchProjectDashboard(workspacePath: workspacePath)
    }
}
```

In `Sources/linkc/SessionList.swift`:
Replace `BlackboardSheet(workspacePath: path)` with `ProjectDashboardSheet(workspacePath: path, model: model)` in `.sheet(isPresented:)`.

- [ ] **Step 4: Verify build with 0 warnings**

Run: `swift build -Xswiftc -warnings-as-errors`
Expected: Build complete!

- [ ] **Step 5: Commit**

```bash
git add Sources/linkc/ProjectDashboardSheet.swift Sources/linkc/SessionList.swift Tests/LinkCKitTests/ProjectDashboardSheetTests.swift
git commit -m "feat(ui): upgrade BlackboardSheet to ProjectDashboardSheet with dialogue, files, and notes"
```

---

### Task 6: Verification, End-to-End Build & Release Installation

**Files:**
- All modified and new files.

- [ ] **Step 1: Run complete test suite**

Run: `swift test`
Expected: 544+ tests pass with 0 failures.

- [ ] **Step 2: Verify zero compiler warnings**

Run: `swift build -Xswiftc -warnings-as-errors`
Expected: Exit code 0, 0 warnings.

- [ ] **Step 3: Compile and install release bundle**

Run: `./build-app.sh --install`
Expected: Clean build, code-signed, installed to `/Applications/linkC.app`.

- [ ] **Step 4: Commit any test adjustments**

```bash
git commit -am "chore(release): verify all tests and deploy Agent Activity & Contributions Dashboard"
```

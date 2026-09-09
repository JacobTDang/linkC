# Task Protocol v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace terminal-scrape completion and free-form message relaying with an explicit task lifecycle (`TaskRecord`), exclusive file leases, kind-tagged messages that structurally cannot loop, truthful agent identity/heartbeats, and an additive-only MCP tool list.

**Architecture:** `inbox.json` becomes v2 with a `tasks` array alongside `messages`; every write goes through `InboxStore` under one `flock`. `MCPServer` gains task tools (`start/complete/cancel/get/my_tasks`) and resolves caller identity from arg → `LINKC_AGENT` env → ancestor process → error. The `AppCoordinator` relay is split into `expireTasks / dispatchTasks / dispatchMessages / relayTurnEnd` in a new `AppCoordinator+Relay.swift`, never reads terminal output for completion, and never injects `.notice` messages.

**Tech Stack:** Swift 6 / SwiftPM, XCTest, Foundation, CryptoKit (SHA-256), Darwin `proc_pidinfo`. Run tests with `swift test --filter <TestClassName>` from the repo root.

**Spec:** `docs/superpowers/specs/2026-09-09-task-protocol-v2-completion-leases-and-loop-guard-design.md`

## Global Constraints

- Inbox file version becomes `2`; v1 files must decode (missing fields default, `kind` inferred from prefix).
- Task states: `queued, delivered, started, done, failed, cancelled, expired`. Only transitions in spec §5.1 are legal; others throw.
- Lease: `leaseExpiresAt = createdAt + 4h`, refreshed to `now + 4h` on start. Queued tasks expire after 60 min undelivered.
- Frame markers (exact strings): `[linkC task`, `[linkC notice]`, `[Peer Note from`, `[Task Completed by`, `[System Notice]`.
- Message frames composed by the store: `.completion` → `[linkC task <id8>] `, `.notice` → `[linkC notice] `, `.peerNote` → `[Peer Note from <displayName>]: `, `.command` → no frame.
- No tool name, required parameter, or parameter type may be removed or changed. `serverInfo.version` = `0.2.0`; `capabilities.tools = {"listChanged": false}`.
- Identity never defaults to `claude`. Unidentified callers may only use: `linkc_get_project_context`, `linkc_check_conflicts`, `linkc_get_inbox`, `linkc_get_task`, `linkc_get_models`, `linkc_get_usage_status`.
- Terminal output is never read to produce a completion or an echo.
- Another agent is editing `Tests/LinkCKitTests/CursorPtyTests.swift` concurrently; do not touch that file and use `git add <explicit paths>` for every commit.
- One deliberate spec addition (recorded in Task 14): `MessageKind.command` for raw slash-command injection used by `linkc_switch_model` when no in-process switcher exists.

---

## File Structure

| File | Responsibility |
|------|----------------|
| `Sources/LinkCKit/Blackboard/InboxModels.swift` (modify) | `TaskState`, `TaskReport`, `TaskRecord`, `MessageKind`, `LinkCFrame`, `InboxError`, `PendingMessage` (+kind/taskId/contentHash), `Inbox` v2 with tolerant decoding |
| `Sources/LinkCKit/Blackboard/InboxStore.swift` (modify) | Task lifecycle methods, kind-aware `enqueue`, dedupe, frame rejection, `markMessageDelivered` |
| `Sources/LinkCKit/Blackboard/BlackboardStore.swift` (modify) | `heartbeat(agentKind:pid:)` |
| `Sources/LinkCKit/Terminal/ProcessSnooper.swift` (modify) | `parentPid(of:)`, `detectAgent(inAncestorsOf:maxDepth:)` |
| `Sources/LinkCKit/Terminal/TerminalSession.swift` (modify) | `public var processId: pid_t` |
| `Sources/LinkCKit/MCP/MCPServer.swift` (modify) | Identity resolution, heartbeat on call, new task tools, refusal in delegate, v0.2.0 |
| `Sources/LinkCKit/MCP/MCPRegistrar.swift` (modify) | `env` parameter, `LINKC_AGENT` per client |
| `Sources/LinkCKit/App/AppCoordinator.swift` (modify) | Remove relay section; widen 4 members from `private` to internal; call new relay entry points; heartbeat own sessions |
| `Sources/LinkCKit/App/AppCoordinator+Relay.swift` (create) | `processPendingMessages` → `expireTasks`, `dispatchTasks`, `dispatchMessages`; `relayTurnEnd`; `checkLimitsAndReroute`; `resolveHandoffGoal` |
| `Sources/LinkCKit/Blackboard/AgentDashboardAggregator.swift` (modify) | Use `msg.kind`, add task timeline items |
| Tests | `InboxStoreTests`, `InboxTaskLifecycleTests` (new), `MCPServerTests`, `MCPServerTaskTests` (new), `MCPServerIdentityTests` (new), `MCPRegistrarTests`, `ProcessSnooperTests`, `BlackboardStoreTests`, `AppCoordinatorRelayTests`, `AgentDashboardAggregatorTests` |

---

### Task 1: Inbox v2 models and tolerant decoding

**Files:**
- Modify: `Sources/LinkCKit/Blackboard/InboxModels.swift`
- Test: `Tests/LinkCKitTests/InboxStoreTests.swift`

**Interfaces:**
- Produces:
  - `enum TaskState: String, Codable, Sendable` with `var isOpen: Bool` and `func canTransition(to:) -> Bool`
  - `struct TaskReport { status: String; summary: String; commits: [String]; tests: [String] }`
  - `struct TaskRecord` (fields per spec §5.2) with `var shortId: String` (first 8 chars of `id`)
  - `enum MessageKind: String, Codable, Sendable { task, completion, peerNote, notice, command }`
  - `enum LinkCFrame` with marker constants, `beginsWithMarker(_:)`, `inferLegacyKind(prompt:)`, `contentHash(from:to:kind:prompt:)`
  - `enum InboxError: Error, LocalizedError, Equatable` with cases `leaseConflict(holders: [TaskRecord])`, `illegalTransition(taskId: String, from: TaskState, to: TaskState)`, `taskNotFound(String)`, `framedBody`, `hopLimit(Int)`, `kindNotAllowed(MessageKind)`, `missingTaskId`, `emptySummary`
  - `PendingMessage` gains `kind: MessageKind`, `taskId: String?`, `contentHash: String`
  - `Inbox` gains `tasks: [TaskRecord]`; default `version = 2`

- [ ] **Step 1: Write the failing tests**

Append to `Tests/LinkCKitTests/InboxStoreTests.swift` inside the class:

```swift
    func testDecodesV1InboxWithInferredKindsAndEmptyTasks() throws {
        let v1 = """
        {
          "version": 1,
          "workspacePath": "\(tempDir.path)",
          "updatedAt": "2026-09-09T10:00:00Z",
          "agentLimits": [],
          "messages": [
            {"id": "a", "fromAgent": "claude", "toAgent": "codex", "prompt": "Build it", "claimedFiles": [], "status": "queued", "rerouteCount": 0, "createdAt": "2026-09-09T10:00:00Z"},
            {"id": "b", "fromAgent": "codex", "toAgent": "claude", "prompt": "[Task Completed by Codex]\\nOriginal Task: x", "claimedFiles": [], "status": "delivered", "rerouteCount": 0, "createdAt": "2026-09-09T10:00:00Z", "deliveredAt": "2026-09-09T10:01:00Z"},
            {"id": "c", "fromAgent": "codex", "toAgent": "claude", "prompt": "[System Notice] limit", "claimedFiles": [], "status": "queued", "rerouteCount": 0, "createdAt": "2026-09-09T10:00:00Z"},
            {"id": "d", "fromAgent": "cursor", "toAgent": "agy", "prompt": "[Peer Note from Cursor Agent]: hi", "claimedFiles": [], "status": "queued", "rerouteCount": 0, "createdAt": "2026-09-09T10:00:00Z"}
          ]
        }
        """
        let inboxURL = tempDir.appendingPathComponent(".linkc/inbox.json")
        try FileManager.default.createDirectory(at: inboxURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try v1.data(using: .utf8)!.write(to: inboxURL)

        let store = InboxStore(workspaceRoot: tempDir.path)
        let inbox = try store.load()
        XCTAssertTrue(inbox.tasks.isEmpty)
        let byId = Dictionary(uniqueKeysWithValues: inbox.messages.map { ($0.id, $0) })
        XCTAssertEqual(byId["a"]?.kind, .task)
        XCTAssertEqual(byId["b"]?.kind, .completion)
        XCTAssertEqual(byId["c"]?.kind, .notice)
        XCTAssertEqual(byId["d"]?.kind, .peerNote)
        XCTAssertNil(byId["a"]?.taskId)
        XCTAssertEqual(byId["a"]?.contentHash, LinkCFrame.contentHash(from: .claude, to: .codex, kind: .task, prompt: "Build it"))
    }

    func testTaskStateTransitionTable() {
        XCTAssertTrue(TaskState.queued.canTransition(to: .delivered))
        XCTAssertTrue(TaskState.queued.canTransition(to: .cancelled))
        XCTAssertTrue(TaskState.queued.canTransition(to: .expired))
        XCTAssertFalse(TaskState.queued.canTransition(to: .started))
        XCTAssertTrue(TaskState.delivered.canTransition(to: .started))
        XCTAssertTrue(TaskState.delivered.canTransition(to: .done))
        XCTAssertTrue(TaskState.delivered.canTransition(to: .failed))
        XCTAssertTrue(TaskState.started.canTransition(to: .done))
        XCTAssertFalse(TaskState.started.canTransition(to: .delivered))
        for terminal in [TaskState.done, .failed, .cancelled, .expired] {
            for next in [TaskState.queued, .delivered, .started, .done, .failed, .cancelled, .expired] {
                XCTAssertFalse(terminal.canTransition(to: next), "\(terminal) -> \(next) must be illegal")
            }
            XCTAssertFalse(terminal.isOpen)
        }
        XCTAssertTrue(TaskState.queued.isOpen && TaskState.delivered.isOpen && TaskState.started.isOpen)
    }

    func testFrameMarkerDetection() {
        XCTAssertTrue(LinkCFrame.beginsWithMarker("[linkC task 1234abcd] done"))
        XCTAssertTrue(LinkCFrame.beginsWithMarker("  [linkC notice] x"))
        XCTAssertTrue(LinkCFrame.beginsWithMarker("[Peer Note from Codex]: hi"))
        XCTAssertTrue(LinkCFrame.beginsWithMarker("[Task Completed by Codex]"))
        XCTAssertTrue(LinkCFrame.beginsWithMarker("[System Notice] limit"))
        XCTAssertFalse(LinkCFrame.beginsWithMarker("Implement the [linkC task] parser"))
        XCTAssertFalse(LinkCFrame.beginsWithMarker("plain brief"))
    }
```

Also change the assertion in `testEmptyInboxInitializesCleanly` and `testCorruptFileFallbackInitializesCleanInbox` from `XCTAssertEqual(inbox.version, 1)` to `XCTAssertEqual(inbox.version, 2)` and add `XCTAssertTrue(inbox.tasks.isEmpty)` to `testEmptyInboxInitializesCleanly`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter InboxStoreTests 2>&1 | tail -20`
Expected: compile errors — `TaskState`, `LinkCFrame`, `kind`, `tasks` not found.

- [ ] **Step 3: Implement the models**

Replace the whole of `Sources/LinkCKit/Blackboard/InboxModels.swift` with:

```swift
import Foundation
import CryptoKit

// MARK: - Task lifecycle

/// Lifecycle state of a delegated task. See spec §5.1 for the transition table.
public enum TaskState: String, Codable, Sendable, CaseIterable {
    case queued, delivered, started, done, failed, cancelled, expired

    public var isOpen: Bool {
        switch self {
        case .queued, .delivered, .started: return true
        case .done, .failed, .cancelled, .expired: return false
        }
    }

    public func canTransition(to next: TaskState) -> Bool {
        switch (self, next) {
        case (.queued, .delivered), (.queued, .cancelled), (.queued, .expired):
            return true
        case (.delivered, .started), (.delivered, .done), (.delivered, .failed),
             (.delivered, .cancelled), (.delivered, .expired):
            return true
        case (.started, .done), (.started, .failed), (.started, .cancelled), (.started, .expired):
            return true
        default:
            return false
        }
    }
}

/// The assignee's explicit report, supplied through `linkc_complete_task`.
public struct TaskReport: Codable, Sendable, Equatable {
    public let status: String   // "done" | "failed"
    public let summary: String
    public let commits: [String]
    public let tests: [String]

    public init(status: String, summary: String, commits: [String] = [], tests: [String] = []) {
        self.status = status
        self.summary = summary
        self.commits = commits
        self.tests = tests
    }
}

/// A delegated unit of work with exactly one assignee and an exclusive lease on `files`.
public struct TaskRecord: Codable, Sendable, Identifiable, Equatable {
    public static let leaseDuration: TimeInterval = 4 * 3600

    public let id: String
    public let fromAgent: AgentKind
    public let toAgent: AgentKind
    public var assigneeSessionId: String?
    public let prompt: String
    public let files: [String]
    public var state: TaskState
    public let hop: Int
    public let createdAt: Date
    public var deliveredAt: Date?
    public var startedAt: Date?
    public var finishedAt: Date?
    public var leaseExpiresAt: Date
    public var report: TaskReport?
    public var cancelReason: String?
    public var unreportedTurnEndNotified: Bool

    public var shortId: String { String(id.prefix(8)) }

    public init(
        id: String = UUID().uuidString,
        fromAgent: AgentKind,
        toAgent: AgentKind,
        assigneeSessionId: String? = nil,
        prompt: String,
        files: [String] = [],
        state: TaskState = .queued,
        hop: Int = 0,
        createdAt: Date = Date(),
        deliveredAt: Date? = nil,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        leaseExpiresAt: Date? = nil,
        report: TaskReport? = nil,
        cancelReason: String? = nil,
        unreportedTurnEndNotified: Bool = false
    ) {
        self.id = id
        self.fromAgent = fromAgent
        self.toAgent = toAgent
        self.assigneeSessionId = assigneeSessionId
        self.prompt = prompt
        self.files = files
        self.state = state
        self.hop = hop
        self.createdAt = createdAt
        self.deliveredAt = deliveredAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.leaseExpiresAt = leaseExpiresAt ?? createdAt.addingTimeInterval(TaskRecord.leaseDuration)
        self.report = report
        self.cancelReason = cancelReason
        self.unreportedTurnEndNotified = unreportedTurnEndNotified
    }
}

// MARK: - Messages

/// What a message *is*. Only `.completion`, `.peerNote`, `.notice`, `.command` are created by v2;
/// `.task` exists to dispatch legacy v1 rows once after upgrade.
public enum MessageKind: String, Codable, Sendable {
    case task
    case completion
    case peerNote
    case notice
    case command
}

/// Frame markers that identify linkC-generated text. A body beginning with any of these is
/// rejected by `InboxStore` so a forwarded message can never become the body of another.
public enum LinkCFrame {
    public static let taskPrefix = "[linkC task"
    public static let noticePrefix = "[linkC notice]"
    public static let peerNotePrefix = "[Peer Note from"
    public static let legacyCompletionPrefix = "[Task Completed by"
    public static let legacySystemNoticePrefix = "[System Notice]"

    public static let allMarkers: [String] = [
        taskPrefix, noticePrefix, peerNotePrefix, legacyCompletionPrefix, legacySystemNoticePrefix
    ]

    /// True when the first non-whitespace characters of `text` are a marker.
    public static func beginsWithMarker(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return allMarkers.contains { trimmed.hasPrefix($0) }
    }

    /// Kind inference for v1 rows that carry no `kind` field.
    public static func inferLegacyKind(prompt: String) -> MessageKind {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(legacyCompletionPrefix) || trimmed.hasPrefix(taskPrefix) { return .completion }
        if trimmed.hasPrefix(legacySystemNoticePrefix) || trimmed.hasPrefix(noticePrefix) { return .notice }
        if trimmed.hasPrefix(peerNotePrefix) { return .peerNote }
        return .task
    }

    /// SHA-256 hex of `from|to|kind|prompt`; used for 24 h dedupe.
    public static func contentHash(from: AgentKind, to: AgentKind, kind: MessageKind, prompt: String) -> String {
        let material = "\(from.rawValue)|\(to.rawValue)|\(kind.rawValue)|\(prompt)"
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Errors surfaced to callers as tool `isError` results.
public enum InboxError: Error, LocalizedError, Equatable {
    case leaseConflict(holders: [TaskRecord])
    case illegalTransition(taskId: String, from: TaskState, to: TaskState)
    case taskNotFound(String)
    case framedBody
    case hopLimit(Int)
    case kindNotAllowed(MessageKind)
    case missingTaskId
    case emptySummary

    public var errorDescription: String? {
        switch self {
        case .leaseConflict(let holders):
            let list = holders.map { h in
                "\(h.files.joined(separator: ", ")) leased by \(h.toAgent.displayName) under task \(h.shortId) (\(h.state.rawValue))"
            }.joined(separator: "; ")
            return "Refused: \(list). Retry with force: true to override."
        case .illegalTransition(let taskId, let from, let to):
            return "Task \(taskId.prefix(8)) is \(from.rawValue); cannot move to \(to.rawValue)."
        case .taskNotFound(let id):
            return "Task \(id) not found."
        case .framedBody:
            return "Rejected: body begins with a linkC frame marker; forwarded messages cannot be re-sent."
        case .hopLimit(let hop):
            return "Rejected: hop \(hop) exceeds the reroute limit of 2."
        case .kindNotAllowed(let kind):
            return "Rejected: message kind '\(kind.rawValue)' cannot be enqueued directly."
        case .missingTaskId:
            return "Rejected: completion messages require a task id."
        case .emptySummary:
            return "Rejected: summary must not be empty."
        }
    }
}

/// Status of a cross-agent pending message in the inbox queue.
public enum MessageStatus: String, Codable, Sendable {
    case queued
    case delivering
    case delivered
    case failed
}

/// A short message routed to another agent (completion line, peer note, notice, or raw command).
public struct PendingMessage: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public let fromAgent: AgentKind
    public let toAgent: AgentKind
    public let prompt: String
    public let claimedFiles: [String]
    public var status: MessageStatus
    public var rerouteCount: Int
    public let createdAt: Date
    public var deliveredAt: Date?
    public let kind: MessageKind
    public let taskId: String?
    public let contentHash: String

    public init(
        id: String = UUID().uuidString,
        fromAgent: AgentKind,
        toAgent: AgentKind,
        prompt: String,
        claimedFiles: [String] = [],
        status: MessageStatus = .queued,
        rerouteCount: Int = 0,
        createdAt: Date = Date(),
        deliveredAt: Date? = nil,
        kind: MessageKind? = nil,
        taskId: String? = nil,
        contentHash: String? = nil
    ) {
        self.id = id
        self.fromAgent = fromAgent
        self.toAgent = toAgent
        self.prompt = prompt
        self.claimedFiles = claimedFiles
        self.status = status
        self.rerouteCount = rerouteCount
        self.createdAt = createdAt
        self.deliveredAt = deliveredAt
        let resolvedKind = kind ?? LinkCFrame.inferLegacyKind(prompt: prompt)
        self.kind = resolvedKind
        self.taskId = taskId
        self.contentHash = contentHash ?? LinkCFrame.contentHash(from: fromAgent, to: toAgent, kind: resolvedKind, prompt: prompt)
    }

    private enum CodingKeys: String, CodingKey {
        case id, fromAgent, toAgent, prompt, claimedFiles, status, rerouteCount, createdAt, deliveredAt, kind, taskId, contentHash
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fromAgent = try c.decode(AgentKind.self, forKey: .fromAgent)
        let toAgent = try c.decode(AgentKind.self, forKey: .toAgent)
        let prompt = try c.decode(String.self, forKey: .prompt)
        let kind = try c.decodeIfPresent(MessageKind.self, forKey: .kind) ?? LinkCFrame.inferLegacyKind(prompt: prompt)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            fromAgent: fromAgent,
            toAgent: toAgent,
            prompt: prompt,
            claimedFiles: try c.decodeIfPresent([String].self, forKey: .claimedFiles) ?? [],
            status: try c.decode(MessageStatus.self, forKey: .status),
            rerouteCount: try c.decodeIfPresent(Int.self, forKey: .rerouteCount) ?? 0,
            createdAt: try c.decode(Date.self, forKey: .createdAt),
            deliveredAt: try c.decodeIfPresent(Date.self, forKey: .deliveredAt),
            kind: kind,
            taskId: try c.decodeIfPresent(String.self, forKey: .taskId),
            contentHash: try c.decodeIfPresent(String.self, forKey: .contentHash)
                ?? LinkCFrame.contentHash(from: fromAgent, to: toAgent, kind: kind, prompt: prompt)
        )
    }
}

/// Records rate limit or quota exhaustion status for an agent kind.
public struct AgentLimitStatus: Codable, Sendable, Equatable {
    public let agent: AgentKind
    public let reason: String
    public let limitedAt: Date
    public let cooldownExpiresAt: Date

    public init(
        agent: AgentKind,
        reason: String,
        limitedAt: Date = Date(),
        cooldownExpiresAt: Date
    ) {
        self.agent = agent
        self.reason = reason
        self.limitedAt = limitedAt
        self.cooldownExpiresAt = cooldownExpiresAt
    }
}

/// Container stored at `<workspaceRoot>/.linkc/inbox.json`.
public struct Inbox: Codable, Sendable, Equatable {
    public static let currentVersion = 2

    public var version: Int
    public var workspacePath: String
    public var updatedAt: Date
    public var messages: [PendingMessage]
    public var agentLimits: [AgentLimitStatus]
    public var tasks: [TaskRecord]

    public init(
        version: Int = Inbox.currentVersion,
        workspacePath: String,
        updatedAt: Date = Date(),
        messages: [PendingMessage] = [],
        agentLimits: [AgentLimitStatus] = [],
        tasks: [TaskRecord] = []
    ) {
        self.version = version
        self.workspacePath = workspacePath
        self.updatedAt = updatedAt
        self.messages = messages
        self.agentLimits = agentLimits
        self.tasks = tasks
    }

    private enum CodingKeys: String, CodingKey {
        case version, workspacePath, updatedAt, messages, agentLimits, tasks
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            version: Inbox.currentVersion,
            workspacePath: try c.decode(String.self, forKey: .workspacePath),
            updatedAt: try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date(),
            messages: try c.decodeIfPresent([PendingMessage].self, forKey: .messages) ?? [],
            agentLimits: try c.decodeIfPresent([AgentLimitStatus].self, forKey: .agentLimits) ?? [],
            tasks: try c.decodeIfPresent([TaskRecord].self, forKey: .tasks) ?? []
        )
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter InboxStoreTests 2>&1 | tail -20`
Expected: all `InboxStoreTests` PASS (including the three new ones).

- [ ] **Step 5: Commit**

```bash
git add Sources/LinkCKit/Blackboard/InboxModels.swift Tests/LinkCKitTests/InboxStoreTests.swift
git commit -m "feat(inbox): add TaskRecord, MessageKind, frame markers, and tolerant v2 decoding"
```

---

### Task 2: `InboxStore` task lifecycle

**Files:**
- Modify: `Sources/LinkCKit/Blackboard/InboxStore.swift`
- Create: `Tests/LinkCKitTests/InboxTaskLifecycleTests.swift`

**Interfaces:**
- Consumes: Task 1 types.
- Produces (all `throws`, all take `timeout: TimeInterval = 5.0` as last parameter):
  - `createTask(from: AgentKind, to: AgentKind, prompt: String, files: [String], hop: Int = 0, force: Bool = false) -> TaskRecord`
  - `markTaskDelivered(taskId: String, sessionId: String)`
  - `markTaskStarted(taskId: String)`
  - `completeTask(taskId: String, report: TaskReport)`
  - `cancelTask(taskId: String, reason: String)`
  - `expireTask(taskId: String, reason: String)`
  - `markUnreportedTurnEndNotified(taskId: String)`
  - `task(id: String) -> TaskRecord?`
  - `openTasks(for agent: AgentKind? = nil) -> [TaskRecord]` (oldest first; `nil` = all)
  - `leaseHolders(for files: [String], excludingAssignee: AgentKind? = nil) -> [TaskRecord]`

- [ ] **Step 1: Write the failing tests**

Create `Tests/LinkCKitTests/InboxTaskLifecycleTests.swift`:

```swift
import XCTest
@testable import LinkCKit

final class InboxTaskLifecycleTests: XCTestCase {
    var tempDir: URL!
    var store: InboxStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-task-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = InboxStore(workspaceRoot: tempDir.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    func testCreateTaskStoresQueuedRecordWithLease() throws {
        let before = Date()
        let task = try store.createTask(from: .claude, to: .codex, prompt: "Build parser", files: ["Sources/P.swift"])
        XCTAssertEqual(task.state, .queued)
        XCTAssertEqual(task.fromAgent, .claude)
        XCTAssertEqual(task.toAgent, .codex)
        XCTAssertEqual(task.files, ["Sources/P.swift"])
        XCTAssertEqual(task.hop, 0)
        XCTAssertGreaterThanOrEqual(task.leaseExpiresAt.timeIntervalSince(before), TaskRecord.leaseDuration - 1)
        XCTAssertEqual(try store.load().tasks.count, 1)
        XCTAssertEqual(try store.task(id: task.id)?.id, task.id)
    }

    func testCreateTaskIsIdempotentForSameAssigneeAndPrompt() throws {
        let a = try store.createTask(from: .claude, to: .codex, prompt: "Same brief", files: [])
        let b = try store.createTask(from: .claude, to: .codex, prompt: "Same brief", files: [])
        XCTAssertEqual(a.id, b.id)
        XCTAssertEqual(try store.load().tasks.count, 1)
    }

    func testCreateTaskRefusesLeaseConflictAndForceOverrides() throws {
        let holder = try store.createTask(from: .claude, to: .codex, prompt: "Own Auth", files: ["Auth.swift", "Other.swift"])
        XCTAssertThrowsError(try store.createTask(from: .claude, to: .cursor, prompt: "Also Auth", files: ["Auth.swift"])) { error in
            guard case InboxError.leaseConflict(let holders) = error else { return XCTFail("Expected leaseConflict, got \(error)") }
            XCTAssertEqual(holders.map(\.id), [holder.id])
        }
        // Same assignee on the same files queues behind
        XCTAssertNoThrow(try store.createTask(from: .claude, to: .codex, prompt: "More Auth", files: ["Auth.swift"]))
        // force overrides
        let forced = try store.createTask(from: .claude, to: .cursor, prompt: "Also Auth", files: ["Auth.swift"], force: true)
        XCTAssertEqual(forced.toAgent, .cursor)
    }

    func testTerminalTasksReleaseLease() throws {
        let holder = try store.createTask(from: .claude, to: .codex, prompt: "Own Auth", files: ["Auth.swift"])
        try store.cancelTask(taskId: holder.id, reason: "test")
        XCTAssertNoThrow(try store.createTask(from: .claude, to: .cursor, prompt: "Also Auth", files: ["Auth.swift"]))
    }

    func testCreateTaskRejectsFramedPromptAndHopLimit() throws {
        XCTAssertThrowsError(try store.createTask(from: .claude, to: .codex, prompt: "[linkC task abcd1234 from Claude]\nx", files: [])) {
            XCTAssertEqual($0 as? InboxError, .framedBody)
        }
        XCTAssertThrowsError(try store.createTask(from: .claude, to: .codex, prompt: "ok", files: [], hop: 3)) {
            XCTAssertEqual($0 as? InboxError, .hopLimit(3))
        }
    }

    func testHappyPathTransitionsStampDates() throws {
        let task = try store.createTask(from: .claude, to: .codex, prompt: "Do it", files: [])
        try store.markTaskDelivered(taskId: task.id, sessionId: "sess-1")
        var t = try XCTUnwrap(store.task(id: task.id))
        XCTAssertEqual(t.state, .delivered)
        XCTAssertEqual(t.assigneeSessionId, "sess-1")
        XCTAssertNotNil(t.deliveredAt)

        let leaseBefore = t.leaseExpiresAt
        try store.markTaskStarted(taskId: task.id)
        t = try XCTUnwrap(store.task(id: task.id))
        XCTAssertEqual(t.state, .started)
        XCTAssertNotNil(t.startedAt)
        XCTAssertGreaterThanOrEqual(t.leaseExpiresAt, leaseBefore)

        try store.completeTask(taskId: task.id, report: TaskReport(status: "done", summary: "Shipped", commits: ["abc123"], tests: ["swift test"]))
        t = try XCTUnwrap(store.task(id: task.id))
        XCTAssertEqual(t.state, .done)
        XCTAssertEqual(t.report?.summary, "Shipped")
        XCTAssertNotNil(t.finishedAt)
    }

    func testCompleteWithFailedStatusSetsFailedState() throws {
        let task = try store.createTask(from: .claude, to: .codex, prompt: "Do it", files: [])
        try store.markTaskDelivered(taskId: task.id, sessionId: "s")
        try store.completeTask(taskId: task.id, report: TaskReport(status: "failed", summary: "Build broke"))
        XCTAssertEqual(try store.task(id: task.id)?.state, .failed)
    }

    func testIllegalTransitionsThrow() throws {
        let task = try store.createTask(from: .claude, to: .codex, prompt: "Do it", files: [])
        XCTAssertThrowsError(try store.markTaskStarted(taskId: task.id)) {
            XCTAssertEqual($0 as? InboxError, .illegalTransition(taskId: task.id, from: .queued, to: .started))
        }
        try store.cancelTask(taskId: task.id, reason: "nah")
        XCTAssertThrowsError(try store.markTaskDelivered(taskId: task.id, sessionId: "s"))
        XCTAssertThrowsError(try store.completeTask(taskId: task.id, report: TaskReport(status: "done", summary: "x")))
        XCTAssertNil(try store.task(id: "missing"))
        XCTAssertThrowsError(try store.markTaskStarted(taskId: "missing")) {
            XCTAssertEqual($0 as? InboxError, .taskNotFound("missing"))
        }
    }

    func testCompleteRejectsEmptySummary() throws {
        let task = try store.createTask(from: .claude, to: .codex, prompt: "Do it", files: [])
        try store.markTaskDelivered(taskId: task.id, sessionId: "s")
        XCTAssertThrowsError(try store.completeTask(taskId: task.id, report: TaskReport(status: "done", summary: "   "))) {
            XCTAssertEqual($0 as? InboxError, .emptySummary)
        }
    }

    func testOpenTasksFiltersByAssigneeAndOrdersOldestFirst() throws {
        let a = try store.createTask(from: .claude, to: .codex, prompt: "A", files: [])
        let b = try store.createTask(from: .claude, to: .cursor, prompt: "B", files: [])
        let c = try store.createTask(from: .agy, to: .codex, prompt: "C", files: [])
        try store.cancelTask(taskId: b.id, reason: "x")
        XCTAssertEqual(try store.openTasks().map(\.id), [a.id, c.id])
        XCTAssertEqual(try store.openTasks(for: .codex).map(\.id), [a.id, c.id])
        XCTAssertEqual(try store.openTasks(for: .cursor), [])
    }

    func testExpireAndUnreportedFlag() throws {
        let task = try store.createTask(from: .claude, to: .codex, prompt: "Do it", files: [])
        try store.markUnreportedTurnEndNotified(taskId: task.id)
        XCTAssertTrue(try XCTUnwrap(store.task(id: task.id)).unreportedTurnEndNotified)
        try store.expireTask(taskId: task.id, reason: "workspace missing")
        let t = try XCTUnwrap(store.task(id: task.id))
        XCTAssertEqual(t.state, .expired)
        XCTAssertEqual(t.cancelReason, "workspace missing")
    }

    func testTerminalTasksOlderThan24hArePrunedOnSave() throws {
        var inbox = Inbox(workspacePath: tempDir.path)
        let old = Date().addingTimeInterval(-26 * 3600)
        inbox.tasks = [
            TaskRecord(id: "old-done", fromAgent: .claude, toAgent: .codex, prompt: "x", state: .done, createdAt: old, finishedAt: old),
            TaskRecord(id: "old-open", fromAgent: .claude, toAgent: .codex, prompt: "y", state: .started, createdAt: old),
            TaskRecord(id: "new-done", fromAgent: .claude, toAgent: .codex, prompt: "z", state: .done, finishedAt: Date())
        ]
        try store.saveRaw(inbox)
        let ids = Set(try store.load().tasks.map(\.id))
        XCTAssertEqual(ids, ["old-open", "new-done"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter InboxTaskLifecycleTests 2>&1 | tail -20`
Expected: compile errors — `createTask` etc. not found.

- [ ] **Step 3: Implement the lifecycle methods**

In `Sources/LinkCKit/Blackboard/InboxStore.swift`, modify `saveUnlocked` to also prune terminal tasks. Replace the pruning block at the top of `saveUnlocked` with:

```swift
        var prunedInbox = inbox
        let now = Date()
        let cutoff = now.addingTimeInterval(-24 * 3600)
        prunedInbox.messages.removeAll { msg in
            if msg.status == .delivered, let deliveredAt = msg.deliveredAt {
                return deliveredAt < cutoff
            }
            return false
        }
        if prunedInbox.messages.count > 100 {
            prunedInbox.messages = Array(prunedInbox.messages.suffix(100))
        }
        prunedInbox.tasks.removeAll { task in
            guard !task.state.isOpen else { return false }
            return (task.finishedAt ?? task.createdAt) < cutoff
        }
        prunedInbox.version = Inbox.currentVersion
```

Then append these methods before the final closing brace of the class:

```swift
    // MARK: - Task lifecycle

    /// Creates a queued task with an exclusive lease on `files`. Refuses when another assignee
    /// holds an open lease on any of the files unless `force`. Idempotent for identical `to`+`prompt`.
    public func createTask(
        from: AgentKind,
        to: AgentKind,
        prompt: String,
        files: [String],
        hop: Int = 0,
        force: Bool = false,
        timeout: TimeInterval = 5.0
    ) throws -> TaskRecord {
        guard hop <= 2 else { throw InboxError.hopLimit(hop) }
        guard !LinkCFrame.beginsWithMarker(prompt) else { throw InboxError.framedBody }

        return try withFileLock(timeout: timeout) {
            var inbox = try loadUnlocked()
            let normalized = files.map { ($0 as NSString).standardizingPath }

            if let existing = inbox.tasks.first(where: { $0.state.isOpen && $0.toAgent == to && $0.prompt == prompt }) {
                return existing
            }

            if !force && !normalized.isEmpty {
                let holders = inbox.tasks.filter { other in
                    other.state.isOpen && other.toAgent != to && !Set(other.files).isDisjoint(with: normalized)
                }
                if !holders.isEmpty { throw InboxError.leaseConflict(holders: holders) }
            }

            let task = TaskRecord(fromAgent: from, toAgent: to, prompt: prompt, files: normalized, hop: hop)
            inbox.tasks.append(task)
            inbox.updatedAt = Date()
            try saveUnlocked(inbox)
            return task
        }
    }

    public func task(id: String, timeout: TimeInterval = 5.0) throws -> TaskRecord? {
        try withFileLock(timeout: timeout) {
            try loadUnlocked().tasks.first { $0.id == id }
        }
    }

    /// Open tasks, oldest first. `agent == nil` returns all; otherwise tasks assigned to `agent`.
    public func openTasks(for agent: AgentKind? = nil, timeout: TimeInterval = 5.0) throws -> [TaskRecord] {
        try withFileLock(timeout: timeout) {
            try loadUnlocked().tasks
                .filter { $0.state.isOpen && (agent == nil || $0.toAgent == agent) }
                .sorted { $0.createdAt < $1.createdAt }
        }
    }

    /// Open tasks whose lease overlaps `files`, optionally ignoring a given assignee.
    public func leaseHolders(for files: [String], excludingAssignee: AgentKind? = nil, timeout: TimeInterval = 5.0) throws -> [TaskRecord] {
        let normalized = Set(files.map { ($0 as NSString).standardizingPath })
        return try withFileLock(timeout: timeout) {
            try loadUnlocked().tasks.filter { task in
                task.state.isOpen
                    && (excludingAssignee == nil || task.toAgent != excludingAssignee)
                    && !Set(task.files).isDisjoint(with: normalized)
            }
        }
    }

    public func markTaskDelivered(taskId: String, sessionId: String, timeout: TimeInterval = 5.0) throws {
        try transition(taskId: taskId, to: .delivered, timeout: timeout) { task in
            task.assigneeSessionId = sessionId
            task.deliveredAt = Date()
        }
    }

    public func markTaskStarted(taskId: String, timeout: TimeInterval = 5.0) throws {
        try transition(taskId: taskId, to: .started, timeout: timeout) { task in
            let now = Date()
            task.startedAt = now
            task.leaseExpiresAt = now.addingTimeInterval(TaskRecord.leaseDuration)
        }
    }

    public func completeTask(taskId: String, report: TaskReport, timeout: TimeInterval = 5.0) throws {
        guard !report.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw InboxError.emptySummary
        }
        let target: TaskState = report.status == "failed" ? .failed : .done
        try transition(taskId: taskId, to: target, timeout: timeout) { task in
            task.report = report
            task.finishedAt = Date()
        }
    }

    public func cancelTask(taskId: String, reason: String, timeout: TimeInterval = 5.0) throws {
        try transition(taskId: taskId, to: .cancelled, timeout: timeout) { task in
            task.cancelReason = reason
            task.finishedAt = Date()
        }
    }

    public func expireTask(taskId: String, reason: String, timeout: TimeInterval = 5.0) throws {
        try transition(taskId: taskId, to: .expired, timeout: timeout) { task in
            task.cancelReason = reason
            task.finishedAt = Date()
        }
    }

    public func markUnreportedTurnEndNotified(taskId: String, timeout: TimeInterval = 5.0) throws {
        try withFileLock(timeout: timeout) {
            var inbox = try loadUnlocked()
            guard let idx = inbox.tasks.firstIndex(where: { $0.id == taskId }) else {
                throw InboxError.taskNotFound(taskId)
            }
            inbox.tasks[idx].unreportedTurnEndNotified = true
            inbox.updatedAt = Date()
            try saveUnlocked(inbox)
        }
    }

    private func transition(
        taskId: String,
        to next: TaskState,
        timeout: TimeInterval,
        mutate: (inout TaskRecord) -> Void
    ) throws {
        try withFileLock(timeout: timeout) {
            var inbox = try loadUnlocked()
            guard let idx = inbox.tasks.firstIndex(where: { $0.id == taskId }) else {
                throw InboxError.taskNotFound(taskId)
            }
            let current = inbox.tasks[idx].state
            guard current.canTransition(to: next) else {
                throw InboxError.illegalTransition(taskId: taskId, from: current, to: next)
            }
            inbox.tasks[idx].state = next
            mutate(&inbox.tasks[idx])
            inbox.updatedAt = Date()
            try saveUnlocked(inbox)
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter "InboxTaskLifecycleTests|InboxStoreTests" 2>&1 | tail -20`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LinkCKit/Blackboard/InboxStore.swift Tests/LinkCKitTests/InboxTaskLifecycleTests.swift
git commit -m "feat(inbox): task lifecycle with validated transitions, exclusive leases, and pruning"
```

---

### Task 3: Kind-aware `enqueue`, dedupe, frame rejection, `markMessageDelivered`

**Files:**
- Modify: `Sources/LinkCKit/Blackboard/InboxStore.swift`
- Modify (rename call sites `markDelivered` → `markMessageDelivered`): `Sources/LinkCKit/App/AppCoordinator.swift:748`, `Tests/LinkCKitTests/InboxStoreTests.swift`, `Tests/LinkCKitTests/AppCoordinatorRelayTests.swift`, `Tests/LinkCKitTests/AgentDashboardAggregatorTests.swift`
- Test: `Tests/LinkCKitTests/InboxStoreTests.swift`

**Interfaces:**
- Produces:
  - `enqueue(from: AgentKind, to: AgentKind, kind: MessageKind, taskId: String? = nil, body: String, timeout:) throws -> PendingMessage` — composes `prompt = frame + body`.
  - `markMessageDelivered(id: String, timeout:) throws` (renamed from `markDelivered`).
  - The legacy `enqueue(from:to:prompt:files:rerouteCount:timeout:)` is kept **unchanged** until Task 14 so intermediate tasks compile; it is annotated `@available(*, deprecated, message: "v1 task messages; use createTask or enqueue(kind:)")`.

- [ ] **Step 1: Write the failing tests**

Append to `InboxStoreTests`:

```swift
    func testKindAwareEnqueueComposesFrames() throws {
        let store = InboxStore(workspaceRoot: tempDir.path)
        let completion = try store.enqueue(from: .codex, to: .claude, kind: .completion, taskId: "abcdef12-3456", body: "done by Codex — shipped")
        XCTAssertEqual(completion.prompt, "[linkC task abcdef12] done by Codex — shipped")
        XCTAssertEqual(completion.kind, .completion)
        XCTAssertEqual(completion.taskId, "abcdef12-3456")

        let note = try store.enqueue(from: .cursor, to: .agy, kind: .peerNote, body: "heads up")
        XCTAssertEqual(note.prompt, "[Peer Note from Cursor Agent]: heads up")

        let notice = try store.enqueue(from: .codex, to: .claude, kind: .notice, body: "Codex is rate limited")
        XCTAssertEqual(notice.prompt, "[linkC notice] Codex is rate limited")

        let cmd = try store.enqueue(from: .claude, to: .claude, kind: .command, body: "/model sonnet")
        XCTAssertEqual(cmd.prompt, "/model sonnet")
    }

    func testEnqueueRejectsFramedBodiesTaskKindAndMissingTaskId() throws {
        let store = InboxStore(workspaceRoot: tempDir.path)
        XCTAssertThrowsError(try store.enqueue(from: .codex, to: .claude, kind: .peerNote, body: "[linkC task 1234abcd] echo")) {
            XCTAssertEqual($0 as? InboxError, .framedBody)
        }
        XCTAssertThrowsError(try store.enqueue(from: .codex, to: .claude, kind: .peerNote, body: "[Task Completed by Codex]\nOriginal Task: x")) {
            XCTAssertEqual($0 as? InboxError, .framedBody)
        }
        XCTAssertThrowsError(try store.enqueue(from: .codex, to: .claude, kind: .task, body: "brief")) {
            XCTAssertEqual($0 as? InboxError, .kindNotAllowed(.task))
        }
        XCTAssertThrowsError(try store.enqueue(from: .codex, to: .claude, kind: .completion, body: "done")) {
            XCTAssertEqual($0 as? InboxError, .missingTaskId)
        }
        XCTAssertTrue(try store.load().messages.isEmpty)
    }

    func testEnqueueDedupesIdenticalContentWithin24h() throws {
        let store = InboxStore(workspaceRoot: tempDir.path)
        let a = try store.enqueue(from: .codex, to: .claude, kind: .peerNote, body: "same")
        let b = try store.enqueue(from: .codex, to: .claude, kind: .peerNote, body: "same")
        XCTAssertEqual(a.id, b.id)
        XCTAssertEqual(try store.load().messages.count, 1)
        // Different recipient is not a duplicate
        _ = try store.enqueue(from: .codex, to: .cursor, kind: .peerNote, body: "same")
        XCTAssertEqual(try store.load().messages.count, 2)
    }
```

Also, in `testMarkDeliveredTransitionsStatusAndStampsDeliveredAt`, rename the two `store.markDelivered(id:` calls to `store.markMessageDelivered(id:`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter InboxStoreTests 2>&1 | tail -20`
Expected: compile errors — no `enqueue(kind:)`, no `markMessageDelivered`.

- [ ] **Step 3: Implement**

In `InboxStore.swift`:

1. Annotate the existing legacy method:

```swift
    /// Legacy v1 task message. Kept only until every caller migrates to `createTask` / `enqueue(kind:)`.
    @available(*, deprecated, message: "v1 task messages; use createTask or enqueue(kind:)")
    public func enqueue(
        from: AgentKind,
        to: AgentKind,
        prompt: String,
        files: [String] = [],
        rerouteCount: Int = 0,
        timeout: TimeInterval = 5.0
    ) throws -> PendingMessage {
```

(body unchanged).

2. Rename `markDelivered(id:timeout:)` to `markMessageDelivered(id:timeout:)` (same body).

3. Add the new enqueue after the legacy one:

```swift
    /// Enqueues a short, kind-tagged message. The store composes the frame; callers pass the bare body.
    /// Rejects framed bodies (loop guard), `.task` kind, completions without a task id, and 24 h duplicates.
    public func enqueue(
        from: AgentKind,
        to: AgentKind,
        kind: MessageKind,
        taskId: String? = nil,
        body: String,
        timeout: TimeInterval = 5.0
    ) throws -> PendingMessage {
        guard kind != .task else { throw InboxError.kindNotAllowed(.task) }
        guard !LinkCFrame.beginsWithMarker(body) else { throw InboxError.framedBody }

        let prompt: String
        switch kind {
        case .completion:
            guard let taskId else { throw InboxError.missingTaskId }
            prompt = "\(LinkCFrame.taskPrefix) \(taskId.prefix(8))] \(body)"
        case .notice:
            prompt = "\(LinkCFrame.noticePrefix) \(body)"
        case .peerNote:
            prompt = "\(LinkCFrame.peerNotePrefix) \(from.displayName)]: \(body)"
        case .command:
            prompt = body
        case .task:
            throw InboxError.kindNotAllowed(.task)
        }

        let hash = LinkCFrame.contentHash(from: from, to: to, kind: kind, prompt: prompt)
        return try withFileLock(timeout: timeout) {
            var inbox = try loadUnlocked()
            let dedupeCutoff = Date().addingTimeInterval(-24 * 3600)
            if let existing = inbox.messages.first(where: {
                $0.contentHash == hash && $0.fromAgent == from && $0.toAgent == to && $0.createdAt >= dedupeCutoff
            }) {
                return existing
            }
            let message = PendingMessage(
                fromAgent: from,
                toAgent: to,
                prompt: prompt,
                claimedFiles: [],
                status: .queued,
                kind: kind,
                taskId: taskId,
                contentHash: hash
            )
            inbox.messages.append(message)
            inbox.updatedAt = Date()
            try saveUnlocked(inbox)
            return message
        }
    }
```

4. Rename call sites: in `Sources/LinkCKit/App/AppCoordinator.swift` line ~748 `try? inboxStore.markDelivered(id: message.id)` → `try? inboxStore.markMessageDelivered(id: message.id)`; in `Tests/LinkCKitTests/AppCoordinatorRelayTests.swift` and `Tests/LinkCKitTests/AgentDashboardAggregatorTests.swift` replace every `inbox.markDelivered(id:` with `inbox.markMessageDelivered(id:`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift build --build-tests 2>&1 | rg -n "error:" ; swift test --filter "InboxStoreTests|InboxTaskLifecycleTests" 2>&1 | tail -20`
Expected: no `error:` lines (deprecation warnings are fine); tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LinkCKit/Blackboard/InboxStore.swift Sources/LinkCKit/App/AppCoordinator.swift Tests/LinkCKitTests/InboxStoreTests.swift Tests/LinkCKitTests/AppCoordinatorRelayTests.swift Tests/LinkCKitTests/AgentDashboardAggregatorTests.swift
git commit -m "feat(inbox): kind-aware enqueue with frame composition, loop guard, and 24h dedupe"
```

---

### Task 4: Process ancestry and blackboard heartbeat

**Files:**
- Modify: `Sources/LinkCKit/Terminal/ProcessSnooper.swift`
- Modify: `Sources/LinkCKit/Blackboard/BlackboardStore.swift`
- Modify: `Sources/LinkCKit/Terminal/TerminalSession.swift` (add `processId`)
- Test: `Tests/LinkCKitTests/ProcessSnooperTests.swift`, `Tests/LinkCKitTests/BlackboardStoreTests.swift`

**Interfaces:**
- Produces:
  - `ProcessSnooper.parentPid(of pid: pid_t) -> pid_t?`
  - `ProcessSnooper.detectAgent(inAncestorsOf pid: pid_t, maxDepth: Int = 8) -> (agent: AgentKind, pid: pid_t)?`
  - `BlackboardStore.heartbeat(agentKind: AgentKind, pid: pid_t, timeout:) throws`
  - `TerminalSession.processId: pid_t` (read-only, `-1` before spawn)

- [ ] **Step 1: Write the failing tests**

Append to `ProcessSnooperTests`:

```swift
    func testParentPidOfSelfMatchesGetppid() {
        XCTAssertEqual(ProcessSnooper.parentPid(of: getpid()), getppid())
        XCTAssertNil(ProcessSnooper.parentPid(of: -1))
    }

    func testDetectAgentInAncestorsRespectsDepthAndInvalidPid() {
        XCTAssertNil(ProcessSnooper.detectAgent(inAncestorsOf: -1))
        XCTAssertNil(ProcessSnooper.detectAgent(inAncestorsOf: getpid(), maxDepth: 0))
        // With a real depth this either finds a CLI (when run inside one) or returns nil; it must not crash.
        _ = ProcessSnooper.detectAgent(inAncestorsOf: getpid())
    }
```

Append to `BlackboardStoreTests` (inside the class; it already has a `tempDir` fixture — if the fixture property is named differently, use that name):

```swift
    func testHeartbeatInsertsIdleRecordAndRefreshesWithoutOverwritingGoal() throws {
        let store = BlackboardStore(workspaceRoot: tempDir.path)
        try store.heartbeat(agentKind: .cursor, pid: 4242)
        var board = try store.load()
        let inserted = try XCTUnwrap(board.activeAgents.first { $0.pid == 4242 })
        XCTAssertEqual(inserted.agentKind, .cursor)
        XCTAssertEqual(inserted.goal, "(idle)")
        XCTAssertEqual(inserted.status, "active")
        XCTAssertTrue(inserted.claimedFiles.isEmpty)

        _ = try store.broadcastIntent(agentKind: .cursor, pid: 4242, goal: "Real goal", files: ["A.swift"])
        let before = try XCTUnwrap(try store.load().activeAgents.first { $0.pid == 4242 }).lastHeartbeat
        try store.heartbeat(agentKind: .cursor, pid: 4242)
        board = try store.load()
        let refreshed = try XCTUnwrap(board.activeAgents.first { $0.pid == 4242 })
        XCTAssertEqual(refreshed.goal, "Real goal")
        XCTAssertEqual(refreshed.claimedFiles, ["A.swift"])
        XCTAssertGreaterThanOrEqual(refreshed.lastHeartbeat, before)
        XCTAssertEqual(board.activeAgents.filter { $0.pid == 4242 }.count, 1)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter "ProcessSnooperTests|BlackboardStoreTests" 2>&1 | tail -20`
Expected: compile errors for `parentPid`, `detectAgent(inAncestorsOf:)`, `heartbeat`.

- [ ] **Step 3: Implement**

Append inside `ProcessSnooper` in `ProcessSnooper.swift`:

```swift
    /// Parent pid via `proc_pidinfo(PROC_PIDTBSDINFO)`. Nil for invalid pids or when the kernel refuses.
    public static func parentPid(of pid: pid_t) -> pid_t? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let got = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard got == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    /// Walks *up* from `pid` (exclusive) through at most `maxDepth` parents and returns the first
    /// ancestor whose executable is a known AI CLI, with that ancestor's pid.
    public static func detectAgent(inAncestorsOf pid: pid_t, maxDepth: Int = 8) -> (agent: AgentKind, pid: pid_t)? {
        guard pid > 0, maxDepth > 0 else { return nil }
        var current = pid
        var pathBuffer = [CChar](repeating: 0, count: 4096)
        for _ in 0..<maxDepth {
            guard let parent = parentPid(of: current), parent > 1 else { return nil }
            let len = proc_pidpath(parent, &pathBuffer, UInt32(pathBuffer.count))
            if len > 0 {
                let path = pathBuffer.withUnsafeBufferPointer { ptr in
                    ptr.baseAddress.map { String(cString: $0) } ?? ""
                }
                if let agent = detectAgent(inPath: path) {
                    return (agent, parent)
                }
            }
            current = parent
        }
        return nil
    }
```

Append inside `BlackboardStore` in `BlackboardStore.swift` (before `pruneStale`):

```swift
    /// Refreshes presence for `pid`. Inserts an idle record when none exists; never overwrites
    /// an existing goal or claimed files.
    public func heartbeat(agentKind: AgentKind, pid: pid_t, timeout: TimeInterval = 5.0) throws {
        try withFileLock(timeout: timeout) {
            var board = try loadUnlocked()
            pruneStaleUnlocked(&board, olderThan: 900)
            if let idx = board.activeAgents.firstIndex(where: { $0.pid == pid }) {
                board.activeAgents[idx].lastHeartbeat = Date()
            } else {
                board.activeAgents.append(
                    AgentRecord(
                        agentId: "agent-\(agentKind.rawValue)-\(pid)",
                        agentKind: agentKind,
                        pid: pid,
                        goal: "(idle)",
                        claimedFiles: [],
                        lastHeartbeat: Date(),
                        status: "active"
                    )
                )
            }
            board.updatedAt = Date()
            try saveUnlocked(board)
        }
    }
```

In `TerminalSession.swift`, directly after `private var childPid: pid_t = -1`, add:

```swift
    /// The spawned shell's pid (`-1` before spawn). Used by the app to heartbeat presence.
    public var processId: pid_t { childPid }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter "ProcessSnooperTests|BlackboardStoreTests" 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LinkCKit/Terminal/ProcessSnooper.swift Sources/LinkCKit/Blackboard/BlackboardStore.swift Sources/LinkCKit/Terminal/TerminalSession.swift Tests/LinkCKitTests/ProcessSnooperTests.swift Tests/LinkCKitTests/BlackboardStoreTests.swift
git commit -m "feat(presence): ancestor-process agent detection and blackboard heartbeat"
```

---

### Task 5: MCP identity resolution and per-call heartbeat

**Files:**
- Modify: `Sources/LinkCKit/MCP/MCPServer.swift`
- Modify: `Tests/LinkCKitTests/MCPServerTests.swift` (setUp only)
- Modify: `Tests/LinkCKitTests/MCPServerModelTests.swift`, `Tests/LinkCKitTests/MCPServerServiceTests.swift` (setUp only, same change)
- Create: `Tests/LinkCKitTests/MCPServerIdentityTests.swift`

**Interfaces:**
- Produces:
  - `MCPServer.init(workspaceRoot:store:inboxStore:modelSwitcher:environment: [String: String] = ProcessInfo.processInfo.environment, ancestorResolver: @Sendable (pid_t) -> (agent: AgentKind, pid: pid_t)? = { ProcessSnooper.detectAgent(inAncestorsOf: $0) })`
  - `struct MCPCaller: Sendable { let agent: AgentKind; let pid: pid_t; var isIdentified: Bool { agent != .shell } }`
  - `func resolveCaller(_ args: [String: Any]) -> MCPCaller` (internal)
  - `static let readOnlyTools: Set<String>`
  - Tool result text for unidentified write: `Cannot identify calling agent; pass agent: "claude" | "agy" | "cursor" | "codex".`

- [ ] **Step 1: Write the failing tests**

Create `Tests/LinkCKitTests/MCPServerIdentityTests.swift`:

```swift
import XCTest
@testable import LinkCKit

final class MCPServerIdentityTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-mcp-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private func call(_ server: MCPServer, _ name: String, _ args: [String: Any] = [:]) throws -> (text: String, isError: Bool) {
        let req: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": args]]
        let data = try JSONSerialization.data(withJSONObject: req)
        let res = try XCTUnwrap(server.handleMessage(data))
        let json = try JSONSerialization.jsonObject(with: res) as? [String: Any]
        let result = json?["result"] as? [String: Any]
        let text = ((result?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        return (text, result?["isError"] as? Bool ?? false)
    }

    func testExplicitAgentArgumentWins() throws {
        let server = MCPServer(workspaceRoot: tempDir.path, environment: ["LINKC_AGENT": "codex"], ancestorResolver: { _ in (.agy, 77) })
        let caller = server.resolveCaller(["agent": "cursor", "pid": 5])
        XCTAssertEqual(caller.agent, .cursor)
        XCTAssertEqual(caller.pid, 5)
    }

    func testEnvironmentIsUsedWhenNoArgument() throws {
        let server = MCPServer(workspaceRoot: tempDir.path, environment: ["LINKC_AGENT": "codex"], ancestorResolver: { _ in nil })
        let caller = server.resolveCaller([:])
        XCTAssertEqual(caller.agent, .codex)
        XCTAssertEqual(caller.pid, getppid())
    }

    func testAncestorResolverIsUsedWhenNoArgumentOrEnvironment() throws {
        let server = MCPServer(workspaceRoot: tempDir.path, environment: [:], ancestorResolver: { _ in (.agy, 77) })
        let caller = server.resolveCaller([:])
        XCTAssertEqual(caller.agent, .agy)
        XCTAssertEqual(caller.pid, 77)
    }

    func testUnidentifiedCallerIsShellNotClaude() throws {
        let server = MCPServer(workspaceRoot: tempDir.path, environment: [:], ancestorResolver: { _ in nil })
        let caller = server.resolveCaller([:])
        XCTAssertEqual(caller.agent, .shell)
        XCTAssertFalse(caller.isIdentified)
    }

    func testUnidentifiedCallerCanReadButNotWrite() throws {
        let server = MCPServer(workspaceRoot: tempDir.path, environment: [:], ancestorResolver: { _ in nil })
        let read = try call(server, "linkc_get_project_context")
        XCTAssertFalse(read.isError)
        let write = try call(server, "linkc_broadcast_intent", ["goal": "x"])
        XCTAssertTrue(write.isError)
        XCTAssertTrue(write.text.contains("Cannot identify calling agent"))
        let note = try call(server, "linkc_post_note", ["title": "t", "content": "c"])
        XCTAssertTrue(note.isError)
    }

    func testEveryIdentifiedCallHeartbeatsTheBlackboard() throws {
        let server = MCPServer(workspaceRoot: tempDir.path, environment: ["LINKC_AGENT": "cursor"], ancestorResolver: { _ in nil })
        _ = try call(server, "linkc_get_models")
        let board = try server.store.load()
        let rec = try XCTUnwrap(board.activeAgents.first { $0.agentKind == .cursor })
        XCTAssertEqual(rec.pid, getppid())
        XCTAssertEqual(rec.goal, "(idle)")
    }
}
```

In `MCPServerTests.swift`, `MCPServerModelTests.swift`, and `MCPServerServiceTests.swift`, change the `setUp` line `server = MCPServer(workspaceRoot: tempDir.path)` (or the equivalent constructor call, keeping any `modelSwitcher:` argument) to pass a deterministic identity so results do not depend on the shell that runs the tests:

```swift
        server = MCPServer(workspaceRoot: tempDir.path, environment: ["LINKC_AGENT": "claude"], ancestorResolver: { _ in nil })
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MCPServerIdentityTests 2>&1 | tail -20`
Expected: compile errors — no `environment:` parameter, no `resolveCaller`.

- [ ] **Step 3: Implement**

In `MCPServer.swift`:

1. Add the caller type above the class:

```swift
/// Who is calling the tool, resolved from the posting process — never assumed.
public struct MCPCaller: Sendable {
    public let agent: AgentKind
    public let pid: pid_t
    public var isIdentified: Bool { agent != .shell }
}
```

2. Extend stored properties and init:

```swift
    public typealias AncestorResolver = @Sendable (_ pid: pid_t) -> (agent: AgentKind, pid: pid_t)?

    public let environment: [String: String]
    public let ancestorResolver: AncestorResolver

    /// Tools an unidentified caller may still use.
    public static let readOnlyTools: Set<String> = [
        "linkc_get_project_context", "linkc_check_conflicts", "linkc_get_inbox",
        "linkc_get_task", "linkc_get_models", "linkc_get_usage_status"
    ]

    /// Tools whose `agent` argument is a target/filter rather than the caller's identity.
    public static let targetAgentTools: Set<String> = ["linkc_switch_model", "linkc_get_models"]

    public static let unidentifiedCallerMessage =
        "Cannot identify calling agent; pass agent: \"claude\" | \"agy\" | \"cursor\" | \"codex\"."

    public init(
        workspaceRoot: String,
        store: BlackboardStore? = nil,
        inboxStore: InboxStore? = nil,
        modelSwitcher: ModelSwitcher? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        ancestorResolver: @escaping AncestorResolver = { ProcessSnooper.detectAgent(inAncestorsOf: $0) }
    ) {
        self.workspaceRoot = (workspaceRoot as NSString).standardizingPath
        self.store = store ?? BlackboardStore(workspaceRoot: workspaceRoot)
        self.inboxStore = inboxStore ?? InboxStore(workspaceRoot: workspaceRoot)
        self.modelSwitcher = modelSwitcher
        self.environment = environment
        self.ancestorResolver = ancestorResolver
    }

    /// Identity: explicit `agent` arg → `LINKC_AGENT` env → ancestor process → `.shell` (unidentified).
    func resolveCaller(_ args: [String: Any]) -> MCPCaller {
        let explicitPid = (args["pid"] as? Int).map { pid_t($0) }
        if let s = (args["agent"] as? String) ?? (args["from"] as? String),
           let kind = AgentKind(rawValue: s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()),
           kind != .shell {
            return MCPCaller(agent: kind, pid: explicitPid ?? getppid())
        }
        if let env = environment["LINKC_AGENT"], let kind = AgentKind(rawValue: env.lowercased()), kind != .shell {
            return MCPCaller(agent: kind, pid: explicitPid ?? getppid())
        }
        if let found = ancestorResolver(getpid()) {
            return MCPCaller(agent: found.agent, pid: explicitPid ?? found.pid)
        }
        return MCPCaller(agent: .shell, pid: explicitPid ?? getppid())
    }
```

3. In `handleToolsCall`, immediately after `let args = ...`, add the gate and heartbeat. For `linkc_switch_model` and `linkc_get_models` the `agent` argument names the *target*, not the caller, so it is stripped before identity resolution:

```swift
        let identityArgs = Self.targetAgentTools.contains(name) ? args.filter { $0.key != "agent" } : args
        let caller = resolveCaller(identityArgs)
        if !caller.isIdentified && !Self.readOnlyTools.contains(name) {
            return toolResultResponse(id: id, text: Self.unidentifiedCallerMessage, isError: true)
        }
        if caller.isIdentified {
            try? store.heartbeat(agentKind: caller.agent, pid: caller.pid)
        }
```

4. Replace every identity default in the switch with `caller`:
   - `linkc_broadcast_intent`: delete the `agentStr`/`agentKind`/`pid` lines; in the `store.broadcastIntent(...)` call and the response text use `caller.agent` and `caller.pid`.
   - `linkc_check_conflicts`: `let pid: pid_t? = (args["pid"] as? Int).map { pid_t($0) } ?? (caller.isIdentified ? caller.pid : nil)` — keep the optional so unidentified callers see all conflicts.
   - `linkc_post_note`: delete `agentStr`/`agentKind`; `authorAgent: caller.agent`.
   - `linkc_delegate_task`: delete the `fromStr`/`fromAgent`/`pid` lines; in `store.broadcastIntent(...)` use `agentKind: caller.agent, pid: caller.pid`; in `inboxStore.enqueue(...)` use `from: caller.agent`. (Task 7 rewrites this case again.)
   - `linkc_send_message`: delete `fromStr`/`fromAgent`; use `caller.agent.displayName` in `formattedPrompt` and `from: caller.agent` in `enqueue`. (Task 7 rewrites this case again.)
   - `linkc_switch_model`: `let agentStr = (args["agent"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? caller.agent.rawValue` in place of `?? "claude"`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter "MCPServerIdentityTests|MCPServerTests|MCPServerModelTests|MCPServerServiceTests" 2>&1 | tail -30`
Expected: PASS. (`MCPServerTests` behaviour is unchanged because its setUp now pins `LINKC_AGENT=claude`.)

- [ ] **Step 5: Commit**

```bash
git add Sources/LinkCKit/MCP/MCPServer.swift Tests/LinkCKitTests/MCPServerIdentityTests.swift Tests/LinkCKitTests/MCPServerTests.swift Tests/LinkCKitTests/MCPServerModelTests.swift Tests/LinkCKitTests/MCPServerServiceTests.swift
git commit -m "feat(mcp): resolve caller identity from process, never default to claude, heartbeat per call"
```

---

### Task 6: MCP task tools (`start`, `complete`, `cancel`, `get`, `my_tasks`)

**Files:**
- Modify: `Sources/LinkCKit/MCP/MCPServer.swift`
- Create: `Tests/LinkCKitTests/MCPServerTaskTests.swift`

**Interfaces:**
- Consumes: `InboxStore` task methods (Task 2), `enqueue(kind:)` (Task 3), `resolveCaller` (Task 5).
- Produces tools: `linkc_start_task {task_id}`, `linkc_complete_task {task_id, status, summary, commits?, tests?}`, `linkc_cancel_task {task_id, reason?, force?}`, `linkc_get_task {task_id}`, `linkc_my_tasks {}`; helper `func taskLine(_ t: TaskRecord) -> String` producing `"<id8> [state] from <From> → <To>: <first 80 chars of prompt>"`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/LinkCKitTests/MCPServerTaskTests.swift`:

```swift
import XCTest
@testable import LinkCKit

final class MCPServerTaskTests: XCTestCase {
    var tempDir: URL!
    var inbox: InboxStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-mcp-task-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        inbox = InboxStore(workspaceRoot: tempDir.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private func server(as agent: AgentKind) -> MCPServer {
        MCPServer(workspaceRoot: tempDir.path, environment: ["LINKC_AGENT": agent.rawValue], ancestorResolver: { _ in nil })
    }

    private func call(_ server: MCPServer, _ name: String, _ args: [String: Any] = [:]) throws -> (text: String, isError: Bool) {
        let req: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": args]]
        let data = try JSONSerialization.data(withJSONObject: req)
        let res = try XCTUnwrap(server.handleMessage(data))
        let json = try JSONSerialization.jsonObject(with: res) as? [String: Any]
        let result = json?["result"] as? [String: Any]
        let text = ((result?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        return (text, result?["isError"] as? Bool ?? false)
    }

    func testStartTaskMovesDeliveredToStarted() throws {
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "Build", files: [])
        try inbox.markTaskDelivered(taskId: task.id, sessionId: "s1")
        let res = try call(server(as: .codex), "linkc_start_task", ["task_id": task.id])
        XCTAssertFalse(res.isError, res.text)
        XCTAssertEqual(try inbox.task(id: task.id)?.state, .started)
        XCTAssertTrue(res.text.contains(task.shortId))
    }

    func testStartTaskOnQueuedTaskIsAnError() throws {
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "Build", files: [])
        let res = try call(server(as: .codex), "linkc_start_task", ["task_id": task.id])
        XCTAssertTrue(res.isError)
        XCTAssertTrue(res.text.contains("queued"))
    }

    func testCompleteTaskRecordsReportEnqueuesOneLineAndPostsNote() throws {
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "Build the very long brief that must not be echoed back in full " + String(repeating: "x", count: 500), files: [])
        try inbox.markTaskDelivered(taskId: task.id, sessionId: "s1")
        let srv = server(as: .codex)
        let res = try call(srv, "linkc_complete_task", [
            "task_id": task.id, "status": "done", "summary": "Implemented and tested.",
            "commits": ["abc1234"], "tests": ["swift test --filter Foo"]
        ])
        XCTAssertFalse(res.isError, res.text)

        let t = try XCTUnwrap(inbox.task(id: task.id))
        XCTAssertEqual(t.state, .done)
        XCTAssertEqual(t.report?.commits, ["abc1234"])

        let msgs = try inbox.load().messages
        XCTAssertEqual(msgs.count, 1)
        let echo = try XCTUnwrap(msgs.first)
        XCTAssertEqual(echo.kind, .completion)
        XCTAssertEqual(echo.toAgent, .claude)
        XCTAssertEqual(echo.fromAgent, .codex)
        XCTAssertEqual(echo.taskId, task.id)
        XCTAssertTrue(echo.prompt.hasPrefix("[linkC task \(task.shortId)] done by Codex"))
        XCTAssertFalse(echo.prompt.contains("xxxxxxxxxx"), "echo must not carry the brief")
        XCTAssertLessThan(echo.prompt.count, 400)

        let notes = try srv.store.load().sharedNotes
        XCTAssertTrue(notes.contains { $0.title == "Task \(task.shortId) done" && $0.content.contains("abc1234") })
    }

    func testCompleteTaskRequiresSummaryAndValidStatus() throws {
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "Build", files: [])
        try inbox.markTaskDelivered(taskId: task.id, sessionId: "s1")
        let srv = server(as: .codex)
        XCTAssertTrue(try call(srv, "linkc_complete_task", ["task_id": task.id, "status": "done", "summary": ""]).isError)
        XCTAssertTrue(try call(srv, "linkc_complete_task", ["task_id": task.id, "status": "maybe", "summary": "x"]).isError)
        XCTAssertTrue(try call(srv, "linkc_complete_task", ["task_id": "nope", "status": "done", "summary": "x"]).isError)
        XCTAssertEqual(try inbox.task(id: task.id)?.state, .delivered)
    }

    func testCancelTaskByDelegatorInjectsOneLineToAssignee() throws {
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "Build", files: [])
        try inbox.markTaskDelivered(taskId: task.id, sessionId: "s1")
        let res = try call(server(as: .claude), "linkc_cancel_task", ["task_id": task.id, "reason": "scope changed"])
        XCTAssertFalse(res.isError, res.text)
        XCTAssertEqual(try inbox.task(id: task.id)?.state, .cancelled)
        let msg = try XCTUnwrap(inbox.load().messages.first)
        XCTAssertEqual(msg.toAgent, .codex)
        XCTAssertEqual(msg.kind, .completion)
        XCTAssertTrue(msg.prompt.contains("cancelled: scope changed"))
    }

    func testCancelQueuedTaskIsSilentAndThirdPartyNeedsForce() throws {
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "Build", files: [])
        let denied = try call(server(as: .cursor), "linkc_cancel_task", ["task_id": task.id])
        XCTAssertTrue(denied.isError)
        let forced = try call(server(as: .cursor), "linkc_cancel_task", ["task_id": task.id, "force": true])
        XCTAssertFalse(forced.isError, forced.text)
        XCTAssertTrue(try inbox.load().messages.isEmpty, "queued cancel must not inject anything")
    }

    func testGetTaskAndMyTasks() throws {
        let mine = try inbox.createTask(from: .claude, to: .codex, prompt: "Assigned to me", files: ["A.swift"])
        let delegated = try inbox.createTask(from: .codex, to: .cursor, prompt: "I delegated this", files: [])
        _ = try inbox.createTask(from: .claude, to: .agy, prompt: "Unrelated", files: [])

        let get = try call(server(as: .codex), "linkc_get_task", ["task_id": mine.id])
        XCTAssertFalse(get.isError)
        XCTAssertTrue(get.text.contains("Assigned to me"))
        XCTAssertTrue(get.text.contains("A.swift"))
        XCTAssertTrue(get.text.contains("queued"))

        let list = try call(server(as: .codex), "linkc_my_tasks")
        XCTAssertTrue(list.text.contains(mine.shortId))
        XCTAssertTrue(list.text.contains(delegated.shortId))
        XCTAssertFalse(list.text.contains("Unrelated"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MCPServerTaskTests 2>&1 | tail -20`
Expected: FAIL — `Unknown tool: linkc_start_task` errors (JSON-RPC error, so `handleMessage` returns an error payload and `result` is nil → assertions fail).

- [ ] **Step 3: Implement**

In `handleToolsList`, append these five entries to the `tools` array (after `linkc_get_usage_status`):

```swift
            [
                "name": "linkc_start_task",
                "description": "Acknowledge and start a task delivered to you (delivered → started). Call this first when you begin work on a [linkC task …] brief.",
                "inputSchema": ["type": "object", "properties": ["task_id": ["type": "string"]], "required": ["task_id"]]
            ],
            [
                "name": "linkc_complete_task",
                "description": "Report the result of a task you were assigned. Sends a one-line echo to the delegator and stores the full report on the blackboard.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "task_id": ["type": "string"],
                        "status": ["type": "string", "enum": ["done", "failed"]],
                        "summary": ["type": "string", "description": "One paragraph: what changed and how it was verified"],
                        "commits": ["type": "array", "items": ["type": "string"]],
                        "tests": ["type": "array", "items": ["type": "string"], "description": "Test commands or test names that passed"]
                    ],
                    "required": ["task_id", "status", "summary"]
                ]
            ],
            [
                "name": "linkc_cancel_task",
                "description": "Cancel a task you delegated or were assigned. If it was already delivered, a one-line stop notice is injected into the assignee's terminal.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "task_id": ["type": "string"],
                        "reason": ["type": "string"],
                        "force": ["type": "boolean", "description": "Cancel a task you are neither delegator nor assignee of"]
                    ],
                    "required": ["task_id"]
                ]
            ],
            [
                "name": "linkc_get_task",
                "description": "Fetch the full record of a task by id: state, full brief, files, report.",
                "inputSchema": ["type": "object", "properties": ["task_id": ["type": "string"]], "required": ["task_id"]]
            ],
            [
                "name": "linkc_my_tasks",
                "description": "List open tasks assigned to you, then open tasks you delegated, one line each.",
                "inputSchema": ["type": "object", "properties": [:]]
            ]
```

Add these helpers to the class:

```swift
    func taskLine(_ t: TaskRecord) -> String {
        let firstLine = t.prompt.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? t.prompt
        return "\(t.shortId) [\(t.state.rawValue)] from \(t.fromAgent.displayName) → \(t.toAgent.displayName): \(firstLine.prefix(80))"
    }

    private func taskMarkdown(_ t: TaskRecord) -> String {
        let iso = ISO8601DateFormatter()
        var text = "# Task \(t.shortId) — \(t.state.rawValue)\n\n"
        text += "- **ID:** \(t.id)\n"
        text += "- **From:** \(t.fromAgent.displayName) → **To:** \(t.toAgent.displayName)\n"
        text += "- **Hop:** \(t.hop)\n"
        text += "- **Created:** \(iso.string(from: t.createdAt))\n"
        if let d = t.deliveredAt { text += "- **Delivered:** \(iso.string(from: d))\n" }
        if let s = t.startedAt { text += "- **Started:** \(iso.string(from: s))\n" }
        if let f = t.finishedAt { text += "- **Finished:** \(iso.string(from: f))\n" }
        text += "- **Lease expires:** \(iso.string(from: t.leaseExpiresAt))\n"
        if !t.files.isEmpty { text += "- **Files:** \(t.files.joined(separator: ", "))\n" }
        if let r = t.cancelReason { text += "- **Reason:** \(r)\n" }
        text += "\n## Brief\n\(t.prompt)\n"
        if let r = t.report {
            text += "\n## Report (\(r.status))\n\(r.summary)\n"
            if !r.commits.isEmpty { text += "\n**Commits:** \(r.commits.joined(separator: ", "))\n" }
            if !r.tests.isEmpty { text += "\n**Tests:** \(r.tests.joined(separator: "; "))\n" }
        }
        return text
    }

    private func requireTask(_ args: [String: Any]) throws -> TaskRecord {
        guard let taskId = (args["task_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !taskId.isEmpty else {
            throw LinkCError.server("Missing required argument 'task_id'.")
        }
        guard let task = try inboxStore.task(id: taskId) else { throw InboxError.taskNotFound(taskId) }
        return task
    }
```

Add these cases to the `switch name` in `handleToolsCall`, before `default:`. Because `InboxError` must surface as an `isError` tool result (not a JSON-RPC error), wrap each body:

```swift
            case "linkc_start_task":
                do {
                    let task = try requireTask(args)
                    try inboxStore.markTaskStarted(taskId: task.id)
                    let updated = try inboxStore.task(id: task.id) ?? task
                    return toolResultResponse(id: id, text: "Started: \(taskLine(updated))")
                } catch {
                    return toolResultResponse(id: id, text: error.localizedDescription, isError: true)
                }

            case "linkc_complete_task":
                do {
                    let task = try requireTask(args)
                    let status = (args["status"] as? String ?? "").lowercased()
                    guard status == "done" || status == "failed" else {
                        return toolResultResponse(id: id, text: "Error: 'status' must be \"done\" or \"failed\".", isError: true)
                    }
                    let summary = (args["summary"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !summary.isEmpty else {
                        return toolResultResponse(id: id, text: InboxError.emptySummary.localizedDescription, isError: true)
                    }
                    let report = TaskReport(
                        status: status,
                        summary: summary,
                        commits: args["commits"] as? [String] ?? [],
                        tests: args["tests"] as? [String] ?? []
                    )
                    try inboxStore.completeTask(taskId: task.id, report: report)

                    let firstLine = summary.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? summary
                    let body = "\(status) by \(caller.agent.displayName) — \(firstLine.prefix(200)). linkc_get_task(\"\(task.id)\") for details."
                    _ = try inboxStore.enqueue(from: caller.agent, to: task.fromAgent, kind: .completion, taskId: task.id, body: body)

                    var note = "\(summary)\n"
                    if !report.commits.isEmpty { note += "\n**Commits:** \(report.commits.joined(separator: ", "))\n" }
                    if !report.tests.isEmpty { note += "\n**Tests:** \(report.tests.joined(separator: "; "))\n" }
                    note += "\nTask id: \(task.id)\n"
                    _ = try store.postNote(authorAgent: caller.agent, title: "Task \(task.shortId) \(status)", content: note, tags: ["task", status])

                    return toolResultResponse(id: id, text: "Reported \(status) for task \(task.shortId). \(task.fromAgent.displayName) will receive a one-line echo.")
                } catch {
                    return toolResultResponse(id: id, text: error.localizedDescription, isError: true)
                }

            case "linkc_cancel_task":
                do {
                    let task = try requireTask(args)
                    let force = args["force"] as? Bool ?? false
                    guard force || caller.agent == task.fromAgent || caller.agent == task.toAgent else {
                        return toolResultResponse(id: id, text: "Error: only \(task.fromAgent.displayName) or \(task.toAgent.displayName) may cancel task \(task.shortId); pass force: true to override.", isError: true)
                    }
                    let reason = (args["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let resolvedReason = (reason?.isEmpty == false) ? reason! : "cancelled by \(caller.agent.displayName)"
                    let wasDelivered = task.state == .delivered || task.state == .started
                    try inboxStore.cancelTask(taskId: task.id, reason: resolvedReason)
                    if wasDelivered {
                        _ = try inboxStore.enqueue(from: caller.agent, to: task.toAgent, kind: .completion, taskId: task.id, body: "cancelled: \(resolvedReason). Stop work on it.")
                    }
                    return toolResultResponse(id: id, text: "Cancelled task \(task.shortId) (\(resolvedReason)).")
                } catch {
                    return toolResultResponse(id: id, text: error.localizedDescription, isError: true)
                }

            case "linkc_get_task":
                do {
                    let task = try requireTask(args)
                    return toolResultResponse(id: id, text: taskMarkdown(task))
                } catch {
                    return toolResultResponse(id: id, text: error.localizedDescription, isError: true)
                }

            case "linkc_my_tasks":
                guard caller.isIdentified else {
                    return toolResultResponse(id: id, text: Self.unidentifiedCallerMessage, isError: true)
                }
                let assigned = try inboxStore.openTasks(for: caller.agent)
                let delegated = try inboxStore.openTasks().filter { $0.fromAgent == caller.agent && $0.toAgent != caller.agent }
                var text = "# Open tasks for \(caller.agent.displayName)\n\n## Assigned to you (\(assigned.count))\n"
                text += assigned.isEmpty ? "_None._\n" : assigned.map { "- \(taskLine($0))" }.joined(separator: "\n") + "\n"
                text += "\n## Delegated by you (\(delegated.count))\n"
                text += delegated.isEmpty ? "_None._\n" : delegated.map { "- \(taskLine($0))" }.joined(separator: "\n") + "\n"
                return toolResultResponse(id: id, text: text)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter "MCPServerTaskTests|MCPServerIdentityTests" 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LinkCKit/MCP/MCPServer.swift Tests/LinkCKitTests/MCPServerTaskTests.swift
git commit -m "feat(mcp): add linkc_start_task, linkc_complete_task, linkc_cancel_task, linkc_get_task, linkc_my_tasks"
```

---

### Task 7: `linkc_delegate_task` creates tasks and refuses lease conflicts; `send_message`, `get_inbox`, `switch_model` migrate; v0.2.0

**Files:**
- Modify: `Sources/LinkCKit/MCP/MCPServer.swift`
- Modify: `Tests/LinkCKitTests/MCPServerTests.swift`
- Modify: `Tests/LinkCKitTests/MCPServerModelTests.swift` (only if it asserts on the enqueued switch command's `prompt`; expectation is unchanged because `.command` has no frame)

**Interfaces:**
- Consumes: `createTask`, `enqueue(kind:)`, `leaseHolders`.
- Produces: `linkc_delegate_task` gains optional `force: boolean`; success text `Task <id> queued for <To>. It will be delivered when <To> is idle. Track with linkc_get_task("<id>").`; refusal text from `InboxError.leaseConflict`. `serverInfo.version = "0.2.0"`, `capabilities.tools = ["listChanged": false]`. Tool count is 15.

- [ ] **Step 1: Update and add tests**

In `MCPServerTests.swift`:

1. `testToolsListDeclaresSevenTools`: change `XCTAssertEqual(tools?.count, 10)` to `15` and add:

```swift
        for name in ["linkc_start_task", "linkc_complete_task", "linkc_cancel_task", "linkc_get_task", "linkc_my_tasks", "linkc_switch_model", "linkc_get_models", "linkc_get_usage_status"] {
            XCTAssertTrue(toolNames.contains(name), "missing \(name)")
        }
```

2. `testInitializeReturnsProtocolAndCapabilities`: add

```swift
        XCTAssertEqual(serverInfo?["version"] as? String, "0.2.0")
        let caps = result?["capabilities"] as? [String: Any]
        let toolsCap = caps?["tools"] as? [String: Any]
        XCTAssertEqual(toolsCap?["listChanged"] as? Bool, false)
```

3. Rewrite `testDelegateTaskEnqueuesAndClaimsFiles` body after the request so it checks the task table instead of messages:

```swift
        XCTAssertTrue(text.contains("queued for Codex"), "Expected success confirmation in: \(text)")
        XCTAssertTrue(text.contains("linkc_get_task"), "Expected tracking hint in: \(text)")
        XCTAssertFalse(result?["isError"] as? Bool ?? false)

        let tasks = try inboxStore.openTasks(for: .codex)
        XCTAssertEqual(tasks.count, 1)
        let task = try XCTUnwrap(tasks.first)
        XCTAssertEqual(task.fromAgent, .claude)
        XCTAssertEqual(task.prompt, "Implement tokenizer module")
        XCTAssertEqual(task.files, ["Sources/Tokenizer.swift"])
        XCTAssertEqual(task.state, .queued)
        XCTAssertTrue(try inboxStore.load().messages.isEmpty, "v2 delegation creates a task, not a message")

        let conflicts = try server.store.checkConflicts(files: ["Sources/Tokenizer.swift"], excludingPid: 2222)
        XCTAssertFalse(conflicts.isEmpty)
        XCTAssertEqual(conflicts.first?.conflictingAgent, .claude)
```

4. Replace the existing collision-warning delegate test (the one asserting `"Collision Warning"` and `"User.swift"`) with:

```swift
    func testDelegateTaskRefusesLeaseConflictUnlessForced() throws {
        let inboxStore = InboxStore(workspaceRoot: tempDir.path)
        let holder = try inboxStore.createTask(from: .claude, to: .codex, prompt: "Own User model", files: ["User.swift"])

        func delegate(force: Bool?) throws -> (text: String, isError: Bool) {
            var arguments: [String: Any] = ["to": "cursor", "prompt": "Also touch User model", "files": ["User.swift"], "from": "claude"]
            if let force { arguments["force"] = force }
            let req: [String: Any] = ["jsonrpc": "2.0", "id": 12, "method": "tools/call", "params": ["name": "linkc_delegate_task", "arguments": arguments]]
            let resData = try XCTUnwrap(server.handleMessage(try JSONSerialization.data(withJSONObject: req)))
            let resJson = try JSONSerialization.jsonObject(with: resData) as? [String: Any]
            let result = resJson?["result"] as? [String: Any]
            let text = ((result?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
            return (text, result?["isError"] as? Bool ?? false)
        }

        let refused = try delegate(force: nil)
        XCTAssertTrue(refused.isError)
        XCTAssertTrue(refused.text.contains("Refused"))
        XCTAssertTrue(refused.text.contains("User.swift"))
        XCTAssertTrue(refused.text.contains(holder.shortId))
        XCTAssertEqual(try inboxStore.openTasks(for: .cursor).count, 0)

        let forced = try delegate(force: true)
        XCTAssertFalse(forced.isError, forced.text)
        XCTAssertEqual(try inboxStore.openTasks(for: .cursor).count, 1)
    }
```

5. `testGetInboxReturnsMarkdown`: replace the `enqueue(from:to:prompt:files:)` seed with a task plus a peer note, and update assertions:

```swift
        let task = try inboxStore.createTask(from: .claude, to: .agy, prompt: "Refactor error types", files: ["Sources/Error.swift"])
        _ = try inboxStore.enqueue(from: .claude, to: .agy, kind: .peerNote, body: "FYI the build is green")
        // ... request unchanged ...
        XCTAssertTrue(text.contains("# linkC Message Inbox"), "Expected header in: \(text)")
        XCTAssertTrue(text.contains("## Open Tasks (1)"), "Expected open tasks section in: \(text)")
        XCTAssertTrue(text.contains(task.shortId))
        XCTAssertTrue(text.contains("Refactor error types"))
        XCTAssertTrue(text.contains("Cursor Agent"), "Expected limited agent in: \(text)")
        XCTAssertTrue(text.contains("Quota exceeded"), "Expected limit reason in: \(text)")
        XCTAssertTrue(text.contains("[peerNote]"), "Expected message kind tag in: \(text)")
        XCTAssertTrue(text.contains("FYI the build is green"))
```

6. Any test that asserts on `linkc_send_message` output should keep working (queued text unchanged); if one asserts the stored `prompt` equals `"[Peer Note from Claude Code]: …"`, it still matches because the store composes the same frame.

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MCPServerTests 2>&1 | tail -30`
Expected: FAIL on count (10 vs 15 — five new tools were added in Task 6, so this may already be 15; then failures are on version, refusal, and get_inbox).

- [ ] **Step 3: Implement**

In `MCPServer.swift`:

1. `handleInitialize`: `"capabilities": ["tools": ["listChanged": false]]` and `"version": "0.2.0"`.

2. `linkc_delegate_task` schema: add `"force": ["type": "boolean", "description": "Override an existing lease held by another assignee"]` to `properties`.

3. Replace the body of `case "linkc_delegate_task":` from the `let files = ...` line to the end of the case with:

```swift
                let files = args["files"] as? [String] ?? []
                let force = args["force"] as? Bool ?? false

                let task: TaskRecord
                do {
                    task = try inboxStore.createTask(from: caller.agent, to: toAgent, prompt: prompt, files: files, force: force)
                } catch let error as InboxError {
                    return toolResultResponse(id: id, text: error.localizedDescription, isError: true)
                }

                if !files.isEmpty {
                    _ = try store.broadcastIntent(
                        agentKind: caller.agent,
                        pid: caller.pid,
                        goal: "Delegated task \(task.shortId) to \(toAgent.displayName)",
                        files: files,
                        status: "delegating"
                    )
                }

                return toolResultResponse(
                    id: id,
                    text: "Task \(task.id) queued for \(toAgent.displayName). It will be delivered when \(toAgent.displayName) is idle. Track with linkc_get_task(\"\(task.id)\")."
                )
```

4. `linkc_send_message`: replace the `formattedPrompt` + legacy `enqueue` with:

```swift
                do {
                    let pending = try inboxStore.enqueue(from: caller.agent, to: toAgent, kind: .peerNote, body: messageText)
                    return toolResultResponse(id: id, text: "Message queued for \(toAgent.displayName) (ID: \(pending.id)). linkC will deliver it when idle.")
                } catch let error as InboxError {
                    return toolResultResponse(id: id, text: error.localizedDescription, isError: true)
                }
```

5. `linkc_switch_model` fallback branch: replace the legacy `enqueue(from: agent, to: agent, prompt: cmd, files: [])` with `_ = try inboxStore.enqueue(from: agent, to: agent, kind: .command, body: cmd)`.

6. `linkc_get_inbox`: after the limits section and before `## Pending Messages`, insert:

```swift
                let openTasks = inbox.tasks.filter { $0.state.isOpen }.sorted { $0.createdAt < $1.createdAt }
                text += "## Open Tasks (\(openTasks.count))\n"
                if openTasks.isEmpty {
                    text += "_No open tasks._\n\n"
                } else {
                    for t in openTasks {
                        let age = Int(now.timeIntervalSince(t.createdAt) / 60)
                        text += "- \(taskLine(t)) — \(age)m old, \(t.files.count) file(s)\n"
                    }
                    text += "\n"
                }
```

and change each pending-message header to `"### Message \(msg.id) [\(msg.kind.rawValue)] [\(msg.status.rawValue.uppercased())]\n"`, add `if let taskId = msg.taskId { text += "- **Task:** \(taskId.prefix(8))\n" }`, and truncate the body: `text += "- **Content:** \(msg.prompt.prefix(200))\n\n"` (drop the fenced block).

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter "MCPServerTests|MCPServerModelTests|MCPServerServiceTests|MCPServerTaskTests|MCPServerIdentityTests" 2>&1 | tail -30`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LinkCKit/MCP/MCPServer.swift Tests/LinkCKitTests/MCPServerTests.swift Tests/LinkCKitTests/MCPServerModelTests.swift
git commit -m "feat(mcp): delegate creates leased tasks and refuses conflicts; peer notes and commands use kinds; v0.2.0"
```

---

### Task 8: Registrar writes `LINKC_AGENT`

**Files:**
- Modify: `Sources/LinkCKit/MCP/MCPRegistrar.swift`
- Test: `Tests/LinkCKitTests/MCPRegistrarTests.swift`

**Interfaces:**
- Produces: `registerServer(configFile:serverName:binaryPath:args:env: [String: String] = [:])`, `registerTomlServer(configFile:serverName:binaryPath:args:env: [String: String] = [:])`. `registerAll` passes `claude`/`cursor`/`agy`/`codex`.

- [ ] **Step 1: Write the failing tests**

Append to `MCPRegistrarTests`:

```swift
    func testRegisterServerWritesEnv() throws {
        let configFile = tempDir.appendingPathComponent("mcp.json")
        try MCPRegistrar.registerServer(configFile: configFile, binaryPath: "/x/linkc-mcp", env: ["LINKC_AGENT": "cursor"])
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: configFile)) as? [String: Any]
        let server = (json?["mcpServers"] as? [String: Any])?["linkc-multiplier"] as? [String: Any]
        XCTAssertEqual(server?["env"] as? [String: String], ["LINKC_AGENT": "cursor"])
    }

    func testRegisterTomlWritesEnvTableAndRewritesInPlace() throws {
        let configFile = tempDir.appendingPathComponent("config.toml")
        try "model = \"gpt-5\"\n".write(to: configFile, atomically: true, encoding: .utf8)
        try MCPRegistrar.registerTomlServer(configFile: configFile, binaryPath: "/x/linkc-mcp", env: ["LINKC_AGENT": "codex"])
        var content = try String(contentsOf: configFile, encoding: .utf8)
        XCTAssertTrue(content.contains("[mcp_servers.linkc-multiplier]"))
        XCTAssertTrue(content.contains("[mcp_servers.linkc-multiplier.env]"))
        XCTAssertTrue(content.contains("LINKC_AGENT = \"codex\""))

        try MCPRegistrar.registerTomlServer(configFile: configFile, binaryPath: "/y/linkc-mcp", env: ["LINKC_AGENT": "codex"])
        content = try String(contentsOf: configFile, encoding: .utf8)
        XCTAssertEqual(content.components(separatedBy: "[mcp_servers.linkc-multiplier.env]").count - 1, 1, "env table must not duplicate")
        XCTAssertTrue(content.contains("model = \"gpt-5\""))
        XCTAssertFalse(content.contains("/x/linkc-mcp"))
    }

    func testRegisterAllSetsAgentIdentityPerClient() throws {
        try MCPRegistrar.registerAll(home: tempDir, binaryPath: "/custom/bin/linkc-mcp")
        func env(_ rel: String) throws -> [String: String]? {
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: tempDir.appendingPathComponent(rel))) as? [String: Any]
            return ((json?["mcpServers"] as? [String: Any])?["linkc-multiplier"] as? [String: Any])?["env"] as? [String: String]
        }
        XCTAssertEqual(try env(".claude.json")?["LINKC_AGENT"], "claude")
        XCTAssertEqual(try env(".cursor/mcp.json")?["LINKC_AGENT"], "cursor")
        XCTAssertEqual(try env(".codex/mcp.json")?["LINKC_AGENT"], "codex")
        let codexToml = try String(contentsOf: tempDir.appendingPathComponent(".codex/config.toml"), encoding: .utf8)
        XCTAssertTrue(codexToml.contains("LINKC_AGENT = \"codex\""))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MCPRegistrarTests 2>&1 | tail -20`
Expected: compile error — extra argument `env:`.

- [ ] **Step 3: Implement**

In `MCPRegistrar.swift`:

1. `registerServer`: add parameter `env: [String: String] = [:]` after `args`; build the entry as

```swift
        var entry: [String: Any] = ["command": binaryPath, "args": args]
        if !env.isEmpty { entry["env"] = env }
        mcpServers[serverName] = entry
```

2. `registerTomlServer`: add parameter `env: [String: String] = [:]`; build the section as

```swift
        var section = """
        \(header)
        command = "\(binaryPath)"\(argsToml)
        """
        if !env.isEmpty {
            let envLines = env.keys.sorted().map { key in
                "\(key) = \"\(env[key]!.replacingOccurrences(of: "\"", with: "\\\""))\""
            }.joined(separator: "\n")
            section += "\n\n[mcp_servers.\(serverName).env]\n\(envLines)"
        }
```

and change the "replace existing" regex so it swallows the old env sub-table too: replace the `nextHeaderRegex` pattern with `#"(\n\[(?!mcp_servers\.\#(NSRegularExpression.escapedPattern(for: serverName))\.env\])|\Z)"#` — i.e. the next header that is *not* our own `.env` table ends the section.

3. `registerAll`: pass `env: ["LINKC_AGENT": "claude"]` to both Claude files, `"cursor"` to Cursor, `"agy"` to Antigravity, and `"codex"` to both Codex registrations.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter MCPRegistrarTests 2>&1 | tail -20`
Expected: PASS (including the four pre-existing tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/LinkCKit/MCP/MCPRegistrar.swift Tests/LinkCKitTests/MCPRegistrarTests.swift
git commit -m "feat(mcp): registrar sets LINKC_AGENT per client so identity comes from the posting process"
```

---

### Task 9: Relay dispatcher — `expireTasks`, `dispatchTasks`, `dispatchMessages`

**Files:**
- Create: `Sources/LinkCKit/App/AppCoordinator+Relay.swift`
- Modify: `Sources/LinkCKit/App/AppCoordinator.swift` (widen access on 4 members; delete old `processPendingMessages`)
- Modify: `Tests/LinkCKitTests/AppCoordinatorRelayTests.swift`

**Interfaces:**
- Consumes: `InboxStore` task and message APIs; `spawnTeammate(in:agent:goal:)`; `terminals.sendInput(sessionId:text:)`; `store.updateState(id:to:)`.
- Produces (all `@MainActor`, on `extension AppCoordinator`):
  - `public func processPendingMessages(workspacePath: String)` — calls `expireTasks`, `dispatchTasks`, `dispatchMessages` in order (same name as before so `handle(_:)` and `sampleAgentStates` need no change).
  - `func expireTasks(workspacePath: String, inboxStore: InboxStore)`
  - `func dispatchTasks(workspacePath: String, inboxStore: InboxStore)`
  - `func dispatchMessages(workspacePath: String, inboxStore: InboxStore)`
  - `static func deliveryFrame(for task: TaskRecord) -> String`
  - `static let queuedTaskExpiry: TimeInterval = 60 * 60`
  - `func isIdle(_ state: SessionState) -> Bool` (true for `.ready`, `.finished`, `.waitingIdle`)
  - `func workspaceExists(_ path: String) -> Bool`

- [ ] **Step 1: Write the failing tests**

In `AppCoordinatorRelayTests.swift`, replace Test 1 and Test 2 (`testProcessPendingMessageAutoSpawnsSessionAndDispatchesPrompt`, `testBusySessionDelaysPromptUntilReadyOrFinished`) with the following, and add the further tests after them:

```swift
    /// Test 1: A queued task auto-spawns the assignee and is delivered exactly once with the v2 frame.
    @MainActor
    func testQueuedTaskAutoSpawnsAssigneeAndDeliversFramedBrief() async throws {
        let ws = tempDir.path
        let inbox = InboxStore(workspaceRoot: ws)
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "Refactor database migrations", files: ["db/migrations.sql"])

        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }

        coordinator.processPendingMessages(workspacePath: ws)

        guard let codexSession = coordinator.store.sessions.first(where: { $0.agentKind == .codex }) else {
            return XCTFail("Expected codex session to be auto-spawned")
        }
        let delivered = try XCTUnwrap(inbox.task(id: task.id))
        XCTAssertEqual(delivered.state, .delivered)
        XCTAssertEqual(delivered.assigneeSessionId, codexSession.id)
        XCTAssertNotNil(delivered.deliveredAt)

        let term = coordinator.terminals.session(id: codexSession.id)
        let echoed = try await waitUntil {
            let out = term?.recentOutput(lines: 20) ?? ""
            // Substrings kept short: the PTY may wrap long lines at the terminal width.
            return out.contains("[linkC task \(task.shortId)")
                && out.contains("Refactor database migrations")
                && out.contains("linkc_start_task")
        }
        XCTAssertTrue(echoed, "Expected framed brief in terminal")

        // Second tick must not redeliver
        coordinator.processPendingMessages(workspacePath: ws)
        XCTAssertEqual(try inbox.task(id: task.id)?.state, .delivered)
        XCTAssertEqual(coordinator.store.sessions.filter { $0.agentKind == .codex }.count, 1)
    }

    /// Test 2: Busy assignee delays the task until idle; only one session of that kind receives it.
    @MainActor
    func testBusyAssigneeDelaysTaskAndOnlyOneSessionReceivesIt() async throws {
        let ws = tempDir.path
        let inbox = InboxStore(workspaceRoot: ws)
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }

        let busy = try coordinator.newSession(cwd: ws, agent: .codex)
        coordinator.store.updateState(id: busy.id, to: .working)
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "Analyze test coverage", files: [])

        coordinator.processPendingMessages(workspacePath: ws)
        XCTAssertEqual(try inbox.task(id: task.id)?.state, .queued)

        let idle = try coordinator.newSession(cwd: ws, agent: .codex)
        coordinator.store.updateState(id: idle.id, to: .ready)
        coordinator.processPendingMessages(workspacePath: ws)

        let t = try XCTUnwrap(inbox.task(id: task.id))
        XCTAssertEqual(t.state, .delivered)
        XCTAssertEqual(t.assigneeSessionId, idle.id)
        XCTAssertEqual(coordinator.store.sessions.filter { $0.agentKind == .codex }.count, 2)
    }

    /// Test 2b: Notices are never injected; completions and peer notes are injected once.
    @MainActor
    func testNoticesAreNeverInjectedButCompletionsAre() async throws {
        let ws = tempDir.path
        let inbox = InboxStore(workspaceRoot: ws)
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }

        let claude = try coordinator.newSession(cwd: ws, agent: .claude)
        coordinator.store.updateState(id: claude.id, to: .ready)

        let notice = try inbox.enqueue(from: .codex, to: .claude, kind: .notice, body: "Codex is rate limited")
        let echo = try inbox.enqueue(from: .codex, to: .claude, kind: .completion, taskId: "abcdef12-0000", body: "done by Codex — shipped")

        coordinator.processPendingMessages(workspacePath: ws)

        let loaded = try inbox.load()
        XCTAssertEqual(loaded.messages.first { $0.id == notice.id }?.status, .delivered)
        XCTAssertEqual(loaded.messages.first { $0.id == echo.id }?.status, .delivered)

        let out = try await waitUntil {
            coordinator.terminals.session(id: claude.id)?.recentOutput(lines: 20).contains("[linkC task abcdef12] done by Codex") ?? false
        }
        XCTAssertTrue(out)
        let noticeLeaked = coordinator.terminals.session(id: claude.id)?.recentOutput(lines: 20).contains("rate limited") ?? false
        XCTAssertFalse(noticeLeaked, "notice text must never reach a terminal")
    }

    /// Test 2c: Expiry rules — stale queue and dead assignee.
    @MainActor
    func testExpireTasksForStaleQueueAndDeadAssignee() async throws {
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }

        // Stale queue
        let ws2 = tempDir.appendingPathComponent("ws2").path
        let inbox2 = InboxStore(workspaceRoot: ws2)
        let t2 = try inbox2.createTask(from: .claude, to: .codex, prompt: "stale", files: [])
        var seeded = try inbox2.load()
        seeded.tasks[0] = TaskRecord(
            id: t2.id, fromAgent: .claude, toAgent: .codex, prompt: "stale", state: .queued,
            createdAt: Date().addingTimeInterval(-61 * 60)
        )
        try inbox2.saveRaw(seeded)
        coordinator.processPendingMessages(workspacePath: ws2)
        let stale = try XCTUnwrap(inbox2.task(id: t2.id))
        XCTAssertEqual(stale.state, .expired)
        XCTAssertEqual(stale.cancelReason, "undelivered for 60m")
        XCTAssertTrue(coordinator.store.sessions.isEmpty, "expired task must not spawn an assignee")

        // Dead assignee
        let ws3 = tempDir.appendingPathComponent("ws3").path
        try FileManager.default.createDirectory(atPath: ws3, withIntermediateDirectories: true)
        let inbox3 = InboxStore(workspaceRoot: ws3)
        let t3 = try inbox3.createTask(from: .claude, to: .codex, prompt: "started then died", files: [])
        try inbox3.markTaskDelivered(taskId: t3.id, sessionId: "no-such-session")
        try inbox3.markTaskStarted(taskId: t3.id)
        coordinator.processPendingMessages(workspacePath: ws3)
        let dead = try XCTUnwrap(inbox3.task(id: t3.id))
        XCTAssertEqual(dead.state, .failed)
        XCTAssertEqual(dead.report?.summary, "assignee session ended before reporting")
        let echo = try XCTUnwrap(inbox3.load().messages.first { $0.taskId == t3.id })
        XCTAssertEqual(echo.kind, .completion)
        XCTAssertEqual(echo.toAgent, .claude)
        XCTAssertTrue(echo.prompt.contains("failed"))
    }

    /// Test 2d: Legacy v1 `.task` rows are still dispatched once.
    @MainActor
    func testLegacyV1TaskMessageIsStillDispatched() async throws {
        let ws = tempDir.path
        let inbox = InboxStore(workspaceRoot: ws)
        var seeded = Inbox(workspacePath: ws)
        seeded.messages = [PendingMessage(id: "legacy-1", fromAgent: .claude, toAgent: .codex, prompt: "Old style brief", status: .queued, kind: .task)]
        try inbox.saveRaw(seeded)

        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }
        coordinator.processPendingMessages(workspacePath: ws)

        XCTAssertEqual(try inbox.load().messages.first?.status, .delivered)
        let codex = try XCTUnwrap(coordinator.store.sessions.first { $0.agentKind == .codex })
        let echoed = try await waitUntil {
            coordinator.terminals.session(id: codex.id)?.recentOutput(lines: 10).contains("Old style brief") ?? false
        }
        XCTAssertTrue(echoed)
    }
```

Because `inbox.json` lives *inside* the workspace, a deleted workspace has no tasks left to mark. What must hold is that the relay never spawns or injects for a missing directory and never recreates it:

```swift
    /// Test 2e: A tick for a workspace that no longer exists spawns nothing and does not recreate the directory.
    @MainActor
    func testMissingWorkspaceTickSpawnsNothingAndDoesNotRecreateDirectory() throws {
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }
        let ws = tempDir.appendingPathComponent("vanishing").path
        let inbox = InboxStore(workspaceRoot: ws)
        _ = try inbox.createTask(from: .claude, to: .codex, prompt: "brief", files: [])
        try FileManager.default.removeItem(atPath: ws)

        coordinator.processPendingMessages(workspacePath: ws)

        XCTAssertTrue(coordinator.store.sessions.isEmpty, "nothing may be spawned for a missing workspace")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ws), "relay must not recreate a deleted workspace")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AppCoordinatorRelayTests 2>&1 | tail -30`
Expected: new tests FAIL (tasks never delivered; notices injected); several old tests may still pass.

- [ ] **Step 3: Implement**

1. In `AppCoordinator.swift` change access on these four declarations (remove `private`):
   - `private let notifications: NotificationManager` → `let notifications: NotificationManager`
   - `private let claudePath: String` → `let claudePath: String`
   - `private let agentPathResolver: ...` → `let agentPathResolver: ...`
   - `private func inspectGitStatus(in:)` → `func inspectGitStatus(in:)`

2. Delete the whole `public func processPendingMessages(workspacePath:)` method (lines ~718–753) from `AppCoordinator.swift`. Leave `checkLimitsAndReroute`, `notifyDelegatorOnTaskCompletion`, and `switchModel` where they are for now (Tasks 10–11 move/replace them).

3. Create `Sources/LinkCKit/App/AppCoordinator+Relay.swift`:

```swift
import Foundation

/// Task Protocol v2 relay: delivers tasks to exactly one assignee, relays short kind-tagged
/// messages, and expires what can no longer be delivered. Never reads terminal output.
extension AppCoordinator {
    /// Queued tasks older than this are expired rather than delivered.
    static let queuedTaskExpiry: TimeInterval = 60 * 60

    /// One relay tick for `workspacePath`: expire, deliver tasks, deliver messages.
    public func processPendingMessages(workspacePath: String) {
        let norm = (workspacePath as NSString).standardizingPath
        let inboxStore = InboxStore(workspaceRoot: norm)
        expireTasks(workspacePath: norm, inboxStore: inboxStore)
        dispatchTasks(workspacePath: norm, inboxStore: inboxStore)
        dispatchMessages(workspacePath: norm, inboxStore: inboxStore)
    }

    func isIdle(_ state: SessionState) -> Bool {
        switch state {
        case .ready, .finished, .waitingIdle: return true
        case .working, .starting, .waitingPermission, .error, .ended: return false
        }
    }

    /// The text injected into the assignee's terminal. Composed at injection time; never stored as a message.
    static func deliveryFrame(for task: TaskRecord) -> String {
        """
        [linkC task \(task.shortId) from \(task.fromAgent.displayName)]
        \(task.prompt)

        When you begin, call linkc_start_task("\(task.id)"). When finished, call linkc_complete_task("\(task.id)", status, summary, commits, tests). Do not paste this brief into any reply.
        """
    }

    // MARK: - Expiry

    /// True when `path` is an existing directory. Every relay step checks this first: the inbox
    /// lives inside the workspace, so a missing workspace has nothing to deliver and must never
    /// be recreated by a store write.
    func workspaceExists(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    func expireTasks(workspacePath: String, inboxStore: InboxStore) {
        guard workspaceExists(workspacePath) else { return }
        guard let open = try? inboxStore.openTasks(), !open.isEmpty else { return }
        let now = Date()

        for task in open {
            switch task.state {
            case .queued:
                if now.timeIntervalSince(task.createdAt) > Self.queuedTaskExpiry {
                    try? inboxStore.expireTask(taskId: task.id, reason: "undelivered for 60m")
                }
            case .delivered, .started:
                let assigneeAlive = task.assigneeSessionId.flatMap { store.session(id: $0) }.map { $0.state != .ended } ?? false
                if !assigneeAlive {
                    let summary = "assignee session ended before reporting"
                    try? inboxStore.completeTask(taskId: task.id, report: TaskReport(status: "failed", summary: summary))
                    _ = try? inboxStore.enqueue(
                        from: task.toAgent, to: task.fromAgent, kind: .completion, taskId: task.id,
                        body: "failed — \(summary). linkc_get_task(\"\(task.id)\") for details."
                    )
                } else if task.leaseExpiresAt < now {
                    try? inboxStore.expireTask(taskId: task.id, reason: "lease expired")
                    _ = try? inboxStore.enqueue(
                        from: task.toAgent, to: task.fromAgent, kind: .completion, taskId: task.id,
                        body: "expired — lease lapsed without a report. linkc_get_task(\"\(task.id)\") for details."
                    )
                }
            case .done, .failed, .cancelled, .expired:
                break
            }
        }
    }

    // MARK: - Tasks

    func dispatchTasks(workspacePath: String, inboxStore: InboxStore) {
        guard workspaceExists(workspacePath) else { return }
        guard let queued = try? inboxStore.openTasks().filter({ $0.state == .queued }), !queued.isEmpty else { return }

        for task in queued {
            let candidates = store.sessions.filter {
                ($0.cwd as NSString).standardizingPath == workspacePath && $0.agentKind == task.toAgent && $0.state != .ended
            }
            var target = candidates.first { isIdle($0.state) }
            if target == nil && candidates.isEmpty {
                guard let spawned = try? spawnTeammate(in: workspacePath, agent: task.toAgent, goal: task.prompt) else { continue }
                store.updateState(id: spawned.id, to: .ready)
                target = store.session(id: spawned.id) ?? spawned
            }
            guard let session = target else { continue } // all busy: wait for a later tick

            terminals.sendInput(sessionId: session.id, text: Self.deliveryFrame(for: task))
            store.updateState(id: session.id, to: .working)
            try? inboxStore.markTaskDelivered(taskId: task.id, sessionId: session.id)
        }
    }

    // MARK: - Messages

    func dispatchMessages(workspacePath: String, inboxStore: InboxStore) {
        guard workspaceExists(workspacePath) else { return }
        guard let pending = try? inboxStore.fetchPending(), !pending.isEmpty else { return }

        for message in pending where message.status == .queued {
            if message.kind == .notice {
                try? inboxStore.markMessageDelivered(id: message.id)
                continue
            }

            var target = store.sessions.first {
                ($0.cwd as NSString).standardizingPath == workspacePath && $0.agentKind == message.toAgent && $0.state != .ended
            }
            if target == nil {
                let goal: String? = message.kind == .task ? message.prompt : nil
                guard let spawned = try? spawnTeammate(in: workspacePath, agent: message.toAgent, goal: goal) else { continue }
                store.updateState(id: spawned.id, to: .ready)
                target = store.session(id: spawned.id) ?? spawned
            }
            guard let session = target, isIdle(session.state) else { continue }

            terminals.sendInput(sessionId: session.id, text: message.prompt)
            if message.kind == .task { store.updateState(id: session.id, to: .working) }
            try? inboxStore.markMessageDelivered(id: message.id)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AppCoordinatorRelayTests 2>&1 | tail -30`
Expected: Tests 1, 2, 2b, 2c, 2d, 2e PASS; Test 5 (`testHookStopTriggersPendingMessageProcessing`) still passes (legacy `.task` row path). Tests 3, 4, 7, 8, 10, 11, 12 may fail — they are rewritten in Tasks 10–11.

- [ ] **Step 5: Commit**

```bash
git add Sources/LinkCKit/App/AppCoordinator+Relay.swift Sources/LinkCKit/App/AppCoordinator.swift Tests/LinkCKitTests/AppCoordinatorRelayTests.swift
git commit -m "feat(relay): v2 dispatcher with single-assignee task delivery, notice suppression, and expiry"
```

---

### Task 10: `relayTurnEnd` replaces terminal-scrape completion

**Files:**
- Modify: `Sources/LinkCKit/App/AppCoordinator+Relay.swift`
- Modify: `Sources/LinkCKit/App/AppCoordinator.swift` (delete `notifyDelegatorOnTaskCompletion`; call `relayTurnEnd` at its two call sites, lines ~264 and ~592)
- Modify: `Tests/LinkCKitTests/AppCoordinatorRelayTests.swift`

**Interfaces:**
- Produces: `@discardableResult public func relayTurnEnd(sessionId: String, workspacePath: String) -> Int` (number of tasks notified).

- [ ] **Step 1: Write the failing tests**

Replace Test 12 (`testTaskCompletionAutonotifiesDelegatingOrchestratorAgent`) with:

```swift
    /// Test 12: Turn end without a report sends exactly one short line, never scrollback, and never loops.
    @MainActor
    func testTurnEndWithoutReportSendsOneLineOncePerTaskAndNeverScrapes() async throws {
        let ws = tempDir.path
        let inbox = InboxStore(workspaceRoot: ws)
        let sink = RecordingSink()
        let coordinator = makeCoordinator(sink: sink)
        defer { coordinator.shutdown() }

        let cursorSession = try coordinator.newSession(cwd: ws, agent: .cursor)
        let task = try inbox.createTask(from: .claude, to: .cursor, prompt: "Build user authentication module", files: ["Auth.swift"])
        try inbox.markTaskDelivered(taskId: task.id, sessionId: cursorSession.id)
        coordinator.store.updateState(id: cursorSession.id, to: .working)

        coordinator.terminals.sendInput(sessionId: cursorSession.id, text: "Generated Auth.swift with 5 tests passing.\n")
        _ = try await waitUntil {
            coordinator.terminals.session(id: cursorSession.id)?.recentOutput(lines: 10).contains("Generated Auth.swift") ?? false
        }

        XCTAssertEqual(coordinator.relayTurnEnd(sessionId: cursorSession.id, workspacePath: ws), 1)
        XCTAssertEqual(coordinator.relayTurnEnd(sessionId: cursorSession.id, workspacePath: ws), 0, "second turn end must not notify again")

        let msgs = try inbox.load().messages
        XCTAssertEqual(msgs.count, 1)
        let line = try XCTUnwrap(msgs.first)
        XCTAssertEqual(line.kind, .completion)
        XCTAssertEqual(line.fromAgent, .cursor)
        XCTAssertEqual(line.toAgent, .claude)
        XCTAssertEqual(line.taskId, task.id)
        XCTAssertTrue(line.prompt.hasPrefix("[linkC task \(task.shortId)] Cursor Agent turn ended without a report"))
        XCTAssertFalse(line.prompt.contains("Generated Auth.swift"), "terminal output must never be relayed")
        XCTAssertFalse(line.prompt.contains("Build user authentication module"), "brief must not be echoed")

        XCTAssertEqual(try inbox.task(id: task.id)?.state, .delivered, "task stays open for the delegator to decide")
        XCTAssertTrue(sink.deliveries.contains { $0.title == "linkC: Cursor Agent turn ended" })
    }

    /// Test 12b: A completion message delivered to the delegator is never treated as a task and never re-echoed.
    @MainActor
    func testCompletionEchoIsNeverReEchoed() throws {
        let ws = tempDir.path
        let inbox = InboxStore(workspaceRoot: ws)
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }

        let claude = try coordinator.newSession(cwd: ws, agent: .claude)
        coordinator.store.updateState(id: claude.id, to: .ready)
        let echo = try inbox.enqueue(from: .codex, to: .claude, kind: .completion, taskId: "abcdef12-0000", body: "done by Codex — shipped")
        coordinator.processPendingMessages(workspacePath: ws)
        XCTAssertEqual(try inbox.load().messages.first { $0.id == echo.id }?.status, .delivered)

        coordinator.store.updateState(id: claude.id, to: .working)
        XCTAssertEqual(coordinator.relayTurnEnd(sessionId: claude.id, workspacePath: ws), 0)
        XCTAssertEqual(try inbox.load().messages.count, 1, "no new message may be produced from an echo")
    }

    /// Test 12c: Explicit completion before turn end means no 'ended without report' line.
    @MainActor
    func testExplicitCompletionSuppressesTurnEndLine() throws {
        let ws = tempDir.path
        let inbox = InboxStore(workspaceRoot: ws)
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }

        let codex = try coordinator.newSession(cwd: ws, agent: .codex)
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "Do it", files: [])
        try inbox.markTaskDelivered(taskId: task.id, sessionId: codex.id)
        try inbox.markTaskStarted(taskId: task.id)
        try inbox.completeTask(taskId: task.id, report: TaskReport(status: "done", summary: "ok"))

        XCTAssertEqual(coordinator.relayTurnEnd(sessionId: codex.id, workspacePath: ws), 0)
        XCTAssertTrue(try inbox.load().messages.isEmpty)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AppCoordinatorRelayTests 2>&1 | tail -30`
Expected: compile error — `relayTurnEnd` not found.

- [ ] **Step 3: Implement**

1. Append to the extension in `AppCoordinator+Relay.swift`:

```swift
    // MARK: - Turn end

    /// For each open task assigned to `sessionId`, sends one short "ended without report" line
    /// to the delegator — once per task. Reads no terminal output. Returns the number notified.
    @discardableResult
    public func relayTurnEnd(sessionId: String, workspacePath: String) -> Int {
        guard let session = store.session(id: sessionId), session.agentKind != .shell else { return 0 }
        let norm = (workspacePath as NSString).standardizingPath
        let inboxStore = InboxStore(workspaceRoot: norm)
        guard let open = try? inboxStore.openTasks(for: session.agentKind) else { return 0 }

        var notified = 0
        for task in open where task.assigneeSessionId == sessionId
            && (task.state == .delivered || task.state == .started)
            && !task.unreportedTurnEndNotified {
            try? inboxStore.markUnreportedTurnEndNotified(taskId: task.id)
            _ = try? inboxStore.enqueue(
                from: session.agentKind, to: task.fromAgent, kind: .completion, taskId: task.id,
                body: "\(session.agentKind.displayName) turn ended without a report. Task remains \(task.state.rawValue); linkc_get_task(\"\(task.id)\") or linkc_cancel_task(\"\(task.id)\")."
            )
            notified += 1
        }
        if notified > 0 {
            notifications.post(
                title: "linkC: \(session.agentKind.displayName) turn ended",
                body: "\(notified) task(s) still open without a report; \(open.first?.fromAgent.displayName ?? "the delegator") was told."
            )
            processPendingMessages(workspacePath: norm)
        }
        return notified
    }
```

2. In `AppCoordinator.swift`:
   - Delete the entire `notifyDelegatorOnTaskCompletion` method.
   - In `handle(_:)`: replace `notifyDelegatorOnTaskCompletion(sessionId: session.id, workspacePath: session.cwd)` with `relayTurnEnd(sessionId: session.id, workspacePath: session.cwd)`.
   - In `sampleAgentStates()`: same replacement.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AppCoordinatorRelayTests 2>&1 | tail -30`
Expected: Tests 12, 12b, 12c PASS. Remaining failures are limited to the reroute tests handled in Task 11.

- [ ] **Step 5: Commit**

```bash
git add Sources/LinkCKit/App/AppCoordinator+Relay.swift Sources/LinkCKit/App/AppCoordinator.swift Tests/LinkCKitTests/AppCoordinatorRelayTests.swift
git commit -m "feat(relay): replace terminal-scrape completion with once-per-task turn-end line"
```

---

### Task 11: Limit reroute cancels the original task and sends a notice

**Files:**
- Modify: `Sources/LinkCKit/App/AppCoordinator+Relay.swift` (new `checkLimitsAndReroute`, `resolveHandoffGoal`)
- Modify: `Sources/LinkCKit/App/AppCoordinator.swift` (delete old `checkLimitsAndReroute`; `spawnTeammate` uses `resolveHandoffGoal`)
- Modify: `Tests/LinkCKitTests/AppCoordinatorRelayTests.swift`

**Interfaces:**
- Consumes: `inspectGitStatus`, `claudePath`, `agentPathResolver`, `notifications` (made internal in Task 9).
- Produces:
  - `@discardableResult public func checkLimitsAndReroute(for sessionId: String) -> Bool` (same signature as before).
  - `func resolveHandoffGoal(workspacePath: String, explicit: String?) -> String?` — explicit → newest open `TaskRecord.prompt` → blackboard `activeAgents.last.goal` → nil.

- [ ] **Step 1: Write the failing tests**

Rewrite Tests 3, 4, 7, 8, 10, 11 in `AppCoordinatorRelayTests.swift`. Each previously seeded a legacy message with `enqueue(from:to:prompt:files:)` + `markMessageDelivered`; each now seeds a task. Replace them with:

```swift
    /// Test 3: Rate limit on a started task cancels it, writes the handoff with the task's brief, and creates a hop+1 task.
    @MainActor
    func testRateLimitCancelsOriginalTaskWritesHandoffAndCreatesHopOneTask() async throws {
        let ws = tempDir.path
        let inbox = InboxStore(workspaceRoot: ws)
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }

        let sourceSession = try coordinator.newSession(cwd: ws, agent: .claude)
        coordinator.store.updateState(id: sourceSession.id, to: .working)
        let original = try inbox.createTask(from: .cursor, to: .claude, prompt: "Build high-throughput streaming proxy", files: ["Proxy.swift"])
        try inbox.markTaskDelivered(taskId: original.id, sessionId: sourceSession.id)
        try inbox.markTaskStarted(taskId: original.id)

        coordinator.terminals.sendInput(sessionId: sourceSession.id, text: "Rate limit reached. Please try again later.\n")
        XCTAssertTrue(try await waitUntil {
            coordinator.terminals.session(id: sourceSession.id)?.recentOutput(lines: 10).contains("Rate limit reached") ?? false
        })

        XCTAssertTrue(coordinator.checkLimitsAndReroute(for: sourceSession.id))
        XCTAssertNotNil(try inbox.isAgentLimited(agent: .claude))

        let cancelled = try XCTUnwrap(inbox.task(id: original.id))
        XCTAssertEqual(cancelled.state, .cancelled)
        XCTAssertTrue(cancelled.cancelReason?.hasPrefix("rerouted to") ?? false)

        let handoff = try String(contentsOf: URL(fileURLWithPath: ws).appendingPathComponent(".linkc/HANDOFF.md"), encoding: .utf8)
        XCTAssertTrue(handoff.contains("Build high-throughput streaming proxy"))
        XCTAssertFalse(handoff.contains("[linkC task"), "handoff goal must be the brief, never a frame")

        let copy = try XCTUnwrap(inbox.openTasks().first { $0.hop == 1 })
        XCTAssertEqual(copy.fromAgent, .cursor, "delegator is preserved across hops")
        XCTAssertNotEqual(copy.toAgent, .claude)
        XCTAssertEqual(copy.prompt, original.prompt)
        XCTAssertEqual(copy.files, ["Proxy.swift"])
        XCTAssertNotNil(coordinator.store.sessions.first { $0.agentKind == copy.toAgent })

        let notice = try XCTUnwrap(inbox.load().messages.first { $0.kind == .notice })
        XCTAssertEqual(notice.toAgent, .cursor)
        XCTAssertTrue(notice.prompt.hasPrefix("[linkC notice]"))
        XCTAssertTrue(notice.prompt.contains("reached usage limit"))
    }

    /// Test 4: Circuit breaker stops re-route after 2 hops and posts an alert notification.
    @MainActor
    func testCircuitBreakerStopsRerouteAfterTwoHops() async throws {
        let ws = tempDir.path
        let inbox = InboxStore(workspaceRoot: ws)
        let sink = RecordingSink()
        let coordinator = makeCoordinator(sink: sink)
        defer { coordinator.shutdown() }

        let session = try coordinator.newSession(cwd: ws, agent: .claude)
        coordinator.store.updateState(id: session.id, to: .working)
        let hop2 = try inbox.createTask(from: .codex, to: .claude, prompt: "Complex distributed algorithm", files: [], hop: 2)
        try inbox.markTaskDelivered(taskId: hop2.id, sessionId: session.id)

        coordinator.terminals.sendInput(sessionId: session.id, text: "You've reached your usage limit\n")
        XCTAssertTrue(try await waitUntil {
            coordinator.terminals.session(id: session.id)?.recentOutput(lines: 10).contains("reached your usage limit") ?? false
        })

        _ = coordinator.checkLimitsAndReroute(for: session.id)

        XCTAssertNotNil(try inbox.isAgentLimited(agent: .claude))
        XCTAssertFalse(try inbox.load().tasks.contains { $0.hop > 2 })
        XCTAssertEqual(try inbox.task(id: hop2.id)?.state, .delivered, "breaker leaves the task for the delegator")
        XCTAssertTrue(try inbox.load().messages.contains { $0.kind == .notice && $0.toAgent == .codex })
        XCTAssertTrue(sink.deliveries.contains { $0.title == "linkC: Swarm Rate Limited" && $0.body.contains("Pausing auto-delegation") })
        XCTAssertEqual(coordinator.store.sessions.count, 1)
    }

    /// Test 7: Old cancelled/rerouted history does not block rerouting the current task.
    @MainActor
    func testRerouteIsScopedToCurrentTaskNotHistory() async throws {
        let ws = tempDir.path
        let inbox = InboxStore(workspaceRoot: ws)
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }

        let old = try inbox.createTask(from: .claude, to: .cursor, prompt: "Old task from yesterday", files: [], hop: 1)
        try inbox.cancelTask(taskId: old.id, reason: "rerouted to Codex after limit")

        let claudeSession = try coordinator.newSession(cwd: ws, agent: .claude)
        coordinator.store.updateState(id: claudeSession.id, to: .working)
        let fresh = try inbox.createTask(from: .codex, to: .claude, prompt: "New fresh task to run", files: ["Fresh.swift"])
        try inbox.markTaskDelivered(taskId: fresh.id, sessionId: claudeSession.id)

        coordinator.terminals.sendInput(sessionId: claudeSession.id, text: "Rate limit reached. Try later.\n")
        XCTAssertTrue(try await waitUntil {
            coordinator.terminals.session(id: claudeSession.id)?.recentOutput(lines: 10).contains("Rate limit reached") ?? false
        })

        XCTAssertTrue(coordinator.checkLimitsAndReroute(for: claudeSession.id))
        let copy = try XCTUnwrap(inbox.openTasks().first { $0.prompt == "New fresh task to run" })
        XCTAssertEqual(copy.hop, 1)
        XCTAssertEqual(try inbox.task(id: fresh.id)?.state, .cancelled)
    }

    /// Test 8: Uninstalled candidates are skipped.
    @MainActor
    func testCheckLimitsAndRerouteSkipsUninstalledCandidateAgents() async throws {
        let ws = tempDir.path
        let scriptURL = tempDir.appendingPathComponent("mock_agent.sh")
        if !FileManager.default.fileExists(atPath: scriptURL.path) {
            try? "#!/bin/sh\nexec /bin/cat\n".write(to: scriptURL, atomically: true, encoding: .utf8)
            var attrs = (try? FileManager.default.attributesOfItem(atPath: scriptURL.path)) ?? [:]
            attrs[.posixPermissions] = 0o755
            try? FileManager.default.setAttributes(attrs, ofItemAtPath: scriptURL.path)
        }
        let settingsDir = tempDir.appendingPathComponent("settings_uninstalled_test")
        try? FileManager.default.createDirectory(at: settingsDir, withIntermediateDirectories: true)
        let coordinator = AppCoordinator(
            terminals: TerminalSessionManager(),
            hookServer: HookServer(port: 0),
            notifications: NotificationManager(sink: RecordingSink(), now: { Date() }),
            claudePath: scriptURL.path,
            settingsDir: settingsDir,
            userSettingsURL: tempDir.appendingPathComponent("user-settings.json"),
            manifestDir: tempDir.appendingPathComponent("manifest_uninstalled_test"),
            agentPathResolver: { kind in kind == .codex ? nil : scriptURL.path },
            isWatching: { _ in false }
        )
        defer { coordinator.shutdown() }

        let inbox = InboxStore(workspaceRoot: ws)
        let claudeSession = try coordinator.newSession(cwd: ws, agent: .claude)
        coordinator.store.updateState(id: claudeSession.id, to: .working)
        let task = try inbox.createTask(from: .cursor, to: .claude, prompt: "Deploy service mesh", files: [])
        try inbox.markTaskDelivered(taskId: task.id, sessionId: claudeSession.id)

        coordinator.terminals.sendInput(sessionId: claudeSession.id, text: "Rate limit reached\n")
        XCTAssertTrue(try await waitUntil {
            coordinator.terminals.session(id: claudeSession.id)?.recentOutput(lines: 10).contains("Rate limit reached") ?? false
        })

        XCTAssertTrue(coordinator.checkLimitsAndReroute(for: claudeSession.id))
        let copy = try XCTUnwrap(inbox.openTasks().first { $0.hop == 1 })
        XCTAssertEqual(copy.toAgent, .agy, "Uninstalled .codex must be skipped; .agy must be selected")
    }

    /// Test 10: Candidates with an active session in the workspace are preferred.
    @MainActor
    func testCheckLimitsAndReroutePrioritizesAgentWithActiveSessionInWorkspace() async throws {
        let ws = tempDir.path
        let inbox = InboxStore(workspaceRoot: ws)
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }

        let claudeSession = try coordinator.newSession(cwd: ws, agent: .claude)
        coordinator.store.updateState(id: claudeSession.id, to: .working)
        let cursorSession = try coordinator.newSession(cwd: ws, agent: .cursor)
        coordinator.store.updateState(id: cursorSession.id, to: .ready)

        let task = try inbox.createTask(from: .shell, to: .claude, prompt: "Refactor router", files: ["Router.swift"])
        try inbox.markTaskDelivered(taskId: task.id, sessionId: claudeSession.id)

        coordinator.terminals.sendInput(sessionId: claudeSession.id, text: "Rate limit reached\n")
        XCTAssertTrue(try await waitUntil {
            coordinator.terminals.session(id: claudeSession.id)?.recentOutput(lines: 10).contains("Rate limit reached") ?? false
        })

        XCTAssertTrue(coordinator.checkLimitsAndReroute(for: claudeSession.id))
        let copy = try XCTUnwrap(inbox.openTasks().first { $0.hop == 1 })
        XCTAssertEqual(copy.toAgent, .cursor, "Active .cursor session in workspace must be prioritized over .codex")
    }

    /// Test 11: The limit alert to the delegator is a notice (never injected) and a desktop notification.
    @MainActor
    func testLimitDetectionSendsNoticeToDelegatingAgent() async throws {
        let ws = tempDir.path
        let inbox = InboxStore(workspaceRoot: ws)
        let sink = RecordingSink()
        let coordinator = makeCoordinator(sink: sink)
        defer { coordinator.shutdown() }

        let codexSession = try coordinator.newSession(cwd: ws, agent: .codex)
        coordinator.store.updateState(id: codexSession.id, to: .finished)
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "Optimize database indices", files: ["schema.sql"])
        try inbox.markTaskDelivered(taskId: task.id, sessionId: codexSession.id)

        coordinator.terminals.sendInput(sessionId: codexSession.id, text: "429 Too Many Requests\n")
        XCTAssertTrue(try await waitUntil {
            coordinator.terminals.session(id: codexSession.id)?.recentOutput(lines: 10).contains("429 Too Many Requests") ?? false
        })

        XCTAssertTrue(coordinator.checkLimitsAndReroute(for: codexSession.id))
        let notice = try XCTUnwrap(inbox.load().messages.first { $0.kind == .notice && $0.fromAgent == .codex && $0.toAgent == .claude })
        XCTAssertTrue(notice.prompt.contains("Codex reached usage limit: '429 Too Many Requests'"))
        XCTAssertTrue(notice.prompt.contains("Free fallback model"))
        XCTAssertEqual(notice.taskId, task.id)
        XCTAssertTrue(sink.deliveries.contains { $0.title == "linkC: Codex Rate Limited" && $0.body.contains("429 Too Many Requests") })
    }
```

Keep Tests 5, 6, 9 unchanged (they do not depend on message shape).

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AppCoordinatorRelayTests 2>&1 | tail -30`
Expected: Tests 3, 4, 7, 8, 10, 11 FAIL (old implementation reads messages, not tasks).

- [ ] **Step 3: Implement**

1. Delete the old `checkLimitsAndReroute(for:)` from `AppCoordinator.swift`.

2. In `AppCoordinator.swift` `spawnTeammate`, replace the block from `var lastGoal: String? = goal` through the inbox fallback (`if lastGoal == nil { let inboxStore = ...  }`) with:

```swift
        let lastGoal = resolveHandoffGoal(workspacePath: norm, explicit: goal)
```

3. Append to `AppCoordinator+Relay.swift`:

```swift
    // MARK: - Handoff goal

    /// Explicit goal → newest open task's brief → blackboard goal → nil. Never reads messages.
    func resolveHandoffGoal(workspacePath: String, explicit: String?) -> String? {
        if let explicit = explicit?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            return explicit
        }
        let norm = (workspacePath as NSString).standardizingPath
        if let open = try? InboxStore(workspaceRoot: norm).openTasks(), let newest = open.last {
            return newest.prompt
        }
        if let board = try? BlackboardStore(workspaceRoot: norm).load(timeout: 0.5),
           let goal = board.activeAgents.last?.goal, !goal.isEmpty, goal != "(idle)" {
            return goal
        }
        return nil
    }

    // MARK: - Limits and reroute

    /// Detects a provider limit in `sessionId`'s recent output (the one place terminal text is read,
    /// and only for pattern matching). Records the cooldown, tells the delegator via a `.notice`,
    /// cancels the current task, and creates a hop+1 copy for the best available peer (max 2 hops).
    @discardableResult
    public func checkLimitsAndReroute(for sessionId: String) -> Bool {
        guard let session = store.session(id: sessionId) else { return false }
        guard session.agentKind != .shell, session.state != .ended else { return false }

        let norm = (session.cwd as NSString).standardizingPath
        let recentOutput = terminals.session(id: sessionId)?.recentOutput(lines: 50) ?? ""
        guard let match = LimitDetector.detectLimit(inOutput: recentOutput, agent: session.agentKind) else { return false }

        let inboxStore = InboxStore(workspaceRoot: norm)
        try? inboxStore.recordLimit(agent: session.agentKind, reason: match.matchedPattern, cooldown: match.cooldown)

        // Current task: newest open task assigned to this exact session.
        let currentTask = (try? inboxStore.openTasks(for: session.agentKind))?
            .filter { $0.assigneeSessionId == sessionId && ($0.state == .delivered || $0.state == .started) }
            .last

        // Tell the delegator (notice: shown in inbox/dashboard, never injected).
        if let currentTask, currentTask.fromAgent != session.agentKind {
            let fallback = AgentModelCatalog.fallbackModels(for: session.agentKind).first?.displayName ?? "fallback"
            _ = try? inboxStore.enqueue(
                from: session.agentKind, to: currentTask.fromAgent, kind: .notice, taskId: currentTask.id,
                body: "\(session.agentKind.displayName) reached usage limit: '\(match.matchedPattern)'. Free fallback model '\(fallback)' is available. Task \(currentTask.shortId) paused."
            )
            notifications.post(
                title: "linkC: \(session.agentKind.displayName) Rate Limited",
                body: "\(session.agentKind.displayName) reached usage limit: '\(match.matchedPattern)'. Free fallback model '\(fallback)' is available."
            )
        }

        // Candidates: installed, not limited, not this agent; prefer ones already active here.
        let supportedPeers: [AgentKind] = [.claude, .codex, .agy, .cursor]
        var candidates = supportedPeers.filter { candidate in
            guard candidate != session.agentKind else { return false }
            guard (try? inboxStore.isAgentLimited(agent: candidate)) == nil else { return false }
            if candidate == .claude {
                return FileManager.default.isExecutableFile(atPath: claudePath)
                    || (agentPathResolver?(candidate) ?? AgentDescriptor.resolveExecutable(for: candidate)) != nil
            }
            if let resolver = agentPathResolver { return resolver(candidate) != nil }
            return AgentDescriptor.resolveExecutable(for: candidate) != nil
        }
        candidates.sort { a, b in
            let aActive = store.sessions.contains { ($0.cwd as NSString).standardizingPath == norm && $0.agentKind == a && $0.state != .ended }
            let bActive = store.sessions.contains { ($0.cwd as NSString).standardizingPath == norm && $0.agentKind == b && $0.state != .ended }
            return aActive && !bActive
        }

        let hop = currentTask?.hop ?? 0
        guard hop < 2, let target = candidates.first else {
            store.updateState(id: session.id, to: .error)
            notifications.post(
                title: "linkC: Swarm Rate Limited",
                body: "All candidate agents in \(URL(fileURLWithPath: norm).lastPathComponent) are rate limited or the task has exhausted its reroute hops. Pausing auto-delegation."
            )
            return true
        }

        // Handoff memo from the task's brief (never from messages).
        _ = try? HandoffComposer.writeHandoffSync(
            workspacePath: norm,
            sourceAgent: session.agentKind,
            lastGoal: resolveHandoffGoal(workspacePath: norm, explicit: currentTask?.prompt),
            gitSummary: inspectGitStatus(in: norm),
            recentTerminalOutput: recentOutput
        )

        if let currentTask {
            try? inboxStore.cancelTask(taskId: currentTask.id, reason: "rerouted to \(target.displayName) after limit")
            _ = try? inboxStore.createTask(
                from: currentTask.fromAgent, to: target, prompt: currentTask.prompt,
                files: currentTask.files, hop: hop + 1, force: true
            )
        } else {
            _ = try? inboxStore.createTask(
                from: session.agentKind, to: target,
                prompt: "Task rerouted from \(session.agentKind.displayName) due to rate limit (\(match.matchedPattern)). Inspect .linkc/HANDOFF.md and continue.",
                files: [], hop: hop + 1, force: true
            )
        }

        store.updateState(id: session.id, to: .error)
        processPendingMessages(workspacePath: norm)
        return true
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AppCoordinatorRelayTests 2>&1 | tail -30`
Expected: all `AppCoordinatorRelayTests` PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LinkCKit/App/AppCoordinator+Relay.swift Sources/LinkCKit/App/AppCoordinator.swift Tests/LinkCKitTests/AppCoordinatorRelayTests.swift
git commit -m "feat(relay): reroute cancels the original task, sends a notice, and sources the handoff goal from tasks"
```

---

### Task 12: App heartbeats its own sessions

**Files:**
- Modify: `Sources/LinkCKit/App/AppCoordinator.swift` (`sampleAgentStates`)
- Test: `Tests/LinkCKitTests/AppCoordinatorRelayTests.swift`

**Interfaces:**
- Consumes: `BlackboardStore.heartbeat`, `TerminalSession.processId`.

- [ ] **Step 1: Write the failing test**

Append to `AppCoordinatorRelayTests`:

```swift
    /// Test 13: sampleAgentStates heartbeats every live non-shell session so presence is truthful.
    @MainActor
    func testSampleAgentStatesHeartbeatsLiveSessions() throws {
        let ws = tempDir.path
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }
        let codex = try coordinator.newSession(cwd: ws, agent: .codex)
        _ = try coordinator.newSession(cwd: ws, agent: .shell)

        coordinator.sampleAgentStates()

        let board = try BlackboardStore(workspaceRoot: ws).load()
        let rec = try XCTUnwrap(board.activeAgents.first { $0.agentKind == .codex })
        XCTAssertEqual(rec.pid, coordinator.terminals.session(id: codex.id)?.processId)
        XCTAssertGreaterThan(rec.pid, 0)
        XCTAssertFalse(board.activeAgents.contains { $0.agentKind == .shell })
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AppCoordinatorRelayTests/testSampleAgentStatesHeartbeatsLiveSessions 2>&1 | tail -10`
Expected: FAIL — no codex record on the blackboard.

- [ ] **Step 3: Implement**

In `sampleAgentStates()`, inside the `for session in store.sessions where session.state != .ended` loop, right after `guard let term = terminals.session(id: session.id) else { continue }`, insert:

```swift
            if session.agentKind != .shell, term.processId > 0 {
                try? BlackboardStore(workspaceRoot: (session.cwd as NSString).standardizingPath)
                    .heartbeat(agentKind: session.agentKind, pid: term.processId, timeout: 0.5)
            }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AppCoordinatorRelayTests 2>&1 | tail -10`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LinkCKit/App/AppCoordinator.swift Tests/LinkCKitTests/AppCoordinatorRelayTests.swift
git commit -m "feat(presence): app heartbeats its own agent sessions on every sample tick"
```

---

### Task 13: Dashboard aggregator reads `kind` and shows tasks

**Files:**
- Modify: `Sources/LinkCKit/Blackboard/AgentDashboardAggregator.swift`
- Modify: `Tests/LinkCKitTests/AgentDashboardAggregatorTests.swift`

**Interfaces:**
- Consumes: `PendingMessage.kind`, `Inbox.tasks`.
- Produces: timeline items with ids `task-<id>` for open and terminal tasks; completion detection by `kind == .completion`.

- [ ] **Step 1: Update tests**

In `AgentDashboardAggregatorTests.swift`, wherever a test seeds a delegated task via the legacy `enqueue(from:to:prompt:files:)` + `markMessageDelivered`, replace with `createTask` + `markTaskDelivered(taskId:sessionId: "s")`. Wherever it seeds a completion via the `"[Task Completed by Cursor Agent]…"` string, replace with `enqueue(from: .cursor, to: .claude, kind: .completion, taskId: task.id, body: "done by Cursor Agent — Generated Auth.swift with 5 tests passing.")`. Update assertions that previously looked for `"Result / Output"`-stripped bodies to expect the body text `"done by Cursor Agent — Generated Auth.swift with 5 tests passing."`. Add one assertion to the main project-aggregation test (the result variable there is `data`, the items property is `activityItems`), and bump its `XCTAssertEqual(data.activityItems.count, 4)` to `5` because the delegated task now yields a `task-…` item in addition to the completion message:

```swift
        XCTAssertTrue(data.activityItems.contains { $0.id == "task-\(task.id)" && $0.kind == .delegatedTask && $0.title.contains("delegated task to Cursor Agent") })
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AgentDashboardAggregatorTests 2>&1 | tail -20`
Expected: FAIL — no `task-…` item; completion not detected.

- [ ] **Step 3: Implement**

In `aggregateProject`, replace `let isCompletion = msg.prompt.hasPrefix("[Task Completed by")` with `let isCompletion = msg.kind == .completion`, and replace the `Result / Output:` stripping with:

```swift
                if let bracket = msg.prompt.firstIndex(of: "]") {
                    itemBody = String(msg.prompt[msg.prompt.index(after: bracket)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    itemBody = msg.prompt
                }
```

Skip `.notice` and `.command` messages entirely (`if msg.kind == .notice || msg.kind == .command { continue }`) at the top of the loop.

After the message loop, add a task loop:

```swift
        // 1b. Process Tasks
        for task in inbox.tasks {
            let done = !task.state.isOpen
            for file in task.files { claimedFilesByAgent[task.toAgent, default: []].insert(file) }
            if task.state == .done { completedCounts[task.toAgent, default: 0] += 1 }
            activityItems.append(
                AgentActivityItem(
                    id: "task-\(task.id)",
                    timestamp: task.finishedAt ?? task.deliveredAt ?? task.createdAt,
                    workspacePath: norm,
                    projectTitle: title,
                    fromAgent: task.fromAgent,
                    toAgent: task.toAgent,
                    kind: done ? .completedTask : .delegatedTask,
                    title: "\(task.fromAgent.displayName) delegated task to \(task.toAgent.displayName) [\(task.state.rawValue)]",
                    body: task.report?.summary ?? task.prompt,
                    claimedFiles: task.files
                )
            )
        }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter "AgentDashboardAggregatorTests|AppCoordinatorDashboardTests|DashboardModelsTests" 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LinkCKit/Blackboard/AgentDashboardAggregator.swift Tests/LinkCKitTests/AgentDashboardAggregatorTests.swift
git commit -m "feat(dashboard): aggregate by message kind and surface task lifecycle items"
```

---

### Task 14: Remove the legacy `enqueue`, amend the spec, full test run

**Files:**
- Modify: `Sources/LinkCKit/Blackboard/InboxStore.swift`
- Modify: any remaining caller of the deprecated `enqueue(from:to:prompt:files:rerouteCount:)` (find with the command below; expected only in tests)
- Modify: `docs/superpowers/specs/2026-09-09-task-protocol-v2-completion-leases-and-loop-guard-design.md`

- [ ] **Step 1: Find remaining legacy callers**

Run: `rg -n "enqueue\(\s*$|enqueue\(from: .*prompt:" Sources Tests`
Expected: matches only in tests (`InboxStoreTests.testEnqueueAddsMessageWithQueuedStatus`, `testFetchPendingReturnsQueuedMessagesInFIFOOrder`, `testMarkDeliveredTransitionsStatusAndStampsDeliveredAt`, `testConcurrentFlockPreventsCorruption`, and any left in `AgentDashboardAggregatorTests`).

- [ ] **Step 2: Migrate those tests**

- `testEnqueueAddsMessageWithQueuedStatus` → seed with `enqueue(from: .claude, to: .codex, kind: .peerNote, body: "Implement ShellTerminalStore tests")`; assert `msg.kind == .peerNote`, `msg.prompt == "[Peer Note from Claude Code]: Implement ShellTerminalStore tests"`, `msg.claimedFiles.isEmpty`.
- `testFetchPendingReturnsQueuedMessagesInFIFOOrder` and `testMarkDeliveredTransitionsStatusAndStampsDeliveredAt` → use `kind: .peerNote, body: "Task N"`.
- `testConcurrentFlockPreventsCorruption` → `enqueue(from: .claude, to: .codex, kind: .peerNote, body: "Concurrent prompt \(i)")`.
- `AppCoordinatorRelayTests.testHookStopTriggersPendingMessageProcessing` (Test 5) → replace the legacy `enqueue` with `let task = try inbox.createTask(from: .codex, to: .claude, prompt: "Review PR #42", files: [])` and change the wait predicate to `(try? inbox.task(id: task.id))?.state == .delivered`.

- [ ] **Step 3: Delete the legacy method**

Remove the deprecated `enqueue(from:to:prompt:files:rerouteCount:timeout:)` from `InboxStore.swift`.

Run: `swift build --build-tests 2>&1 | rg -n "error:|warning: .*deprecated"`
Expected: no output.

- [ ] **Step 4: Amend the spec for `MessageKind.command` and missing-workspace handling**

In the spec §5.3, change the enum listing to include `case command // raw text injected verbatim (e.g. "/model sonnet" from linkc_switch_model); no frame` and add to §7.3 `linkc_switch_model`: "When no in-process switcher exists, the command is enqueued as `kind: .command` and injected verbatim."

In §8.3 replace the first bullet ("Workspace directory does not exist → every open task for it → `expired("workspace missing")`") with: "Workspace directory does not exist → the relay tick returns without spawning, injecting, or writing. `inbox.json` lives inside the workspace, so there is nothing left to mark and a store write would recreate the deleted directory."

- [ ] **Step 5: Full test run**

Run: `swift test 2>&1 | tail -30`
Expected: all tests PASS (the concurrently edited `CursorPtyTests` may be skipped or fail for reasons unrelated to this work; note it but do not modify that file).

- [ ] **Step 6: Commit**

```bash
git add Sources/LinkCKit/Blackboard/InboxStore.swift Tests/LinkCKitTests/InboxStoreTests.swift Tests/LinkCKitTests/AgentDashboardAggregatorTests.swift Tests/LinkCKitTests/AppCoordinatorRelayTests.swift docs/superpowers/specs/2026-09-09-task-protocol-v2-completion-leases-and-loop-guard-design.md
git commit -m "refactor(inbox): remove legacy v1 enqueue; document MessageKind.command and missing-workspace behaviour"
```

---

### Task 15: Rebuild and re-register the MCP binary

**Files:** none in the repo (operational step so the running clients pick up identity and the new tools).

- [ ] **Step 1: Build the release binary and install**

Run: `swift build -c release --product linkc-mcp 2>&1 | tail -3 && cp .build/release/linkc-mcp ~/.local/bin/linkc-mcp && ~/.local/bin/linkc-mcp --install`
Expected: `✓ linkc-multiplier MCP registered across Claude, Cursor, Codex, and Antigravity`

- [ ] **Step 2: Verify identity env landed**

Run: `rg -n "LINKC_AGENT" ~/.cursor/mcp.json ~/.claude.json ~/.codex/config.toml`
Expected: one match per file with the matching agent kind.

- [ ] **Step 3: Smoke test the stdio server**

Run:
```bash
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | LINKC_AGENT=cursor ~/.local/bin/linkc-mcp | rg -o '"version":"0.2.0"|linkc_complete_task|"listChanged":false'
```
Expected: three lines: `"version":"0.2.0"`, `linkc_complete_task`, `"listChanged":false`.

Note for the user: clients that cached the old tool list need a reconnect to see the five new tools; nothing they already call has changed.

---

## Self-Review

**Spec coverage**

| Spec section | Task |
|---|---|
| §5.1 states/transitions | 1, 2 |
| §5.2 `TaskRecord`, lease | 1, 2 |
| §5.3 `MessageKind`, hash | 1, 3 (+ `.command`, Task 14) |
| §5.4 v2 decode, pruning | 1, 2 |
| §6 store API, loop guard, dedupe, rename | 2, 3, 14 |
| §7.1 stability, version, `listChanged` | 7 |
| §7.2 identity, heartbeat, read-only set | 5 |
| §7.3 tools | 6, 7 |
| §7.4 frame markers | 1, 3, 9 |
| §8.1 `dispatchTasks` | 9 |
| §8.2 `dispatchMessages` | 9 |
| §8.3 `expireTasks` | 9 |
| §8.4 `relayTurnEnd` | 10 |
| §8.5 reroute | 11 |
| §8.6 handoff goal | 11 |
| §9 registrar env | 8 |
| §10 heartbeat, ancestors, app heartbeat | 4, 12 |
| §11 dashboard | 13 |
| §12 error handling | 2, 5, 6, 7 (InboxError → isError results) |
| §13 tests | each task |
| §14 rollout | 9 (legacy `.task` dispatch), 15 |

**Type consistency**: `markMessageDelivered(id:)`, `markTaskDelivered(taskId:sessionId:)`, `markTaskStarted(taskId:)`, `completeTask(taskId:report:)`, `cancelTask(taskId:reason:)`, `expireTask(taskId:reason:)`, `openTasks(for:)`, `task(id:)`, `enqueue(from:to:kind:taskId:body:)`, `createTask(from:to:prompt:files:hop:force:)`, `resolveCaller(_:) -> MCPCaller`, `relayTurnEnd(sessionId:workspacePath:) -> Int`, `resolveHandoffGoal(workspacePath:explicit:)`, `TerminalSession.processId`, `BlackboardStore.heartbeat(agentKind:pid:)`, `ProcessSnooper.detectAgent(inAncestorsOf:maxDepth:)` are used with the same names and parameter labels in every task above.

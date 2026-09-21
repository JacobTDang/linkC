# Session Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Relaunching linkC brings back each session on its own conversation and never two on one, and agents linkC started for tasks close themselves once they have sat idle for 10 minutes with no task.

**Architecture:** Two pure decisions in LinkCKit — `RelaunchPlan` (what comes back, what goes to Earlier, what is dropped) and `WorkerReaper` (which workers to close now) — plus an `isWorker` flag on `Session` and `RestorableSession`. `AppCoordinator` keeps conversation ids through saves, marks the relay's spawns as workers, adopts a worker when the user opens it, runs the plan at relaunch, and runs the reaper as a relay phase.

**Tech Stack:** Swift 6 (strict concurrency), SwiftPM, XCTest. macOS 14.

**Spec:** `docs/superpowers/specs/2026-09-20-session-lifecycle-design.md`

## Global Constraints

- No new dependencies. Mock data only in tests; no test-only branches in production code.
- Commit messages must never contain the word "claude" in any case, and carry no `Co-Authored-By`, `Claude-Session`, or "Generated with" trailers. Check with `git log -1 --format=%B | grep -ci claude` → `0`.
- Never run `./build-app.sh`, install or launch the app, or touch `~/.local/bin/linkc-mcp` — the user's live agent sessions run inside the installed app.
- Never close a session the user opened. Only the relay's spawns are workers; opening a worker's terminal (`focusSession`) makes it the user's for good.
- Idle grace: **10 minutes**. Idle states: `ready`, `finished`, `waitingIdle` — never `starting`, `working`, `waitingPermission`, `error`.
- A worker holds a task when an open task (`TaskState.isOpen`) has `assigneeSessionId` equal to its id.
- When entries compete for one conversation, the last in manifest order wins (most recently launched).
- `RestorableSession.isWorker` is optional on decode: an old manifest's entries read as the user's.
- Relay phases follow the convention: return `true` on an inbox lock timeout (`isRelayLockTimeout`) to end the tick; log other failures with `NSLog`; never throw.
- Run one test class with `swift test --filter LinkCKitTests.<ClassName>`; the full suite with `swift test`. Both take minutes — Bash timeout 600000 ms.

---

### Task 1: The relaunch plan

**Files:**
- Modify: `Sources/LinkCKit/App/WorkspaceManifest.swift` (`RestorableSession`: new `isWorker` field, init parameter, coding key, decode, encode)
- Create: `Sources/LinkCKit/App/RelaunchPlan.swift`
- Test: `Tests/LinkCKitTests/RelaunchPlanTests.swift`

**Interfaces:**
- Consumes: `RestorableSession` (`linkcId`, `claudeSessionId`, `cwd`, `agentKind`), `AgentKind`
- Produces:
  - `RestorableSession.isWorker: Bool` (`var`), and `isWorker: Bool = false` as the last `init` parameter
  - `RelaunchPlan` with `relaunch: [String]`, `toEarlier: [String]`, `drop: [String]` (linkC ids, each in manifest order)
  - `RelaunchPlan.make(entries: [RestorableSession], workersHoldingTasks: Set<String>) -> RelaunchPlan`

Rules (from the spec): a worker not in `workersHoldingTasks` is dropped. Among the rest, a Claude entry with an id competes with every other entry carrying the same id; any other entry competes with every entry of the same agent in the same standardized folder; the last in each contest is relaunched and the others go to Earlier. An id-less Claude entry also goes to Earlier when a Claude entry in the same folder resumes by id — it would continue that same newest conversation.

- [ ] **Step 1: Write the failing tests**

Create `Tests/LinkCKitTests/RelaunchPlanTests.swift`:

```swift
import XCTest
@testable import LinkCKit

final class RelaunchPlanTests: XCTestCase {
    private func entry(
        _ id: String, _ agent: AgentKind = .claude, cwd: String = "/p/linkC",
        conversation: String? = nil, worker: Bool = false
    ) -> RestorableSession {
        RestorableSession(
            linkcId: id, claudeSessionId: conversation, cwd: cwd, title: "t", agentKind: agent,
            wasActiveOnQuit: true, endedAt: nil, isWorker: worker)
    }

    private func plan(_ entries: [RestorableSession], holding: Set<String> = []) -> RelaunchPlan {
        RelaunchPlan.make(entries: entries, workersHoldingTasks: holding)
    }

    func testAClaudeSessionWithAnIdComesBack() {
        let result = plan([entry("A", conversation: "c1")])
        XCTAssertEqual(result, RelaunchPlan(relaunch: ["A"], toEarlier: [], drop: []))
    }

    func testTwoEntriesOnOneConversationBringBackOnlyTheLast() {
        let result = plan([entry("A", conversation: "c1"), entry("B", conversation: "c1")])
        XCTAssertEqual(result, RelaunchPlan(relaunch: ["B"], toEarlier: ["A"], drop: []))
    }

    func testOneContinuePerFolderAndAgentTheNewestWinning() {
        let result = plan([entry("A", .agy), entry("B", .agy), entry("C", .agy, cwd: "/p/other")])
        XCTAssertEqual(result, RelaunchPlan(relaunch: ["B", "C"], toEarlier: ["A"], drop: []))
    }

    func testDifferentAgentsInOneFolderEachContinue() {
        let result = plan([entry("A", .agy), entry("B", .cursor), entry("C", .codex)])
        XCTAssertEqual(result.relaunch, ["A", "B", "C"])
        XCTAssertEqual(result.toEarlier, [])
    }

    func testAnIdlessClaudeEntryYieldsToOneResumingByIdInTheSameFolder() {
        let result = plan([entry("A", conversation: "c1"), entry("B")])
        XCTAssertEqual(result, RelaunchPlan(relaunch: ["A"], toEarlier: ["B"], drop: []))
    }

    func testAnIdlessClaudeEntryContinuesWhenNoneResumesInItsFolder() {
        let result = plan([entry("A", conversation: "c1", cwd: "/p/one"), entry("B", cwd: "/p/two")])
        XCTAssertEqual(result.relaunch, ["A", "B"])
    }

    func testAWorkerComesBackOnlyWhileItHoldsATask() {
        let result = plan(
            [entry("W1", .codex, worker: true), entry("W2", .codex, cwd: "/p/other", worker: true)],
            holding: ["W1"])
        XCTAssertEqual(result, RelaunchPlan(relaunch: ["W1"], toEarlier: [], drop: ["W2"]))
    }

    func testFoldersCompareStandardized() {
        let result = plan([entry("A", .agy, cwd: "/p/linkC/"), entry("B", .agy, cwd: "/p/./linkC")])
        XCTAssertEqual(result, RelaunchPlan(relaunch: ["B"], toEarlier: ["A"], drop: []))
    }

    func testAnOldManifestEntryReadsAsTheUsers() throws {
        let json = #"{"linkcId":"A","cwd":"/p","title":"t","agentKind":"claude","wasActiveOnQuit":true}"#
        let decoded = try JSONDecoder().decode(RestorableSession.self, from: Data(json.utf8))
        XCTAssertFalse(decoded.isWorker)
    }

    func testIsWorkerSurvivesARoundTrip() throws {
        let original = entry("W", .codex, worker: true)
        let decoded = try JSONDecoder().decode(RestorableSession.self, from: JSONEncoder().encode(original))
        XCTAssertTrue(decoded.isWorker)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter LinkCKitTests.RelaunchPlanTests`
Expected: build FAILS ("cannot find 'RelaunchPlan' in scope", extra argument `isWorker`).

- [ ] **Step 3: Add `isWorker` to `RestorableSession`**

In `Sources/LinkCKit/App/WorkspaceManifest.swift`, in `RestorableSession`:

- Add the property after `endedAt`:

```swift
    /// A session linkC started to carry a delegated task, not one the user opened. Workers leave
    /// nothing under Earlier and come back on relaunch only while they still hold a task.
    public var isWorker: Bool
```

- Add `isWorker: Bool = false` as the last `init` parameter and `self.isWorker = isWorker` in its body.
- Add `case isWorker` to `CodingKeys`.
- In `init(from:)`: `isWorker = try container.decodeIfPresent(Bool.self, forKey: .isWorker) ?? false`
- In `encode(to:)`: `try container.encode(isWorker, forKey: .isWorker)`

- [ ] **Step 4: Write `RelaunchPlan`**

Create `Sources/LinkCKit/App/RelaunchPlan.swift`:

```swift
import Foundation

/// What a relaunch does with each session that was live at quit: bring it back, file it under
/// Earlier, or drop it. Pure — every input is a value — so each rule is tested without launching
/// anything.
///
/// Two sessions must never land on one conversation. A Claude entry with an id resumes exactly
/// that conversation; every other entry can only continue its folder's newest conversation for
/// its agent, so at most one per folder and agent may. Whenever entries compete, the last in
/// manifest order wins: it was launched most recently.
public struct RelaunchPlan: Equatable, Sendable {
    /// Entries to launch again, in manifest order.
    public let relaunch: [String]
    /// Entries kept, stamped ended, and shown under Earlier for the user to restore by hand.
    public let toEarlier: [String]
    /// Worker entries that hold no task: removed from the manifest.
    public let drop: [String]

    public init(relaunch: [String], toEarlier: [String], drop: [String]) {
        self.relaunch = relaunch
        self.toEarlier = toEarlier
        self.drop = drop
    }

    public static func make(entries: [RestorableSession], workersHoldingTasks: Set<String>) -> RelaunchPlan {
        var drop: [String] = []
        var candidates: [RestorableSession] = []
        for entry in entries {
            if entry.isWorker && !workersHoldingTasks.contains(entry.linkcId) {
                drop.append(entry.linkcId)
            } else {
                candidates.append(entry)
            }
        }

        var winner: [String: String] = [:]   // contest key → the last entry's linkC id
        for entry in candidates { winner[contestKey(entry)] = entry.linkcId }

        // An id-less Claude entry would continue its folder's newest conversation — the one a
        // Claude entry resuming by id in the same folder is about to reopen. Never both.
        let foldersResumingClaude = Set(candidates.filter(resumesClaudeById).map(folder))

        var relaunch: [String] = []
        var toEarlier: [String] = []
        for entry in candidates {
            let wonItsContest = winner[contestKey(entry)] == entry.linkcId
            let yieldsToResume = entry.agentKind == .claude && !resumesClaudeById(entry)
                && foldersResumingClaude.contains(folder(entry))
            if wonItsContest && !yieldsToResume {
                relaunch.append(entry.linkcId)
            } else {
                toEarlier.append(entry.linkcId)
            }
        }
        return RelaunchPlan(relaunch: relaunch, toEarlier: toEarlier, drop: drop)
    }

    private static func folder(_ entry: RestorableSession) -> String {
        (entry.cwd as NSString).standardizingPath
    }

    private static func resumesClaudeById(_ entry: RestorableSession) -> Bool {
        entry.agentKind == .claude && !(entry.claudeSessionId ?? "").isEmpty
    }

    /// Two entries with the same key would open the same conversation.
    private static func contestKey(_ entry: RestorableSession) -> String {
        if resumesClaudeById(entry), let id = entry.claudeSessionId {
            return "id|\(id)"
        }
        return "continue|\(folder(entry))|\(entry.agentKind.rawValue)"
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter LinkCKitTests.RelaunchPlanTests && swift test --filter LinkCKitTests.WorkspaceManifestTests`
Expected: PASS (10 new tests; the manifest's existing tests unchanged).

- [ ] **Step 6: Revert-proof**

1. Change `if wonItsContest && !yieldsToResume` to `if !yieldsToResume`. Confirm `testTwoEntriesOnOneConversationBringBackOnlyTheLast` and `testOneContinuePerFolderAndAgentTheNewestWinning` FAIL. Restore; confirm they pass.
2. Change `let yieldsToResume = entry.agentKind == .claude && ...` to `let yieldsToResume = false`. Confirm `testAnIdlessClaudeEntryYieldsToOneResumingByIdInTheSameFolder` FAILS. Restore; confirm it passes.

- [ ] **Step 7: Full suite and commit**

Run: `swift test 2>&1 | tail -5` → 0 failures.

```bash
git add Sources/LinkCKit/App/WorkspaceManifest.swift Sources/LinkCKit/App/RelaunchPlan.swift Tests/LinkCKitTests/RelaunchPlanTests.swift
git commit -m "feat(sessions): plan a relaunch that never opens one conversation twice"
```

---

### Task 2: The idle-worker rule

**Files:**
- Modify: `Sources/LinkCKit/Core/Domain.swift` (`Session`: new `isWorker` field and init parameter)
- Create: `Sources/LinkCKit/Core/WorkerReaper.swift`
- Test: `Tests/LinkCKitTests/WorkerReaperTests.swift`

**Interfaces:**
- Consumes: `Session` (`id`, `state`, `stateChangedAt`), `SessionState`
- Produces:
  - `Session.isWorker: Bool` (`var`), and `isWorker: Bool = false` as the last `Session.init` parameter
  - `WorkerReaper.idleGrace: TimeInterval` (600)
  - `WorkerReaper.closable(sessions: [Session], taskAssignees: Set<String>, now: Date, grace: TimeInterval = WorkerReaper.idleGrace) -> [String]`

- [ ] **Step 1: Write the failing tests**

Create `Tests/LinkCKitTests/WorkerReaperTests.swift`:

```swift
import XCTest
@testable import LinkCKit

final class WorkerReaperTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func session(
        _ id: String, _ state: SessionState, idleFor minutes: Double, worker: Bool = true
    ) -> Session {
        Session(
            id: id, cwd: "/p", title: "p", state: state,
            stateChangedAt: now.addingTimeInterval(-minutes * 60), isWorker: worker)
    }

    private func closable(_ sessions: [Session], holding: Set<String> = []) -> [String] {
        WorkerReaper.closable(sessions: sessions, taskAssignees: holding, now: now)
    }

    func testAWorkerIdlePastTheGraceIsClosed() {
        for state in [SessionState.ready, .finished, .waitingIdle] {
            XCTAssertEqual(closable([session("W", state, idleFor: 10)]), ["W"], "\(state)")
        }
    }

    func testAWorkerInsideTheGraceIsKept() {
        XCTAssertEqual(closable([session("W", .finished, idleFor: 9)]), [])
    }

    func testAWorkerThatIsNotIdleIsKept() {
        for state in [SessionState.starting, .working, .waitingPermission, .error] {
            XCTAssertEqual(closable([session("W", state, idleFor: 60)]), [], "\(state)")
        }
    }

    func testAWorkerHoldingATaskIsKept() {
        XCTAssertEqual(closable([session("W", .finished, idleFor: 60)], holding: ["W"]), [])
    }

    func testTheUsersSessionIsNeverClosed() {
        XCTAssertEqual(closable([session("U", .finished, idleFor: 600, worker: false)]), [])
    }

    func testTheGraceIsTenMinutes() {
        XCTAssertEqual(WorkerReaper.idleGrace, 600)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter LinkCKitTests.WorkerReaperTests`
Expected: build FAILS ("cannot find 'WorkerReaper' in scope", extra argument `isWorker`).

- [ ] **Step 3: Add `isWorker` to `Session`**

In `Sources/LinkCKit/Core/Domain.swift`, in `Session`, add after `modelTier`:

```swift
    /// A session linkC started to carry a delegated task, not one the user opened. Closed once it
    /// has sat idle with no task for `WorkerReaper.idleGrace`; opening it makes it the user's.
    public var isWorker: Bool
```

Add `isWorker: Bool = false` as the last `init` parameter and `self.isWorker = isWorker` in its body.

- [ ] **Step 4: Write `WorkerReaper`**

Create `Sources/LinkCKit/Core/WorkerReaper.swift`:

```swift
import Foundation

/// Which workers to close now. A worker is closed once it holds no open task and has sat idle —
/// finished, ready, or waiting for input — for the grace. A session the user opened is never
/// closed, and neither is one still working or waiting on a prompt. Pure: `now` is injected.
public enum WorkerReaper {
    /// Long enough for back-to-back tasks and a follow-up to reuse a worker and its context.
    public static let idleGrace: TimeInterval = 10 * 60

    private static let idleStates: Set<SessionState> = [.ready, .finished, .waitingIdle]

    public static func closable(
        sessions: [Session], taskAssignees: Set<String>, now: Date, grace: TimeInterval = idleGrace
    ) -> [String] {
        sessions
            .filter { session in
                session.isWorker
                    && !taskAssignees.contains(session.id)
                    && idleStates.contains(session.state)
                    && now.timeIntervalSince(session.stateChangedAt) >= grace
            }
            .map(\.id)
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter LinkCKitTests.WorkerReaperTests`
Expected: PASS (6 tests).

- [ ] **Step 6: Revert-proof**

Delete the `&& !taskAssignees.contains(session.id)` line. Confirm `testAWorkerHoldingATaskIsKept` FAILS. Restore; confirm it passes.

- [ ] **Step 7: Full suite and commit**

Run: `swift test 2>&1 | tail -5` → 0 failures.

```bash
git add Sources/LinkCKit/Core/Domain.swift Sources/LinkCKit/Core/WorkerReaper.swift Tests/LinkCKitTests/WorkerReaperTests.swift
git commit -m "feat(sessions): decide which idle workers to close"
```

---

### Task 3: Keep ids, mark workers, adopt on open

**Files:**
- Modify: `Sources/LinkCKit/Core/SessionStore.swift` (`SessionStore.create`, new `adopt(id:)`)
- Modify: `Sources/LinkCKit/App/WorkspaceManifest.swift` (new `markAdopted(linkcId:)`)
- Modify: `Sources/LinkCKit/App/AppCoordinator.swift` (`launch`, `newSession`, `spawnTeammate`, `prepareForShutdown`, `cleanup(sessionId:)`, `focusSession`)
- Modify: `Sources/LinkCKit/App/AppCoordinator+Relay.swift` (every `spawnTeammate(` call)
- Test: `Tests/LinkCKitTests/AppCoordinatorIntegrationTests.swift`, `Tests/LinkCKitTests/AppCoordinatorRelayTests.swift`

**Interfaces:**
- Consumes: Task 1's `RestorableSession.isWorker` and its `init(..., isWorker:)`; Task 2's `Session.isWorker` and `Session.init(..., isWorker:)`
- Produces:
  - `SessionStore.create(cwd:title:id:agentKind:model:modelTier:claudeSessionId:isWorker:)` — the last two new, defaulting to `nil` / `false`
  - `SessionStore.adopt(id: String)`
  - `WorkspaceManifest.markAdopted(linkcId: String)`
  - `AppCoordinator.newSession(cwd:agent:mode:tier:select:asWorker:)` and `spawnTeammate(in:agent:goal:tier:asWorker:)` — `asWorker: Bool = false`
  - Every relay spawn passes `asWorker: true`

- [ ] **Step 1: Write the failing tests**

In `Tests/LinkCKitTests/AppCoordinatorIntegrationTests.swift`, add inside the test class (it already has `makeCoordinator(sink:claudePath:settingsDir:manifestDir:)` and `RecordingSink`):

```swift
    /// A session restarted with a saved conversation id keeps it through a save made before any
    /// hook has reported — that save used to write nil over the id it was resumed with.
    func testARestartedSessionKeepsItsIdThroughASaveBeforeAnyHook() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-keepid-\(UUID().uuidString)")
        let cwd = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-cwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cwd) }
        WorkspaceManifest(directory: dir).upsert(RestorableSession(
            linkcId: "L1", claudeSessionId: "conv-1", cwd: cwd.path, title: "p", wasActiveOnQuit: true))

        let coordinator = makeCoordinator(sink: RecordingSink(), claudePath: "/bin/cat", settingsDir: dir, manifestDir: dir)
        coordinator.restoreActiveSessions()
        defer { coordinator.store.sessions.forEach { coordinator.stopSession($0.id) } }
        coordinator.prepareForShutdown()

        XCTAssertEqual(coordinator.store.session(id: "L1")?.claudeSessionId, "conv-1")
        XCTAssertEqual(WorkspaceManifest(directory: dir).entries.first { $0.linkcId == "L1" }?.claudeSessionId, "conv-1")
    }

    /// Opening a worker's terminal makes it the user's, in memory and on disk.
    func testOpeningAWorkerMakesItTheUsers() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-adopt-\(UUID().uuidString)")
        let cwd = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-cwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cwd) }

        let coordinator = makeCoordinator(sink: RecordingSink(), settingsDir: dir, manifestDir: dir)
        let worker = try coordinator.newSession(cwd: cwd.path, agent: .codex, asWorker: true)
        defer { coordinator.stopSession(worker.id) }
        XCTAssertEqual(coordinator.store.session(id: worker.id)?.isWorker, true)
        XCTAssertEqual(WorkspaceManifest(directory: dir).entries.first { $0.linkcId == worker.id }?.isWorker, true)

        coordinator.focusSession(worker.id)

        XCTAssertEqual(coordinator.store.session(id: worker.id)?.isWorker, false)
        XCTAssertEqual(WorkspaceManifest(directory: dir).entries.first { $0.linkcId == worker.id }?.isWorker, false)
    }

    /// A worker that ends leaves nothing under Earlier; the user's session does.
    func testAStoppedWorkerLeavesNothingUnderEarlier() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-worker-end-\(UUID().uuidString)")
        let cwdA = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-cwd-\(UUID().uuidString)")
        let cwdB = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-cwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cwdA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cwdB, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: cwdA)
            try? FileManager.default.removeItem(at: cwdB)
        }

        let coordinator = makeCoordinator(sink: RecordingSink(), settingsDir: dir, manifestDir: dir)
        let worker = try coordinator.newSession(cwd: cwdA.path, agent: .codex, asWorker: true)
        let mine = try coordinator.newSession(cwd: cwdB.path, agent: .codex)
        coordinator.stopSession(worker.id)
        coordinator.stopSession(mine.id)

        XCTAssertEqual(coordinator.restorables.map(\.linkcId), [mine.id])
        XCTAssertNil(WorkspaceManifest(directory: dir).entries.first { $0.linkcId == worker.id })
    }
```

In `Tests/LinkCKitTests/AppCoordinatorRelayTests.swift`, add inside the test class, using the file's existing `makeCoordinator(...)` with its defaults:

```swift
    /// A session the relay spawns to carry a task is a worker.
    @MainActor
    func testTheRelaysSpawnIsAWorker() throws {
        let ws = tempDir.path
        let inbox = InboxStore(workspaceRoot: ws)
        let coordinator = makeCoordinator()
        defer {
            coordinator.store.sessions.forEach { coordinator.stopSession($0.id) }
            coordinator.shutdown()
        }
        _ = try inbox.createTask(from: .claude, to: .codex, prompt: "spawn a worker", files: [])

        coordinator.dispatchTasks(workspacePath: ws, inboxStore: inbox)

        let spawned = try XCTUnwrap(coordinator.store.sessions.first { $0.agentKind == .codex })
        XCTAssertTrue(spawned.isWorker)
    }
```

If `makeCoordinator` in that file has required parameters, pass the same values its other dispatch tests pass.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter LinkCKitTests.AppCoordinatorIntegrationTests` and `swift test --filter LinkCKitTests.AppCoordinatorRelayTests`
Expected: build FAILS (no `asWorker:` parameter on `newSession`). Capture it.

- [ ] **Step 3: Store and manifest helpers**

In `Sources/LinkCKit/Core/SessionStore.swift`, change `create` to take and pass the two new values:

```swift
    @discardableResult
    public func create(cwd: String, title: String, id: String = UUID().uuidString, agentKind: AgentKind = .claude,
                       model: String? = nil, modelTier: ModelTier? = nil,
                       claudeSessionId: String? = nil, isWorker: Bool = false) -> Session {
        let s = Session(id: id, cwd: cwd, title: title, claudeSessionId: claudeSessionId, agentKind: agentKind,
                        model: model, modelTier: modelTier, isWorker: isWorker)
        sessions.append(s)
        return s
    }

    /// The user opened this worker's terminal: from now on it is theirs, and never closed for them.
    public func adopt(id: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }), sessions[idx].isWorker else { return }
        sessions[idx].isWorker = false
    }
```

In `Sources/LinkCKit/App/WorkspaceManifest.swift`, add next to `bindClaudeId`:

```swift
    /// The user opened this worker: record it as theirs. No-op for an unknown id or no change.
    public func markAdopted(linkcId: String) {
        guard let i = entries.firstIndex(where: { $0.linkcId == linkcId }), entries[i].isWorker else { return }
        entries[i].isWorker = false
        save()
    }
```

- [ ] **Step 4: Coordinator changes**

In `Sources/LinkCKit/App/AppCoordinator.swift`:

1. `launch(...)`: add a parameter `asWorker: Bool = false` (before `select`). Create the session with the id it is resumed with and the worker flag:

```swift
        let session = store.create(cwd: cwd, title: title, id: id ?? UUID().uuidString, agentKind: agent,
                                   model: model, modelTier: model == nil ? nil : tier,
                                   claudeSessionId: resumeId, isWorker: asWorker)
```

   and add `isWorker: asWorker` to the `RestorableSession(...)` it upserts after a successful start.

2. `newSession(...)`: add `asWorker: Bool = false` after `select` and pass it to `launch`.

3. `spawnTeammate(...)`: add `asWorker: Bool = false` after `tier` and pass it to `newSession`.

4. `prepareForShutdown(...)`: never write a nil id over a saved one, and save the flag:

```swift
        for s in store.sessions where s.state != .ended {
            let liveAgent = terminals.session(id: s.id)?.sampleForegroundAgent() ?? s.agentKind
            // A restored session learns its id from its first hook. A save before then must keep
            // the id it was resumed with, not overwrite it with nothing.
            let savedId = manifest.entries.first { $0.linkcId == s.id }?.claudeSessionId
            manifest.upsert(RestorableSession(
                linkcId: s.id,
                claudeSessionId: s.claudeSessionId ?? savedId,
                cwd: s.cwd,
                title: s.title,
                agentKind: liveAgent,
                wasActiveOnQuit: true,
                endedAt: nil,
                isWorker: s.isWorker
            ))
        }
```

5. `cleanup(sessionId:)`: read the flag before the session is removed, and remove a worker's entry instead of stamping it ended:

```swift
    private func cleanup(sessionId: String) {
        let wasWorker = store.session(id: sessionId)?.isWorker ?? false
        store.remove(id: sessionId)
        // ... every existing line between here and the manifest update stays unchanged ...
        if wasWorker {
            // A worker was linkC's, not the user's: its report is in the task record, so it
            // leaves nothing under Earlier.
            manifest.remove(linkcId: sessionId)
        } else {
            // The session ended or was stopped — keep its manifest entry but stamp it, so it
            // becomes a restorable card. (No-op when there is no entry, e.g. a launch that failed
            // before start.)
            manifest.markEnded(linkcId: sessionId, at: Date())
        }
        syncRestorables()
    }
```

6. `focusSession(_:)`: after `terminals.select(id)`, add:

```swift
        // Opening a worker's terminal makes it the user's: they are using it now.
        store.adopt(id: id)
        manifest.markAdopted(linkcId: id)
```

In `Sources/LinkCKit/App/AppCoordinator+Relay.swift`, add `asWorker: true` to every `spawnTeammate(` call (find them with `grep -n "spawnTeammate(" Sources/LinkCKit/App/AppCoordinator+Relay.swift`) — every one of them spawns to carry a delegated task.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter LinkCKitTests.AppCoordinatorIntegrationTests` and `swift test --filter LinkCKitTests.AppCoordinatorRelayTests`
Expected: PASS, including the four new tests.

- [ ] **Step 6: Revert-proof**

1. In `prepareForShutdown`, change `s.claudeSessionId ?? savedId` to `s.claudeSessionId`. Confirm `testARestartedSessionKeepsItsIdThroughASaveBeforeAnyHook` FAILS. Restore.
2. In `cleanup`, make both branches call `manifest.markEnded(...)`. Confirm `testAStoppedWorkerLeavesNothingUnderEarlier` FAILS. Restore.

- [ ] **Step 7: Full suite and commit**

Run: `swift build 2>&1 | grep -E "error:|warning:" | head; swift test 2>&1 | tail -5` → no errors or warnings, 0 failures.

```bash
git add Sources/LinkCKit/Core/SessionStore.swift Sources/LinkCKit/App/WorkspaceManifest.swift Sources/LinkCKit/App/AppCoordinator.swift Sources/LinkCKit/App/AppCoordinator+Relay.swift Tests/LinkCKitTests/AppCoordinatorIntegrationTests.swift Tests/LinkCKitTests/AppCoordinatorRelayTests.swift
git commit -m "fix(sessions): keep conversation ids through a save and mark the relay's spawns as workers"
```

---

### Task 4: Relaunch by plan, close idle workers

**Files:**
- Modify: `Sources/LinkCKit/App/AppCoordinator.swift` (`restoreActiveSessions`, new private `workersHoldingOpenTasks(_:)`)
- Create: `Sources/LinkCKit/App/AppCoordinator+Workers.swift` (the reaper phase)
- Modify: `Sources/LinkCKit/App/AppCoordinator+Relay.swift` (`processPendingMessages`)
- Test: `Tests/LinkCKitTests/AppCoordinatorIntegrationTests.swift`, `Tests/LinkCKitTests/AppCoordinatorRelayTests.swift`

**Interfaces:**
- Consumes: `RelaunchPlan.make(entries:workersHoldingTasks:)`, `WorkerReaper.closable(sessions:taskAssignees:now:)`, `launch(..., asWorker:)`, `InboxStore.openTasks(timeout:)`, `isRelayLockTimeout(_:)`, `stopSession(_:)`, `AppCoordinator.now`
- Produces: `AppCoordinator.reapIdleWorkers(workspacePath: String, inboxStore: InboxStore) -> Bool` (`@discardableResult`, internal)

- [ ] **Step 1: Write the failing tests**

In `Tests/LinkCKitTests/AppCoordinatorIntegrationTests.swift`, add:

```swift
    /// A relaunch brings back one session per conversation: of two entries on one Claude id the
    /// last comes back and the other goes to Earlier; an id-less Claude entry in the same folder
    /// goes to Earlier too; a worker with no task is dropped.
    func testARelaunchBringsBackOneSessionPerConversation() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-relaunch-\(UUID().uuidString)")
        let cwd = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-cwd-\(UUID().uuidString)")
        let cwdW = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-cwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cwdW, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: cwd)
            try? FileManager.default.removeItem(at: cwdW)
        }
        let seed = WorkspaceManifest(directory: dir)
        seed.upsert(RestorableSession(linkcId: "A", claudeSessionId: "c1", cwd: cwd.path, title: "p", wasActiveOnQuit: true))
        seed.upsert(RestorableSession(linkcId: "B", claudeSessionId: "c1", cwd: cwd.path, title: "p", wasActiveOnQuit: true))
        seed.upsert(RestorableSession(linkcId: "C", claudeSessionId: nil, cwd: cwd.path, title: "p", wasActiveOnQuit: true))
        seed.upsert(RestorableSession(linkcId: "W", cwd: cwdW.path, title: "w", agentKind: .codex,
                                      wasActiveOnQuit: true, isWorker: true))

        let coordinator = makeCoordinator(sink: RecordingSink(), claudePath: "/bin/cat", settingsDir: dir, manifestDir: dir)
        coordinator.restoreActiveSessions()
        defer { coordinator.store.sessions.forEach { coordinator.stopSession($0.id) } }

        XCTAssertEqual(coordinator.store.sessions.map(\.id), ["B"])
        XCTAssertEqual(Set(coordinator.restorables.map(\.linkcId)), ["A", "C"])
        XCTAssertNil(WorkspaceManifest(directory: dir).entries.first { $0.linkcId == "W" })
    }
```

In `Tests/LinkCKitTests/AppCoordinatorRelayTests.swift`, add (the file's `ControllableClock` and `makeCoordinator(now:)` are already there):

```swift
    /// An idle worker is closed once past the grace; the user's session never is.
    @MainActor
    func testAnIdleWorkerIsClosedAfterTheGraceAndTheUsersSessionIsNot() throws {
        let ws = (tempDir.path as NSString).standardizingPath
        let inbox = InboxStore(workspaceRoot: ws)
        let clock = ControllableClock()
        let coordinator = makeCoordinator(now: clock.now)
        defer {
            coordinator.store.sessions.forEach { coordinator.stopSession($0.id) }
            coordinator.shutdown()
        }
        let worker = try coordinator.newSession(cwd: ws, agent: .codex, asWorker: true)
        let mine = try coordinator.newSession(cwd: ws, agent: .codex)
        coordinator.store.updateState(id: worker.id, to: .finished)
        coordinator.store.updateState(id: mine.id, to: .finished)

        clock.set(Date().addingTimeInterval(9 * 60))
        coordinator.reapIdleWorkers(workspacePath: ws, inboxStore: inbox)
        XCTAssertNotNil(coordinator.store.session(id: worker.id), "9 minutes idle: still inside the grace")

        clock.set(Date().addingTimeInterval(11 * 60))
        coordinator.reapIdleWorkers(workspacePath: ws, inboxStore: inbox)
        XCTAssertNil(coordinator.store.session(id: worker.id), "past the grace with no task: closed")
        XCTAssertNotNil(coordinator.store.session(id: mine.id), "the user's session is never closed")
    }

    /// A worker still holding an open task is never closed, however long it has been idle.
    @MainActor
    func testAWorkerHoldingATaskIsNotClosed() throws {
        let ws = (tempDir.path as NSString).standardizingPath
        let inbox = InboxStore(workspaceRoot: ws)
        let clock = ControllableClock()
        let coordinator = makeCoordinator(now: clock.now)
        defer {
            coordinator.store.sessions.forEach { coordinator.stopSession($0.id) }
            coordinator.shutdown()
        }
        let worker = try coordinator.newSession(cwd: ws, agent: .codex, asWorker: true)
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "held", files: [])
        try inbox.markTaskDelivered(taskId: task.id, sessionId: worker.id)
        coordinator.store.updateState(id: worker.id, to: .finished)

        clock.set(Date().addingTimeInterval(60 * 60))
        coordinator.reapIdleWorkers(workspacePath: ws, inboxStore: inbox)

        XCTAssertNotNil(coordinator.store.session(id: worker.id))
    }
```

If `markTaskDelivered` requires a `timeout:` argument or differs in name, use the store's real delivery method (see `dispatchTasks` in `Sources/LinkCKit/App/AppCoordinator+Relay.swift`, which calls it).

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter LinkCKitTests.AppCoordinatorIntegrationTests` and `swift test --filter LinkCKitTests.AppCoordinatorRelayTests`
Expected: the relaunch test FAILS (all three Claude entries come back, the worker too), and the relay tests fail to build (no `reapIdleWorkers`). Capture both.

- [ ] **Step 3: Relaunch by plan**

In `Sources/LinkCKit/App/AppCoordinator.swift`, replace `restoreActiveSessions()` with:

```swift
    /// Brings back the sessions that were live when linkC last quit — each on its own
    /// conversation, never two on one (see `RelaunchPlan`). Entries that lose a contest for a
    /// conversation go under Earlier; workers that no longer hold a task are dropped.
    public func restoreActiveSessions() {
        let active = manifest.entries.filter { $0.wasActiveOnQuit || $0.endedAt == nil }
        let plan = RelaunchPlan.make(entries: active, workersHoldingTasks: workersHoldingOpenTasks(active))
        for id in plan.drop { manifest.remove(linkcId: id) }
        for id in plan.toEarlier { manifest.markEnded(linkcId: id, at: now()) }
        for var r in active where plan.relaunch.contains(r.linkcId) {
            r.wasActiveOnQuit = false
            if FileManager.default.fileExists(atPath: r.cwd) {
                if (try? launch(
                    cwd: r.cwd,
                    title: r.title,
                    agent: r.agentKind,
                    mode: .continueLast,
                    resumeId: r.claudeSessionId,
                    id: r.linkcId,
                    asWorker: r.isWorker,
                    select: true
                )) == nil {
                    manifest.upsert(r)
                }
            } else {
                manifest.upsert(r)
            }
        }
        syncRestorables()
    }

    /// The worker entries that still hold an open task in their workspace. An inbox that cannot
    /// be read is logged, and its workers are treated as holding nothing — the user's own
    /// sessions do not depend on it.
    private func workersHoldingOpenTasks(_ entries: [RestorableSession]) -> Set<String> {
        var holding: Set<String> = []
        let folders = Set(entries.filter(\.isWorker).map { ($0.cwd as NSString).standardizingPath })
        for folder in folders {
            do {
                holding.formUnion(try InboxStore(workspaceRoot: folder).openTasks().compactMap(\.assigneeSessionId))
            } catch {
                NSLog("[linkC] relaunch: open tasks for %@ could not be read — its workers stay closed: %@",
                      folder, String(describing: error))
            }
        }
        return holding
    }
```

- [ ] **Step 4: The reaper phase**

Create `Sources/LinkCKit/App/AppCoordinator+Workers.swift`:

```swift
import Foundation

extension AppCoordinator {
    /// Closes this workspace's workers that have sat idle with no open task for
    /// `WorkerReaper.idleGrace`. A relay phase: returns `true` when the inbox lock was still
    /// contended after `relayLockTimeout`, so the tick stops there; any other failure is logged
    /// and closes nothing.
    @discardableResult
    func reapIdleWorkers(workspacePath: String, inboxStore: InboxStore) -> Bool {
        let workers = store.sessions.filter {
            $0.isWorker && ($0.cwd as NSString).standardizingPath == workspacePath
        }
        guard !workers.isEmpty else { return false }
        let assignees: Set<String>
        do {
            assignees = Set(try inboxStore.openTasks(timeout: Self.relayLockTimeout).compactMap(\.assigneeSessionId))
        } catch {
            if isRelayLockTimeout(error) { return true }
            NSLog("[linkC relay] reapIdleWorkers: open tasks — %@", String(describing: error))
            return false
        }
        for id in WorkerReaper.closable(sessions: workers, taskAssignees: assignees, now: now()) {
            NSLog("[linkC relay] closing idle worker %@ in %@", id, workspacePath)
            stopSession(id)
        }
        return false
    }
}
```

In `Sources/LinkCKit/App/AppCoordinator+Relay.swift`, in `processPendingMessages`, add a phase right after the `watchStuckTasks` guard:

```swift
        guard !reapIdleWorkers(workspacePath: norm, inboxStore: inboxStore) else {
            return logRelayLockContention(workspacePath: norm)
        }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter LinkCKitTests.AppCoordinatorIntegrationTests` and `swift test --filter LinkCKitTests.AppCoordinatorRelayTests`
Expected: PASS, including the three new tests.

- [ ] **Step 6: Revert-proof**

1. In `restoreActiveSessions`, change `where plan.relaunch.contains(r.linkcId)` to relaunch every entry. Confirm `testARelaunchBringsBackOneSessionPerConversation` FAILS. Restore.
2. In `reapIdleWorkers`, pass `taskAssignees: []`. Confirm `testAWorkerHoldingATaskIsNotClosed` FAILS. Restore.

- [ ] **Step 7: Full suite and commit**

Run: `swift build 2>&1 | grep -E "error:|warning:" | head; swift test 2>&1 | tail -5` → no errors or warnings, 0 failures.

```bash
git add Sources/LinkCKit/App/AppCoordinator.swift Sources/LinkCKit/App/AppCoordinator+Workers.swift Sources/LinkCKit/App/AppCoordinator+Relay.swift Tests/LinkCKitTests/AppCoordinatorIntegrationTests.swift Tests/LinkCKitTests/AppCoordinatorRelayTests.swift
git commit -m "feat(sessions): relaunch by plan and close idle workers"
```

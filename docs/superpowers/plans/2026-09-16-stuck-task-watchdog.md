# Stuck-Task Watchdog Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Report a task that is out with a worker but no longer moving — one line to the delegating agent, one notification to the user — without ever cancelling, reassigning, or retrying it.

**Architecture:** A new phase in the relay's once-a-second tick reads open tasks and decides whether each looks stuck from three signals: never started, its worker waiting on a prompt, or its worker's screen gone quiet. The quiet signal comes from a per-session screen signature kept in memory and refreshed by the state sampling that already reads those rows once a second. A fourth signal, about the orchestrator rather than the worker, warns the user when a notice cannot be delivered.

**Tech Stack:** Swift 6 (strict concurrency, `swiftLanguageMode(.v6)`), SwiftPM, XCTest, SwiftTerm terminals, file-locked JSON stores (`InboxStore`).

**Spec:** `docs/superpowers/specs/2026-09-16-stuck-task-watchdog-design.md`

## Global Constraints

- Thresholds, exactly: never started **10 minutes**, waiting on the user **5 minutes**, gone quiet **15 minutes**, notice cannot land **5 minutes**.
- Nothing is cancelled, reassigned, retried, or rerouted automatically. The only actions are an enqueued line to the delegator and a user notification.
- Each stuck spell is reported **once**; when the task moves again the mark is cleared so a later stall reports again.
- New `TaskRecord` fields must be **optional** — the type uses synthesized `Codable`, and `InboxStore.loadUnlocked` throws on a decode error, which would take the whole inbox down for rows written before this change.
- Relay phases never throw: they return `true` when the inbox lock was contended (caller ends the tick), and `NSLog` any other failure. Never block the main actor.
- Every store call the watchdog makes passes `timeout: AppCoordinator.relayLockTimeout` (0.5s), not the 5s default.
- Screen signatures and can't-land marks are in-memory only. Nothing new is written to `blackboard.json` or `inbox.json` on a tick where nothing changed.
- Commit messages must never mention Claude or add attribution/co-author trailers.
- Every new test must be revert-proofed: break the behaviour, watch that exact test fail, restore the file, confirm `git diff` is clean.

## File Structure

| File | Responsibility |
|---|---|
| `Sources/LinkCKit/Terminal/TerminalPreview.swift` (modify) | Add `isLiveMarkerRow(_:)` — which rows tick on their own and so must not count as progress. |
| `Sources/LinkCKit/Terminal/TerminalSession.swift` (modify) | Add `screenSignature()` over the visible rows minus live markers. |
| `Sources/LinkCKit/App/AppCoordinator.swift` (modify) | Two stored properties (screen signatures, reported can't-land notices), refresh signatures in `sampleAgentStates`, drop a session's signature in `cleanup(sessionId:)`. Extensions cannot hold stored properties, which is why they live here. |
| `Sources/LinkCKit/Blackboard/InboxModels.swift` (modify) | `TaskRecord.stuckNotifiedAt: Date?`. |
| `Sources/LinkCKit/Blackboard/InboxStore.swift` (modify) | `setStuckNotified(taskId:at:timeout:)`. |
| `Sources/LinkCKit/App/AppCoordinator+Watchdog.swift` (create) | Thresholds, `StuckReason`, `stuckReason(for:at:)`, `watchStuckTasks(workspacePath:inboxStore:)`, `noteUndeliveredNotice(_:)`. |
| `Sources/LinkCKit/App/AppCoordinator+Relay.swift` (modify) | Run the phase in `processPendingMessages`; route task notices to the delegating session; stop spawning for non-task messages. |
| `Tests/LinkCKitTests/TerminalTests.swift` (modify) | `isLiveMarkerRow` rows. |
| `Tests/LinkCKitTests/InboxStoreTests.swift` (modify) | The mark, its clear, and a row written without it. |
| `Tests/LinkCKitTests/AppCoordinatorWatchdogTests.swift` (create) | The phase: each signal, once-only, recovery, routing, no-spawn, can't-land. |

---

### Task 1: Screen signature and quiet clock

**Files:**
- Modify: `Sources/LinkCKit/Terminal/TerminalPreview.swift` (add after `isTrustPrompt`)
- Modify: `Sources/LinkCKit/Terminal/TerminalSession.swift` (add next to `showsTrustPrompt()`)
- Modify: `Sources/LinkCKit/App/AppCoordinator.swift`
- Test: `Tests/LinkCKitTests/TerminalTests.swift`, `Tests/LinkCKitTests/AppCoordinatorWatchdogTests.swift` (create)

**Interfaces:**
- Produces: `TerminalPreview.isLiveMarkerRow(_ row: String) -> Bool`; `TerminalSession.screenSignature() -> String`; `AppCoordinator.screenUnchangedSince(_ sessionId: String) -> Date?`.
- Consumes: `TerminalSession.visibleContentRows()` (already private in that file), `AppCoordinator.now` (injectable clock).

- [ ] **Step 1: Write the failing row test**

In `Tests/LinkCKitTests/TerminalTests.swift`, inside `final class TerminalPreviewTests`, at the end of the class (after `testRecognizesATrustDialogWhoseQuestionWraps`):

```swift
    /// Rows that redraw on their own each second — a working footer, a timer, an animated
    /// spinner — say nothing about progress. Everything else does.
    func testLiveMarkerRowsAreOnlyTheOnesThatTickOnTheirOwn() {
        XCTAssertTrue(TerminalPreview.isLiveMarkerRow("  ⏵⏵ bypass permissions on (shift+tab to cycle) · esc to interrupt · ← for agents"))
        XCTAssertTrue(TerminalPreview.isLiveMarkerRow("esc to cancel                                    Gemini 3.8 Flash · high"))
        XCTAssertTrue(TerminalPreview.isLiveMarkerRow("• Working (9s • esc to interrupt) · 1 background terminal running"))
        XCTAssertTrue(TerminalPreview.isLiveMarkerRow("✻ Percolating… (12s · ↓ 115 tokens)"))
        XCTAssertTrue(TerminalPreview.isLiveMarkerRow("⣾  Running command..."))

        XCTAssertFalse(TerminalPreview.isLiveMarkerRow("● Bash(sleep 15 && echo finished) (ctrl+o to expand)"))
        XCTAssertFalse(TerminalPreview.isLiveMarkerRow("  Ran 1 shell command"))
        XCTAssertFalse(TerminalPreview.isLiveMarkerRow("⏺ finished"))
        XCTAssertFalse(TerminalPreview.isLiveMarkerRow("   "))
    }
```

- [ ] **Step 2: Run it and watch it fail**

Run: `swift test --filter testLiveMarkerRowsAreOnlyTheOnesThatTickOnTheirOwn`
Expected: FAIL to build with `type 'TerminalPreview' has no member 'isLiveMarkerRow'`.

- [ ] **Step 3: Add the row check**

In `Sources/LinkCKit/Terminal/TerminalPreview.swift`, directly after the closing brace of `isTrustPrompt(_:)`:

```swift
    /// Whether a row redraws on its own while a turn runs — a working footer, a spinner row with a
    /// timer or token counter, or an animated Braille spinner. A screen signature leaves these out,
    /// so a ticking timer never looks like progress. A row led by a static glyph (Codex's "•",
    /// Claude Code's "⏺", Antigravity's "●") is ordinary output and counts.
    public static func isLiveMarkerRow(_ row: String) -> Bool {
        let text = visibleText(row)
        guard !text.isEmpty else { return false }
        if isWorkingFooter(text) { return true }
        if text.contains("esc to interrupt") { return true }
        if text.range(of: #"… \(\d+[hms][\dhms ]*·\s*[↑↓]"#, options: .regularExpression) != nil { return true }
        return text.unicodeScalars.first.map { (0x2800...0x28FF).contains($0.value) } ?? false
    }
```

- [ ] **Step 4: Run it and watch it pass**

Run: `swift test --filter testLiveMarkerRowsAreOnlyTheOnesThatTickOnTheirOwn`
Expected: PASS, 1 test, 0 failures.

- [ ] **Step 5: Add the session signature**

In `Sources/LinkCKit/Terminal/TerminalSession.swift`, directly after `showsTrustPrompt()`:

```swift
    /// A signature of the visible screen with live markers removed — the watchdog's progress
    /// signal. Tool output, new lines and status changes change it; a spinner's own timer does
    /// not. "" when the PTY was never started. In-process only: `hashValue` is seeded per launch.
    public func screenSignature() -> String {
        let rows = visibleContentRows().filter { !TerminalPreview.isLiveMarkerRow($0) }
        return String(rows.joined(separator: "\n").hashValue)
    }
```

- [ ] **Step 6: Write the failing quiet-clock test**

Create `Tests/LinkCKitTests/AppCoordinatorWatchdogTests.swift`. This file's helpers are reused by Tasks 3 and 4:

```swift
import XCTest
import os
@testable import LinkCKit

/// A wall clock a test moves forward instantly instead of sleeping through a threshold.
private final class ControllableClock: Sendable {
    private let box: OSAllocatedUnfairLock<Date>
    init(_ initial: Date = Date()) { box = OSAllocatedUnfairLock(initialState: initial) }
    func set(_ date: Date) { box.withLock { $0 = date } }
    func advance(_ seconds: TimeInterval) { box.withLock { $0 = $0.addingTimeInterval(seconds) } }
    func now() -> Date { box.withLock { $0 } }
}

final class AppCoordinatorWatchdogTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-watchdog-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    final class RecordingSink: NotificationSink, @unchecked Sendable {
        private let lock = NSLock()
        private var _deliveries: [(id: String, title: String, body: String)] = []
        var deliveries: [(id: String, title: String, body: String)] {
            lock.lock(); defer { lock.unlock() }; return _deliveries
        }
        func deliver(id: String, title: String, body: String) {
            lock.lock(); _deliveries.append((id, title, body)); lock.unlock()
        }
    }

    /// A mock agent that negotiates bracketed paste (so the relay will deliver to it) and then
    /// copies its input through, like a real CLI's raw-mode loop.
    @MainActor
    private func makeCoordinator(
        sink: NotificationSink = RecordingSink(),
        now: @escaping @MainActor @Sendable () -> Date = Date.init
    ) -> AppCoordinator {
        let scriptURL = tempDir.appendingPathComponent("mock_agent.sh")
        if !FileManager.default.fileExists(atPath: scriptURL.path) {
            let scriptContent = "#!/bin/sh\nstty -echo 2>/dev/null\nprintf '\\033[?2004h'\nexec /bin/cat\n"
            try? scriptContent.write(to: scriptURL, atomically: true, encoding: .utf8)
            var attrs = (try? FileManager.default.attributesOfItem(atPath: scriptURL.path)) ?? [:]
            attrs[.posixPermissions] = 0o755
            try? FileManager.default.setAttributes(attrs, ofItemAtPath: scriptURL.path)
        }
        let settingsDir = tempDir.appendingPathComponent("settings")
        try? FileManager.default.createDirectory(at: settingsDir, withIntermediateDirectories: true)
        return AppCoordinator(
            terminals: TerminalSessionManager(),
            hookServer: HookServer(port: 0),
            notifications: NotificationManager(sink: sink, now: { Date() }),
            claudePath: scriptURL.path,
            settingsDir: settingsDir,
            userSettingsURL: tempDir.appendingPathComponent("user-settings.json"),
            manifestDir: tempDir.appendingPathComponent("manifest"),
            agentPathResolver: { _ in scriptURL.path },
            deliverySettle: 0,
            now: now,
            isWatching: { _ in false }
        )
    }

    @MainActor
    private func waitUntil(_ predicate: @MainActor () -> Bool, iterations: Int = 100) async throws -> Bool {
        for _ in 0..<iterations {
            if predicate() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return predicate()
    }

    /// The quiet clock starts when a screen is first sampled and only restarts when the screen
    /// really changes — a spinner redrawing its timer must not count.
    @MainActor
    func testTheQuietClockRestartsOnlyWhenTheScreenChanges() async throws {
        let clock = ControllableClock()
        let coordinator = makeCoordinator(now: { clock.now() })
        defer { coordinator.shutdown() }
        let session = try coordinator.newSession(cwd: tempDir.path, agent: .claude)
        let term = try XCTUnwrap(coordinator.terminals.session(id: session.id))
        let started = try await waitUntil { term.isRunning }
        XCTAssertTrue(started, "the mock agent never started")

        coordinator.sampleAgentStates()
        let firstSeen = try XCTUnwrap(coordinator.screenUnchangedSince(session.id))

        clock.advance(60)
        term.sendInput("✻ Percolating… (12s · ↓ 115 tokens)\r")
        _ = try await waitUntil { term.recentOutput(lines: 5).contains("Percolating") }
        coordinator.sampleAgentStates()
        XCTAssertEqual(coordinator.screenUnchangedSince(session.id), firstSeen, "a spinner row is not progress")

        clock.advance(60)
        term.sendInput("Ran 1 shell command\r")
        _ = try await waitUntil { term.recentOutput(lines: 5).contains("Ran 1 shell command") }
        coordinator.sampleAgentStates()
        XCTAssertEqual(coordinator.screenUnchangedSince(session.id), clock.now(), "real output restarts the clock")
    }
}
```

- [ ] **Step 7: Run it and watch it fail**

Run: `swift test --filter testTheQuietClockRestartsOnlyWhenTheScreenChanges`
Expected: FAIL to build with `value of type 'AppCoordinator' has no member 'screenUnchangedSince'`.

- [ ] **Step 8: Track signatures in the coordinator**

In `Sources/LinkCKit/App/AppCoordinator.swift`, add next to `var lastSpawnFailure: SpawnFailure?`:

```swift
    /// Per session: the last screen signature seen and when it last changed — the watchdog's
    /// "gone quiet" clock. In memory only, so the clock restarts after a relaunch. Stored here
    /// rather than in the watchdog extension because extensions cannot hold stored properties.
    private var screenSignatures: [String: (signature: String, since: Date)] = [:]
    /// Notices already reported to the user as undeliverable, by message id. Also in memory: a
    /// notice still stuck after a relaunch is worth one more mention.
    var undeliveredNoticesReported: Set<String> = []

    /// When `sessionId`'s screen last changed; nil if it has never been sampled.
    func screenUnchangedSince(_ sessionId: String) -> Date? { screenSignatures[sessionId]?.since }
```

In the same file, inside `sampleAgentStates()`, immediately after the `BlackboardStore(...).heartbeat(...)` block and before `checkLimitsAndReroute(for: session.id)` (so it runs for every agent kind, including the ones whose state comes from hooks):

```swift
            // The watchdog's progress signal, taken from the same once-a-second row read.
            let signature = term.screenSignature()
            if screenSignatures[session.id]?.signature != signature {
                screenSignatures[session.id] = (signature, now())
            }
```

Find the cleanup site and drop the entry with it:

Run: `grep -n 'notifications.forget' Sources/LinkCKit/App/AppCoordinator.swift`

Add directly after that line:

```swift
        screenSignatures.removeValue(forKey: sessionId)
        undeliveredNoticesReported = []
```

- [ ] **Step 9: Run both tests and watch them pass**

Run: `swift test --filter 'testLiveMarkerRowsAreOnlyTheOnesThatTickOnTheirOwn|testTheQuietClockRestartsOnlyWhenTheScreenChanges'`
Expected: PASS, 2 tests, 0 failures.

- [ ] **Step 10: Revert-proof both**

Break `isLiveMarkerRow` to `return false`, run the two tests, confirm both fail, restore, confirm `git diff --stat` shows the file unchanged from your edit. Then break the signature refresh (comment out the `if screenSignatures[...]` block), run the quiet-clock test, confirm it fails, restore.

- [ ] **Step 11: Run the full suite**

Run: `swift test 2>&1 | tail -3`
Expected: 0 failures.

- [ ] **Step 12: Commit**

```bash
git add Sources/LinkCKit/Terminal/TerminalPreview.swift Sources/LinkCKit/Terminal/TerminalSession.swift Sources/LinkCKit/App/AppCoordinator.swift Tests/LinkCKitTests/TerminalTests.swift Tests/LinkCKitTests/AppCoordinatorWatchdogTests.swift
git commit -m "feat(watchdog): track when a session's screen last changed"
```

---

### Task 2: The once-only mark on a task

**Files:**
- Modify: `Sources/LinkCKit/Blackboard/InboxModels.swift` (`TaskRecord`)
- Modify: `Sources/LinkCKit/Blackboard/InboxStore.swift` (next to `markUnreportedTurnEndNotified`)
- Test: `Tests/LinkCKitTests/InboxStoreTests.swift`

**Interfaces:**
- Produces: `TaskRecord.stuckNotifiedAt: Date?` (init parameter `stuckNotifiedAt: Date? = nil`, placed after `unreportedTurnEndNotified`); `InboxStore.setStuckNotified(taskId: String, at: Date?, timeout: TimeInterval = 5.0) throws`.
- Consumes: `InboxError.taskNotFound(_:)`, `withFileLock(timeout:)`, `loadUnlocked()`, `saveUnlocked(_:)` — all already in `InboxStore`.

- [ ] **Step 1: Write the failing test**

At the end of the main test class in `Tests/LinkCKitTests/InboxStoreTests.swift`:

```swift
    func testTheStuckMarkIsSetClearedAndOptionalOnOldRows() throws {
        let store = InboxStore(workspaceRoot: tempDir.path)
        let task = try store.createTask(from: .claude, to: .codex, prompt: "Refactor migrations", files: [])
        XCTAssertNil(try store.task(id: task.id)?.stuckNotifiedAt)

        let at = Date(timeIntervalSince1970: 1_800_000_000)
        try store.setStuckNotified(taskId: task.id, at: at)
        XCTAssertEqual(try store.task(id: task.id)?.stuckNotifiedAt, at)

        try store.setStuckNotified(taskId: task.id, at: nil)
        XCTAssertNil(try store.task(id: task.id)?.stuckNotifiedAt, "a task that moves again must be reportable later")

        XCTAssertThrowsError(try store.setStuckNotified(taskId: "no-such-task", at: at))

        // A row written before this field existed must still decode: the store throws on a decode
        // error, which would take the whole inbox down.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(task)) as? [String: Any])
        json.removeValue(forKey: "stuckNotifiedAt")
        let legacy = try JSONDecoder().decode(TaskRecord.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.stuckNotifiedAt)
    }
```

- [ ] **Step 2: Run it and watch it fail**

Run: `swift test --filter testTheStuckMarkIsSetClearedAndOptionalOnOldRows`
Expected: FAIL to build with `value of type 'TaskRecord' has no member 'stuckNotifiedAt'`.

- [ ] **Step 3: Add the field**

In `Sources/LinkCKit/Blackboard/InboxModels.swift`, in `TaskRecord`, after `public var unreportedTurnEndNotified: Bool`:

```swift
    /// When the watchdog last reported this task stuck; cleared when it moves again so a later
    /// stall reports again. Optional for the same reason as `tier`: `loadUnlocked` throws on a
    /// decode error, so a required field would make every task row written before the watchdog
    /// unreadable and take the inbox with it.
    public var stuckNotifiedAt: Date?
```

In the same type's `init`, after the `unreportedTurnEndNotified: Bool = false,` parameter:

```swift
        stuckNotifiedAt: Date? = nil,
```

and after the `self.unreportedTurnEndNotified = unreportedTurnEndNotified` assignment:

```swift
        self.stuckNotifiedAt = stuckNotifiedAt
```

- [ ] **Step 4: Add the store call**

In `Sources/LinkCKit/Blackboard/InboxStore.swift`, directly after `markUnreportedTurnEndNotified(taskId:timeout:)`:

```swift
    /// Records that the delegator was told this task looks stuck, or clears it (`at: nil`) when
    /// the task moves again. One locked read-modify-write, like the turn-end mark above.
    public func setStuckNotified(taskId: String, at date: Date?, timeout: TimeInterval = 5.0) throws {
        try withFileLock(timeout: timeout) {
            var inbox = try loadUnlocked()
            guard let idx = inbox.tasks.firstIndex(where: { $0.id == taskId }) else {
                throw InboxError.taskNotFound(taskId)
            }
            inbox.tasks[idx].stuckNotifiedAt = date
            inbox.updatedAt = Date()
            try saveUnlocked(inbox)
        }
    }
```

- [ ] **Step 5: Run it and watch it pass**

Run: `swift test --filter testTheStuckMarkIsSetClearedAndOptionalOnOldRows`
Expected: PASS, 1 test, 0 failures.

- [ ] **Step 6: Revert-proof it**

Change `inbox.tasks[idx].stuckNotifiedAt = date` to `inbox.tasks[idx].stuckNotifiedAt = nil`, run the test, confirm it fails on the "set" assertion, restore, confirm the file matches your edit.

- [ ] **Step 7: Run the full suite and commit**

Run: `swift test 2>&1 | tail -3` — expected 0 failures.

```bash
git add Sources/LinkCKit/Blackboard/InboxModels.swift Sources/LinkCKit/Blackboard/InboxStore.swift Tests/LinkCKitTests/InboxStoreTests.swift
git commit -m "feat(watchdog): record when a task was reported stuck"
```

---

### Task 3: The watchdog phase

**Files:**
- Create: `Sources/LinkCKit/App/AppCoordinator+Watchdog.swift`
- Modify: `Sources/LinkCKit/App/AppCoordinator+Relay.swift` (`processPendingMessages`)
- Test: `Tests/LinkCKitTests/AppCoordinatorWatchdogTests.swift`

**Interfaces:**
- Consumes: `AppCoordinator.screenUnchangedSince(_:)` (Task 1); `InboxStore.setStuckNotified(taskId:at:timeout:)` and `TaskRecord.stuckNotifiedAt` (Task 2); existing `echo(_:for:inboxStore:timeout:)`, `workspaceExists(_:)`, `isRelayLockTimeout(_:)`, `InboxStore.openTasks(for:timeout:)`, `notifications.post(title:body:)`, `store.session(id:)`, `Session.stateChangedAt`, `AppCoordinator.relayLockTimeout`, `AppCoordinator.now`.
- Produces: `AppCoordinator.watchStuckTasks(workspacePath:inboxStore:) -> Bool`; `AppCoordinator.StuckReason`; `AppCoordinator.stuckReason(for:at:) -> StuckReason?`.

- [ ] **Step 1: Write the failing signal test**

Add to `AppCoordinatorWatchdogTests`:

```swift
    /// A brief typed into a session that never starts the task: after 10 minutes the delegator
    /// gets one line and the user one notification, and a second tick repeats neither.
    @MainActor
    func testANeverStartedTaskIsReportedOnceToTheDelegatorAndTheUser() async throws {
        let ws = tempDir.path
        let clock = ControllableClock()
        let sink = RecordingSink()
        let coordinator = makeCoordinator(sink: sink, now: { clock.now() })
        defer { coordinator.shutdown() }
        let inbox = InboxStore(workspaceRoot: ws)
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "Refactor migrations", files: [])

        coordinator.processPendingMessages(workspacePath: ws)
        let codex = try XCTUnwrap(coordinator.store.sessions.first(where: { $0.agentKind == .codex }))
        coordinator.store.updateState(id: codex.id, to: .ready)
        let ready = try await waitUntil { coordinator.terminals.session(id: codex.id)?.acceptsPaste ?? false }
        XCTAssertTrue(ready, "the mock agent never negotiated bracketed paste")
        coordinator.processPendingMessages(workspacePath: ws)
        XCTAssertEqual(try inbox.task(id: task.id)?.state, .delivered)

        clock.advance(11 * 60)
        coordinator.processPendingMessages(workspacePath: ws)

        let notices = try inbox.fetchPending().filter { $0.prompt.contains("looks stuck") }
        XCTAssertEqual(notices.count, 1, "the delegator is told once")
        XCTAssertTrue(notices[0].prompt.contains(task.shortId))
        XCTAssertTrue(notices[0].prompt.contains("never started"))
        XCTAssertEqual(sink.deliveries.filter { $0.body.contains("never started") }.count, 1)
        XCTAssertNotNil(try inbox.task(id: task.id)?.stuckNotifiedAt)

        clock.advance(5 * 60)
        coordinator.processPendingMessages(workspacePath: ws)
        XCTAssertEqual(try inbox.fetchPending().filter { $0.prompt.contains("looks stuck") }.count, 1, "a second tick must not repeat it")
    }
```

- [ ] **Step 2: Run it and watch it fail**

Run: `swift test --filter testANeverStartedTaskIsReportedOnceToTheDelegatorAndTheUser`
Expected: FAIL — `XCTAssertEqual failed: ("0") is not equal to ("1") - the delegator is told once`.

- [ ] **Step 3: Write the phase**

Create `Sources/LinkCKit/App/AppCoordinator+Watchdog.swift`:

```swift
import Foundation

/// The stuck-task watchdog: reports a task that is out with a worker but no longer moving. It
/// never cancels, reassigns, or retries — the whole action is one line to the delegating agent and
/// one notification to the user, once per stuck spell.
extension AppCoordinator {
    /// Delivered this long ago without the worker starting it.
    static let neverStartedThreshold: TimeInterval = 10 * 60
    /// The worker has been sitting on a prompt this long.
    static let waitingOnUserThreshold: TimeInterval = 5 * 60
    /// The worker says it is working but its screen has not changed for this long.
    static let goneQuietThreshold: TimeInterval = 15 * 60

    /// Why a task looks stuck, in the words the delegator and the user are told.
    enum StuckReason: String, Equatable {
        case neverStarted = "delivered 10m ago and never started"
        case waitingOnUser = "its worker has been waiting on a prompt for 5m"
        case goneQuiet = "its worker's screen has not changed for 15m"
    }

    /// The reason `task` looks stuck at `date`, or nil while it is still moving. A long quiet test
    /// run is indistinguishable from a hang from outside; the action is only a notice.
    func stuckReason(for task: TaskRecord, at date: Date) -> StuckReason? {
        if task.state == .delivered, let deliveredAt = task.deliveredAt,
           date.timeIntervalSince(deliveredAt) > Self.neverStartedThreshold {
            return .neverStarted
        }
        guard let sessionId = task.assigneeSessionId, let session = store.session(id: sessionId) else { return nil }
        if session.state == .waitingPermission,
           date.timeIntervalSince(session.stateChangedAt) > Self.waitingOnUserThreshold {
            return .waitingOnUser
        }
        if session.state == .working, let since = screenUnchangedSince(sessionId),
           date.timeIntervalSince(since) > Self.goneQuietThreshold {
            return .goneQuiet
        }
        return nil
    }

    /// One watchdog pass over `workspacePath`'s open tasks. Returns `true` when the inbox lock was
    /// still contended after `Self.relayLockTimeout`, which ends the tick.
    @discardableResult
    func watchStuckTasks(workspacePath: String, inboxStore: InboxStore) -> Bool {
        guard workspaceExists(workspacePath) else { return false }
        let open: [TaskRecord]
        do {
            open = try inboxStore.openTasks(timeout: Self.relayLockTimeout)
        } catch {
            if isRelayLockTimeout(error) { return true }
            NSLog("[linkC relay] watchStuckTasks: open tasks — %@", String(describing: error))
            return false
        }

        let date = now()
        var reported: [StuckReason] = []
        for task in open where task.state == .delivered || task.state == .started {
            do {
                guard let reason = stuckReason(for: task, at: date) else {
                    // Moving again: clear the mark so a later stall is reported.
                    if task.stuckNotifiedAt != nil {
                        try inboxStore.setStuckNotified(taskId: task.id, at: nil, timeout: Self.relayLockTimeout)
                    }
                    continue
                }
                guard task.stuckNotifiedAt == nil else { continue }
                try echo(
                    "Task \(task.shortId) looks stuck: \(reason.rawValue). "
                        + "linkc_get_task(\"\(task.id)\") or linkc_cancel_task(\"\(task.id)\").",
                    for: task,
                    inboxStore: inboxStore,
                    timeout: Self.relayLockTimeout
                )
                try inboxStore.setStuckNotified(taskId: task.id, at: date, timeout: Self.relayLockTimeout)
                reported.append(reason)
            } catch {
                if isRelayLockTimeout(error) { return true }
                NSLog("[linkC relay] watchStuckTasks: task %@ — %@", task.shortId, String(describing: error))
            }
        }

        if let first = reported.first {
            notifications.post(
                title: "linkC: \(reported.count) task(s) look stuck",
                body: "\(first.rawValue). The delegating agent was told."
            )
        }
        return false
    }
}
```

- [ ] **Step 4: Run the phase every tick**

In `Sources/LinkCKit/App/AppCoordinator+Relay.swift`, in `processPendingMessages(workspacePath:)`, directly after the `expireTasks` guard and before the `launchVerifications` guard:

```swift
        // After expiry, so a task that is already dead is failed rather than reported stuck.
        guard !watchStuckTasks(workspacePath: norm, inboxStore: inboxStore) else {
            return logRelayLockContention(workspacePath: norm)
        }
```

- [ ] **Step 5: Run it and watch it pass**

Run: `swift test --filter testANeverStartedTaskIsReportedOnceToTheDelegatorAndTheUser`
Expected: PASS, 1 test, 0 failures.

- [ ] **Step 6: Write the other two signals and recovery**

Add to `AppCoordinatorWatchdogTests`:

```swift
    /// A worker sitting on a prompt for 5 minutes, and a worker whose screen has not changed for
    /// 15, are both stuck; when the screen moves again the mark clears and a later stall reports.
    @MainActor
    func testAWaitingWorkerAndAQuietWorkerAreBothReported() async throws {
        let ws = tempDir.path
        let clock = ControllableClock()
        let coordinator = makeCoordinator(now: { clock.now() })
        defer { coordinator.shutdown() }
        let inbox = InboxStore(workspaceRoot: ws)

        let waiting = try coordinator.newSession(cwd: ws, agent: .codex)
        let waitingTask = try inbox.createTask(from: .claude, to: .codex, prompt: "One", files: [])
        try inbox.markTaskDelivered(taskId: waitingTask.id, sessionId: waiting.id)
        try inbox.markTaskStarted(taskId: waitingTask.id)
        coordinator.store.updateState(id: waiting.id, to: .waitingPermission)

        clock.advance(6 * 60)
        coordinator.processPendingMessages(workspacePath: ws)
        let waitingNotice = try inbox.fetchPending().first { $0.prompt.contains(waitingTask.shortId) }
        XCTAssertTrue(waitingNotice?.prompt.contains("waiting on a prompt") ?? false)

        let quiet = try coordinator.newSession(cwd: ws, agent: .cursor)
        let quietTask = try inbox.createTask(from: .claude, to: .cursor, prompt: "Two", files: [])
        try inbox.markTaskDelivered(taskId: quietTask.id, sessionId: quiet.id)
        try inbox.markTaskStarted(taskId: quietTask.id)
        let term = try XCTUnwrap(coordinator.terminals.session(id: quiet.id))
        XCTAssertTrue(try await waitUntil { term.isRunning })
        coordinator.sampleAgentStates()
        coordinator.store.updateState(id: quiet.id, to: .working)

        clock.advance(16 * 60)
        coordinator.processPendingMessages(workspacePath: ws)
        XCTAssertTrue(try inbox.task(id: quietTask.id)?.stuckNotifiedAt != nil)
        XCTAssertTrue(try inbox.fetchPending().first { $0.prompt.contains(quietTask.shortId) }?.prompt.contains("screen has not changed") ?? false)

        // The screen moves: the mark clears and a later stall is reported again.
        term.sendInput("Ran 1 shell command\r")
        _ = try await waitUntil { term.recentOutput(lines: 5).contains("Ran 1 shell command") }
        coordinator.sampleAgentStates()
        coordinator.store.updateState(id: quiet.id, to: .working)
        coordinator.processPendingMessages(workspacePath: ws)
        XCTAssertNil(try inbox.task(id: quietTask.id)?.stuckNotifiedAt, "a task that moves again must be reportable later")

        clock.advance(16 * 60)
        coordinator.processPendingMessages(workspacePath: ws)
        XCTAssertNotNil(try inbox.task(id: quietTask.id)?.stuckNotifiedAt, "a later stall reports again")
        XCTAssertEqual(try inbox.fetchPending().filter { $0.prompt.contains(quietTask.shortId) }.count, 2)
    }
```

`markTaskDelivered(taskId:sessionId:)` puts a task in `.delivered` with that session as its assignee; `markTaskStarted(taskId:)` then moves it to `.started`. Both tests mark their task started on purpose: `stuckReason` checks `.neverStarted` first and only for a `.delivered` task, so a started task is the only way to test the other two signals in isolation.

- [ ] **Step 7: Run both tests and watch them pass**

Run: `swift test --filter 'AppCoordinatorWatchdogTests'`
Expected: PASS, 3 tests, 0 failures.

- [ ] **Step 8: Revert-proof each signal**

One at a time: make `stuckReason` return nil for that branch (e.g. change `.neverStarted`'s `if` condition to `if false`), run the test that covers it, confirm it fails, restore. Then break the recovery clear (`at: nil` → `at: date`), run the second test, confirm the "reportable later" assertion fails, restore. Confirm each file matches your edit afterwards.

- [ ] **Step 9: Run the full suite and commit**

Run: `swift test 2>&1 | tail -3` — expected 0 failures.

```bash
git add Sources/LinkCKit/App/AppCoordinator+Watchdog.swift Sources/LinkCKit/App/AppCoordinator+Relay.swift Tests/LinkCKitTests/AppCoordinatorWatchdogTests.swift
git commit -m "feat(watchdog): report a task whose worker has stopped moving"
```

---

### Task 4: Notice routing and the can't-land warning

**Files:**
- Modify: `Sources/LinkCKit/App/AppCoordinator+Relay.swift` (`dispatchMessages`)
- Modify: `Sources/LinkCKit/App/AppCoordinator+Watchdog.swift` (add `noteUndeliveredNotice`)
- Test: `Tests/LinkCKitTests/AppCoordinatorWatchdogTests.swift`

**Interfaces:**
- Consumes: `AppCoordinator.undeliveredNoticesReported` (Task 1), `PendingMessage.taskId/createdAt/kind/toAgent/id`, `InboxStore.task(id:timeout:)`, `TaskRecord.fromSessionId`, `AgentKind.displayName`.
- Produces: `AppCoordinator.noticeCannotLandThreshold`; `AppCoordinator.noteUndeliveredNotice(_ message: PendingMessage)`.

- [ ] **Step 1: Write the failing routing test**

Add to `AppCoordinatorWatchdogTests`:

```swift
    /// A task's notice belongs to the session that delegated it, not to any session of that agent
    /// kind. With no session free to take it, nothing is spawned and the user is told once.
    @MainActor
    func testANoticeGoesToTheDelegatingSessionAndOtherwiseWaits() async throws {
        let ws = tempDir.path
        let clock = ControllableClock()
        let sink = RecordingSink()
        let coordinator = makeCoordinator(sink: sink, now: { clock.now() })
        defer { coordinator.shutdown() }
        let inbox = InboxStore(workspaceRoot: ws)

        let other = try coordinator.newSession(cwd: ws, agent: .claude)
        let delegator = try coordinator.newSession(cwd: ws, agent: .claude)
        for id in [other.id, delegator.id] {
            coordinator.store.updateState(id: id, to: .ready)
            _ = try await waitUntil { coordinator.terminals.session(id: id)?.acceptsPaste ?? false }
        }
        let task = try inbox.createTask(from: .claude, to: .codex, fromSessionId: delegator.id, prompt: "Refactor", files: [])
        _ = try inbox.enqueue(from: .codex, to: .claude, kind: .completion, taskId: task.id, body: "Task \(task.shortId) looks stuck")

        coordinator.processPendingMessages(workspacePath: ws)

        let delegatorTerm = try XCTUnwrap(coordinator.terminals.session(id: delegator.id))
        let otherTerm = try XCTUnwrap(coordinator.terminals.session(id: other.id))
        let landed = try await waitUntil { delegatorTerm.recentOutput(lines: 20).contains(task.shortId) }
        XCTAssertTrue(landed, "the delegating session must receive its task's notice")
        XCTAssertFalse(otherTerm.recentOutput(lines: 20).contains(task.shortId), "another session of the same kind must not")
    }

    @MainActor
    func testAnUndeliverableNoticeSpawnsNothingAndWarnsTheUserOnce() async throws {
        let ws = tempDir.path
        let clock = ControllableClock()
        let sink = RecordingSink()
        let coordinator = makeCoordinator(sink: sink, now: { clock.now() })
        defer { coordinator.shutdown() }
        let inbox = InboxStore(workspaceRoot: ws)
        let message = try inbox.enqueue(from: .codex, to: .claude, kind: .completion, body: "Task ABCD1234 looks stuck")

        coordinator.processPendingMessages(workspacePath: ws)
        XCTAssertTrue(coordinator.store.sessions.isEmpty, "a notice must never spawn a session")
        XCTAssertEqual(try inbox.fetchPending().filter { $0.id == message.id }.count, 1, "it waits instead")
        XCTAssertTrue(sink.deliveries.isEmpty, "not yet — it has only just been queued")

        clock.advance(6 * 60)
        coordinator.processPendingMessages(workspacePath: ws)
        coordinator.processPendingMessages(workspacePath: ws)
        XCTAssertEqual(sink.deliveries.filter { $0.body.contains("waiting") }.count, 1, "told once, not every tick")
    }
```

- [ ] **Step 2: Run them and watch them fail**

Run: `swift test --filter 'testANoticeGoesToTheDelegatingSessionAndOtherwiseWaits|testAnUndeliverableNoticeSpawnsNothingAndWarnsTheUserOnce'`
Expected: FAIL — the first because the notice lands in whichever session was created first, the second because today a session is spawned to receive it (`store.sessions.isEmpty` fails).

- [ ] **Step 3: Add the warning**

In `Sources/LinkCKit/App/AppCoordinator+Watchdog.swift`, inside the same extension:

```swift
    /// A notice queued this long with nobody able to take it is worth telling the user about.
    static let noticeCannotLandThreshold: TimeInterval = 5 * 60

    /// Tells the user once that a message cannot reach its agent — blocked on a prompt, busy past
    /// the threshold, or no session of that kind alive. Task briefs are excluded: they spawn.
    func noteUndeliveredNotice(_ message: PendingMessage) {
        guard message.kind != .task,
              now().timeIntervalSince(message.createdAt) > Self.noticeCannotLandThreshold,
              !undeliveredNoticesReported.contains(message.id) else { return }
        undeliveredNoticesReported.insert(message.id)
        notifications.post(
            title: "linkC: \(message.toAgent.displayName) has not seen a notice",
            body: "A message has been waiting 5m — no \(message.toAgent.displayName) session is free to take it."
        )
    }
```

- [ ] **Step 4: Route to the delegating session and stop spawning for notices**

In `Sources/LinkCKit/App/AppCoordinator+Relay.swift`, in `dispatchMessages(workspacePath:inboxStore:)`, replace the target block (currently `var target = store.sessions.first { ... }` through the `if target == nil { ... spawnTeammate ... continue }` block, and the `guard let session = target, isIdle(session.state) else { continue }` line that follows) with:

```swift
            // A notice about a task belongs to the session that delegated it: any other session of
            // that kind is a different conversation. Fall back to one only when it is gone.
            var target: Session?
            if let taskId = message.taskId,
               let record = ((try? inboxStore.task(id: taskId, timeout: Self.relayLockTimeout)) ?? nil),
               let delegatorId = record.fromSessionId {
                target = store.sessions.first { $0.id == delegatorId && $0.state != .ended }
            }
            if target == nil {
                target = store.sessions.first {
                    ($0.cwd as NSString).standardizingPath == workspacePath && $0.agentKind == message.toAgent && $0.state != .ended
                }
            }
            if target == nil {
                // Only a task brief is worth spawning an agent for. A notice waits for a session
                // to exist, and the user is told when it has waited too long.
                guard message.kind == .task else {
                    noteUndeliveredNotice(message)
                    continue
                }
                let goal: String? = message.kind == .task ? message.prompt : nil
                do {
                    _ = try spawnTeammate(in: workspacePath, agent: message.toAgent, goal: goal)
                } catch {
                    lastSpawnFailure = SpawnFailure(agent: message.toAgent, workspacePath: workspacePath, error: String(describing: error))
                    NSLog("[linkC relay] dispatchMessages: message %@ could not spawn %@ — %@",
                          message.id, message.toAgent.displayName, String(describing: error))
                }
                continue
            }
            guard let session = target, isIdle(session.state) else {
                noteUndeliveredNotice(message)
                continue
            }
```

- [ ] **Step 5: Run them and watch them pass**

Run: `swift test --filter 'testANoticeGoesToTheDelegatingSessionAndOtherwiseWaits|testAnUndeliverableNoticeSpawnsNothingAndWarnsTheUserOnce'`
Expected: PASS, 2 tests, 0 failures.

- [ ] **Step 6: Revert-proof both**

Delete the delegator lookup (the first `if let taskId ...` block), run the routing test, confirm it fails, restore. Change `guard message.kind == .task else { ... }` back to always spawning, run the second test, confirm `store.sessions.isEmpty` fails, restore. Confirm the file matches your edit afterwards.

- [ ] **Step 7: Run the full suite and commit**

Run: `swift test 2>&1 | tail -3` — expected 0 failures.

```bash
git add Sources/LinkCKit/App/AppCoordinator+Relay.swift Sources/LinkCKit/App/AppCoordinator+Watchdog.swift Tests/LinkCKitTests/AppCoordinatorWatchdogTests.swift
git commit -m "feat(watchdog): send a task's notice to the session that delegated it"
```

---

## Notes for the implementer

- The relay tick runs once a second per workspace on the main actor. Anything added to it must be cheap and must never wait on a lock longer than `AppCoordinator.relayLockTimeout`.
- `AppCoordinator` is `@MainActor`; every test above is `@MainActor` for the same reason.
- Mock agent sessions never reach `.ready` on their own (`ProcessSnooper` finds no real agent in the process tree), which is why the tests set the state directly.
- If a test needs a threshold to pass, advance the injected clock. Never `sleep` a real threshold.

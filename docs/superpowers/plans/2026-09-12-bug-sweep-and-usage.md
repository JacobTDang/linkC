# Bug Sweep and Usage Visibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the thirteen defects still open from the 2026-09-12 bug sweep, and let an orchestrator see what each agent has left before it delegates.

**Architecture:** The fixes are independent and each lands with its own tests. The usage work adds two pure readers over files the agent CLIs already write, plus the MCP surface that reports them. Nothing new is persisted and no process gains a dependency on another's memory.

**Tech Stack:** Swift 6 (strict concurrency, `swiftLanguageMode(.v6)`), SwiftPM, XCTest. No new dependencies.

## Global Constraints

- Usage design: `docs/superpowers/specs/2026-09-12-usage-visibility-design.md`. Where this plan and that spec disagree, ask.
- **No silent fallback.** A value that cannot be determined is reported as unavailable with a reason. A failure that cannot be handled is logged loudly. `try?` around a store write is a defect unless the comment says why the failure is safe to drop.
- **Never invent work.** No code path may create a task that no caller asked for.
- Two kinds of process share every state file — the app, and one `linkc-mcp` per agent CLI. Any change to a file's shape must let an older binary keep reading it, and must not let an older binary destroy it.
- The MCP tool surface is a stability contract: optional additions only, existing parameters never changed or removed.
- Swift 6 strict concurrency. A `@Sendable` closure cannot capture a `var`.
- Tests first for every task: write it, run it, watch it fail for the stated reason, then fix. The suite is 745 tests, 4 skipped, 0 failures at `7ce2e57`; it must stay green.
- Never mention Claude, Anthropic, or any AI assistant in a commit message, and never add an attribution trailer.
- **When writing tests or comments, do not quote an agent's exhaustion banner text.** Those strings are what the limit detector matches, and this terminal's own output is scanned. Refer to them as "the banner phrases" in prose; in test fixtures the strings are required and fine.

## Reference: work already written but not merged

Branch `recovered/agent-sweep-fixes` holds an unreviewed implementation of Tasks 2, 3 and parts of 1 and 6, written by a Codex session acting on tasks linkC synthesized from a false-positive match. It is worth reading for approach — `git show 0332417` — but it is not a source of truth: it was cancelled mid-flight and never reviewed. Do not cherry-pick it wholesale.

## File Structure

| File | Responsibility |
|---|---|
| `Sources/LinkCKit/Blackboard/BlackboardStore.swift` | Task 1: a decode failure must not become an empty board. |
| `Sources/LinkCKit/App/AppCoordinator+Relay.swift` | Tasks 2, 3, 6, 7, 8: delivery, expiry, verification exclusivity, lock discipline. |
| `Sources/LinkCKit/Verification/VerificationRunner.swift` | Task 3: distinguish "could not run" from "tests failed". |
| `Sources/LinkCKit/Terminal/TerminalSession.swift` | Task 4: paste-mode readiness. |
| `Sources/LinkCKit/MCP/MCPServer.swift` | Tasks 5, 11: assignee-scoped authorization, tier argument validation, usage reporting, delegation warning. |
| `Sources/LinkCKit/Blackboard/InboxStore.swift` | Tasks 5, 6: assignee checks, message pruning, dedupe. |
| `Sources/LinkCKit/Config/AgentModelStore.swift` | Task 9: missing versus unreadable. |
| `Sources/LinkCKit/Usage/AgentUsage.swift` (new) | Task 10: the usage model and thresholds. |
| `Sources/LinkCKit/Usage/CodexUsageReader.swift` (new) | Task 10: read Codex's rollout records. |
| `Sources/LinkCKit/Usage/ClaudeUsageReader.swift` (new) | Task 10: window figures from the transcripts. |

---

### Task 1: A corrupt blackboard must not erase itself

**Files:**
- Modify: `Sources/LinkCKit/Blackboard/BlackboardStore.swift` (`loadUnlocked`, around line 88-99)
- Test: `Tests/LinkCKitTests/BlackboardStoreStressTests.swift` (`testCorruptedJSONRecovery`, line 135)

**Interfaces:**
- Produces: `BlackboardStore.loadUnlocked` throws on an undecodable file instead of returning a fresh `Blackboard`.

**The defect:** `loadUnlocked`'s catch returns `Blackboard(projectPath: workspaceRoot)`. The app heartbeats every live session once a second (`AppCoordinator.swift:549-551`, wrapped in `try?`), and each heartbeat is a load-modify-save — so one unreadable file becomes an empty file within a second, losing every `sharedNotes` entry an agent wrote. `InboxStore.loadUnlocked` was already fixed to throw for exactly this reason; the blackboard kept the old shape. `testCorruptedJSONRecovery` asserts the erasure is correct behaviour, which is why nothing caught it.

- [ ] **Step 1: Rewrite the test to the correct contract**

Replace `testCorruptedJSONRecovery` with:

```swift
    /// An unreadable blackboard is preserved, not replaced. The app heartbeats every session
    /// once a second, and each heartbeat is a load-modify-save: if a decode failure read as
    /// "empty board", the next heartbeat would overwrite the file and every shared note in it.
    func testCorruptedJSONIsPreservedRatherThanErased() throws {
        let store = BlackboardStore(workspaceRoot: tempDir.path)
        _ = try store.broadcastIntent(agentKind: .claude, pid: 501, goal: "Initial setup", files: ["Sources/Main.swift"])
        _ = try store.postNote(agentKind: .claude, pid: 501, note: "a note nobody can afford to lose")

        let path = tempDir.appendingPathComponent(".linkc/blackboard.json").path
        let good = try Data(contentsOf: URL(fileURLWithPath: path))
        try Data("{\"version\": 1, \"activeAgents\": [{\"incomplete\": tr".utf8).write(to: URL(fileURLWithPath: path))

        XCTAssertThrowsError(try store.load(), "an undecodable board must surface, not read as empty")
        XCTAssertThrowsError(try store.heartbeat(agentKind: .claude, pid: 501),
                             "a heartbeat must not be able to overwrite a file it could not read")

        let after = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertNotEqual(after, good, "sanity: the file is still the corrupt bytes we wrote")
        XCTAssertEqual(after.count, 48, "the corrupt file is left exactly as found")

        // Repair is a deliberate act: once the bytes are valid again, writes resume.
        try good.write(to: URL(fileURLWithPath: path))
        let repaired = try store.load()
        XCTAssertEqual(repaired.sharedNotes.count, 1)
    }
```

Check `postNote`'s real signature in `BlackboardStore.swift` before using it; if it differs, match it rather than changing the store.

- [ ] **Step 2: Run it and watch it fail**

Run: `swift test --filter BlackboardStoreStressTests`
Expected: FAIL — `load()` returns an empty board instead of throwing.

- [ ] **Step 3: Make the decode failure loud**

```swift
        let data = try Data(contentsOf: blackboardURL)
        do {
            return try decoder.decode(Blackboard.self, from: data)
        } catch {
            // Never substitute an empty board. Every mutation here is load-modify-save, and the
            // app heartbeats once a second per session: returning empty would overwrite the file
            // and lose every shared note in it. A missing file is legitimately empty (handled
            // above); an unreadable one is a problem the caller must see.
            NSLog("linkC: blackboard.json at %@ is unreadable — %@", blackboardURL.path, String(describing: error))
            throw error
        }
```

- [ ] **Step 4: Check every caller survives a throw**

Run: `grep -n 'heartbeat\|broadcastIntent\|postNote\|checkConflicts' Sources/LinkCKit/App/*.swift Sources/LinkCKit/MCP/MCPServer.swift`
Each app-side caller already uses `try?` and now skips a tick instead of erasing the file — acceptable, and the NSLog above makes it visible. Each MCP-side caller already returns `isError`. If you find a caller that would now silently stop working with no log, add the log there and say so in your report.

- [ ] **Step 5: Run the suite**

Run: `swift test`
Expected: 745 tests, 4 skipped, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add Sources/LinkCKit/Blackboard/BlackboardStore.swift Tests/LinkCKitTests/BlackboardStoreStressTests.swift
git commit -m "fix(blackboard): surface an unreadable board instead of erasing it"
```

---

### Task 2: Do not deliver work into a checkout being verified

**Files:**
- Modify: `Sources/LinkCKit/App/AppCoordinator+Relay.swift` (`processPendingMessages` line 12-19, `dispatchTasks` line 126, `dispatchMessages` line 177)
- Test: `Tests/LinkCKitTests/AppCoordinatorRelayTests.swift`

**Interfaces:**
- Consumes: `AppCoordinator.verificationsInFlight: Set<String>` (`AppCoordinator.swift:61`).
- Produces: delivery is suppressed for a workspace while a verification for it is in flight.

**The defect:** `verificationsInFlight` is consulted only inside `launchVerifications`. A verification runs the delegator's command at a reported sha and then checks that HEAD still equals that sha and the tree is clean — but the relay keeps delivering new briefs into the same checkout while that runs, and agents share one working copy. A worker that starts editing mid-run makes a correct task fail its clean check; a worker whose edit lands and reverts inside the window makes the verdict simply wrong.

- [ ] **Step 1: Write the failing test**

```swift
    /// A verification owns the checkout while it runs: it executes the delegator's command and
    /// then requires HEAD and a clean tree to still match the reported sha. Delivering another
    /// brief into that same working copy mid-run corrupts the verdict.
    @MainActor
    func testNoTaskIsDeliveredWhileAVerificationIsInFlight() async throws {
        let ws = tempDir.path
        let inbox = InboxStore(workspaceRoot: ws)
        let gateStarted = expectation(description: "gate started")
        let release = expectation(description: "released")
        let verifier = BlockingVerifier(started: gateStarted, release: release)
        let coordinator = makeCoordinator(verifier: verifier)
        defer { coordinator.shutdown(); release.fulfill() }

        let idle = try coordinator.newSession(cwd: ws, agent: .codex, mode: .new, tier: .standard)
        coordinator.store.updateState(id: idle.id, to: .ready)

        // One task needing a gate, and one already queued and deliverable.
        _ = try inbox.createTask(from: .claude, to: .codex, tier: .standard, prompt: "needs a gate", files: [],
                                 verification: Verification(branch: "main", baseSha: String(repeating: "a", count: 40),
                                                            command: "true", testPaths: ["t"]))
        let deliverable = try inbox.createTask(from: .claude, to: .codex, tier: .standard, prompt: "plain brief", files: [])

        coordinator.processPendingMessages(workspacePath: ws)
        await fulfillment(of: [gateStarted], timeout: 5)

        coordinator.processPendingMessages(workspacePath: ws)
        XCTAssertEqual(try inbox.task(id: deliverable.id)?.state, .queued,
                       "nothing may be injected into a checkout under verification")
    }
```

`BlockingVerifier` is a test double you add beside the existing `ScriptedVerifier` in that file: its `gate` fulfils `started`, waits on `release`, then returns a passing gate verdict. Model it on `ScriptedVerifier`'s shape and conform to the same `TaskVerifier` requirements.

- [ ] **Step 2: Run it and watch it fail**

Run: `swift test --filter testNoTaskIsDeliveredWhileAVerificationIsInFlight`
Expected: FAIL — the second task reaches `.delivered`.

- [ ] **Step 3: Launch verifications before delivery, and gate delivery on them**

In `processPendingMessages`, move `launchVerifications` ahead of the two dispatch calls so a run claims the workspace before anything is handed out:

```swift
    /// One relay tick for `workspacePath`: expire, start verification, then deliver only if no
    /// run holds this checkout. A verification owns HEAD and the tree while it runs.
    public func processPendingMessages(workspacePath: String) {
        let norm = (workspacePath as NSString).standardizingPath
        let inboxStore = InboxStore(workspaceRoot: norm)
        expireTasks(workspacePath: norm, inboxStore: inboxStore)
        launchVerifications(workspacePath: norm, inboxStore: inboxStore)
        dispatchTasks(workspacePath: norm, inboxStore: inboxStore)
        dispatchMessages(workspacePath: norm, inboxStore: inboxStore)
    }
```

Then add the same guard to the top of both `dispatchTasks` and `dispatchMessages`, directly after their existing `workspaceExists` guard:

```swift
        // A verification owns this checkout until it finishes: injecting a brief now would let a
        // worker edit the tree the verdict is about to be measured against.
        guard !verificationsInFlight.contains(workspacePath) else { return }
```

- [ ] **Step 4: Run the relay suite**

Run: `swift test --filter AppCoordinatorRelayTests`
Expected: PASS. If an existing test now fails because it expected delivery during a run, read it carefully: if it was asserting the old behaviour, update it and say so in your report; if it reveals a real deadlock (delivery permanently starved), stop and report instead of loosening the guard.

- [ ] **Step 5: Run the suite and commit**

```bash
swift test
git add Sources/LinkCKit/App/AppCoordinator+Relay.swift Tests/LinkCKitTests/AppCoordinatorRelayTests.swift
git commit -m "fix(relay): hold delivery while a verification owns the checkout"
```

---

### Task 3: A gate that is still running must not be expired

**Files:**
- Modify: `Sources/LinkCKit/App/AppCoordinator+Relay.swift` (`expireTasks`, the `.gating` arm around line 63), `Sources/LinkCKit/Verification/VerificationRunner.swift` (`verify`, around line 83)
- Test: `Tests/LinkCKitTests/AppCoordinatorRelayTests.swift`, `Tests/LinkCKitTests/VerificationRunnerTests.swift`

**Interfaces:**
- Produces: a `.gating` task whose gate is in flight is left alone; `verify` distinguishes "command could not run" from "tests failed".

**The defect:** the `.gating` arm expires on `now - createdAt > queuedTaskExpiry` (3600s) with no regard for a run in progress. A gate may legitimately take up to its `timeoutSeconds` (max 3600) and may have waited behind `maxConcurrentVerifications`. When the expiry fires mid-run the task is marked expired with "gate did not run within 60m" — untrue — and when the real verdict arrives, `resolveGate` throws `illegalTransition` and `finishVerification` only logs it. The delegator is told a falsehood and the real result is dropped. `.reported` already extends its lease on report for this very reason.

- [ ] **Step 1: Write the failing test**

```swift
    /// A gate may legitimately run for its whole timeout, and may have queued behind another
    /// run. Expiring it mid-flight tells the delegator the gate never ran and then throws the
    /// real verdict away.
    @MainActor
    func testAGateInFlightIsNotExpired() async throws {
        let ws = tempDir.path
        let inbox = InboxStore(workspaceRoot: ws)
        let gateStarted = expectation(description: "gate started")
        let release = expectation(description: "released")
        let coordinator = makeCoordinator(verifier: BlockingVerifier(started: gateStarted, release: release))
        defer { coordinator.shutdown(); release.fulfill() }

        let task = try inbox.createTask(from: .claude, to: .codex, tier: .standard, prompt: "needs a gate", files: [],
                                        verification: Verification(branch: "main", baseSha: String(repeating: "a", count: 40),
                                                                   command: "true", testPaths: ["t"]))
        coordinator.processPendingMessages(workspacePath: ws)
        await fulfillment(of: [gateStarted], timeout: 5)

        // Age the row past the expiry window while its gate is still running.
        var raw = try inbox.load()
        if let i = raw.tasks.firstIndex(where: { $0.id == task.id }) {
            raw.tasks[i] = raw.tasks[i].with(createdAt: Date().addingTimeInterval(-2 * 3600))
        }
        try inbox.saveRaw(raw)

        coordinator.expireTasks(workspacePath: ws, inboxStore: inbox)
        XCTAssertEqual(try inbox.task(id: task.id)?.state, .gating, "an in-flight gate is not stale")
    }
```

`TaskRecord` has no `with(createdAt:)` helper. Either add a test-only helper in the test file that rebuilds the record through `TaskRecord.init` preserving every field, or write the aged row as raw JSON the way `InboxTaskLifecycleTests` does. Do not add production API for a test's convenience.

- [ ] **Step 2: Run it and watch it fail**

Run: `swift test --filter testAGateInFlightIsNotExpired`
Expected: FAIL — the task is `.expired`.

- [ ] **Step 3: Skip expiry for a task whose run is in flight**

`verificationsInFlight` is keyed by workspace, so it cannot say *which* task is running. Add that: change it to `var verificationsInFlight: [String: String] = [:]` (workspace → task id) in `AppCoordinator.swift:61`, update `launchVerifications` to insert `[workspacePath: task.id]` and `finishVerification` to remove the key, keep the two existing guards (`verificationsInFlight[workspacePath] == nil` and `verificationsInFlight.count < Self.maxConcurrentVerifications`), and in `expireTasks` skip the task that is running:

```swift
        for task in open {
            // A run in flight is not a stale task. Its own timeout bounds it.
            if verificationsInFlight[workspacePath] == task.id { continue }
```

Task 2's delivery guard becomes `verificationsInFlight[workspacePath] == nil`.

- [ ] **Step 4: Name the infrastructure failure in `verify`**

`gate` already separates exit 126/127 ("command could not run") from a real failure; `verify` calls every nonzero exit "tests failed". Mirror the gate's wording for 126 and 127 so a broken harness at the reported sha does not read as a failing test. Keep the outcome `failed` either way — only the reason text changes. Add a `VerificationRunnerTests` case asserting the reason for exit 127.

- [ ] **Step 5: Run the suite and commit**

```bash
swift test
git add Sources/LinkCKit/App/AppCoordinator+Relay.swift Sources/LinkCKit/App/AppCoordinator.swift Sources/LinkCKit/Verification/VerificationRunner.swift Tests/LinkCKitTests/AppCoordinatorRelayTests.swift Tests/LinkCKitTests/VerificationRunnerTests.swift
git commit -m "fix(verification): never expire a gate that is still running"
```

---

### Task 4: Do not inject a brief before the TUI can accept a paste

**Files:**
- Modify: `Sources/LinkCKit/Terminal/TerminalSession.swift` (`sendInput`, around line 186), `Sources/LinkCKit/App/AppCoordinator+Relay.swift` (`isIdle` / the delivery guards)
- Test: `Tests/LinkCKitTests/AgentSubmitPtyTests.swift`, `Tests/LinkCKitTests/AppCoordinatorRelayTests.swift`

**Interfaces:**
- Produces: `TerminalSession.acceptsPaste: Bool` — true once the child has enabled bracketed paste.

**The defect:** `sendInput` wraps multi-line text in a bracketed paste only when `terminalView.getTerminal().bracketedPasteMode` is already true, and SwiftTerm sets that flag only after the child emits the enable sequence. Readiness does not wait for it: Claude's `.sessionStart` hook drives a relay tick in the same call that marks the session ready, and other kinds are promoted on process liveness alone. A brief delivered in that gap goes through the plain-text branch with embedded newlines, which a line-oriented TUI submits line by line — shredding the brief. No test can see it: every mock agent is `cat`, which never enables paste mode, so both branches look identical, and the live tests all sleep six seconds before injecting.

- [ ] **Step 1: Expose the negotiated state**

In `TerminalSession`:

```swift
    /// True once the child has turned on bracketed paste — the first moment a multi-line frame
    /// can be delivered as one unit rather than as a run of submitted lines.
    public var acceptsPaste: Bool {
        guard liveness.withLock({ $0 }) else { return false }
        return _terminalView?.getTerminal().bracketedPasteMode ?? false
    }
```

Read `_terminalView` directly, as `recentOutput` does, so asking the question never forces a view to exist.

- [ ] **Step 2: Write the failing live test**

Add to `AgentSubmitPtyTests.swift` (same `LINKC_LIVE_AGENT_TESTS=1` gate as its neighbours):

```swift
    /// Delivery used to be allowed as soon as the process existed. This is the boundary case:
    /// inject the moment the process is up, with no warm-up sleep, and the frame must still
    /// arrive as one message rather than as a run of submitted lines.
    func testAMultiLineFrameSurvivesInjectionRightAfterStart() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LINKC_LIVE_AGENT_TESTS"] == "1", "Drives the real Claude CLI; set LINKC_LIVE_AGENT_TESTS=1 to run it.")
        guard let path = AgentDescriptor.resolveExecutable(for: .claude),
              FileManager.default.isExecutableFile(atPath: path) else { return }

        let session = TerminalSession(id: "test-claude-paste-boundary", cwd: FileManager.default.currentDirectoryPath, title: "claude", agentKind: .claude)
        try session.start(executable: path, args: AgentDescriptor.arguments(for: .claude, mode: .new), env: [:])

        // No warm-up: poll the negotiated flag, which is what delivery must wait for.
        var ready = false
        for _ in 0..<200 {
            try await Task.sleep(for: .milliseconds(50))
            if session.acceptsPaste { ready = true; break }
        }
        XCTAssertTrue(ready, "the CLI must negotiate bracketed paste; delivery keys off this")

        session.sendInput("[linkC test frame]\nAdd one hundred thirty seven to forty two. Reply with the digits only, nothing else.\n\nA second paragraph, so the input takes the bracketed-paste path.")

        var answered = false
        for _ in 0..<80 {
            try await Task.sleep(for: .milliseconds(250))
            if session.recentOutput(lines: 40).contains(Self.marker) { answered = true; break }
        }
        session.terminate()
        XCTAssertTrue(answered, "the frame must arrive whole and be answered")
    }
```

- [ ] **Step 3: Run it and record what you see**

Run: `LINKC_LIVE_AGENT_TESTS=1 swift test --filter AgentSubmitPtyTests`
This settles the open question from the sweep. Record in your report how long negotiation took and whether the flag was ever false when the process was already alive. If the flag is true before the process is usefully up, say so — the guard in Step 4 is still correct, but the finding's severity changes.

- [ ] **Step 4: Require paste readiness for a multi-line delivery**

In `dispatchTasks`, a candidate must be able to accept the frame. The brief is always multi-line, so add to the candidate filter:

```swift
                    && (terminals.session(id: $0.id)?.acceptsPaste ?? false)
```

Leave `dispatchMessages` alone for single-line notices, but in `sendInput` make the fallback honest: when text is multi-line and paste mode is off, log it and still send the paste sequence rather than the raw branch — a TUI that ignores the wrapper is no worse off, and one that honours it is saved.

```swift
        let multiLine = !trimmed.isEmpty && trimmed.contains("\n")
        if multiLine && !terminalView.getTerminal().bracketedPasteMode {
            NSLog("linkC: session %@ has not negotiated bracketed paste; sending the paste sequence anyway", id)
        }
        let pasted = multiLine
```

- [ ] **Step 5: Keep the mock-agent tests working**

`cat` never negotiates paste mode, so the new candidate filter would starve every relay test. Give the test mock a way to say yes: either have `makeCoordinator`'s mock script emit the enable sequence on start (`printf '\033[?2004h'` before `exec /bin/cat`), or add a test seam on `TerminalSession` that the tests set. Prefer the mock script — it exercises the real negotiation path. Update `AppCoordinatorRelayTests` and `AppCoordinatorIntegrationTests` mocks together.

- [ ] **Step 6: Run the suite and commit**

```bash
swift test
git add Sources/LinkCKit/Terminal/TerminalSession.swift Sources/LinkCKit/App/AppCoordinator+Relay.swift Tests/LinkCKitTests/
git commit -m "fix(delivery): wait for bracketed paste before injecting a brief"
```

---

### Task 5: Only the assignee may act on a task

**Files:**
- Modify: `Sources/LinkCKit/MCP/MCPServer.swift` (`linkc_start_task` ~707, `linkc_complete_task` ~723, `linkc_cancel_task` ~763, `linkc_my_tasks`, the `tier` parse ~448)
- Test: `Tests/LinkCKitTests/MCPServerTaskTests.swift`

**Interfaces:**
- Consumes: `TaskRecord.assigneeSessionId`, and `environment["LINKC_SESSION"]` which the MCP process already inherits.
- Produces: lifecycle calls refuse when the caller is not the assignee session.

**The defect:** `start`, `complete` and `cancel` authorize on `caller.agent == task.toAgent` only. `assigneeSessionId` is written on delivery and never read — zero references in `MCPServer.swift`. Tier-pinned sessions mean several sessions of one kind now run at once, so a sibling that never received the brief can complete the task and hand the delegator a fabricated report. `linkc_my_tasks` lists by kind, so it advertises the task to that sibling as its own.

- [ ] **Step 1: Write the failing tests**

```swift
    func testOnlyTheAssigneeSessionMayCompleteATask() throws {
        let task = try inbox.createTask(from: .claude, to: .codex, tier: .standard, prompt: "Build", files: [])
        try inbox.markTaskDelivered(taskId: task.id, sessionId: "session-A")

        let sibling = MCPServer(workspaceRoot: tempDir.path, inboxStore: inbox,
                                environment: ["LINKC_AGENT": "codex", "LINKC_SESSION": "session-B"],
                                ancestorResolver: { _ in nil }, modelSettings: { .seeded })
        let refused = try call(sibling, "linkc_complete_task", ["task_id": task.id, "status": "done", "summary": "I did it"])
        XCTAssertTrue(refused.isError, refused.text)
        XCTAssertEqual(try inbox.task(id: task.id)?.state, .delivered, "a sibling may not settle another session's task")

        let assignee = MCPServer(workspaceRoot: tempDir.path, inboxStore: inbox,
                                 environment: ["LINKC_AGENT": "codex", "LINKC_SESSION": "session-A"],
                                 ancestorResolver: { _ in nil }, modelSettings: { .seeded })
        let ok = try call(assignee, "linkc_complete_task", ["task_id": task.id, "status": "done", "summary": "done"])
        XCTAssertFalse(ok.isError, ok.text)
    }

    func testAnUnknownSessionMayStillActWhenTheTaskHasNoAssignee() throws {
        // A queued task has no assignee yet, and a session-less caller (an agent started outside
        // linkC) must not be locked out of its own kind's work.
        let task = try inbox.createTask(from: .claude, to: .codex, tier: .standard, prompt: "Build", files: [])
        let res = try call(server(as: .codex, models: .seeded), "linkc_cancel_task", ["task_id": task.id, "reason": "not needed"])
        XCTAssertFalse(res.isError, res.text)
    }

    func testANonStringTierIsRefusedRatherThanIgnored() throws {
        let res = try call(server(as: .claude, models: .seeded), "linkc_delegate_task",
                           ["to": "codex", "prompt": "Rename a file", "tier": 3])
        XCTAssertTrue(res.isError)
        XCTAssertTrue(res.text.contains("tier must be light, standard or deep"), res.text)
    }
```

- [ ] **Step 2: Run them and watch them fail**

Run: `swift test --filter MCPServerTaskTests`
Expected: the sibling completes the task; a numeric tier is silently treated as absent.

- [ ] **Step 3: Add the assignee check**

Add one helper next to `requireTask` and use it in all three handlers:

```swift
    /// A task delivered to a specific session belongs to that session. Several sessions of one
    /// kind run at once now that sessions are pinned per tier, and a sibling that never received
    /// the brief must not be able to settle it. A task with no assignee yet is open to its kind,
    /// and a caller with no session id is not locked out — linkC cannot prove it is not the
    /// assignee, and refusing would break agents started outside linkC.
    func callerMayAct(on task: TaskRecord) -> Bool {
        guard let assignee = task.assigneeSessionId,
              let caller = environment["LINKC_SESSION"], !caller.isEmpty else { return true }
        return assignee == caller
    }
```

Refusal text: `Error: task <id8> is assigned to another session.` with `isError: true`. Apply it in `linkc_start_task` and `linkc_complete_task`; for `linkc_cancel_task` apply it only on the assignee branch, since the delegator may always cancel and `force` still overrides.

- [ ] **Step 4: Scope `linkc_my_tasks`**

Where it lists tasks assigned to the caller, drop rows whose `assigneeSessionId` is another session, so the sibling is never shown work it cannot act on. Leave unassigned rows visible.

- [ ] **Step 5: Refuse a malformed tier**

In the `tier` parse, distinguish absent from present-but-not-a-string:

```swift
                let tier: ModelTier?
                if let raw = args["tier"] {
                    guard let text = raw as? String,
                          let parsed = ModelTier(rawValue: text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
                        return toolResultResponse(id: id, text: "Error: tier must be light, standard or deep.", isError: true)
                    }
                    tier = parsed
                } else {
                    tier = nil
                }
```

Then keep the existing default-tier and cursor logic, driven by whether `tier` is nil.

- [ ] **Step 6: Run the suite and commit**

```bash
swift test
git add Sources/LinkCKit/MCP/MCPServer.swift Tests/LinkCKitTests/MCPServerTaskTests.swift
git commit -m "fix(mcp): only the assignee session may settle a task"
```

---

### Task 6: Stop losing queued messages

**Files:**
- Modify: `Sources/LinkCKit/Blackboard/InboxStore.swift` (`saveUnlocked` pruning ~108-121, `enqueue` dedupe ~180-184), `Sources/LinkCKit/App/AppCoordinator+Relay.swift` (`dispatchMessages` ~209-222)
- Test: `Tests/LinkCKitTests/InboxStoreTests.swift`, `Tests/LinkCKitTests/AppCoordinatorRelayTests.swift`

**Interfaces:**
- Produces: the message cap drops delivered rows before queued ones; dedupe only matches an undelivered row; delivery marks before injecting.

**Three defects, one file each:**
1. `prunedInbox.messages.suffix(100)` trims by recency regardless of status, so a busy workspace silently drops undelivered completions — the delegator never learns its task finished. `testLimitsMessagesTo100OnSave` asserts the loss is correct, which is why it never caught it.
2. `enqueue`'s 24-hour dedupe matches on content/from/to/time but not status, so re-sending an identical body returns an already-*delivered* row. `dispatchMessages` only picks up `.queued`, so nothing is delivered while the caller is told it was queued.
3. `dispatchMessages` injects and *then* marks delivered. If the mark throws — a five-second lock timeout under contention — the row stays queued and the next tick injects the same text again. `dispatchTasks` marks first, on purpose.

- [ ] **Step 1: Write the failing tests**

```swift
    func testTheMessageCapDropsDeliveredRowsBeforeQueuedOnes() throws {
        var inbox = Inbox(workspacePath: tempDir.path)
        // 95 delivered, then 20 queued: the cap must sacrifice delivered rows, not undelivered work.
        for i in 0..<95 {
            inbox.messages.append(PendingMessage(id: "old-\(i)", fromAgent: .claude, toAgent: .codex,
                                                 prompt: "old \(i)", status: .delivered, kind: .completion,
                                                 deliveredAt: Date()))
        }
        for i in 0..<20 {
            inbox.messages.append(PendingMessage(id: "new-\(i)", fromAgent: .codex, toAgent: .claude,
                                                 prompt: "result \(i)", status: .queued, kind: .completion))
        }
        try store.saveRaw(inbox)

        let saved = try store.load().messages
        XCTAssertEqual(saved.filter { $0.status == .queued }.count, 20, "no undelivered message may be dropped")
        XCTAssertLessThanOrEqual(saved.count, 100)
    }

    func testResendingAfterDeliveryQueuesAgainRatherThanReturningTheDeliveredRow() throws {
        let first = try store.enqueue(from: .claude, to: .codex, kind: .peerNote, body: "same body")
        try store.markMessageDelivered(id: first.id)
        let second = try store.enqueue(from: .claude, to: .codex, kind: .peerNote, body: "same body")
        XCTAssertNotEqual(second.id, first.id, "a delivered row must not satisfy a fresh send")
        XCTAssertEqual(second.status, .queued)
    }
```

Check `PendingMessage.init`'s real signature before using it and match it; do not add parameters for the test's convenience.

For the ordering defect, add to `AppCoordinatorRelayTests`:

```swift
    /// The mark must land before the text, or a failed mark re-injects the same message every
    /// tick. dispatchTasks already marks first.
    @MainActor
    func testAMessageIsMarkedDeliveredBeforeItIsInjected() async throws {
        let ws = tempDir.path
        let inbox = InboxStore(workspaceRoot: ws)
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }

        let session = try coordinator.newSession(cwd: ws, agent: .codex, mode: .new)
        coordinator.store.updateState(id: session.id, to: .ready)
        let msg = try inbox.enqueue(from: .claude, to: .codex, kind: .peerNote, body: "one delivery only")

        coordinator.processPendingMessages(workspacePath: ws)
        XCTAssertEqual(try inbox.load().messages.first { $0.id == msg.id }?.status, .delivered)

        // A second tick must not re-inject: assert the text appears exactly once.
        coordinator.processPendingMessages(workspacePath: ws)
        let out = try await waitUntil { coordinator.terminals.session(id: session.id)?.recentOutput(lines: 40).contains("one delivery only") ?? false }
        XCTAssertTrue(out)
        let occurrences = (coordinator.terminals.session(id: session.id)?.recentOutput(lines: 40) ?? "")
            .components(separatedBy: "one delivery only").count - 1
        XCTAssertEqual(occurrences, 1, "a delivered message is never injected twice")
    }
```

- [ ] **Step 2: Run them and watch them fail**

Run: `swift test --filter "InboxStoreTests|testAMessageIsMarkedDeliveredBeforeItIsInjected"`
Expected: queued rows are dropped by the cap; the resend returns the delivered row.

- [ ] **Step 3: Prune delivered first**

```swift
        if prunedInbox.messages.count > 100 {
            // Sacrifice delivered rows before undelivered ones: a dropped queued completion means
            // a delegator never learns its task finished.
            let queued = prunedInbox.messages.filter { $0.status != .delivered }
            let delivered = prunedInbox.messages.filter { $0.status == .delivered }
            let room = max(0, 100 - queued.count)
            prunedInbox.messages = (delivered.suffix(room) + queued).sorted { $0.createdAt < $1.createdAt }
        }
```

If `queued.count` alone exceeds 100, keep them all: never drop undelivered work to satisfy a cosmetic cap. Say so in a comment.

- [ ] **Step 4: Dedupe only against undelivered rows**

Add `$0.status != .delivered` to the `enqueue` dedupe predicate.

- [ ] **Step 5: Mark before injecting**

In `dispatchMessages`, move `markMessageDelivered` above `terminals.sendInput`, and on a throw `continue` without injecting — the next tick retries cleanly. Keep the model-switch tier re-derivation after the send, where it belongs.

- [ ] **Step 6: Fix the tests that asserted the old behaviour**

`testLimitsMessagesTo100OnSave` encodes the loss. Rewrite it to assert the new rule and say in your report that you did.

- [ ] **Step 7: Run the suite and commit**

```bash
swift test
git add Sources/LinkCKit/Blackboard/InboxStore.swift Sources/LinkCKit/App/AppCoordinator+Relay.swift Tests/LinkCKitTests/
git commit -m "fix(inbox): never drop or double-deliver an undelivered message"
```

---

### Task 7: Get the relay's file locks off the main actor

**Files:**
- Modify: `Sources/LinkCKit/App/AppCoordinator.swift` (`sampleAgentStates`), `Sources/LinkCKit/App/AppCoordinator+Relay.swift` (`processPendingMessages` and the four store round-trips it drives)
- Test: `Tests/LinkCKitTests/AppCoordinatorRelayTests.swift`

**Interfaces:**
- Produces: no change to behaviour; the tick's store reads no longer block the main actor for up to five seconds each.

**The defect:** `sampleAgentStates` is `@MainActor` and runs once a second. It calls `processPendingMessages` per active workspace, which performs four store round-trips, each taking an exclusive `flock` with a five-second timeout and reading the whole file. Eight to ten MCP processes write the same file. One slow writer therefore stalls the UI for up to five seconds, several times per tick. The author knew the cost: the blackboard heartbeat two lines away uses a 0.5-second timeout.

- [ ] **Step 1: Write the test that pins the requirement**

```swift
    /// The relay must not hold the main actor waiting on a contended lock. With the inbox lock
    /// held by another holder, a tick has to give up quickly rather than stalling the UI.
    @MainActor
    func testATickDoesNotBlockTheMainActorOnAContendedLock() async throws {
        let ws = tempDir.path
        let inbox = InboxStore(workspaceRoot: ws)
        _ = try inbox.createTask(from: .claude, to: .codex, tier: .standard, prompt: "brief", files: [])
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }

        let lockPath = tempDir.appendingPathComponent(".linkc/inbox.lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
        XCTAssertGreaterThan(fd, 0)
        XCTAssertEqual(flock(fd, LOCK_EX), 0)
        defer { flock(fd, LOCK_UN); close(fd) }

        let start = Date()
        coordinator.processPendingMessages(workspacePath: ws)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 1.5, "a contended tick must yield quickly, not wait out a 5s timeout per call")
    }
```

Confirm the lock file's real name and location in `InboxStore` before using it; if the lock is on the inbox file itself, lock that instead.

- [ ] **Step 2: Run it and watch it fail**

Run: `swift test --filter testATickDoesNotBlockTheMainActorOnAContendedLock`
Expected: FAIL — elapsed is several seconds.

- [ ] **Step 3: Give the relay a short timeout**

Add `static let relayLockTimeout: TimeInterval = 0.5` beside `maxConcurrentVerifications`, and pass it to every store call the tick makes (`openTasks`, `fetchPending`, `load`, and the transition calls in `expireTasks`/`dispatchTasks`/`dispatchMessages`). A timeout is not a failure: the tick skips and the next one retries a second later. Log at most once per tick when a timeout is what ended it, so a permanently contended workspace is visible rather than silently idle.

Do not move the tick off the main actor in this task. `AppCoordinator` is `@MainActor` throughout and the session store is main-actor state; making the tick reentrant is a larger change than this sweep should carry. If you believe the short timeout is insufficient, report that rather than starting the bigger refactor.

- [ ] **Step 4: Run the suite and commit**

```bash
swift test
git add Sources/LinkCKit/App/ Tests/LinkCKitTests/AppCoordinatorRelayTests.swift
git commit -m "fix(relay): yield quickly on a contended lock instead of stalling the UI"
```

---

### Task 8: Fail loud where the relay currently fails silently

**Files:**
- Modify: `Sources/LinkCKit/App/AppCoordinator+Relay.swift` (the two `try? spawnTeammate` sites ~159 and ~204, `checkLimitsAndReroute`'s no-capable-peer branch), `Sources/LinkCKit/Blackboard/InboxStore.swift` and `Sources/LinkCKit/Blackboard/BlackboardStore.swift` (the ignored `rename` results), `Sources/LinkCKit/Config/MCPRegistrar.swift`
- Test: `Tests/LinkCKitTests/AppCoordinatorRelayTests.swift`, `Tests/LinkCKitTests/InboxStoreTests.swift`

**Three defects:**
1. `_ = try? spawnTeammate(...)` swallows every failure with no log. If the target CLI is not installed, the task sits `.queued` forever, retried every second, with nothing anywhere saying why. The sibling branch three lines above logs when a tier has no model — this one is the same situation and says nothing.
2. In `checkLimitsAndReroute`, the "no peer can serve this tier" branch returns without marking the session, so the top-of-function guard never blocks re-entry: every tick re-detects the same banner still sitting in the scrollback and calls `recordLimit`, which overwrites `cooldownExpiresAt = now + cooldown`. The cooldown is re-armed once a second, forever, and the agent reads as limited workspace-wide indefinitely.
3. `_ = rename(...)` in three stores drops a failed rename on the floor, so a caller is told a write landed when the file is unchanged. A crash between the temp write and the rename also leaves `.linkc/inbox.tmp.<uuid>` behind, and nothing ever sweeps those.

- [ ] **Step 1: Write the failing tests**

```swift
    /// A spawn that cannot happen must say so. Otherwise the task is retried every second for
    /// four hours and the only symptom is silence.
    @MainActor
    func testASpawnFailureIsLoggedAndLeavesTheTaskQueued() throws {
        let ws = tempDir.path
        let inbox = InboxStore(workspaceRoot: ws)
        // No resolver entry for codex: the executable cannot be found.
        let coordinator = makeCoordinator(agentPathResolver: { _ in nil })
        defer { coordinator.shutdown() }

        let task = try inbox.createTask(from: .claude, to: .codex, tier: .standard, prompt: "brief", files: [])
        coordinator.processPendingMessages(workspacePath: ws)

        XCTAssertEqual(try inbox.task(id: task.id)?.state, .queued)
        XCTAssertTrue(coordinator.store.sessions.isEmpty, "nothing was spawned")
        XCTAssertEqual(coordinator.lastSpawnFailure?.agent, .codex, "the failure is recorded, not swallowed")
    }
```

`makeCoordinator` currently hardcodes its resolver; add an `agentPathResolver:` parameter with the existing mock as its default. `lastSpawnFailure` is new observable state on `AppCoordinator` — a small struct holding the agent kind, the workspace, and the error text, set whenever a spawn fails. It exists so the failure is assertable and so the UI can surface it later; if you would rather assert the log, propose that instead and say why in your report.

```swift
    /// A limit with no capable peer must not re-arm its own cooldown every tick.
    @MainActor
    func testACooldownIsNotReArmedOnEveryTick() async throws {
        let ws = tempDir.path
        let inbox = InboxStore(workspaceRoot: ws)
        var models = AgentModelSettings.seeded
        models.setModel("", for: .agy, tier: .standard)
        models.setModel("", for: .cursor, tier: .standard)
        let coordinator = makeCoordinator(models: models)
        defer { coordinator.shutdown() }

        let session = try coordinator.newSession(cwd: ws, agent: .claude, mode: .new, tier: .standard)
        coordinator.store.updateState(id: session.id, to: .working)
        let task = try inbox.createTask(from: .cursor, to: .claude, tier: .standard, prompt: "work", files: [])
        try inbox.markTaskDelivered(taskId: task.id, sessionId: session.id)
        try inbox.markTaskStarted(taskId: task.id)

        coordinator.terminals.sendInput(sessionId: session.id, text: "Usage cap hit.\n")
        _ = try await waitUntil { coordinator.terminals.session(id: session.id)?.recentOutput(lines: 10).contains("Usage cap hit") ?? false }

        _ = coordinator.checkLimitsAndReroute(for: session.id)
        let first = try XCTUnwrap(try inbox.isAgentLimited(agent: .claude)?.cooldownExpiresAt)
        try await Task.sleep(for: .milliseconds(1100))
        _ = coordinator.checkLimitsAndReroute(for: session.id)
        let second = try XCTUnwrap(try inbox.isAgentLimited(agent: .claude)?.cooldownExpiresAt)

        XCTAssertEqual(first, second, "the same unhandled limit must not push its own expiry out")
    }
```

- [ ] **Step 2: Run them and watch them fail**

Run: `swift test --filter "testASpawnFailureIsLoggedAndLeavesTheTaskQueued|testACooldownIsNotReArmedOnEveryTick"`

- [ ] **Step 3: Make the spawn failure visible**

Replace both `_ = try? spawnTeammate(...)` sites with a `do`/`catch` that logs in the style of the surrounding lines and records `lastSpawnFailure`. The task still stays queued — that part is correct.

- [ ] **Step 4: Stop the cooldown treadmill**

In the no-capable-peer branch, mark the session the same way the other return paths do so the top guard prevents re-entry, and have `recordLimit` keep the earlier expiry when a live cooldown for that agent and reason already exists rather than overwriting it. Both halves are needed: the guard stops the re-detection, and the store stops the clock being pushed out by anything else that re-records.

- [ ] **Step 5: Check the renames and sweep the temps**

Make all three `rename` call sites throw on failure, with the errno in the message. Then, in `InboxStore` and `BlackboardStore`, delete any `*.tmp.*` sibling older than an hour when a save succeeds — a cheap sweep on a path already being written, no new timer. Add an `InboxStoreTests` case that a stale temp file is removed and a fresh one is not.

- [ ] **Step 6: Run the suite and commit**

```bash
swift test
git add Sources/LinkCKit/ Tests/LinkCKitTests/
git commit -m "fix(relay): log a failed spawn, stop re-arming a cooldown, check every rename"
```

---

### Task 9: An unreadable settings file is never overwritten

**Files:**
- Modify: `Sources/LinkCKit/Config/AgentModelStore.swift` (`load`, `save`), `Sources/LinkCKit/Preferences/AppPreferences.swift`
- Test: `Tests/LinkCKitTests/AgentModelStoreTests.swift`

**The defect:** `load()` uses `try? Data(contentsOf:)`, so a file that exists but cannot be read (permissions, I/O error) is indistinguishable from one that is absent, and both silently become the seeded mapping with no log. `AppPreferences` caches that, and the first settings edit writes the whole file — so a mapping written by a newer build, or hand-edited without every key, is replaced by seeds. The type's own doc comment promises the opposite: an unreadable file is "logged and left alone, never rewritten under the user".

- [ ] **Step 1: Write the failing tests**

```swift
    func testAMissingFileAndAnUnreadableFileAreDistinguished() throws {
        let store = AgentModelStore(directory: dir)
        XCTAssertEqual(store.load(), AgentModelSettings.seeded, "absent means nothing configured yet")

        try Data("{ not json".utf8).write(to: URL(fileURLWithPath: store.path))
        XCTAssertEqual(store.load(), AgentModelSettings.seeded, "an unreadable file still yields a usable mapping")
        XCTAssertTrue(store.lastLoadFailed, "but the store knows it could not read the file")
    }

    func testAnUnreadableFileIsNotOverwrittenBySave() throws {
        let store = AgentModelStore(directory: dir)
        let corrupt = Data("{ not json".utf8)
        try corrupt.write(to: URL(fileURLWithPath: store.path))
        _ = store.load()

        var edited = AgentModelSettings.seeded
        edited.setModel("gpt-7-nova", for: .codex, tier: .deep)
        store.save(edited)

        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: store.path)), corrupt,
                       "a file we could not read is never replaced under the user")
    }
```

- [ ] **Step 2: Run them and watch them fail**

Run: `swift test --filter AgentModelStoreTests`

- [ ] **Step 3: Implement**

Split the read: `FileManager.fileExists` decides absent from present, `Data(contentsOf:)`'s throw is logged with the path and errno, and a decode failure is logged as it is today. Record it on the store (`lastLoadFailed`, or a small `LoadOutcome` if you prefer — name it for what it means) and have `save` refuse, with a log, while that flag is set. Clear the flag on a successful load. Mirror the guidance into the doc comment so code and comment finally agree.

Keep the behaviour that callers always get a usable mapping: the point is that the user's file is preserved, not that the app stops working.

- [ ] **Step 4: Run the suite and commit**

```bash
swift test
git add Sources/LinkCKit/Config/AgentModelStore.swift Sources/LinkCKit/Preferences/AppPreferences.swift Tests/LinkCKitTests/AgentModelStoreTests.swift
git commit -m "fix(models): never overwrite a settings file we could not read"
```

---

### Task 10: Read what each agent has left

**Files:**
- Create: `Sources/LinkCKit/Usage/AgentUsage.swift`, `Sources/LinkCKit/Usage/CodexUsageReader.swift`, `Sources/LinkCKit/Usage/ClaudeUsageReader.swift`
- Test: `Tests/LinkCKitTests/CodexUsageReaderTests.swift`, `Tests/LinkCKitTests/ClaudeUsageReaderTests.swift`, `Tests/LinkCKitTests/AgentUsageTests.swift` (all new)

**Interfaces:**
- Produces: `UsageWindow`, `AgentUsage` (shapes fixed by the spec's §5), `CodexUsageReader(sessionsDirectory:)` and `ClaudeUsageReader(projectsDirectory:)`, each with `read() -> AgentUsage`.
- Consumes: `UsageWindows` and `TranscriptTailReader` in `Sources/LinkCKit/Usage/` for the Claude side.

**Real data.** A Codex rollout line looks like this, and the reader must parse exactly it:

```json
{"type":"token_count","info":{"total_token_usage":{"total_tokens":210936}},
 "rate_limits":{"limit_id":"codex","primary":{"used_percent":23.0,"window_minutes":300,"resets_at":1789200270},
 "secondary":{"used_percent":39.0,"window_minutes":10080,"resets_at":1789500060},"plan_type":"plus"}}
```

`resets_at` is epoch seconds. `window_minutes` 300 renders as `5h`, 10080 as `7d`; any other value renders as `\(minutes)m` rather than being dropped.

- [ ] **Step 1: Write the model and its tests**

Copy `UsageWindow` and `AgentUsage` verbatim from the spec's §5, then:

```swift
final class AgentUsageTests: XCTestCase {
    func testAReadingIsStaleAfterAnHour() {
        let fresh = AgentUsage(agent: .codex, windows: [], planType: nil,
                               observedAt: Date().addingTimeInterval(-59 * 60), unavailableReason: nil)
        let stale = AgentUsage(agent: .codex, windows: [], planType: nil,
                               observedAt: Date().addingTimeInterval(-61 * 60), unavailableReason: nil)
        XCTAssertFalse(fresh.isStale)
        XCTAssertTrue(stale.isStale)
    }

    func testTheWarnThresholdIsInclusive() {
        func usage(_ percent: Double) -> AgentUsage {
            AgentUsage(agent: .codex, windows: [UsageWindow(label: "5h", usedPercent: percent, tokens: nil, resetsAt: nil)],
                       planType: nil, observedAt: Date(), unavailableReason: nil)
        }
        XCTAssertNil(usage(79.9).windowNeedingWarning)
        XCTAssertEqual(usage(80).windowNeedingWarning?.label, "5h")
        XCTAssertEqual(usage(80.1).windowNeedingWarning?.label, "5h")
    }

    func testAStaleOrUnavailableReadingNeverWarns() {
        let stale = AgentUsage(agent: .codex, windows: [UsageWindow(label: "5h", usedPercent: 99, tokens: nil, resetsAt: nil)],
                               planType: nil, observedAt: Date().addingTimeInterval(-2 * 3600), unavailableReason: nil)
        XCTAssertNil(stale.windowNeedingWarning, "a stale number must not drive a warning")
        let unknown = AgentUsage(agent: .agy, windows: [], planType: nil, observedAt: nil,
                                 unavailableReason: "agy writes no local session records")
        XCTAssertNil(unknown.windowNeedingWarning)
    }
}
```

`isStale` and `windowNeedingWarning` are the two derived properties this implies; add them to `AgentUsage` with `staleAfter: TimeInterval = 3600` as a named constant.

- [ ] **Step 2: Write the Codex reader's tests**

```swift
final class CodexUsageReaderTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("codex-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func write(_ name: String, _ lines: [String], modified: Date) throws {
        let url = dir.appendingPathComponent(name)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    private let record = """
    {"type":"token_count","info":{"total_token_usage":{"total_tokens":210936}},"rate_limits":{"limit_id":"codex","primary":{"used_percent":23.0,"window_minutes":300,"resets_at":1789200270},"secondary":{"used_percent":39.0,"window_minutes":10080,"resets_at":1789500060},"plan_type":"plus"}}
    """

    func testItReadsTheNewestFileThatCarriesLimits() throws {
        try write("rollout-old.jsonl", ["{\"type\":\"other\"}"], modified: Date().addingTimeInterval(-7200))
        try write("rollout-new.jsonl", ["{\"type\":\"other\"}", record], modified: Date())

        let usage = CodexUsageReader(sessionsDirectory: dir).read()
        XCTAssertNil(usage.unavailableReason)
        XCTAssertEqual(usage.planType, "plus")
        XCTAssertEqual(usage.windows.count, 2)
        XCTAssertEqual(usage.windows[0].label, "5h")
        XCTAssertEqual(usage.windows[0].usedPercent, 23.0)
        XCTAssertEqual(usage.windows[0].resetsAt, Date(timeIntervalSince1970: 1789200270))
        XCTAssertEqual(usage.windows[1].label, "7d")
        XCTAssertEqual(usage.windows[1].usedPercent, 39.0)
    }

    func testItTakesTheLastRecordInAFile() throws {
        let later = record.replacingOccurrences(of: "\"used_percent\":23.0", with: "\"used_percent\":44.0")
        try write("rollout-a.jsonl", [record, later], modified: Date())
        XCTAssertEqual(CodexUsageReader(sessionsDirectory: dir).read().windows[0].usedPercent, 44.0)
    }

    func testEachFailureModeNamesItself() throws {
        let missing = CodexUsageReader(sessionsDirectory: dir.appendingPathComponent("nope")).read()
        XCTAssertNotNil(missing.unavailableReason)
        XCTAssertTrue(missing.windows.isEmpty)

        let empty = CodexUsageReader(sessionsDirectory: dir).read()
        XCTAssertNotNil(empty.unavailableReason, "a directory with no rollout files says so")

        try write("rollout-a.jsonl", ["{\"type\":\"other\"}"], modified: Date())
        XCTAssertNotNil(CodexUsageReader(sessionsDirectory: dir).read().unavailableReason,
                        "files with no rate-limit record say so")
    }

    func testARecordNearTheTailBoundaryIsStillFound() throws {
        let filler = String(repeating: "{\"type\":\"filler\"}\n", count: 4000)
        try write("rollout-big.jsonl", [filler, record], modified: Date())
        XCTAssertEqual(CodexUsageReader(sessionsDirectory: dir).read().windows.first?.usedPercent, 23.0)
    }
}
```

Each `unavailableReason` must be a distinct sentence naming which situation it was, per the spec's §9 table. Assert the distinctions, not just non-nil, once you have written the strings.

- [ ] **Step 3: Run them and watch them fail**

Run: `swift test --filter "AgentUsageTests|CodexUsageReaderTests"`
Expected: FAIL — the types do not exist.

- [ ] **Step 4: Implement the model and the Codex reader**

The reader: enumerate `sessionsDirectory` recursively for names matching `rollout-*.jsonl`, sort by modification date descending, take at most 5, and for each read only the trailing 64 KB (open the file, seek to `max(0, size - 65536)`), split on newlines, drop the first partial line, and scan from the end for the first line whose JSON has a `rate_limits` object. Map `primary` and `secondary` through a window-label helper (300 → `5h`, 10080 → `7d`, else minutes). `observedAt` is that file's modification date. Return on the first file that yields a record; if none do, return the reason.

Constants — the 5-file and 64 KB caps, and the two window labels — are named `static let`s, not literals buried in the loop.

- [ ] **Step 5: Write and implement the Claude reader**

Its test builds two fixture transcripts with known `usage` blocks and asserts the 5-hour and 7-day token totals, `usedPercent == nil`, and `observedAt` equal to the newest transcript's modification date. The implementation delegates the arithmetic to the existing `UsageWindows` rather than recomputing it; if that type's entry point is `@MainActor` or otherwise unusable from the MCP process, extract the pure part and say in your report what you moved.

- [ ] **Step 6: Run the suite and commit**

```bash
swift test
git add Sources/LinkCKit/Usage/ Tests/LinkCKitTests/
git commit -m "feat(usage): read each agent's own records for what it has left"
```

---

### Task 11: Report usage, and warn when a target is nearly out

**Files:**
- Modify: `Sources/LinkCKit/MCP/MCPServer.swift` (`linkc_get_usage_status` ~668, its tool description ~230, `linkc_delegate_task`'s success text)
- Test: `Tests/LinkCKitTests/MCPServerUsageTests.swift` (new), `Tests/LinkCKitTests/MCPServerTaskTests.swift`

**Interfaces:**
- Consumes: `AgentUsage`, `CodexUsageReader`, `ClaudeUsageReader` from Task 10.
- Produces: `MCPServer.init(..., usageReaders: [AgentKind: @Sendable () -> AgentUsage] = …)` — injected so tests never read the real home directory, defaulting to the two real readers plus nothing for agy and cursor.

**The defect being fixed:** the tool promises "current token usage, 5-hour rolling window stats, reset timestamps, and active rate limits" and returns none of the first three. It also prints a per-agent default model taken from the stale `AgentModelCatalog`, reporting `gpt-4o` for Codex when the configured model is `gpt-5.6-sol`.

- [ ] **Step 1: Write the failing tests**

```swift
final class MCPServerUsageTests: XCTestCase {
    // tempDir / inbox setup as in MCPServerTaskTests

    private func server(readers: [AgentKind: @Sendable () -> AgentUsage]) -> MCPServer {
        MCPServer(workspaceRoot: tempDir.path, inboxStore: inbox,
                  environment: ["LINKC_AGENT": "claude"], ancestorResolver: { _ in nil },
                  modelSettings: { .seeded }, usageReaders: readers)
    }

    func testItReportsWhatEachAgentHasLeft() throws {
        let codex = AgentUsage(agent: .codex,
                               windows: [UsageWindow(label: "5h", usedPercent: 23, tokens: nil, resetsAt: Date().addingTimeInterval(3600)),
                                         UsageWindow(label: "7d", usedPercent: 39, tokens: nil, resetsAt: nil)],
                               planType: "plus", observedAt: Date(), unavailableReason: nil)
        let agy = AgentUsage(agent: .agy, windows: [], planType: nil, observedAt: nil,
                             unavailableReason: "agy writes no local session records")
        let res = try call(server(readers: [.codex: { codex }, .agy: { agy }]), "linkc_get_usage_status")

        XCTAssertFalse(res.isError, res.text)
        XCTAssertTrue(res.text.contains("23%"), res.text)
        XCTAssertTrue(res.text.contains("plan plus"), res.text)
        XCTAssertTrue(res.text.contains("agy writes no local session records"), res.text)
        XCTAssertFalse(res.text.contains("gpt-4o"), "the stale catalog must not appear: \(res.text)")
        XCTAssertFalse(res.text.contains("Default Model"), "the default-model line is gone: \(res.text)")
    }

    func testAThrowingReaderStillReturnsAResult() throws {
        struct Boom: Error {}
        let res = try call(server(readers: [.codex: { AgentUsage.unavailable(.codex, reason: "reader failed") }]),
                           "linkc_get_usage_status")
        XCTAssertFalse(res.isError, "usage is informational; it never fails the call")
        XCTAssertTrue(res.text.contains("reader failed"), res.text)
    }

    func testAStaleReadingSaysSo() throws {
        let old = AgentUsage(agent: .codex,
                             windows: [UsageWindow(label: "5h", usedPercent: 23, tokens: nil, resetsAt: nil)],
                             planType: nil, observedAt: Date().addingTimeInterval(-3 * 3600), unavailableReason: nil)
        let res = try call(server(readers: [.codex: { old }]), "linkc_get_usage_status")
        XCTAssertTrue(res.text.lowercased().contains("stale"), res.text)
    }
}
```

Add `AgentUsage.unavailable(_:reason:)` as the named constructor those call sites want. In `MCPServerTaskTests`:

```swift
    func testADelegationWarnsWhenTheTargetIsNearlyOut() throws {
        let hot = AgentUsage(agent: .codex,
                             windows: [UsageWindow(label: "5h", usedPercent: 86, tokens: nil, resetsAt: Date().addingTimeInterval(3600))],
                             planType: nil, observedAt: Date(), unavailableReason: nil)
        let res = try call(server(as: .claude, models: .seeded, readers: [.codex: { hot }]),
                           "linkc_delegate_task", ["to": "codex", "prompt": "Rename a file"])
        XCTAssertFalse(res.isError, res.text)
        XCTAssertTrue(res.text.contains("86%"), res.text)
        XCTAssertTrue(res.text.contains("5h"), res.text)
        XCTAssertEqual(try inbox.openTasks().count, 1, "the delegation still happens")
    }

    func testADelegationUnderTheThresholdIsNotAnnotated() throws {
        let calm = AgentUsage(agent: .codex,
                              windows: [UsageWindow(label: "5h", usedPercent: 12, tokens: nil, resetsAt: nil)],
                              planType: nil, observedAt: Date(), unavailableReason: nil)
        let res = try call(server(as: .claude, models: .seeded, readers: [.codex: { calm }]),
                           "linkc_delegate_task", ["to": "codex", "prompt": "Rename a file"])
        XCTAssertFalse(res.text.contains("%"), "no usage line under the threshold: \(res.text)")
    }
```

Extend that file's `server(as:models:)` helper with a `readers:` parameter defaulting to empty.

- [ ] **Step 2: Run them and watch them fail**

Run: `swift test --filter "MCPServerUsageTests|MCPServerTaskTests"`
Expected: FAIL — `usageReaders` does not exist.

- [ ] **Step 3: Implement the reporting**

Take `usageReaders` in the initializer, defaulting to the real readers for codex and claude and an `unavailable` reader for agy and cursor naming why. Render exactly the shape in the spec's §7: a section per agent, one line per window, the plan type on the heading when known, the observation age, a stale marker past the threshold, and the reason when nothing is known. Keep the active-limits section as it is. Delete the default-model section. Rewrite the tool's description to name exactly these fields.

- [ ] **Step 4: Implement the delegation warning**

After a delegation succeeds, ask the target's reader and append one sentence when `windowNeedingWarning` is non-nil — the spec's §8 wording, with the percentage, the window label, and the reset time when known. Wrap the read so nothing it does can fail the delegation: on a throw, log and return the unannotated text.

- [ ] **Step 5: Run the suite and commit**

```bash
swift test
git add Sources/LinkCKit/MCP/MCPServer.swift Tests/LinkCKitTests/
git commit -m "feat(usage): report what each agent has left and warn a delegation near a ceiling"
```

---

## Not in this plan

- **The three ThreadSanitizer races in SwiftTerm's `LocalProcess.childStopped`** (main thread versus the PTY read thread on child exit, reproducible with `swift test --sanitize=thread`). They are in the dependency, not in linkC, and the fix belongs upstream. Worth an issue against SwiftTerm with the stack traces; do not vendor a patched copy as part of this sweep.
- **Replacing the terminal-scraped limit detector with structured signals.** Task 10 builds the Codex source that makes it possible, but swapping the detector over is spec two's business, together with push delivery and deleting the rest of the scraping.
- **`recovered/agent-sweep-fixes`.** Read it for reference, then delete the branch once Tasks 2, 3 and 6 have landed properly.
- **Every store read takes an exclusive lock.** `load`, `fetchPending`, `task(id:)`, `openTasks` and `checkConflicts` all take `LOCK_EX` for a pure read, which is the contention that makes Task 7 necessary in the first place. A shared lock for readers is the real fix and touches every lock site in both stores — worth its own change, with the stress tests extended to prove readers no longer serialize.
- **`TaskRecord` decodes strictly.** `PendingMessage` has a tolerant hand-written `init(from:)`; `TaskRecord` does not, so every field but the handful of optionals is required. Because `InboxStore.loadUnlocked` now throws by design, the next required field added to `TaskRecord` will not wipe an old binary's inbox — it will brick it, throwing on every delegation and every relay tick until that binary is replaced. Generalizing the tolerance is cheap insurance and should happen before the next field is added, not after.
- **Possible duplicate agent rows on the blackboard.** The app heartbeats with the PTY child's pid while the MCP server records the caller's pid, and rows are keyed on pid alone — so one logical agent may appear twice in `activeAgents` and inflate the dashboard count. Suspected from tracing only; settle it with one live run comparing the two pids before changing anything.

## Rollout

`./build-app.sh`, then restart linkC and its MCP clients. No file formats change, so an older binary keeps reading everything; the new blackboard behaviour only makes an existing failure visible rather than silent.

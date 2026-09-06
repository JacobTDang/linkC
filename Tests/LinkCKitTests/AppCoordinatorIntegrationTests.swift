import XCTest
@testable import LinkCKit

/// End-to-end wiring test: a real HTTP hook POST flows through the real HookServer, the
/// decoder, the store, the focus policy, and into a recording notification sink — exercising
/// the actual AppCoordinator glue with only the terminal spawn and the UN center faked out.
@MainActor
final class AppCoordinatorIntegrationTests: XCTestCase {

    private final class RecordingSink: NotificationSink, @unchecked Sendable {
        private let lock = NSLock()
        private var _deliveries: [(id: String, title: String, body: String)] = []
        var deliveries: [(id: String, title: String, body: String)] {
            lock.lock(); defer { lock.unlock() }; return _deliveries
        }
        func deliver(id: String, title: String, body: String) {
            lock.lock(); _deliveries.append((id, title, body)); lock.unlock()
        }
    }

    /// Builds a coordinator wired to a real (but un-spawned) terminal manager and a fake
    /// notification center. `isWatching` returns false so notifiable states would notify.
    private func makeCoordinator(
        sink: NotificationSink,
        claudePath: String = "/x/claude",
        settingsDir: URL = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-test-\(UUID().uuidString)"),
        manifestDir: URL? = nil
    ) -> AppCoordinator {
        AppCoordinator(
            terminals: TerminalSessionManager(),
            hookServer: HookServer(port: 0),
            notifications: NotificationManager(sink: sink, now: { Date() }),
            claudePath: claudePath,
            settingsDir: settingsDir,
            userSettingsURL: FileManager.default.temporaryDirectory.appendingPathComponent("no-such-settings.json"),
            manifestDir: manifestDir ?? settingsDir,
            isWatching: { _ in false }
        )
    }

    /// Fires one hook at the live server and waits for its 200 — so by the time it returns,
    /// the event has been enqueued onto the coordinator's serial stream (respond enqueues
    /// before it replies). Awaiting each in turn thus fixes enqueue order.
    private func fireHook(port: UInt16, token: String? = nil, event: String, session: String) async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/hook")!)
        request.httpMethod = "POST"
        request.setValue(event, forHTTPHeaderField: "X-LinkC-Event")
        request.setValue(session, forHTTPHeaderField: "X-LinkC-Session")
        if let token { request.setValue(token, forHTTPHeaderField: "X-LinkC-Token") }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"session_id":"c1","cwd":"/tmp"}"#.utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    /// Polls until `predicate` holds (or times out). Used to await async event propagation.
    private func waitUntil(_ predicate: () -> Bool, iterations: Int = 100) async throws -> Bool {
        for _ in 0..<iterations {
            if predicate() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return predicate()
    }

    /// Spoof protection: a hook POST without the per-run token gets a 200 (never block a
    /// turn) but its event is DROPPED — a local process that doesn't know the token cannot
    /// manipulate session state.
    func testHookWithoutTokenIsDropped() async throws {
        let sink = RecordingSink()
        let coordinator = makeCoordinator(sink: sink)
        try coordinator.start()
        defer { coordinator.shutdown() }

        _ = coordinator.store.create(cwd: "/tmp", title: "api", id: "L1")

        try await fireHook(port: coordinator.hookPort, token: nil, event: "session_end", session: "L1")
        try await fireHook(port: coordinator.hookPort, token: "wrong-token", event: "session_end", session: "L1")

        // Give any (incorrect) processing a beat to happen, then assert nothing changed.
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNotNil(coordinator.store.session(id: "L1"), "a tokenless/badly-tokened event must not prune a session")
        XCTAssertEqual(coordinator.store.session(id: "L1")?.state, .starting)
    }

    /// I1: a SessionEnd hook prunes the session from the store — dead entries must not
    /// accumulate — and ending a session posts no notification.
    func testSessionEndPrunesSessionFromStore() async throws {
        let sink = RecordingSink()
        let coordinator = makeCoordinator(sink: sink)
        try coordinator.start()
        defer { coordinator.shutdown() }

        _ = coordinator.store.create(cwd: "/tmp", title: "api", id: "L1")
        XCTAssertNotNil(coordinator.store.session(id: "L1"))

        try await fireHook(port: coordinator.hookPort, token: coordinator.hookToken, event: "session_end", session: "L1")

        let removed = try await waitUntil { coordinator.store.session(id: "L1") == nil }
        XCTAssertTrue(removed, "a SessionEnd hook must prune the session from the store")
        XCTAssertTrue(sink.deliveries.isEmpty, "ending a session must not post a notification")
    }

    /// I3: events are applied strictly in arrival order. A userPromptSubmit → stop →
    /// sessionEnd sequence must settle on the terminal end (session pruned), never stick on
    /// an earlier .working/.finished state as reordered unstructured tasks could.
    func testSerialEventSequenceSettlesOnTerminalEnd() async throws {
        let sink = RecordingSink()
        let coordinator = makeCoordinator(sink: sink)
        try coordinator.start()
        defer { coordinator.shutdown() }

        _ = coordinator.store.create(cwd: "/tmp", title: "api", id: "L1")

        try await fireHook(port: coordinator.hookPort, token: coordinator.hookToken, event: "user_prompt_submit", session: "L1")
        try await fireHook(port: coordinator.hookPort, token: coordinator.hookToken, event: "stop", session: "L1")
        try await fireHook(port: coordinator.hookPort, token: coordinator.hookToken, event: "session_end", session: "L1")

        let removed = try await waitUntil { coordinator.store.session(id: "L1") == nil }
        XCTAssertTrue(removed, "the terminal SessionEnd must win — the session must not be stuck working/finished")
    }

    /// A real Stop hook POST drives the store to `.finished`, binds the claude id, and — since
    /// the user is not watching (isWatching == false) — posts exactly one notification.
    func testHookPostDrivesStoreAndNotification() async throws {
        let sink = RecordingSink()
        let coordinator = makeCoordinator(sink: sink)
        try coordinator.start()
        defer { coordinator.shutdown() }

        // Seed a session the way newSession would (without launching a real terminal).
        _ = coordinator.store.create(cwd: "/tmp", title: "api", id: "L1")

        // Fire a real Stop hook at the live server.
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(coordinator.hookPort)/hook")!)
        request.httpMethod = "POST"
        request.setValue("stop", forHTTPHeaderField: "X-LinkC-Event")
        request.setValue("L1", forHTTPHeaderField: "X-LinkC-Session")
        request.setValue(coordinator.hookToken, forHTTPHeaderField: "X-LinkC-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"session_id":"c1","cwd":"/tmp","hook_event_name":"Stop"}"#.utf8)
        let (respData, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(data: respData, encoding: .utf8), "{}")

        let finished = try await waitUntil { coordinator.store.session(id: "L1")?.state == .finished }
        XCTAssertTrue(finished, "Stop hook should have driven session L1 to .finished")
        XCTAssertEqual(coordinator.store.session(id: "L1")?.claudeSessionId, "c1")

        // A finished session while not watching should have posted exactly one notification.
        let deliveries = sink.deliveries
        XCTAssertEqual(deliveries.count, 1)
        XCTAssertEqual(deliveries.first?.id, "L1")
        XCTAssertTrue(deliveries.first?.body.contains("finished") ?? false)
    }

    /// newSession writes the per-session settings file and launches a terminal; stopSession
    /// kills that terminal, deletes the settings file, and removes the session from the store.
    /// Uses `/bin/cat` as a stand-in for claude — a real but harmless PTY child that blocks on
    /// its input rather than exiting on its own, so the "file exists after launch" assertion
    /// isn't raced by the auto-prune that a self-exiting child would trigger.
    func testStopSessionLaunchesThenCleansUpSettingsAndSession() async throws {
        let settingsDir = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-cleanup-\(UUID().uuidString)")
        let cwd = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-cwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cwd) }

        let coordinator = makeCoordinator(sink: RecordingSink(), claudePath: "/bin/cat", settingsDir: settingsDir)

        let session = try coordinator.newSession(cwd: cwd.path, mode: .new)
        let settingsFile = settingsDir.appendingPathComponent("session-\(session.id).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: settingsFile.path), "newSession must write the per-session settings file")
        XCTAssertNotNil(coordinator.terminals.session(id: session.id), "newSession must register a terminal")
        XCTAssertEqual(coordinator.terminals.selectedId, session.id, "the new session must be selected")

        coordinator.stopSession(session.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: settingsFile.path), "stopSession must delete the per-session settings file")
        XCTAssertNil(coordinator.store.session(id: session.id), "stopSession must remove the session from the store")
        XCTAssertNil(coordinator.terminals.session(id: session.id), "stopSession must remove the terminal")
    }

    /// The launch mode maps to the right claude flag (pure mapping — no spawn needed).
    func testLaunchModeClaudeArgs() {
        XCTAssertEqual(LaunchMode.new.claudeArgs, [])
        XCTAssertEqual(LaunchMode.continueLast.claudeArgs, ["--continue"])
        XCTAssertEqual(LaunchMode.resume.claudeArgs, ["--resume"])
    }

    /// The shared arg builder used by both the new-session and restore paths. A captured claude
    /// id always wins (`--resume <id>`); otherwise the mode's own flag is used, so restore with no
    /// captured id falls back to `--continue` in the folder.
    func testLaunchArgsTableDriven() {
        let cases: [(mode: LaunchMode, resumeId: String?, expected: [String])] = [
            (.new, nil, []),
            (.continueLast, nil, ["--continue"]),
            (.resume, nil, ["--resume"]),
            (.new, "abc", ["--resume", "abc"]),
            (.continueLast, "abc", ["--resume", "abc"]),
            (.resume, "abc", ["--resume", "abc"]),
            (.new, "", []), // an empty id is not a real conversation → treat as no resume
        ]
        for c in cases {
            XCTAssertEqual(
                AppCoordinator.launchArgs(mode: c.mode, resumeId: c.resumeId),
                c.expected,
                "mode \(c.mode) resumeId \(String(describing: c.resumeId))"
            )
        }
    }

    /// A live session is recorded in the manifest but is NOT a restorable while it is running
    /// (its linkC id matches a live session). It becomes restorable only once it ends.
    func testLiveSessionIsRecordedButNotRestorable() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-restore-\(UUID().uuidString)")
        let cwd = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-cwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cwd) }

        let coordinator = makeCoordinator(sink: RecordingSink(), claudePath: "/bin/cat", settingsDir: dir, manifestDir: dir)
        let session = try coordinator.newSession(cwd: cwd.path, mode: .new)
        defer { coordinator.stopSession(session.id) } // kill the /bin/cat stand-in

        XCTAssertTrue(coordinator.restorables.isEmpty, "a live session must not show as restorable")
    }

    /// The full lifecycle: create → bind claude id via a hook → stop. A fresh coordinator over the
    /// same manifest directory then surfaces it as a restorable carrying the captured claude id and
    /// an `endedAt`; dismissing it removes it for good.
    func testEndedSessionBecomesRestorableThenDismissable() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-restore-\(UUID().uuidString)")
        let cwd = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-cwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cwd) }

        let coordinator = makeCoordinator(sink: RecordingSink(), claudePath: "/bin/cat", settingsDir: dir, manifestDir: dir)
        let session = try coordinator.newSession(cwd: cwd.path, mode: .new)
        // A hook binds claude's real conversation id onto the session (and the manifest entry).
        coordinator.handle(HookEvent(kind: .stop, linkcSessionId: session.id, claudeSessionId: "cabc", cwd: cwd.path))
        coordinator.stopSession(session.id) // cleanup → endedAt stamped, entry kept

        // A brand-new coordinator (simulating a relaunch) reads the manifest from disk.
        let relaunched = makeCoordinator(sink: RecordingSink(), settingsDir: dir, manifestDir: dir)
        XCTAssertEqual(relaunched.restorables.count, 1)
        let r = try XCTUnwrap(relaunched.restorables.first)
        XCTAssertEqual(r.linkcId, session.id)
        XCTAssertEqual(r.claudeSessionId, "cabc")
        XCTAssertEqual(r.cwd, cwd.path)
        XCTAssertNotNil(r.endedAt, "a stopped session must carry an endedAt")

        relaunched.dismiss(r)
        XCTAssertTrue(relaunched.restorables.isEmpty)
        // Persisted: a further relaunch also sees nothing.
        XCTAssertTrue(makeCoordinator(sink: RecordingSink(), settingsDir: dir, manifestDir: dir).restorables.isEmpty)
    }

    /// Restoring a card spawns a fresh live session and consumes the restorable (the new live
    /// session gets its own manifest entry; the old one is removed).
    func testRestoreConsumesRestorableAndSpawnsLiveSession() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-restore-\(UUID().uuidString)")
        let cwd = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-cwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cwd) }

        // Seed the manifest as a previous run would have left it.
        WorkspaceManifest(directory: dir).upsert(
            RestorableSession(linkcId: "OLD", claudeSessionId: "cabc", cwd: cwd.path, title: "proj", endedAt: Date())
        )

        let coordinator = makeCoordinator(sink: RecordingSink(), claudePath: "/bin/cat", settingsDir: dir, manifestDir: dir)
        XCTAssertEqual(coordinator.restorables.count, 1)
        let r = try XCTUnwrap(coordinator.restorables.first)

        let live = try coordinator.restore(r)
        defer { coordinator.stopSession(live.id) }

        XCTAssertNotEqual(live.id, "OLD", "restore must create a fresh live session, not reuse the old id")
        XCTAssertEqual(live.cwd, cwd.path)
        XCTAssertNotNil(coordinator.store.session(id: live.id), "the restored session must be live in the store")
        XCTAssertTrue(coordinator.restorables.isEmpty, "the restorable must be consumed by restoring it")
    }

    /// `restoreAll` restores every card; an empty restorable set makes it a no-op.
    func testRestoreAllRestoresEveryCard() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-restore-\(UUID().uuidString)")
        let cwdA = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-cwd-\(UUID().uuidString)")
        let cwdB = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-cwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cwdA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cwdB, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: cwdA)
            try? FileManager.default.removeItem(at: cwdB)
        }

        let seed = WorkspaceManifest(directory: dir)
        seed.upsert(RestorableSession(linkcId: "A", claudeSessionId: "ca", cwd: cwdA.path, title: "a", endedAt: Date()))
        seed.upsert(RestorableSession(linkcId: "B", claudeSessionId: nil, cwd: cwdB.path, title: "b", endedAt: Date()))

        let coordinator = makeCoordinator(sink: RecordingSink(), claudePath: "/bin/cat", settingsDir: dir, manifestDir: dir)
        XCTAssertEqual(coordinator.restorables.count, 2)

        try coordinator.restoreAll()
        defer { coordinator.store.sessions.forEach { coordinator.stopSession($0.id) } }

        XCTAssertTrue(coordinator.restorables.isEmpty, "restoreAll must consume every restorable")
        XCTAssertEqual(coordinator.store.sessions.count, 2, "restoreAll must spawn a live session per card")
    }

    /// I2: two id-less restorables in the same folder must NOT both launch `--continue` — the
    /// second would attach to the same conversation the first just started writing. Restore all
    /// launches one, refuses the other, and surfaces the refusal.
    func testRestoreAllRefusesSecondContinueInSameFolder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-collide-\(UUID().uuidString)")
        let cwd = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-cwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cwd) }

        // Same-folder duplicates can no longer come from disk (load keeps one entry per
        // folder), but two id-less sessions can still end in the same folder during ONE run —
        // hooks never bound a claude id, so both would restore as `--continue`.
        let coordinator = makeCoordinator(sink: RecordingSink(), claudePath: "/bin/cat", settingsDir: dir, manifestDir: dir)
        try coordinator.newSession(cwd: cwd.path, mode: .new)
        try coordinator.newSession(cwd: cwd.path, mode: .new)
        coordinator.store.sessions.forEach { coordinator.stopSession($0.id) }
        XCTAssertEqual(coordinator.restorables.count, 2, "both ended sessions must be restorable mid-run")

        XCTAssertThrowsError(try coordinator.restoreAll(), "the second same-folder --continue must be refused and surfaced")
        defer { coordinator.store.sessions.forEach { coordinator.stopSession($0.id) } }

        XCTAssertEqual(coordinator.store.sessions.count, 1, "exactly one --continue may launch per folder")
        XCTAssertEqual(coordinator.restorables.count, 1, "the refused card must remain restorable")
    }

    /// I3: a spawn that never happens (bad executable) must fail loud — an error, no phantom
    /// session, no phantom restorable, no orphaned settings file.
    func testLaunchWithBadClaudePathFailsLoud() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-badexec-\(UUID().uuidString)")
        let coordinator = makeCoordinator(
            sink: RecordingSink(),
            claudePath: "/nonexistent/claude-\(UUID().uuidString)",
            settingsDir: dir,
            manifestDir: dir
        )
        XCTAssertThrowsError(try coordinator.newSession(cwd: "/tmp"))
        XCTAssertTrue(coordinator.store.sessions.isEmpty, "a failed spawn must not leave a session row")
        XCTAssertTrue(coordinator.restorables.isEmpty, "a failed spawn must not manufacture a restorable")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        XCTAssertFalse(leftovers.contains { $0.hasPrefix("session-") }, "a failed spawn must not orphan its settings file")
    }

    /// M3: stale per-session settings files from a crashed run are swept at startup; the
    /// workspace manifest is untouched.
    func testStartupSweepRemovesOrphanedSettingsFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-sweep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stale = dir.appendingPathComponent("session-stale.json")
        try Data("{}".utf8).write(to: stale)
        let seed = WorkspaceManifest(directory: dir)
        seed.upsert(RestorableSession(linkcId: "old", claudeSessionId: "c", cwd: "/tmp", title: "old", endedAt: Date()))

        let coordinator = makeCoordinator(sink: RecordingSink(), settingsDir: dir, manifestDir: dir)
        try coordinator.start()
        defer { coordinator.shutdown() }

        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path), "orphaned session-*.json must be swept at startup")
        XCTAssertEqual(coordinator.restorables.count, 1, "the manifest must survive the sweep")
    }

    /// Coordinator-level sweep coverage: a subagent spawned mid-turn stays running through a
    /// permission pause (it may be alive behind the prompt — no sweep mid-turn) and is only
    /// swept, flagged, once the turn genuinely ends.
    func testSweepHoldsThroughPermissionPauseThenSweepsWhenTurnEnds() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-sweep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let transcript = dir.appendingPathComponent("t.jsonl")
        let spawn = """
        {"type":"assistant","timestamp":"2026-07-23T04:00:00Z","message":{"content":[\
        {"type":"tool_use","id":"toolu_A","name":"Agent",\
        "input":{"description":"Survey","subagent_type":"Explore","prompt":"..."}}]}}
        """
        try "".write(to: transcript, atomically: true, encoding: .utf8)

        let coordinator = makeCoordinator(sink: RecordingSink(), settingsDir: dir, manifestDir: dir)
        let tracker = UsageTracker(projectsDir: dir)
        coordinator.usageTracker = tracker
        _ = coordinator.store.create(cwd: "/tmp", title: "api", id: "L1")

        // 1: userPromptSubmit -> working, on an empty transcript (the turn just began).
        coordinator.handle(HookEvent(
            kind: .userPromptSubmit, linkcSessionId: "L1", claudeSessionId: nil, cwd: "/tmp",
            transcriptPath: transcript.path
        ))
        XCTAssertEqual(coordinator.store.session(id: "L1")?.state, .working)

        // The spawn lands mid-turn — appended after the submit, the way real spawns arrive.
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: transcript.path))
        handle.seekToEndOfFile()
        handle.write(Data((spawn + "\n").utf8))
        try handle.close()

        // 2: notificationPermission -> waitingPermission; a mid-turn pause must not sweep.
        coordinator.handle(HookEvent(
            kind: .notificationPermission, linkcSessionId: "L1", claudeSessionId: nil, cwd: "/tmp",
            transcriptPath: transcript.path
        ))
        XCTAssertEqual(coordinator.store.session(id: "L1")?.state, .waitingPermission)
        XCTAssertTrue(tracker.sessionAgents("L1").contains(where: \.isRunning), "a permission pause must not sweep mid-turn")

        // 3: stop -> finished; the turn is over, so the backstop ends the run and flags it.
        coordinator.handle(HookEvent(
            kind: .stop, linkcSessionId: "L1", claudeSessionId: nil, cwd: "/tmp",
            transcriptPath: transcript.path
        ))
        XCTAssertEqual(coordinator.store.session(id: "L1")?.state, .finished)
        let runs = tracker.sessionAgents("L1")
        XCTAssertFalse(runs.contains(where: \.isRunning), "the turn ending must sweep the still-running run")
        XCTAssertEqual(runs.first?.endedBySweep, true, "the sweep must flag the run it ended")
    }

    /// A spawn already in the transcript when a prompt is submitted belongs to an earlier
    /// turn (a resumed session replays its whole history) — submit must sweep it, or it
    /// shows as "running" for however long the new turn takes.
    func testPromptSubmitSweepsRunsFromEarlierTurns() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-sweep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let transcript = dir.appendingPathComponent("t.jsonl")
        let staleSpawn = """
        {"type":"assistant","timestamp":"2026-07-21T04:00:00Z","message":{"content":[\
        {"type":"tool_use","id":"toolu_OLD","name":"Agent",\
        "input":{"description":"Ancient","subagent_type":"Explore","prompt":"..."}}]}}
        """
        try (staleSpawn + "\n").write(to: transcript, atomically: true, encoding: .utf8)

        let coordinator = makeCoordinator(sink: RecordingSink(), settingsDir: dir, manifestDir: dir)
        let tracker = UsageTracker(projectsDir: dir)
        coordinator.usageTracker = tracker
        _ = coordinator.store.create(cwd: "/tmp", title: "api", id: "L1")

        coordinator.handle(HookEvent(
            kind: .userPromptSubmit, linkcSessionId: "L1", claudeSessionId: nil, cwd: "/tmp",
            transcriptPath: transcript.path
        ))

        let runs = tracker.sessionAgents("L1")
        XCTAssertEqual(runs.count, 1, "the historical spawn must still be parsed")
        XCTAssertFalse(runs.contains(where: \.isRunning), "prompt submit must sweep pre-turn runs")
        XCTAssertEqual(runs.first?.endedBySweep, true)
    }

    /// prepareForShutdown snapshots all active sessions to the manifest with wasActiveOnQuit == true,
    /// samples live foreground agents, and persists the selected session ID to UserDefaults.
    func testPrepareForShutdownPersistsActiveSessionsWithLiveAgentAndActiveOnQuit() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-shutdown-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: dir)
            UserDefaults.standard.removeObject(forKey: "LinkCLastSelectedSessionId")
        }

        let coordinator = makeCoordinator(sink: RecordingSink(), settingsDir: dir, manifestDir: dir)
        _ = coordinator.store.create(cwd: "/tmp/project1", title: "p1", id: "L1", agentKind: .claude)
        coordinator.store.apply(HookEvent(kind: .userPromptSubmit, linkcSessionId: "L1", claudeSessionId: "c1", cwd: "/tmp/project1"))

        _ = coordinator.store.create(cwd: "/tmp/project2", title: "p2", id: "L2", agentKind: .cursor)
        _ = coordinator.terminals.makeSession(id: "L2", cwd: "/tmp/project2", title: "p2", agentKind: .cursor)

        _ = coordinator.store.create(cwd: "/tmp/project3", title: "p3", id: "L3", agentKind: .agy)
        coordinator.store.apply(HookEvent(kind: .sessionEnd, linkcSessionId: "L3", claudeSessionId: nil, cwd: "/tmp/project3"))

        coordinator.prepareForShutdown(selectedId: "L2")

        XCTAssertEqual(UserDefaults.standard.string(forKey: "LinkCLastSelectedSessionId"), "L2")

        let entries = coordinator.manifest.entries
        guard let entry1 = entries.first(where: { $0.linkcId == "L1" }) else {
            return XCTFail("Missing manifest entry for L1")
        }
        XCTAssertTrue(entry1.wasActiveOnQuit)
        XCTAssertNil(entry1.endedAt)
        XCTAssertEqual(entry1.agentKind, .claude)
        XCTAssertEqual(entry1.claudeSessionId, "c1")
        XCTAssertEqual(entry1.cwd, "/tmp/project1")

        guard let entry2 = entries.first(where: { $0.linkcId == "L2" }) else {
            return XCTFail("Missing manifest entry for L2")
        }
        XCTAssertTrue(entry2.wasActiveOnQuit)
        XCTAssertNil(entry2.endedAt)
        XCTAssertEqual(entry2.agentKind, .cursor)

        let entry3 = entries.first(where: { $0.linkcId == "L3" })
        XCTAssertFalse(entry3?.wasActiveOnQuit ?? false)

        // Verify disk persistence to workspace.json
        let fileURL = dir.appendingPathComponent("workspace.json")
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let diskEntries = try decoder.decode([RestorableSession].self, from: data)
        XCTAssertTrue(diskEntries.contains { $0.linkcId == "L1" && $0.wasActiveOnQuit && $0.endedAt == nil })
        XCTAssertTrue(diskEntries.contains { $0.linkcId == "L2" && $0.wasActiveOnQuit && $0.endedAt == nil })
    }

    /// ShellCoordinator.prepareForShutdown snapshots all running shells with wasActiveOnQuit == true and detected agents.
    func testShellCoordinatorPrepareForShutdownPersistsRunningShells() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-shell-shutdown-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let terminals = TerminalSessionManager()
        let shellCoordinator = ShellCoordinator(terminals: terminals, manifestDir: dir)

        _ = shellCoordinator.store.add(id: "S1", cwd: "/tmp/shell1", title: "sh1", command: "npm run dev")
        shellCoordinator.store.updateDetectedAgent(id: "S1", agent: .codex)

        _ = shellCoordinator.store.add(id: "S2", cwd: "/tmp/shell2", title: "sh2", command: nil)
        shellCoordinator.store.markExited(id: "S2", code: 0)

        shellCoordinator.prepareForShutdown()

        guard let entries = shellCoordinator.manifest?.entries else {
            return XCTFail("Shell manifest should exist")
        }

        guard let shell1 = entries.first(where: { $0.id == "S1" }) else {
            return XCTFail("Missing shell manifest entry for S1")
        }
        XCTAssertTrue(shell1.wasActiveOnQuit)
        XCTAssertNil(shell1.endedAt)
        XCTAssertEqual(shell1.detectedAgent, .codex)
        XCTAssertEqual(shell1.command, "npm run dev")

        let shell2 = entries.first(where: { $0.id == "S2" })
        XCTAssertFalse(shell2?.wasActiveOnQuit ?? false)

        // Verify disk persistence to shells.json
        let fileURL = dir.appendingPathComponent("shells.json")
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let diskEntries = try decoder.decode([RestorableShell].self, from: data)
        XCTAssertTrue(diskEntries.contains { $0.id == "S1" && $0.wasActiveOnQuit && $0.detectedAgent == .codex && $0.endedAt == nil })
    }

    /// AppCoordinator.shutdown() invokes prepareForShutdown() to persist active sessions.
    func testAppCoordinatorShutdownCallsPrepareForShutdown() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-shutdown-call-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let coordinator = makeCoordinator(sink: RecordingSink(), settingsDir: dir, manifestDir: dir)
        _ = coordinator.store.create(cwd: "/tmp/proj", title: "proj", id: "L4", agentKind: .agy)

        coordinator.shutdown()

        let entries = coordinator.manifest.entries
        guard let entry = entries.first(where: { $0.linkcId == "L4" }) else {
            return XCTFail("Missing manifest entry for L4")
        }
        XCTAssertTrue(entry.wasActiveOnQuit)
        XCTAssertNil(entry.endedAt)
        XCTAssertEqual(entry.agentKind, .agy)
    }
}


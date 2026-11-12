import XCTest
import os
@testable import LinkCKit

/// What linkC does with a task that names one model of an agent: never moved to another agent,
/// OpenCode's free-only rule at launch, the delegator told at once when the task cannot run, and
/// a CLI that rejects its model at launch.
@MainActor
final class AppCoordinatorModelTaskTests: XCTestCase {
    nonisolated(unsafe) private var tempDir: URL!
    private let sink = CapturingSink()

    private final class CapturingSink: NotificationSink, @unchecked Sendable {
        private let lock = NSLock()
        private var all: [(id: String, title: String, body: String)] = []
        var deliveries: [(id: String, title: String, body: String)] { lock.withLock { all } }
        func deliver(id: String, title: String, body: String) { lock.withLock { all.append((id, title, body)) } }
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-model-task-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    /// A stand-in agent that negotiates bracketed paste and waits for input, like a TUI.
    private var mockAgent: String {
        script(named: "mock_agent.sh", body: "stty -echo 2>/dev/null\nprintf '\\033[?2004h'\nexec /bin/cat\n")
    }

    /// A stand-in agent that prints `line` and exits by itself, as a CLI does that rejects its model.
    private func exitingAgent(printing line: String) -> String {
        script(named: "exiting_agent.sh", body: "printf '\(line)\\r\\n'\nsleep 0.3\nexit 1\n")
    }

    private func script(named name: String, body: String) -> String {
        let url = tempDir.appendingPathComponent(name)
        try? "#!/bin/sh\n\(body)".write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func makeCoordinator(
        agent: String? = nil,
        installed: Set<AgentKind>? = nil,
        models: AgentModelSettings = .seeded,
        openCodeModels: @escaping AppCoordinator.OpenCodeModelLister = { _ in ["opencode/big-pickle"] },
        kiloModels: @escaping AppCoordinator.OpenCodeModelLister = { _ in [] },
        lists: @escaping @Sendable () throws -> [AgentKind: AgentModelList] = TestModelLists.none
    ) -> AppCoordinator {
        let agentPath = agent ?? mockAgent
        let settingsDir = tempDir.appendingPathComponent("settings")
        try? FileManager.default.createDirectory(at: settingsDir, withIntermediateDirectories: true)
        return AppCoordinator(
            terminals: TerminalSessionManager(),
            hookServer: HookServer.forTesting(),
            notifications: NotificationManager(sink: sink, now: { Date() }),
            claudePath: agentPath,
            settingsDir: settingsDir,
            userSettingsURL: tempDir.appendingPathComponent("user-settings.json"),
            manifestDir: tempDir.appendingPathComponent("manifest"),
            agentPathResolver: { kind in installed.map { $0.contains(kind) } ?? true ? agentPath : nil },
            userHome: tempDir.appendingPathComponent("home"),
            modelSettings: { models },
            modelLists: lists,
            deliverySettle: 0,
            injectionGap: 0,
            turnEndQuietPeriod: 0,
            openCodeModels: openCodeModels,
            kiloModels: kiloModels,
            isWatching: { _ in false }
        )
    }

    private func waitUntil(polls: Int = TestWait.polls, _ predicate: @MainActor () -> Bool) async throws -> Bool {
        for _ in 0..<polls {
            if predicate() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return predicate()
    }

    private func waitForPasteReady(_ coordinator: AppCoordinator, sessionId: String) async throws {
        let ready = try await waitUntil { coordinator.terminals.session(id: sessionId)?.acceptsPaste ?? false }
        XCTAssertTrue(ready, "session \(sessionId) never negotiated bracketed paste")
    }

    private func notices(_ inbox: InboxStore, for task: TaskRecord) throws -> [PendingMessage] {
        try inbox.load().messages.filter { $0.kind == .notice && $0.taskId == task.id }
    }

    // MARK: - A task with a model is never rerouted

    /// A worker on a Gemini model hits its limit while it holds a task for that model. The model
    /// means nothing to another agent, so the task is neither cancelled nor copied. It stays with
    /// its worker, and the delegator is told at once what is limited and what is not.
    func testAModelTaskIsNeverReroutedWhenItsWorkerHitsALimit() async throws {
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }
        let inbox = InboxStore(workspaceRoot: tempDir.path)
        let worker = try coordinator.newSession(cwd: tempDir.path, agent: .agy, model: "gemini-3.8-flash-medium")
        coordinator.store.updateState(id: worker.id, to: .finished)
        let task = try inbox.createTask(from: .claude, to: .agy, model: "gemini-3.8-flash-medium",
                                        prompt: "Use Flash.", files: [])
        try inbox.markTaskDelivered(taskId: task.id, sessionId: worker.id)
        try inbox.markTaskStarted(taskId: task.id)
        coordinator.terminals.sendInput(sessionId: worker.id, text: "quota exceeded\n")
        let shown = try await waitUntil {
            coordinator.terminals.session(id: worker.id)?.recentOutput(lines: 10).contains("quota exceeded") ?? false
        }
        XCTAssertTrue(shown, "the mock agent never printed the banner")

        XCTAssertTrue(coordinator.checkLimitsAndReroute(for: worker.id))

        XCTAssertEqual(try inbox.task(id: task.id)?.state, .started, "the task stays with its worker")
        XCTAssertFalse(try inbox.load().tasks.contains { $0.hop > 0 }, "no copy for another agent")
        XCTAssertEqual(coordinator.store.session(id: worker.id)?.state, .error)
        let told = try notices(inbox, for: task)
        XCTAssertEqual(told.count, 1, "the delegator is told at once")
        let text = try XCTUnwrap(told.first).prompt
        XCTAssertTrue(text.contains(task.shortId), text)
        XCTAssertTrue(text.contains("Gemini pool is limited until"), text)
        XCTAssertTrue(text.contains("Not limited:"), text)
    }

    // MARK: - A limited worker carries on

    /// A worker on a Gemini model, holding a started task for that model, that has just hit its limit.
    private func limitedModelWorker(
        _ coordinator: AppCoordinator, inbox: InboxStore
    ) async throws -> (worker: Session, task: TaskRecord) {
        let worker = try coordinator.newSession(cwd: tempDir.path, agent: .agy, model: "gemini-3.8-flash-medium")
        coordinator.store.updateState(id: worker.id, to: .finished)
        let task = try inbox.createTask(from: .claude, to: .agy, model: "gemini-3.8-flash-medium",
                                        prompt: "Use Flash.", files: [])
        try inbox.markTaskDelivered(taskId: task.id, sessionId: worker.id)
        try inbox.markTaskStarted(taskId: task.id)
        coordinator.terminals.sendInput(sessionId: worker.id, text: "quota exceeded\n")
        let shown = try await waitUntil {
            coordinator.terminals.session(id: worker.id)?.recentOutput(lines: 10).contains("quota exceeded") ?? false
        }
        XCTAssertTrue(shown, "the mock agent never printed the banner")
        XCTAssertTrue(coordinator.checkLimitsAndReroute(for: worker.id))
        XCTAssertEqual(coordinator.store.session(id: worker.id)?.state, .error)
        return (worker, task)
    }

    private func endLimits(_ inbox: InboxStore) throws {
        var seeded = try inbox.load()
        seeded.agentLimits = []
        try inbox.saveRaw(seeded)
    }

    private func carryOnMessages(_ inbox: InboxStore, for worker: Session) throws -> [PendingMessage] {
        try inbox.load().messages.filter { $0.toSessionId == worker.id }
    }

    /// The delegator was told the task "carries on when the limit ends": when the worker's session
    /// recovers from the limit, the worker is told to, once.
    func testALimitedModelWorkerIsToldToCarryOnOnceItsLimitEnds() async throws {
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }
        let inbox = InboxStore(workspaceRoot: ProjectPath.canonical(tempDir.path))
        let (worker, task) = try await limitedModelWorker(coordinator, inbox: inbox)

        coordinator.sampleAgentStates()
        XCTAssertEqual(coordinator.store.session(id: worker.id)?.state, .error, "the limit is still on")
        XCTAssertTrue(try carryOnMessages(inbox, for: worker).isEmpty, "nothing to say while the limit lasts")

        try endLimits(inbox)
        coordinator.sampleAgentStates()

        XCTAssertNotEqual(coordinator.store.session(id: worker.id)?.state, .error)
        let told = try carryOnMessages(inbox, for: worker)
        XCTAssertEqual(told.map(\.prompt), ["linkC: the limit has ended. Carry on with task \(task.id)."])
        XCTAssertEqual(told.first?.toAgent, .agy)

        // Delivered, and the worker keeps its screen: later samples add nothing.
        coordinator.dispatchMessages(workspacePath: tempDir.path, inboxStore: inbox)
        coordinator.sampleAgentStates()
        coordinator.sampleAgentStates()
        XCTAssertEqual(try carryOnMessages(inbox, for: worker).count, 1, "once per recovery")
        XCTAssertEqual(try inbox.task(id: task.id)?.state, .started)
    }

    /// A task that ended while its worker was limited has nothing to carry on with.
    func testALimitedWorkerWhoseTaskEndedIsNotToldToCarryOn() async throws {
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }
        let inbox = InboxStore(workspaceRoot: ProjectPath.canonical(tempDir.path))
        let (worker, task) = try await limitedModelWorker(coordinator, inbox: inbox)
        try inbox.cancelTask(taskId: task.id, reason: "not needed")

        try endLimits(inbox)
        coordinator.sampleAgentStates()

        XCTAssertNotEqual(coordinator.store.session(id: worker.id)?.state, .error)
        XCTAssertTrue(try carryOnMessages(inbox, for: worker).isEmpty)
    }

    /// The delegator's notice that the task stays with its limited worker is not given up on when the
    /// inbox cannot be written at that moment: the next tick sends it.
    func testTheStaysNoticeIsRetriedOnTheNextTickWhenItCouldNotBeWritten() async throws {
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }
        let root = ProjectPath.canonical(tempDir.path)
        let inbox = InboxStore(workspaceRoot: root)
        try inbox.recordLimit(agent: .agy, reason: "quota exceeded", cooldown: 1800, pool: "gemini")
        let linkcDir = URL(fileURLWithPath: root).appendingPathComponent(".linkc").path
        let worker = try coordinator.newSession(cwd: tempDir.path, agent: .agy, model: "gemini-3.8-flash-medium")
        coordinator.store.updateState(id: worker.id, to: .finished)
        let task = try inbox.createTask(from: .claude, to: .agy, model: "gemini-3.8-flash-medium",
                                        prompt: "Use Flash.", files: [])
        try inbox.markTaskDelivered(taskId: task.id, sessionId: worker.id)
        try inbox.markTaskStarted(taskId: task.id)
        coordinator.terminals.sendInput(sessionId: worker.id, text: "quota exceeded\n")
        let shown = try await waitUntil {
            coordinator.terminals.session(id: worker.id)?.recentOutput(lines: 10).contains("quota exceeded") ?? false
        }
        XCTAssertTrue(shown)

        // The inbox cannot be written: no file can be added to its folder.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: linkcDir)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: linkcDir) }
        XCTAssertTrue(coordinator.checkLimitsAndReroute(for: worker.id))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: linkcDir)
        XCTAssertTrue(try notices(inbox, for: task).isEmpty, "the notice could not be written yet")

        coordinator.processPendingMessages(workspacePath: root)

        let told = try notices(inbox, for: task)
        XCTAssertEqual(told.count, 1, "the next tick sends it: \(told.map(\.prompt))")
        XCTAssertTrue(try XCTUnwrap(told.first).prompt.contains("stays with Antigravity"), told.first?.prompt ?? "")

        coordinator.processPendingMessages(workspacePath: root)
        XCTAssertEqual(try notices(inbox, for: task).count, 1, "and only once")
    }

    /// A limit seen on a session records the pool of the model that session runs.
    func testALimitIsRecordedForTheSessionsModelPool() async throws {
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }
        let inbox = InboxStore(workspaceRoot: tempDir.path)
        let flash = try coordinator.newSession(cwd: tempDir.path, agent: .agy, model: "gemini-3.8-flash-medium")
        coordinator.store.updateState(id: flash.id, to: .finished)
        coordinator.terminals.sendInput(sessionId: flash.id, text: "quota exceeded\n")
        let shown = try await waitUntil {
            coordinator.terminals.session(id: flash.id)?.recentOutput(lines: 10).contains("quota exceeded") ?? false
        }
        XCTAssertTrue(shown)

        coordinator.checkLimitsAndReroute(for: flash.id)

        let rows = try inbox.load().agentLimits
        XCTAssertEqual(rows.map(\.agent), [.agy])
        XCTAssertEqual(rows.first?.pool, "gemini")
        XCTAssertNil(try inbox.isAgentLimited(agent: .agy, model: "claude-opus-4-6-thinking"),
                     "a Gemini limit does not limit the Claude/GPT pool")
    }

    func testALimitOnAClaudeModelSessionIsRecordedForTheClaudeGptPool() async throws {
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }
        let inbox = InboxStore(workspaceRoot: tempDir.path)
        let opus = try coordinator.newSession(cwd: tempDir.path, agent: .agy, model: "claude-opus-4-6-thinking")
        coordinator.store.updateState(id: opus.id, to: .finished)
        coordinator.terminals.sendInput(sessionId: opus.id, text: "quota exceeded\n")
        let shown = try await waitUntil {
            coordinator.terminals.session(id: opus.id)?.recentOutput(lines: 10).contains("quota exceeded") ?? false
        }
        XCTAssertTrue(shown)

        coordinator.checkLimitsAndReroute(for: opus.id)

        XCTAssertEqual(try inbox.load().agentLimits.first?.pool, "claude-gpt")
    }

    /// An agent whose quota covers the whole account has no pool: its limit limits every model.
    func testALimitOnAnotherAgentIsRecordedWithoutAPool() async throws {
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }
        let inbox = InboxStore(workspaceRoot: tempDir.path)
        let codex = try coordinator.newSession(cwd: tempDir.path, agent: .codex, model: "gpt-5.6-sol")
        coordinator.store.updateState(id: codex.id, to: .finished)
        coordinator.terminals.sendInput(sessionId: codex.id, text: "429 Too Many Requests\n")
        let shown = try await waitUntil {
            coordinator.terminals.session(id: codex.id)?.recentOutput(lines: 10).contains("429 Too Many") ?? false
        }
        XCTAssertTrue(shown)

        coordinator.checkLimitsAndReroute(for: codex.id)

        let row = try XCTUnwrap(try inbox.load().agentLimits.first)
        XCTAssertEqual(row.agent, .codex)
        XCTAssertNil(row.pool)
    }

    // MARK: - A held task tells its delegator once

    /// A model task whose pool is limited waits, and the delegator hears why the first time it is
    /// held: what is limited, until when, and what is not. Later passes say nothing, and no worker
    /// is started for it.
    func testAHeldModelTaskTellsItsDelegatorOnceNotOnEveryPass() throws {
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }
        let inbox = InboxStore(workspaceRoot: tempDir.path)
        try inbox.recordLimit(agent: .agy, reason: "quota exceeded", cooldown: 3600, pool: "gemini")
        let task = try inbox.createTask(from: .claude, to: .agy, model: "gemini-3.8-flash-medium",
                                        prompt: "Use Flash.", files: [])

        for _ in 0..<3 {
            coordinator.dispatchTasks(workspacePath: tempDir.path, inboxStore: inbox)
            // Delivering the notice frees the inbox to take an identical one: only the relay's own mark stops a repeat.
            coordinator.dispatchMessages(workspacePath: tempDir.path, inboxStore: inbox)
        }

        let told = try notices(inbox, for: task)
        XCTAssertEqual(told.count, 1, "one notice, not one per pass: \(told.map(\.prompt))")
        let text = try XCTUnwrap(told.first).prompt
        XCTAssertTrue(text.contains("Task \(task.shortId) waits:"), text)
        XCTAssertTrue(text.contains("agy's Gemini pool is limited until"), text)
        XCTAssertTrue(text.contains("quota exceeded"), text)
        XCTAssertTrue(text.contains("Not limited:"), text)
        XCTAssertEqual(try inbox.task(id: task.id)?.state, .queued)
        XCTAssertTrue(coordinator.store.sessions.isEmpty, "no worker is started for a held task")
    }

    /// The mark that a held task was told about lasts only while the hold does: when the limit has
    /// lapsed and a later one holds the task again, its delegator hears about that one too.
    func testAHeldTaskIsToldAgainWhenAnotherLimitHoldsItLater() throws {
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }
        let inbox = InboxStore(workspaceRoot: tempDir.path)
        let task = try inbox.createTask(from: .claude, to: .agy, model: "gemini-3.8-flash-medium",
                                        prompt: "Use Flash.", files: [])
        try inbox.recordLimit(agent: .agy, reason: "first", cooldown: 1800, pool: "gemini")
        coordinator.dispatchTasks(workspacePath: tempDir.path, inboxStore: inbox)
        XCTAssertEqual(try notices(inbox, for: task).count, 1)

        // The limit lapses: the task is no longer held, so this pass starts its worker.
        var seeded = try inbox.load()
        seeded.agentLimits = []
        try inbox.saveRaw(seeded)
        coordinator.dispatchTasks(workspacePath: tempDir.path, inboxStore: inbox)
        XCTAssertEqual(coordinator.store.sessions.count, 1)
        XCTAssertEqual(try notices(inbox, for: task).count, 1, "nothing new to say while it is not held")

        try inbox.recordLimit(agent: .agy, reason: "second", cooldown: 1800, pool: "gemini")
        coordinator.dispatchTasks(workspacePath: tempDir.path, inboxStore: inbox)
        XCTAssertEqual(try notices(inbox, for: task).count, 2, "held again by a new limit")
    }

    /// A task whose own session sits rate-limited waits too, and its delegator is told once.
    func testATaskWaitingOnARateLimitedSessionTellsItsDelegatorOnce() throws {
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }
        let inbox = InboxStore(workspaceRoot: tempDir.path)
        let session = coordinator.store.create(cwd: ProjectPath.canonical(tempDir.path), title: "agy", id: "L1",
                                               agentKind: .agy, model: "gemini-3.8-flash-medium", isWorker: true)
        coordinator.store.updateState(id: session.id, to: .error)
        let task = try inbox.createTask(from: .claude, to: .agy, model: "gemini-3.8-flash-medium",
                                        prompt: "Use Flash.", files: [])

        for _ in 0..<3 {
            coordinator.dispatchTasks(workspacePath: tempDir.path, inboxStore: inbox)
            // Delivering the notice frees the inbox to take an identical one: only the relay's own mark stops a repeat.
            coordinator.dispatchMessages(workspacePath: tempDir.path, inboxStore: inbox)
        }

        let told = try notices(inbox, for: task)
        XCTAssertEqual(told.count, 1, "\(told.map(\.prompt))")
        XCTAssertTrue(try XCTUnwrap(told.first).prompt.contains("rate-limited"), told.first?.prompt ?? "")
    }

    /// A hold that lasts past the time the task would expire in the queue is no hold: the queue would
    /// end the task without a word. The task fails at once, and its delegator is told when the limit
    /// ends and where else to send the work.
    func testATaskHeldPastItsQueueExpiryFailsAtOnceAndTellsItsDelegator() throws {
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }
        let inbox = InboxStore(workspaceRoot: tempDir.path)
        try inbox.recordLimit(agent: .agy, reason: "quota exceeded", cooldown: 2 * 3600, pool: "gemini")
        let task = try inbox.createTask(from: .claude, to: .agy, model: "gemini-3.8-flash-medium",
                                        prompt: "Use Flash.", files: [])

        coordinator.dispatchTasks(workspacePath: tempDir.path, inboxStore: inbox)

        let failed = try XCTUnwrap(inbox.task(id: task.id))
        XCTAssertEqual(failed.state, .failed)
        let reason = try XCTUnwrap(failed.cancelReason)
        XCTAssertTrue(reason.hasPrefix("agy's Gemini pool is limited until "), reason)
        XCTAssertTrue(reason.hasSuffix(" (quota exceeded). That is after this task would expire in the queue; "
                                       + "delegate it again then, or to: claude, agy's Claude/GPT pool, cursor, codex, grok, opencode, kilo."),
                      reason)
        let told = try inbox.load().messages.filter { $0.taskId == task.id && $0.toAgent == .claude }
        XCTAssertTrue(told.contains { $0.prompt.contains("failed") && $0.prompt.contains(reason) },
                      told.map(\.prompt).joined(separator: "\n"))
        XCTAssertTrue(coordinator.store.sessions.isEmpty, "no worker is started for it")
    }

    /// A limit that ends in time is still a hold, so the task waits.
    func testATaskHeldForLessThanItsQueueExpiryStillWaits() throws {
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }
        let inbox = InboxStore(workspaceRoot: tempDir.path)
        try inbox.recordLimit(agent: .agy, reason: "quota exceeded", cooldown: 1800, pool: "gemini")
        let task = try inbox.createTask(from: .claude, to: .agy, model: "gemini-3.8-flash-medium",
                                        prompt: "Use Flash.", files: [])

        coordinator.dispatchTasks(workspacePath: tempDir.path, inboxStore: inbox)

        XCTAssertEqual(try inbox.task(id: task.id)?.state, .queued)
    }

    /// The same when every other pool is limited too: nothing to offer, so the text says only when.
    func testAHeldPastExpiryTaskWithNowhereElseSaysOnlyToDelegateAgainLater() throws {
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }
        let inbox = InboxStore(workspaceRoot: tempDir.path)
        for agent in AgentKind.peers where agent != .agy {
            try inbox.recordLimit(agent: agent, reason: "cap", cooldown: 4 * 3600)
        }
        try inbox.recordLimit(agent: .agy, reason: "quota exceeded", cooldown: 4 * 3600, pool: "claude-gpt")
        try inbox.recordLimit(agent: .agy, reason: "quota exceeded", cooldown: 4 * 3600, pool: "gemini")
        let task = try inbox.createTask(from: .claude, to: .agy, model: "gemini-3.8-flash-medium",
                                        prompt: "Use Flash.", files: [])

        coordinator.dispatchTasks(workspacePath: tempDir.path, inboxStore: inbox)

        let reason = try XCTUnwrap(inbox.task(id: task.id)?.cancelReason)
        XCTAssertTrue(reason.hasSuffix("That is after this task would expire in the queue; delegate it again then."), reason)
        XCTAssertFalse(reason.contains("or to:"), reason)
    }

    /// While a task is held, a limit that is pushed later is news: the delegator is told the new end,
    /// and only once for each end.
    func testAHeldTaskIsToldAgainWhenItsLimitEndsLater() throws {
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }
        let inbox = InboxStore(workspaceRoot: tempDir.path)
        let task = try inbox.createTask(from: .claude, to: .agy, model: "gemini-3.8-flash-medium",
                                        prompt: "Use Flash.", files: [])
        try inbox.recordLimit(agent: .agy, reason: "quota exceeded", cooldown: 900, pool: "gemini")
        let firstEnd = try XCTUnwrap(inbox.liveLimits(agent: .agy).first).cooldownExpiresAt

        func pass() throws {
            coordinator.dispatchTasks(workspacePath: tempDir.path, inboxStore: inbox)
            coordinator.dispatchMessages(workspacePath: tempDir.path, inboxStore: inbox)
        }
        try pass()
        try pass()
        XCTAssertEqual(try notices(inbox, for: task).count, 1, "one notice for the first end")

        let laterEnd = firstEnd.addingTimeInterval(1800)
        try inbox.extendLimit(agent: .agy, until: laterEnd, pool: "gemini")
        try pass()
        try pass()

        let told = try notices(inbox, for: task)
        XCTAssertEqual(told.count, 2, "a second notice for the later end, then silence: \(told.map(\.prompt))")
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE HH:mm"
        let latest = try XCTUnwrap(told.last).prompt
        XCTAssertTrue(latest.contains("limited until \(formatter.string(from: laterEnd))"), latest)
        XCTAssertEqual(try inbox.task(id: task.id)?.state, .queued)
    }

    /// A task waiting for a rate-limited session says when that session's limit ends, when a limit row
    /// holds it. Here the session runs a Claude/GPT model on the task's tier and the tier's own model is
    /// a Gemini one, so only the session is limited.
    func testATaskWaitingOnALimitedSessionSaysWhenItsLimitEnds() throws {
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }
        let inbox = InboxStore(workspaceRoot: tempDir.path)
        let session = coordinator.store.create(cwd: ProjectPath.canonical(tempDir.path), title: "agy", id: "L1",
                                               agentKind: .agy, model: "claude-opus-4-6-thinking",
                                               modelTier: .standard, isWorker: true)
        coordinator.store.updateState(id: session.id, to: .error)
        try inbox.recordLimit(agent: .agy, reason: "quota exceeded", cooldown: 1800, pool: "claude-gpt")
        let end = try XCTUnwrap(inbox.liveLimits(agent: .agy).first).cooldownExpiresAt
        let task = try inbox.createTask(from: .claude, to: .agy, tier: .standard, prompt: "Standard.", files: [])

        coordinator.dispatchTasks(workspacePath: tempDir.path, inboxStore: inbox)

        let formatter = DateFormatter()
        formatter.dateFormat = "EEE HH:mm"
        let told = try notices(inbox, for: task)
        XCTAssertEqual(told.count, 1, "\(told.map(\.prompt))")
        let text = try XCTUnwrap(told.first).prompt
        XCTAssertTrue(text.contains("rate-limited until \(formatter.string(from: end))"), text)
        XCTAssertEqual(try inbox.task(id: task.id)?.state, .queued)
    }

    // MARK: - OpenCode runs free models only, at launch

    func testLaunchRefusesANonFreeOpenCodeModel() throws {
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }

        XCTAssertThrowsError(try coordinator.newSession(cwd: tempDir.path, agent: .opencode,
                                                        model: "opencode/claude-sonnet-5")) { error in
            XCTAssertEqual(String(describing: error), "opencode/claude-sonnet-5 is not a free OpenCode model")
        }
        XCTAssertTrue(coordinator.store.sessions.isEmpty)
        XCTAssertTrue(coordinator.terminals.sessions.isEmpty)
    }

    func testSpawnTeammateRefusesANonFreeOpenCodeModel() throws {
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }

        XCTAssertThrowsError(try coordinator.spawnTeammate(in: tempDir.path, agent: .opencode,
                                                           model: "anthropic/claude-opus-5", asWorker: true)) { error in
            XCTAssertTrue(String(describing: error).contains("anthropic/claude-opus-5 is not a free OpenCode model"),
                          String(describing: error))
        }
        XCTAssertTrue(coordinator.store.sessions.isEmpty)
    }

    /// The New menu, and a worker for a tier task, launch on the default tier's model: a persisted
    /// non-free model there is refused too.
    func testLaunchRefusesAPersistedNonFreeOpenCodeTierModel() throws {
        var settings = AgentModelSettings.seeded
        settings.setModel("opencode/claude-sonnet-5", for: .opencode, tier: .standard)
        let coordinator = makeCoordinator(models: settings)
        defer { coordinator.shutdown() }

        XCTAssertThrowsError(try coordinator.newSession(cwd: tempDir.path, agent: .opencode)) { error in
            XCTAssertTrue(String(describing: error).contains("opencode/claude-sonnet-5 is not a free OpenCode model"),
                          String(describing: error))
        }
        XCTAssertThrowsError(try coordinator.spawnTeammate(in: tempDir.path, agent: .opencode, tier: .standard,
                                                           asWorker: true))
        XCTAssertTrue(coordinator.store.sessions.isEmpty)
    }

    func testAFreeOpenCodeModelLaunches() throws {
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }
        let session = try coordinator.newSession(cwd: tempDir.path, agent: .opencode, model: "opencode/beam-free")
        XCTAssertEqual(session.model, "opencode/beam-free")
        let local = try coordinator.newSession(cwd: tempDir.path, agent: .opencode, model: "ollama/qwen3.8:27b-32k")
        XCTAssertEqual(local.model, "ollama/qwen3.8:27b-32k")
    }

    /// A model task for a paid OpenCode model fails at once, with the reason, and its delegator
    /// is told. Nothing is started and nothing waits in the queue.
    func testAQueuedNonFreeOpenCodeModelTaskFailsAtOnceAndTellsItsDelegator() throws {
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }
        let inbox = InboxStore(workspaceRoot: tempDir.path)
        let task = try inbox.createTask(from: .claude, to: .opencode, model: "opencode/claude-sonnet-5",
                                        prompt: "Paid work.", files: [])

        coordinator.dispatchTasks(workspacePath: tempDir.path, inboxStore: inbox)

        let failed = try XCTUnwrap(inbox.task(id: task.id))
        XCTAssertEqual(failed.state, .failed)
        XCTAssertTrue(failed.cancelReason?.contains("opencode/claude-sonnet-5 is not free") ?? false, failed.cancelReason ?? "nil")
        let told = try inbox.load().messages.filter { $0.taskId == task.id && $0.toAgent == .claude }
        XCTAssertTrue(told.contains { $0.prompt.contains("failed") && $0.prompt.contains("not free") },
                      told.map(\.prompt).joined(separator: "\n"))
        XCTAssertTrue(coordinator.store.sessions.isEmpty)
    }

    /// A free model OpenCode does not list right now is refused the same way the tier path refuses it.
    func testAnOpenCodeModelTaskForAnUnlistedModelFailsAtOnce() async throws {
        let coordinator = makeCoordinator(openCodeModels: { _ in ["opencode/big-pickle"] })
        defer { coordinator.shutdown() }
        let inbox = InboxStore(workspaceRoot: tempDir.path)
        let task = try inbox.createTask(from: .claude, to: .opencode, model: "opencode/gone-free",
                                        prompt: "Gone.", files: [])

        coordinator.dispatchTasks(workspacePath: tempDir.path, inboxStore: inbox)   // starts the listing
        let listed = try await waitUntil { coordinator.openCodeModelCheckCount > 0 }
        XCTAssertTrue(listed, "the listing never finished")
        coordinator.dispatchTasks(workspacePath: tempDir.path, inboxStore: inbox)

        let failed = try XCTUnwrap(inbox.task(id: task.id))
        XCTAssertEqual(failed.state, .failed)
        XCTAssertTrue(failed.cancelReason?.contains("opencode/gone-free") ?? false, failed.cancelReason ?? "nil")
        XCTAssertTrue(failed.cancelReason?.contains("not among the models OpenCode lists") ?? false, failed.cancelReason ?? "nil")
        XCTAssertTrue(coordinator.store.sessions.isEmpty)
    }

    func testAnOpenCodeModelTaskForAListedFreeModelStartsAWorker() async throws {
        let coordinator = makeCoordinator(openCodeModels: { _ in ["opencode/beam-free"] })
        defer { coordinator.shutdown() }
        let inbox = InboxStore(workspaceRoot: tempDir.path)
        _ = try inbox.createTask(from: .claude, to: .opencode, model: "opencode/beam-free",
                                 prompt: "Free work.", files: [])

        coordinator.dispatchTasks(workspacePath: tempDir.path, inboxStore: inbox)
        let listed = try await waitUntil { coordinator.openCodeModelCheckCount > 0 }
        XCTAssertTrue(listed)
        coordinator.dispatchTasks(workspacePath: tempDir.path, inboxStore: inbox)

        let worker = try XCTUnwrap(coordinator.store.sessions.first { $0.agentKind == .opencode && $0.isWorker })
        XCTAssertEqual(worker.model, "opencode/beam-free")
    }

    // MARK: - A CLI that rejects its model at launch

    /// The worker's own process ends while it is still starting: the task fails at once, with the
    /// last line the CLI printed.
    func testAModelWorkerThatExitsByItselfWhileStartingFailsItsTask() async throws {
        let coordinator = makeCoordinator(agent: exitingAgent(printing: "Error: unknown model id"))
        defer { coordinator.shutdown() }
        let inbox = InboxStore(workspaceRoot: tempDir.path)
        let task = try inbox.createTask(from: .claude, to: .agy, model: "claude-opus-4-6-thinking",
                                        prompt: "Use Opus.", files: [])

        coordinator.dispatchTasks(workspacePath: tempDir.path, inboxStore: inbox)
        let failed = try await waitUntil { (try? inbox.task(id: task.id)?.state) == .failed }
        XCTAssertTrue(failed, "the worker's exit never failed its task")

        let reason = try XCTUnwrap(inbox.task(id: task.id)?.cancelReason)
        XCTAssertTrue(reason.contains("exited at launch with model claude-opus-4-6-thinking"), reason)
        XCTAssertTrue(reason.contains("Error: unknown model id"), reason)
        let told = try inbox.load().messages.filter { $0.taskId == task.id && $0.toAgent == .claude }
        XCTAssertTrue(told.contains { $0.prompt.contains("failed") }, told.map(\.prompt).joined(separator: "\n"))
    }

    /// A CLI that exits without printing anything leaves no last line to quote: the reason says so,
    /// rather than ending in a dangling colon.
    func testAModelWorkerThatExitsWithAnEmptyScreenFailsItsTaskSayingSo() async throws {
        let coordinator = makeCoordinator(agent: exitingAgent(printing: ""))
        defer { coordinator.shutdown() }
        let inbox = InboxStore(workspaceRoot: tempDir.path)
        let task = try inbox.createTask(from: .claude, to: .agy, model: "claude-opus-4-6-thinking",
                                        prompt: "Use Opus.", files: [])

        coordinator.dispatchTasks(workspacePath: tempDir.path, inboxStore: inbox)
        let failed = try await waitUntil { (try? inbox.task(id: task.id)?.state) == .failed }
        XCTAssertTrue(failed, "the worker's exit never failed its task")

        let reason = try XCTUnwrap(inbox.task(id: task.id)?.cancelReason)
        XCTAssertEqual(reason, "\(AgentKind.agy.displayName) exited at launch with model claude-opus-4-6-thinking (nothing on its screen).")
    }

    /// agy prints "model not recognized" and keeps running: harmless. When agy exits after it, the
    /// exit is an exit.
    func testAnAgyWorkerThatExitsAfterModelNotRecognizedStillFailsItsTask() async throws {
        let coordinator = makeCoordinator(agent: exitingAgent(printing: "model not recognized"))
        defer { coordinator.shutdown() }
        let inbox = InboxStore(workspaceRoot: tempDir.path)
        let task = try inbox.createTask(from: .claude, to: .agy, model: "claude-opus-4-6-thinking",
                                        prompt: "Use Opus.", files: [])

        coordinator.dispatchTasks(workspacePath: tempDir.path, inboxStore: inbox)
        let failed = try await waitUntil { (try? inbox.task(id: task.id)?.state) == .failed }
        XCTAssertTrue(failed, "an exit after the warning is still an exit")
        XCTAssertTrue(try XCTUnwrap(inbox.task(id: task.id)?.cancelReason).contains("model not recognized"))
    }

    /// agy printing the warning and running on is not a failure: nothing ends, and the task waits for
    /// its worker like any other.
    func testAnAgyWorkerThatKeepsRunningAfterModelNotRecognizedFailsNothing() async throws {
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }
        let inbox = InboxStore(workspaceRoot: tempDir.path)
        let task = try inbox.createTask(from: .claude, to: .agy, model: "claude-opus-4-6-thinking",
                                        prompt: "Use Opus.", files: [])
        let worker = try coordinator.spawnTeammate(in: tempDir.path, agent: .agy,
                                                   model: "claude-opus-4-6-thinking", asWorker: true)
        coordinator.terminals.session(id: worker.id)?.terminalView.feed(text: "model not recognized\r\n")

        coordinator.dispatchTasks(workspacePath: tempDir.path, inboxStore: inbox)

        XCTAssertEqual(try inbox.task(id: task.id)?.state, .queued)
        XCTAssertNotNil(coordinator.store.session(id: worker.id))
    }

    /// A launch that throws fails the queued model task with the launch's own error.
    func testALaunchThatThrowsFailsTheQueuedModelTaskWithTheLaunchError() throws {
        let coordinator = makeCoordinator(installed: [])
        defer { coordinator.shutdown() }
        let inbox = InboxStore(workspaceRoot: tempDir.path)
        let task = try inbox.createTask(from: .claude, to: .agy, model: "claude-opus-4-6-thinking",
                                        prompt: "Use Opus.", files: [])

        coordinator.dispatchTasks(workspacePath: tempDir.path, inboxStore: inbox)

        let failed = try XCTUnwrap(inbox.task(id: task.id))
        XCTAssertEqual(failed.state, .failed)
        let reason = try XCTUnwrap(failed.cancelReason)
        XCTAssertTrue(reason.contains("Executable for"), reason)
        XCTAssertTrue(reason.contains("claude-opus-4-6-thinking"), reason)
        XCTAssertFalse(reason.hasSuffix(": "), "the reason is the launch's error, not an empty line: \(reason)")
        let told = try inbox.load().messages.filter { $0.taskId == task.id && $0.toAgent == .claude }
        XCTAssertTrue(told.contains { $0.prompt.contains("failed") }, told.map(\.prompt).joined(separator: "\n"))
    }

    /// A tier task keeps today's behaviour when its launch throws: it stays queued, and the failure is recorded.
    func testALaunchThatThrowsLeavesATierTaskQueued() throws {
        let coordinator = makeCoordinator(installed: [])
        defer { coordinator.shutdown() }
        let inbox = InboxStore(workspaceRoot: tempDir.path)
        let task = try inbox.createTask(from: .claude, to: .agy, tier: .standard, prompt: "Flash.", files: [])

        coordinator.dispatchTasks(workspacePath: tempDir.path, inboxStore: inbox)

        XCTAssertEqual(try inbox.task(id: task.id)?.state, .queued)
        XCTAssertNotNil(coordinator.lastSpawnFailure)
    }

    /// A worker the user closes while it is starting did not reject anything: the task stays queued.
    func testAModelWorkerTheUserClosesWhileStartingFailsNothing() throws {
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }
        let inbox = InboxStore(workspaceRoot: tempDir.path)
        let task = try inbox.createTask(from: .claude, to: .agy, model: "claude-opus-4-6-thinking",
                                        prompt: "Use Opus.", files: [])
        let worker = try coordinator.spawnTeammate(in: tempDir.path, agent: .agy,
                                                   model: "claude-opus-4-6-thinking", asWorker: true)
        XCTAssertEqual(coordinator.store.session(id: worker.id)?.state, .starting)

        coordinator.stopSession(worker.id)

        XCTAssertEqual(try inbox.task(id: task.id)?.state, .queued)
        XCTAssertFalse(try inbox.load().messages.contains { $0.taskId == task.id })
    }

    /// The same exit for a tier task keeps today's behaviour: the task stays queued.
    func testATierWorkerThatExitsAtLaunchLeavesItsTaskQueued() async throws {
        let coordinator = makeCoordinator(agent: exitingAgent(printing: "Error: boom"))
        defer { coordinator.shutdown() }
        let inbox = InboxStore(workspaceRoot: tempDir.path)
        let task = try inbox.createTask(from: .claude, to: .agy, tier: .standard, prompt: "Flash.", files: [])

        coordinator.dispatchTasks(workspacePath: tempDir.path, inboxStore: inbox)
        let gone = try await waitUntil { coordinator.store.sessions.isEmpty }
        XCTAssertTrue(gone, "the worker never exited")

        XCTAssertEqual(try inbox.task(id: task.id)?.state, .queued)
    }

    // MARK: - Recovery from a rate-limited state is pool-aware

    /// A Gemini session in the error state recovers once the Gemini pool is free, even while the
    /// Claude/GPT pool is limited: its own model's pool decides.
    func testAGeminiSessionRecoversWhileOnlyTheClaudePoolIsLimited() throws {
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }
        let inbox = InboxStore(workspaceRoot: ProjectPath.canonical(tempDir.path))
        try inbox.recordLimit(agent: .agy, reason: "quota exceeded", cooldown: 3600, pool: "claude-gpt")
        let session = try coordinator.newSession(cwd: ProjectPath.canonical(tempDir.path), agent: .agy,
                                                 model: "gemini-3.8-flash-medium")
        coordinator.store.updateState(id: session.id, to: .error)

        coordinator.sampleAgentStates()

        XCTAssertNotEqual(coordinator.store.session(id: session.id)?.state, .error)
    }

    /// And stays in the error state while its own pool is limited.
    func testAGeminiSessionStaysLimitedWhileItsOwnPoolIsLimited() throws {
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }
        let inbox = InboxStore(workspaceRoot: ProjectPath.canonical(tempDir.path))
        try inbox.recordLimit(agent: .agy, reason: "quota exceeded", cooldown: 3600, pool: "gemini")
        let session = try coordinator.newSession(cwd: ProjectPath.canonical(tempDir.path), agent: .agy,
                                                 model: "gemini-3.8-flash-medium")
        coordinator.store.updateState(id: session.id, to: .error)

        coordinator.sampleAgentStates()

        XCTAssertEqual(coordinator.store.session(id: session.id)?.state, .error)
    }

    // MARK: - A typed model matches a listed one in any case

    func testSwitchModelSendsTheListedIdWhenTheTypedOneDiffersInCase() throws {
        let lists: @Sendable () throws -> [AgentKind: AgentModelList] = {
            [.agy: AgentModelList(models: [ListedModel(id: "gemini-3.8-flash-medium", name: "Flash")],
                                  fetchedAt: Date(), error: nil)]
        }
        let coordinator = makeCoordinator(lists: lists)
        defer { coordinator.shutdown() }
        let session = try coordinator.newSession(cwd: tempDir.path, agent: .agy, model: "gemini-3.8-flash-low")
        coordinator.store.updateState(id: session.id, to: .ready)

        let message = try coordinator.switchModel(in: tempDir.path, agent: .agy, to: "Gemini-3.8-Flash-Medium")

        XCTAssertTrue(message.contains("'gemini-3.8-flash-medium'"), message)
        XCTAssertEqual(coordinator.recentlyInjectedTexts(sessionId: session.id).last, "/model gemini-3.8-flash-medium")
    }
}

import XCTest
@testable import LinkCKit

/// Cross-project tasks: return address, pointers, ask, and (later) pointer-following tools.
final class CrossProjectTasksTests: XCTestCase {
    private var tempDir: URL!
    private var home: URL!
    private var away: URL!
    private var file: KnownProjectsFile!
    private var homeInbox: InboxStore!
    private var awayInbox: InboxStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-xproj-tasks-\(UUID().uuidString)")
        home = tempDir.appendingPathComponent("money-printer")
        away = tempDir.appendingPathComponent("away")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: away, withIntermediateDirectories: true)
        file = KnownProjectsFile(url: tempDir.appendingPathComponent("projects.json"))
        homeInbox = InboxStore(workspaceRoot: home.path)
        awayInbox = InboxStore(workspaceRoot: away.path)
        try file.write([
            KnownProject(path: ProjectPath.canonical(home.path), sessions: [
                .init(id: "home-claude", agent: "claude", activity: .idle)
            ]),
            KnownProject(path: ProjectPath.canonical(away.path), sessions: [
                .init(id: "away-codex", agent: "codex", activity: .idle)
            ])
        ])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private func homeServer() -> MCPServer {
        MCPServer(workspaceRoot: home.path, inboxStore: homeInbox,
                  environment: ["LINKC_AGENT": "claude", "LINKC_SESSION": "home-claude"],
                  ancestorResolver: { _ in nil }, modelSettings: { .seeded },
                  sessionResolver: { nil }, usageReaders: [:], modelLists: TestModelLists.none, knownProjects: file)
    }

    private func call(_ server: MCPServer, _ tool: String, _ arguments: [String: Any]) throws -> (text: String, isError: Bool) {
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                      "params": ["name": tool, "arguments": arguments]]
        let response = try XCTUnwrap(server.handleMessage(try JSONSerialization.data(withJSONObject: request)))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: response) as? [String: Any])
        let result = try XCTUnwrap(json["result"] as? [String: Any])
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        return (text, result["isError"] as? Bool ?? false)
    }

    // MARK: - Model / store

    func testOldInboxWithoutSentTasksOrFromProjectStillLoads() throws {
        let json = """
        {"version":2,"workspacePath":"/p","updatedAt":"2026-01-01T00:00:00Z","messages":[],"agentLimits":[],"tasks":[{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","fromAgent":"claude","toAgent":"codex","prompt":"hi","files":[],"state":"queued","hop":0,"createdAt":"2026-01-01T00:00:00Z","leaseExpiresAt":"2026-01-01T04:00:00Z","unreportedTurnEndNotified":false}]}
        """
        let url = home.appendingPathComponent(".linkc/inbox.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
        let inbox = try homeInbox.load()
        XCTAssertTrue(inbox.sentTasks.isEmpty)
        XCTAssertNil(inbox.tasks.first?.fromProject)
        XCTAssertFalse(inbox.tasks.first?.isQuestion ?? true)
    }

    func testCreateTaskStoresFromProjectAndQuestion() throws {
        let task = try awayInbox.createTask(
            from: .claude, to: .codex, prompt: "q", files: [],
            fromProject: ProjectPath.canonical(home.path), isQuestion: true
        )
        XCTAssertEqual(task.fromProject, ProjectPath.canonical(home.path))
        XCTAssertTrue(task.isQuestion)
        XCTAssertEqual(task.question, true)
    }

    func testSentTaskPointerRoundTrip() throws {
        let id = UUID().uuidString
        try homeInbox.recordSent(SentTask(taskId: id, project: ProjectPath.canonical(away.path), fromSessionId: "home-claude"))
        let found = try XCTUnwrap(homeInbox.sentTask(matching: String(id.prefix(8))))
        XCTAssertEqual(found.taskId, id)
        XCTAssertEqual(try homeInbox.sentTasks().count, 1)
        try homeInbox.dropSent(taskId: id)
        XCTAssertTrue(try homeInbox.sentTasks().isEmpty)

        let a = "aaaaaaaa-1111-4111-8111-111111111111"
        let b = "aaaaaaaa-2222-4222-8222-222222222222"
        try homeInbox.recordSent(SentTask(taskId: a, project: "/p/a"))
        try homeInbox.recordSent(SentTask(taskId: b, project: "/p/b"))
        XCTAssertThrowsError(try homeInbox.sentTask(matching: "aaaaaaaa")) { error in
            guard case InboxError.ambiguousTaskId = error else {
                return XCTFail("expected ambiguousTaskId, got \(error)")
            }
        }
    }

    // MARK: - deliveryFrame

    @MainActor
    func testDeliveryFrameNamesTheSendingProjectAndQuestionInstructions() {
        let task = TaskRecord(
            fromAgent: .claude, toAgent: .codex, prompt: "What is the ledger?",
            fromProject: "/p/money-printer", isQuestion: true
        )
        let frame = AppCoordinator.deliveryFrame(for: task)
        XCTAssertTrue(frame.hasPrefix("\(LinkCFrame.taskPrefix) \(task.shortId) from money-printer · Claude Code]"), frame)
        XCTAssertTrue(frame.contains("This is a question from money-printer."), frame)
        XCTAssertTrue(frame.contains("linkc_complete_task(\"\(task.id)\""), frame)
        XCTAssertFalse(frame.contains("commit your work"), frame)

        let local = TaskRecord(fromAgent: .claude, toAgent: .codex, prompt: "work")
        let localFrame = AppCoordinator.deliveryFrame(for: local)
        XCTAssertTrue(localFrame.hasPrefix("\(LinkCFrame.taskPrefix) \(local.shortId) from Claude Code]"), localFrame)
        XCTAssertTrue(localFrame.contains("commit your work"), localFrame)
    }

    // MARK: - linkc_delegate_task(project:)

    func testDelegateTaskWithProjectWritesTargetAndPointer() throws {
        let result = try call(homeServer(), "linkc_delegate_task", [
            "project": "away", "to": "codex", "prompt": "fix the ledger"
        ])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("away") || result.text.lowercased().contains("away"), result.text)

        let task = try XCTUnwrap(awayInbox.openTasks().first)
        XCTAssertEqual(task.fromProject, ProjectPath.canonical(home.path))
        XCTAssertEqual(task.fromSessionId, "home-claude")
        XCTAssertEqual(task.toAgent, .codex)
        XCTAssertTrue(try homeInbox.fetchPending().isEmpty)

        let pointer = try XCTUnwrap(homeInbox.sentTasks().first)
        XCTAssertEqual(pointer.taskId, task.id)
        XCTAssertEqual(pointer.project, ProjectPath.canonical(away.path))
        XCTAssertEqual(pointer.fromSessionId, "home-claude")
        XCTAssertTrue(result.text.contains(task.shortId), result.text)
    }

    func testDelegateTaskUnknownProjectWritesNothing() throws {
        let result = try call(homeServer(), "linkc_delegate_task", [
            "project": "ghost", "to": "codex", "prompt": "nope"
        ])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(try awayInbox.openTasks().isEmpty)
        XCTAssertTrue(try homeInbox.sentTasks().isEmpty)
        XCTAssertTrue(try homeInbox.openTasks().isEmpty)
    }

    func testDelegateTaskRespectsLeaseInTargetProject() throws {
        _ = try awayInbox.createTask(from: .claude, to: .cursor, prompt: "hold", files: ["Sources/A.swift"])
        let result = try call(homeServer(), "linkc_delegate_task", [
            "project": "away", "to": "codex", "prompt": "also A", "files": ["Sources/A.swift"]
        ])
        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(result.text.lowercased().contains("lease") || result.text.lowercased().contains("refused"), result.text)
        XCTAssertEqual(try awayInbox.openTasks().count, 1)
        XCTAssertTrue(try homeInbox.sentTasks().isEmpty)
    }

    // MARK: - linkc_ask

    func testAskCreatesQuestionTaskAndPointer() throws {
        let result = try call(homeServer(), "linkc_ask", [
            "project": "away", "question": "How is the ledger?"
        ])
        XCTAssertFalse(result.isError, result.text)
        let task = try XCTUnwrap(awayInbox.openTasks().first)
        XCTAssertTrue(task.isQuestion)
        XCTAssertEqual(task.toAgent, .claude)
        XCTAssertTrue(task.files.isEmpty)
        XCTAssertEqual(task.fromProject, ProjectPath.canonical(home.path))
        XCTAssertEqual(try homeInbox.sentTasks().first?.taskId, task.id)
    }

    func testAskRefusesFreebuffBecauseItIsOnlyForLongRunningWork() throws {
        let result = try call(homeServer(), "linkc_ask", [
            "project": "away", "to": "freebuff", "question": "Quick status?"
        ])
        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(result.text.contains("Freebuff is for long-running work; ask another agent."), result.text)
        XCTAssertTrue(try awayInbox.openTasks().isEmpty)
    }

    func testAskRefusesMissingArgsAndVerify() throws {
        XCTAssertTrue(try call(homeServer(), "linkc_ask", ["question": "x"]).isError)
        XCTAssertTrue(try call(homeServer(), "linkc_ask", ["project": "away"]).isError)
        let verified = try call(homeServer(), "linkc_ask", [
            "project": "away", "question": "x",
            "verify": ["branch": "b", "base_sha": "deadbeef", "command": "true", "test_paths": ["t"]]
        ])
        XCTAssertTrue(verified.isError)
        XCTAssertTrue(verified.text.lowercased().contains("verified") || verified.text.lowercased().contains("verify"), verified.text)
    }

    // MARK: - Pointer-following tools (A4)

    private func delegateToAway(prompt: String = "fix away") throws -> TaskRecord {
        let result = try call(homeServer(), "linkc_delegate_task", [
            "project": "away", "to": "codex", "prompt": prompt
        ])
        XCTAssertFalse(result.isError, result.text)
        return try XCTUnwrap(awayInbox.openTasks().first)
    }

    func testGetTaskFollowsTheSentPointer() throws {
        let task = try delegateToAway()
        let result = try call(homeServer(), "linkc_get_task", ["task_id": task.shortId])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains(task.id), result.text)
        XCTAssertTrue(result.text.contains("fix away"), result.text)
    }

    func testCancelTaskFromHomeCancelsInAwayWithStopNotice() throws {
        let task = try delegateToAway()
        try awayInbox.markTaskDelivered(taskId: task.id, sessionId: "away-worker")
        let result = try call(homeServer(), "linkc_cancel_task", ["task_id": task.shortId, "reason": "no longer needed"])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(try awayInbox.task(id: task.id)?.state, .cancelled)
        let stop = try XCTUnwrap(awayInbox.load().messages.first { $0.taskId == task.id })
        XCTAssertEqual(stop.toSessionId, "away-worker")
        XCTAssertTrue(stop.prompt.contains("cancelled"), stop.prompt)
    }

    func testCloseWorkerFromHomeWritesInAway() throws {
        let task = try delegateToAway()
        try awayInbox.markTaskDelivered(taskId: task.id, sessionId: "away-worker")
        try awayInbox.markTaskStarted(taskId: task.id)
        try awayInbox.reportTask(taskId: task.id, report: TaskReport(status: "done", summary: "done"))
        try awayInbox.acceptUnverified(taskId: task.id)
        let wait = MCPServer.CloseAnswerWait(timeout: 0, interval: 0.01, sleep: { _ in })
        let server = MCPServer(
            workspaceRoot: home.path, inboxStore: homeInbox,
            environment: ["LINKC_AGENT": "claude", "LINKC_SESSION": "home-claude"],
            ancestorResolver: { _ in nil }, modelSettings: { .seeded },
            sessionResolver: { nil }, usageReaders: [:],
            closeAnswerWait: wait, modelLists: TestModelLists.none, knownProjects: file
        )
        let result = try call(server, "linkc_close_worker", ["task_id": task.shortId])
        let recorded = try XCTUnwrap(awayInbox.task(id: task.id)?.closeRequest)
        XCTAssertEqual(recorded.by, .delegator)
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("Close"), result.text)
    }

    func testMyTasksListsDelegatedWithProjectArrow() throws {
        let task = try delegateToAway(prompt: "list me")
        let result = try call(homeServer(), "linkc_my_tasks", [:])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains(task.shortId), result.text)
        XCTAssertTrue(result.text.contains("→ away"), result.text)
    }

    func testSendMessageWithTaskIdEnqueuesInAway() throws {
        let task = try delegateToAway()
        try awayInbox.markTaskDelivered(taskId: task.id, sessionId: "away-worker")
        let result = try call(homeServer(), "linkc_send_message", [
            "to": "codex", "message": "nudge", "task_id": task.shortId
        ])
        XCTAssertFalse(result.isError, result.text)
        let msg = try XCTUnwrap(awayInbox.fetchPending().first)
        XCTAssertEqual(msg.toSessionId, "away-worker")
        XCTAssertTrue(try homeInbox.fetchPending().isEmpty)
    }

    func testAMessageToTheWorkerOfASentTaskCarriesItsOriginAndTheCrossProjectCap() throws {
        let task = try delegateToAway()
        try awayInbox.markTaskDelivered(taskId: task.id, sessionId: "away-worker")

        let tooLong = try call(homeServer(), "linkc_send_message", [
            "to": "codex", "message": String(repeating: "x", count: PendingMessage.crossProjectMessageLimit + 1),
            "task_id": task.shortId
        ])
        XCTAssertTrue(tooLong.isError)
        XCTAssertTrue(tooLong.text.hasPrefix("Messages to another project are at most 2,000 characters."), tooLong.text)
        XCTAssertTrue(try awayInbox.fetchPending().isEmpty)

        let sent = try call(homeServer(), "linkc_send_message", ["to": "codex", "message": "nudge", "task_id": task.shortId])
        XCTAssertFalse(sent.isError, sent.text)
        let message = try XCTUnwrap(awayInbox.fetchPending().first)
        XCTAssertEqual(message.fromProject, ProjectPath.canonical(home.path))
        XCTAssertEqual(message.fromSessionId, "home-claude")
        XCTAssertTrue(message.prompt.contains("money-printer"), message.prompt)
    }

    func testSwitchModelWithTaskIdEnqueuesInAwayOrCallsSwitcherWithAwayPath() throws {
        let task = try delegateToAway()
        try awayInbox.markTaskDelivered(taskId: task.id, sessionId: "away-worker")
        let model = try XCTUnwrap(AgentModelSettings.seeded.model(for: .codex, tier: .light))

        let enqueued = try call(homeServer(), "linkc_switch_model", ["model": model, "task_id": task.id])
        XCTAssertFalse(enqueued.isError, enqueued.text)
        let cmd = try XCTUnwrap(awayInbox.fetchPending().first { $0.kind == .command })
        XCTAssertEqual(cmd.toSessionId, "away-worker")

        final class Seen: @unchecked Sendable {
            var workspace: String?
            var sessionId: String??
        }
        let seen = Seen()
        let switching = MCPServer(
            workspaceRoot: home.path, inboxStore: homeInbox,
            modelSwitcher: { _, _, sessionId, workspace in
                seen.workspace = workspace
                seen.sessionId = sessionId
                return "switched"
            },
            environment: ["LINKC_AGENT": "claude", "LINKC_SESSION": "home-claude"],
            ancestorResolver: { _ in nil }, modelSettings: { .seeded },
            sessionResolver: { nil }, usageReaders: [:], modelLists: TestModelLists.none, knownProjects: file
        )
        let switched = try call(switching, "linkc_switch_model", ["model": model, "task_id": task.id])
        XCTAssertFalse(switched.isError, switched.text)
        XCTAssertEqual(seen.workspace, ProjectPath.canonical(away.path))
        XCTAssertEqual(seen.sessionId, .some("away-worker"))
    }

    func testStalePointerIsDroppedWhenTaskIsGone() throws {
        let task = try delegateToAway()
        var inbox = try awayInbox.load()
        inbox.tasks.removeAll { $0.id == task.id }
        try awayInbox.saveRaw(inbox)
        let result = try call(homeServer(), "linkc_get_task", ["task_id": task.shortId])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.lowercased().contains("not found"), result.text)
        XCTAssertTrue(try homeInbox.sentTasks().isEmpty)
    }

    // MARK: - Review fixes

    private func server(
        root: URL, inbox: InboxStore, agent: String, session: String,
        openCodeModels: @escaping MCPServer.OpenCodeModelLister = { _ in [] }
    ) -> MCPServer {
        MCPServer(workspaceRoot: root.path, inboxStore: inbox,
                  environment: ["LINKC_AGENT": agent, "LINKC_SESSION": session],
                  ancestorResolver: { _ in nil }, modelSettings: { .seeded },
                  sessionResolver: { nil }, usageReaders: [:],
                  openCodeModels: openCodeModels, modelLists: TestModelLists.none, knownProjects: file)
    }

    /// The codex worker that holds tasks in `away`.
    private func awayWorker() -> MCPServer {
        server(root: away, inbox: awayInbox, agent: "codex", session: "away-worker")
    }

    private func hold(_ hop: Int, in inbox: InboxStore, as session: String, prompt: String = "held") throws -> TaskRecord {
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: prompt, files: [], hop: hop)
        try inbox.markTaskDelivered(taskId: task.id, sessionId: session)
        return task
    }

    func testReplaceSentPointsTheSendersRecordAtTheCopyAndKeepsItsOwnerAndSession() throws {
        let old = UUID().uuidString
        let new = UUID().uuidString
        let created = Date(timeIntervalSince1970: 1_000)
        try homeInbox.recordSent(SentTask(taskId: old, project: "/p/away", fromSessionId: "home-claude", createdAt: created))

        XCTAssertTrue(try homeInbox.replaceSent(taskId: old, with: new))

        let pointers = try homeInbox.sentTasks()
        XCTAssertEqual(pointers.map(\.taskId), [new])
        XCTAssertEqual(pointers.first?.project, "/p/away")
        XCTAssertEqual(pointers.first?.fromSessionId, "home-claude")
        XCTAssertEqual(pointers.first?.createdAt, created)
    }

    func testReplaceSentWithNoPointerChangesNothingAndSaysSo() throws {
        XCTAssertFalse(try homeInbox.replaceSent(taskId: UUID().uuidString, with: UUID().uuidString))
        XCTAssertTrue(try homeInbox.sentTasks().isEmpty)
    }

    // MARK: A stale known project is not recreated

    func testDelegatingToAProjectWhoseFolderIsGoneIsRefusedAndNothingIsCreated() throws {
        let listedPath = ProjectPath.canonical(away.path)
        try FileManager.default.removeItem(at: away)

        let delegated = try call(homeServer(), "linkc_delegate_task", ["project": "away", "to": "codex", "prompt": "fix"])
        let asked = try call(homeServer(), "linkc_ask", ["project": "away", "question": "why?"])

        for result in [delegated, asked] {
            XCTAssertTrue(result.isError, result.text)
            XCTAssertTrue(result.text.contains("away's folder \(listedPath) no longer exists"), result.text)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: away.path), "the refusal must not recreate the folder")
        XCTAssertTrue(try homeInbox.sentTasks().isEmpty)
    }

    // MARK: Hops count across projects (spec 5.3)

    func testAWorkerHoldingAHopTwoTaskCannotDelegateOrAskAnywhere() throws {
        _ = try hold(2, in: awayInbox, as: "away-worker")

        let toProject = try call(awayWorker(), "linkc_delegate_task", ["project": "money-printer", "to": "claude", "prompt": "go on"])
        let ask = try call(awayWorker(), "linkc_ask", ["project": "money-printer", "question": "and you?"])
        let local = try call(awayWorker(), "linkc_delegate_task", ["to": "cursor", "prompt": "local"])

        for result in [toProject, ask, local] {
            XCTAssertTrue(result.isError, result.text)
            XCTAssertTrue(result.text.contains("hop 3"), result.text)
        }
        XCTAssertTrue(try homeInbox.openTasks().isEmpty)
        XCTAssertEqual(try awayInbox.openTasks().count, 1, "only the task it already held")
        XCTAssertTrue(try awayInbox.sentTasks().isEmpty)
    }

    func testAWorkerHoldingAHopZeroTaskCreatesAHopOneTaskInTheOtherProject() throws {
        _ = try hold(0, in: awayInbox, as: "away-worker")

        let result = try call(awayWorker(), "linkc_delegate_task", ["project": "money-printer", "to": "claude", "prompt": "next"])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(try homeInbox.openTasks().first?.hop, 1)
    }

    func testAWorkerHoldingAHopOneTaskCreatesAHopTwoTaskLocally() throws {
        _ = try hold(1, in: awayInbox, as: "away-worker")

        let result = try call(awayWorker(), "linkc_delegate_task", ["to": "cursor", "prompt": "local"])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(try awayInbox.openTasks().first { $0.prompt == "local" }?.hop, 2)
    }

    func testASessionHoldingNothingStartsAtHopZero() throws {
        _ = try hold(2, in: awayInbox, as: "some-other-session")

        let result = try call(awayWorker(), "linkc_delegate_task", ["project": "money-printer", "to": "claude", "prompt": "fresh"])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(try homeInbox.openTasks().first?.hop, 0, "a task held by another session is not this caller's")
    }

    // MARK: start and complete are assignee tools

    func testTheAskingSessionCannotStartOrCompleteItsOwnCrossProjectAsk() throws {
        let asked = try call(homeServer(), "linkc_ask", ["project": "away", "question": "How is the ledger?"])
        XCTAssertFalse(asked.isError, asked.text)
        let task = try XCTUnwrap(awayInbox.openTasks().first)

        let started = try call(homeServer(), "linkc_start_task", ["task_id": task.shortId])
        let completed = try call(homeServer(), "linkc_complete_task", [
            "task_id": task.shortId, "status": "done", "summary": "I answered myself"
        ])

        for result in [started, completed] {
            XCTAssertTrue(result.isError, result.text)
            XCTAssertTrue(result.text.lowercased().contains("not found"), result.text)
        }
        XCTAssertEqual(try awayInbox.task(id: task.id)?.state, .queued)
        XCTAssertNil(try awayInbox.task(id: task.id)?.report)

        // A caller linkC cannot tell the session of (Codex's MCP servers, notably) is not locked out of an
        // assignee's tools, so only the lookup keeps it out of a task that lives in another project.
        try awayInbox.markTaskDelivered(taskId: task.id, sessionId: "away-claude")
        let unresolved = MCPServer(workspaceRoot: home.path, inboxStore: homeInbox,
                                   environment: ["LINKC_AGENT": "claude"],
                                   ancestorResolver: { _ in nil }, modelSettings: { .seeded },
                                   sessionResolver: { nil }, usageReaders: [:], modelLists: TestModelLists.none, knownProjects: file)
        let startedBlind = try call(unresolved, "linkc_start_task", ["task_id": task.shortId])
        let completedBlind = try call(unresolved, "linkc_complete_task", [
            "task_id": task.shortId, "status": "done", "summary": "I answered myself"
        ])
        for result in [startedBlind, completedBlind] {
            XCTAssertTrue(result.isError, result.text)
            XCTAssertTrue(result.text.lowercased().contains("not found"), result.text)
        }
        XCTAssertEqual(try awayInbox.task(id: task.id)?.state, .delivered)
    }

    // MARK: Who a cancel notice goes to

    private func delegatedLocally() throws -> TaskRecord {
        let task = try homeInbox.createTask(from: .claude, to: .codex, fromSessionId: "home-claude", prompt: "local work", files: [])
        try homeInbox.markTaskDelivered(taskId: task.id, sessionId: "home-worker")
        return task
    }

    func testTheDelegatorCancellingALocalTaskTellsTheWorker() throws {
        let task = try delegatedLocally()

        let result = try call(homeServer(), "linkc_cancel_task", ["task_id": task.shortId, "reason": "changed my mind"])

        XCTAssertFalse(result.isError, result.text)
        let notice = try XCTUnwrap(homeInbox.load().messages.first { $0.taskId == task.id })
        XCTAssertEqual(notice.toAgent, .codex)
        XCTAssertEqual(notice.toSessionId, "home-worker")
        XCTAssertTrue(notice.prompt.contains("cancelled: changed my mind. Stop work on it."), notice.prompt)
    }

    func testTheWorkerCancellingALocalTaskTellsTheDelegatorNotItself() throws {
        let task = try delegatedLocally()
        let worker = server(root: home, inbox: homeInbox, agent: "codex", session: "home-worker")

        let result = try call(worker, "linkc_cancel_task", ["task_id": task.shortId, "reason": "cannot be done"])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(try homeInbox.task(id: task.id)?.state, .cancelled)
        let notice = try XCTUnwrap(homeInbox.load().messages.first { $0.taskId == task.id })
        XCTAssertEqual(notice.toAgent, .claude, "the delegator is told")
        XCTAssertNil(notice.toSessionId, "not addressed to a session, so it reaches the delegator")
        XCTAssertTrue(notice.prompt.contains("cancelled by its worker: cannot be done"), notice.prompt)
    }

    func testAForcedCancelByAnotherAgentStillStopsTheWorker() throws {
        let task = try delegatedLocally()
        let bystander = server(root: home, inbox: homeInbox, agent: "cursor", session: "home-cursor")

        let result = try call(bystander, "linkc_cancel_task", ["task_id": task.shortId, "force": true])

        XCTAssertFalse(result.isError, result.text)
        let notice = try XCTUnwrap(homeInbox.load().messages.first { $0.taskId == task.id })
        XCTAssertEqual(notice.toAgent, .codex)
        XCTAssertEqual(notice.toSessionId, "home-worker")
    }

    func testTheWorkerCancellingACrossProjectTaskTellsTheDelegatorAtHome() throws {
        let task = try delegateToAway()
        try awayInbox.markTaskDelivered(taskId: task.id, sessionId: "away-worker")

        let result = try call(awayWorker(), "linkc_cancel_task", ["task_id": task.shortId, "reason": "cannot be done"])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(try awayInbox.task(id: task.id)?.state, .cancelled)
        let notice = try XCTUnwrap(awayInbox.load().messages.first { $0.taskId == task.id })
        XCTAssertEqual(notice.toAgent, .claude)
        XCTAssertNil(notice.toSessionId, "with no addressee the relay forwards it to the sending project")
        XCTAssertTrue(notice.prompt.contains("cancelled by its worker: cannot be done"), notice.prompt)
    }

    // MARK: linkc_my_tasks drops a pointer whose task is gone

    func testMyTasksDropsAPointerWhoseTaskIsGoneFromTheTargetInbox() throws {
        let task = try delegateToAway(prompt: "will vanish")
        var inbox = try awayInbox.load()
        inbox.tasks.removeAll { $0.id == task.id }
        try awayInbox.saveRaw(inbox)

        let result = try call(homeServer(), "linkc_my_tasks", [:])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertFalse(result.text.contains(task.shortId), result.text)
        XCTAssertTrue(try homeInbox.sentTasks().isEmpty, "a pointer to nothing is dropped, not skipped every time")
    }

    func testMyTasksKeepsAPointerWhoseTaskIsFinished() throws {
        let task = try delegateToAway(prompt: "finished")
        try awayInbox.cancelTask(taskId: task.id, reason: "done with it")

        let result = try call(homeServer(), "linkc_my_tasks", [:])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(try homeInbox.sentTasks().map(\.taskId), [task.id], "get_task can still read a finished task")
    }

    // MARK: Delegated files are claimed where the work happens

    func testFilesDelegatedToAnotherProjectAreClaimedOnItsBlackboardNotTheSenders() throws {
        let result = try call(homeServer(), "linkc_delegate_task", [
            "project": "away", "to": "codex", "prompt": "touch A", "files": ["Sources/A.swift"]
        ])
        XCTAssertFalse(result.isError, result.text)

        let senders = try BlackboardStore(workspaceRoot: home.path).load().activeAgents.flatMap(\.claimedFiles)
        let targets = try BlackboardStore(workspaceRoot: away.path).load().activeAgents.flatMap(\.claimedFiles)
        XCTAssertTrue(senders.isEmpty, "target-relative paths must not land on the sender's board: \(senders)")
        XCTAssertEqual(targets, ["Sources/A.swift"])
    }

    // MARK: Every check runs against the target project

    func testDelegatingToAnAgentInLimitCooldownInTheTargetProjectIsRefused() throws {
        try awayInbox.recordLimit(agent: .codex, reason: "429", cooldown: 3600)

        let result = try call(homeServer(), "linkc_delegate_task", ["project": "away", "to": "codex", "prompt": "fix"])

        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(result.text.contains("codex is limited until"), result.text)
        XCTAssertTrue(result.text.contains("(429)"), result.text)
        XCTAssertTrue(try awayInbox.openTasks().isEmpty)
        XCTAssertTrue(try homeInbox.sentTasks().isEmpty)
    }

    func testTheOpenCodeModelListingRunsForTheTargetFolder() throws {
        final class Seen: @unchecked Sendable { var folders: [String] = [] }
        let seen = Seen()
        let offered = AgentModelSettings.seeded.models[AgentKind.opencode.rawValue]?.values.map { $0 } ?? []
        let sender = server(root: home, inbox: homeInbox, agent: "claude", session: "home-claude",
                            openCodeModels: { folder in seen.folders.append(folder); return offered })

        let result = try call(sender, "linkc_delegate_task", ["project": "away", "to": "opencode", "prompt": "fix"])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(seen.folders, [ProjectPath.canonical(away.path)])
    }

    func testAFailedPointerWriteIsReportedWithTheTaskIdTheTargetNowHolds() throws {
        // A readable inbox in `home` whose folder can no longer take a write: the task is created in
        // `away`, and only the pointer cannot be saved.
        _ = try homeInbox.enqueue(from: .claude, to: .codex, kind: .peerNote, body: "seed")
        let linkc = home.appendingPathComponent(".linkc")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: linkc.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: linkc.path) }

        let result = try call(homeServer(), "linkc_delegate_task", ["project": "away", "to": "codex", "prompt": "fix"])

        let created = try XCTUnwrap(awayInbox.openTasks().first)
        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(result.text.contains(created.id), result.text)
        XCTAssertTrue(result.text.contains("won't track"), result.text)
    }
}

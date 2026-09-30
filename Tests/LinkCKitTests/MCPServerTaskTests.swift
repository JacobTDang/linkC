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
        MCPServer(workspaceRoot: tempDir.path, environment: ["LINKC_AGENT": agent.rawValue],
                  ancestorResolver: { _ in nil }, sessionResolver: { nil }, usageReaders: [:])
    }

    private func server(as agent: AgentKind, models: AgentModelSettings,
                        readers: [AgentKind: MCPServer.UsageReader] = [:],
                        warnCapableAgents: Set<AgentKind> = MCPServer.defaultWarnCapableAgents) -> MCPServer {
        MCPServer(workspaceRoot: tempDir.path,
                  environment: ["LINKC_AGENT": agent.rawValue],
                  ancestorResolver: { _ in nil },
                  modelSettings: { models },
                  sessionResolver: { nil },
                  usageReaders: readers,
                  warnCapableAgents: warnCapableAgents)
    }

    /// A caller with a fixed session, delivered through `LINKC_SESSION` the way most agents pass
    /// it, but with the ancestry fallback stubbed so the test never reads real processes.
    private func server(as agent: AgentKind, session: String) -> MCPServer {
        MCPServer(workspaceRoot: tempDir.path,
                  environment: ["LINKC_AGENT": agent.rawValue, "LINKC_SESSION": session],
                  ancestorResolver: { _ in nil }, sessionResolver: { nil }, usageReaders: [:])
    }

    func testStartTaskMovesDeliveredToStarted() throws {
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "Build", files: [])
        try inbox.markTaskDelivered(taskId: task.id, sessionId: "s1")
        let res = try mcpCall(server(as: .codex), "linkc_start_task", ["task_id": task.id])
        XCTAssertFalse(res.isError, res.text)
        XCTAssertEqual(try inbox.task(id: task.id)?.state, .started)
        XCTAssertTrue(res.text.contains(task.shortId))
    }

    func testStartTaskOnQueuedTaskIsAnError() throws {
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "Build", files: [])
        let res = try mcpCall(server(as: .codex), "linkc_start_task", ["task_id": task.id])
        XCTAssertTrue(res.isError)
        XCTAssertTrue(res.text.contains("queued"))
    }

    func testStartTaskByNonAssigneeIsRejected() throws {
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "Build", files: [])
        try inbox.markTaskDelivered(taskId: task.id, sessionId: "s1")

        let res = try mcpCall(server(as: .agy), "linkc_start_task", ["task_id": task.id])

        XCTAssertTrue(res.isError)
        XCTAssertTrue(res.text.contains("assigned to Codex"))
        XCTAssertEqual(try inbox.task(id: task.id)?.state, .delivered)
    }

    func testCompleteTaskRecordsReportAndWritesNothingElse() throws {
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "Build", files: [])
        try inbox.markTaskDelivered(taskId: task.id, sessionId: "s1")
        let srv = server(as: .codex)
        let res = try mcpCall(srv, "linkc_complete_task", [
            "task_id": task.id, "status": "done", "summary": "Implemented and tested.",
            "commits": ["abc1234"], "tests": ["accepted and ignored"]
        ])
        XCTAssertFalse(res.isError, res.text)
        XCTAssertEqual(res.text, "Reported. Unverified task.")
        let t = try XCTUnwrap(inbox.task(id: task.id))
        XCTAssertEqual(t.state, .reported)
        XCTAssertEqual(t.report?.commits, ["abc1234"])
        XCTAssertTrue(try inbox.load().messages.isEmpty, "the relay sends the outcome line, not the tool")
        XCTAssertTrue(try srv.store.load().sharedNotes.isEmpty, "the report lives only on the task")
    }

    func testCompleteTaskByNonAssigneeIsRejected() throws {
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "Build", files: [])
        try inbox.markTaskDelivered(taskId: task.id, sessionId: "s1")

        let res = try mcpCall(server(as: .agy), "linkc_complete_task", [
            "task_id": task.id,
            "status": "done",
            "summary": "Implemented."
        ])

        XCTAssertTrue(res.isError)
        XCTAssertTrue(res.text.contains("assigned to Codex"))
        XCTAssertEqual(try inbox.task(id: task.id)?.state, .delivered)
        XCTAssertFalse(try inbox.load().messages.contains { $0.kind == .completion })
    }

    func testCompleteTaskRequiresSummaryAndValidStatus() throws {
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "Build", files: [])
        try inbox.markTaskDelivered(taskId: task.id, sessionId: "s1")
        let srv = server(as: .codex)
        XCTAssertTrue(try mcpCall(srv, "linkc_complete_task", ["task_id": task.id, "status": "done", "summary": ""]).isError)
        XCTAssertTrue(try mcpCall(srv, "linkc_complete_task", ["task_id": task.id, "status": "maybe", "summary": "x"]).isError)
        XCTAssertTrue(try mcpCall(srv, "linkc_complete_task", ["task_id": "nope", "status": "done", "summary": "x"]).isError)
        XCTAssertEqual(try inbox.task(id: task.id)?.state, .delivered)
    }

    func testCancelTaskByDelegatorInjectsOneLineToAssignee() throws {
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "Build", files: [])
        try inbox.markTaskDelivered(taskId: task.id, sessionId: "s1")
        let res = try mcpCall(server(as: .claude), "linkc_cancel_task", ["task_id": task.id, "reason": "scope changed"])
        XCTAssertFalse(res.isError, res.text)
        XCTAssertEqual(try inbox.task(id: task.id)?.state, .cancelled)
        let msg = try XCTUnwrap(inbox.load().messages.first)
        XCTAssertEqual(msg.toAgent, .codex)
        XCTAssertEqual(msg.kind, .completion)
        XCTAssertTrue(msg.prompt.contains("cancelled: scope changed"))
    }

    func testCancelQueuedTaskIsSilentAndThirdPartyNeedsForce() throws {
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "Build", files: [])
        let denied = try mcpCall(server(as: .cursor), "linkc_cancel_task", ["task_id": task.id])
        XCTAssertTrue(denied.isError)
        let forced = try mcpCall(server(as: .cursor), "linkc_cancel_task", ["task_id": task.id, "force": true])
        XCTAssertFalse(forced.isError, forced.text)
        XCTAssertTrue(try inbox.load().messages.isEmpty, "queued cancel must not inject anything")
    }

    func testOnlyTheAssigneeSessionMayCompleteATask() throws {
        let task = try inbox.createTask(from: .claude, to: .codex, tier: .standard, prompt: "Build", files: [])
        try inbox.markTaskDelivered(taskId: task.id, sessionId: "session-A")

        let sibling = MCPServer(workspaceRoot: tempDir.path, inboxStore: inbox,
                                environment: ["LINKC_AGENT": "codex", "LINKC_SESSION": "session-B"],
                                ancestorResolver: { _ in nil }, modelSettings: { .seeded }, sessionResolver: { nil },
                                usageReaders: [:])
        let refused = try mcpCall(sibling, "linkc_complete_task", ["task_id": task.id, "status": "done", "summary": "I did it"])
        XCTAssertTrue(refused.isError, refused.text)
        XCTAssertEqual(try inbox.task(id: task.id)?.state, .delivered, "a sibling may not settle another session's task")

        let assignee = MCPServer(workspaceRoot: tempDir.path, inboxStore: inbox,
                                 environment: ["LINKC_AGENT": "codex", "LINKC_SESSION": "session-A"],
                                 ancestorResolver: { _ in nil }, modelSettings: { .seeded }, sessionResolver: { nil },
                                 usageReaders: [:])
        let ok = try mcpCall(assignee, "linkc_complete_task", ["task_id": task.id, "status": "done", "summary": "done"])
        XCTAssertFalse(ok.isError, ok.text)
    }

    func testAnUnknownSessionMayStillActWhenTheTaskHasNoAssignee() throws {
        // A queued task has no assignee yet, and a session-less caller (an agent started outside
        // linkC) must not be locked out of its own kind's work.
        let task = try inbox.createTask(from: .claude, to: .codex, tier: .standard, prompt: "Build", files: [])
        let res = try mcpCall(server(as: .codex, models: .seeded), "linkc_cancel_task", ["task_id": task.id, "reason": "not needed"])
        XCTAssertFalse(res.isError, res.text)
    }

    // MARK: - Session resolution (Codex: environment has no LINKC_SESSION)

    /// Codex spawns its MCP servers with only `LINKC_AGENT` set — the session id never lands in
    /// `environment`. `sessionResolver` stands in for the ancestry walk that recovers it from the
    /// Codex CLI process; `callerMayAct` must key off whatever it returns, exactly as if the
    /// session had arrived through `LINKC_SESSION` directly.
    func testSessionResolverStandsInForAnAbsentEnvironmentSession() throws {
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "Build", files: [])
        try inbox.markTaskDelivered(taskId: task.id, sessionId: "session-A")

        let sibling = MCPServer(workspaceRoot: tempDir.path, inboxStore: inbox,
                                environment: ["LINKC_AGENT": "codex"],
                                ancestorResolver: { _ in nil }, sessionResolver: { "session-B" },
                                usageReaders: [:])
        let refused = try mcpCall(sibling, "linkc_complete_task", ["task_id": task.id, "status": "done", "summary": "nope"])
        XCTAssertTrue(refused.isError, refused.text)
        XCTAssertEqual(try inbox.task(id: task.id)?.state, .delivered, "a sibling recovered via the resolver still may not settle another session's task")

        let assignee = MCPServer(workspaceRoot: tempDir.path, inboxStore: inbox,
                                 environment: ["LINKC_AGENT": "codex"],
                                 ancestorResolver: { _ in nil }, sessionResolver: { "session-A" },
                                 usageReaders: [:])
        let ok = try mcpCall(assignee, "linkc_complete_task", ["task_id": task.id, "status": "done", "summary": "done"])
        XCTAssertFalse(ok.isError, ok.text)
    }

    /// The relay must never hand a task back to its own delegator; that stamp is written from the
    /// same session lookup, so it must also work when the session only comes from the resolver.
    func testDelegateStampsFromSessionIdFromTheResolverWhenEnvironmentHasNoSession() throws {
        let srv = MCPServer(workspaceRoot: tempDir.path, inboxStore: inbox,
                            environment: ["LINKC_AGENT": "claude"],
                            ancestorResolver: { _ in nil }, modelSettings: { .seeded },
                            sessionResolver: { "session-Z" }, usageReaders: [:])
        let res = try mcpCall(srv, "linkc_delegate_task", ["to": "agy", "prompt": "Rename a file"])
        XCTAssertFalse(res.isError, res.text)
        let task = try XCTUnwrap(inbox.openTasks().first)
        XCTAssertEqual(task.fromSessionId, "session-Z")
    }

    /// A process's ancestry never changes while it runs, so the default resolver's real ancestor
    /// walk must run at most once for the life of a long-running `linkc-mcp` process rather than
    /// re-walking `sysctl` on every guarded tool call. `AncestorSessionCache.walk` stands in for
    /// that walk so this test can count invocations without reading real processes; this is the
    /// only place in the suite that ever touches the cache, so the result does not depend on test
    /// execution order.
    /// `walk`'s default closure fails fast (see its doc comment) when read under XCTest without
    /// an injected `sessionResolver` — but a trap can't be asserted against in-process, so this
    /// proves the detection it relies on instead: running inside this very test suite must read
    /// as "under XCTest" every time, not just when some other test happens to have linked it.
    func testAncestorSessionCacheDetectsRunningUnderXCTest() {
        XCTAssertTrue(AncestorSessionCache.isRunningUnderXCTest)
    }

    func testDefaultSessionResolverWalksTheAncestryAtMostOnce() throws {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var invocations = 0
            var count: Int { lock.withLock { invocations } }
            func increment() -> String? {
                lock.withLock { invocations += 1 }
                return "stub-session"
            }
        }
        let counter = Counter()
        AncestorSessionCache.walk = counter.increment

        // No `sessionResolver` argument: this is the real default, which now goes through the
        // cache instead of walking the ancestry fresh on every call.
        let server = MCPServer(workspaceRoot: tempDir.path, ancestorResolver: { _ in nil }, usageReaders: [:])

        XCTAssertEqual(server.sessionResolver(), "stub-session")
        XCTAssertEqual(server.sessionResolver(), "stub-session")
        XCTAssertEqual(server.sessionResolver(), "stub-session")
        XCTAssertEqual(counter.count, 1, "the ancestor walk must run at most once per process")
    }

    // MARK: - linkc_start_task session scoping (Finding 2)

    func testStartTaskBySiblingSessionIsRefusedAndByAssigneeSucceeds() throws {
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "Build", files: [])
        try inbox.markTaskDelivered(taskId: task.id, sessionId: "session-A")

        let refused = try mcpCall(server(as: .codex, session: "session-B"), "linkc_start_task", ["task_id": task.id])
        XCTAssertTrue(refused.isError, refused.text)
        XCTAssertEqual(try inbox.task(id: task.id)?.state, .delivered)

        let ok = try mcpCall(server(as: .codex, session: "session-A"), "linkc_start_task", ["task_id": task.id])
        XCTAssertFalse(ok.isError, ok.text)
        XCTAssertEqual(try inbox.task(id: task.id)?.state, .started)
    }

    // MARK: - linkc_cancel_task session scoping (Finding 3)

    func testCancelTaskSessionScoping() throws {
        // A sibling session of the assignee's kind, without the assignee's session, is refused.
        let assignedTask = try inbox.createTask(from: .claude, to: .codex, prompt: "Build", files: [])
        try inbox.markTaskDelivered(taskId: assignedTask.id, sessionId: "session-A")
        let siblingRefused = try mcpCall(server(as: .codex, session: "session-B"), "linkc_cancel_task", ["task_id": assignedTask.id])
        XCTAssertTrue(siblingRefused.isError, siblingRefused.text)
        XCTAssertEqual(try inbox.task(id: assignedTask.id)?.state, .delivered)

        // The assignee can cancel its own task.
        let ownTask = try inbox.createTask(from: .claude, to: .codex, prompt: "Build 2", files: [])
        try inbox.markTaskDelivered(taskId: ownTask.id, sessionId: "session-A")
        let ownCancel = try mcpCall(server(as: .codex, session: "session-A"), "linkc_cancel_task", ["task_id": ownTask.id])
        XCTAssertFalse(ownCancel.isError, ownCancel.text)
        XCTAssertEqual(try inbox.task(id: ownTask.id)?.state, .cancelled)

        // The delegator can cancel a task assigned to another session — the delegator branch is
        // unconditional and does not consult callerMayAct at all.
        let delegated = try inbox.createTask(from: .claude, to: .codex, prompt: "Build 3", files: [])
        try inbox.markTaskDelivered(taskId: delegated.id, sessionId: "session-A")
        let delegatorCancel = try mcpCall(server(as: .claude), "linkc_cancel_task", ["task_id": delegated.id])
        XCTAssertFalse(delegatorCancel.isError, delegatorCancel.text)
        XCTAssertEqual(try inbox.task(id: delegated.id)?.state, .cancelled)

        // force overrides a sibling that is neither the assignee nor the delegator.
        let forced = try inbox.createTask(from: .claude, to: .codex, prompt: "Build 4", files: [])
        try inbox.markTaskDelivered(taskId: forced.id, sessionId: "session-A")
        let forceCancel = try mcpCall(server(as: .codex, session: "session-B"), "linkc_cancel_task", ["task_id": forced.id, "force": true])
        XCTAssertFalse(forceCancel.isError, forceCancel.text)
        XCTAssertEqual(try inbox.task(id: forced.id)?.state, .cancelled)
    }

    // MARK: - linkc_my_tasks session scoping (Finding 4)

    func testMyTasksHidesATaskAssignedToASiblingSessionButKeepsUnassignedAndDelegatedRows() throws {
        let assignedToSibling = try inbox.createTask(from: .claude, to: .codex, prompt: "Sibling's task", files: [])
        try inbox.markTaskDelivered(taskId: assignedToSibling.id, sessionId: "session-A")
        let unassigned = try inbox.createTask(from: .claude, to: .codex, prompt: "Unassigned task", files: [])
        let delegatedByMe = try inbox.createTask(from: .codex, to: .cursor, prompt: "Delegated by me", files: [])

        let list = try mcpCall(server(as: .codex, session: "session-B"), "linkc_my_tasks")

        XCTAssertFalse(list.text.contains(assignedToSibling.shortId), "a sibling's assigned task must not be listed: \(list.text)")
        XCTAssertTrue(list.text.contains(unassigned.shortId), "an unassigned task stays visible: \(list.text)")
        XCTAssertTrue(list.text.contains(delegatedByMe.shortId), "the caller's own delegated section still lists it: \(list.text)")
    }

    func testGetTaskAndMyTasks() throws {
        let mine = try inbox.createTask(from: .claude, to: .codex, prompt: "Assigned to me", files: ["A.swift"])
        let delegated = try inbox.createTask(from: .codex, to: .cursor, prompt: "I delegated this", files: [])
        _ = try inbox.createTask(from: .claude, to: .agy, prompt: "Unrelated", files: [])

        let get = try mcpCall(server(as: .codex), "linkc_get_task", ["task_id": mine.id])
        XCTAssertFalse(get.isError)
        XCTAssertTrue(get.text.contains("Assigned to me"))
        XCTAssertTrue(get.text.contains("A.swift"))
        XCTAssertTrue(get.text.contains("queued"))

        let list = try mcpCall(server(as: .codex), "linkc_my_tasks")
        XCTAssertTrue(list.text.contains(mine.shortId))
        XCTAssertTrue(list.text.contains(delegated.shortId))
        XCTAssertFalse(list.text.contains("Unrelated"))
    }

    // MARK: - Verified tasks

    /// tempDir as a repository with check.sh committed on branch task/x; returns that commit.
    private func repoWithTests() throws -> String {
        try runGit(["init", "-q", "-b", "main"], in: tempDir)
        try "#!/bin/sh\ntest -f marker.txt\n".write(to: tempDir.appendingPathComponent("check.sh"), atomically: true, encoding: .utf8)
        try runGit(["add", "check.sh"], in: tempDir)
        try runGit(["commit", "-q", "-m", "tests"], in: tempDir)
        try runGit(["checkout", "-q", "-b", "task/x"], in: tempDir)
        return try runGit(["rev-parse", "HEAD"], in: tempDir)
    }

    private func verify(base: String, branch: String = "task/x", paths: [String] = ["check.sh"]) -> [String: Any] {
        ["branch": branch, "base_sha": base, "command": "./check.sh", "test_paths": paths]
    }

    func testDelegateWithVerifyCreatesAGatingTaskAtTheFullBase() throws {
        let base = try repoWithTests()
        let res = try mcpCall(server(as: .claude), "linkc_delegate_task",
                           ["to": "codex", "prompt": "Make check pass", "verify": verify(base: String(base.prefix(7))), "tier": "deep"])
        XCTAssertFalse(res.isError, res.text)
        let task = try XCTUnwrap(inbox.load().tasks.first)
        XCTAssertEqual(task.state, .gating)
        XCTAssertEqual(task.verification?.baseSha, base)
        XCTAssertEqual(task.verification?.timeoutSeconds, 600)
        XCTAssertEqual(res.text, "Task \(task.shortId) created. linkC will confirm the tests fail at \(base.prefix(7)) before delivery.")
    }

    func testDelegateWithVerifyRejectsBadReferences() throws {
        let base = try repoWithTests()
        let srv = server(as: .claude)
        let badBase = try mcpCall(srv, "linkc_delegate_task", ["to": "codex", "prompt": "A", "verify": verify(base: "deadbeef")])
        XCTAssertTrue(badBase.isError)
        XCTAssertTrue(badBase.text.contains("verify.base_sha"), badBase.text)

        let missingPath = try mcpCall(srv, "linkc_delegate_task", ["to": "codex", "prompt": "B", "verify": verify(base: base, paths: ["nope.sh"])])
        XCTAssertTrue(missingPath.isError)
        XCTAssertTrue(missingPath.text.contains("'nope.sh' does not exist at \(base.prefix(7))"), missingPath.text)

        try runGit(["checkout", "-q", "-b", "other"], in: tempDir)
        try "x\n".write(to: tempDir.appendingPathComponent("extra.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "extra.txt"], in: tempDir)
        try runGit(["commit", "-q", "-m", "moved"], in: tempDir)
        let movedBranch = try mcpCall(srv, "linkc_delegate_task", ["to": "codex", "prompt": "C", "verify": verify(base: base, branch: "other")])
        XCTAssertTrue(movedBranch.isError)
        XCTAssertTrue(movedBranch.text.contains("not base \(base.prefix(7))"), movedBranch.text)

        XCTAssertTrue(try inbox.load().tasks.isEmpty, "a rejected verify creates no task")
    }

    func testVerifiedCompleteNeedsTheShaOfARealCommit() throws {
        let base = try repoWithTests()
        _ = try mcpCall(server(as: .claude), "linkc_delegate_task", ["to": "codex", "prompt": "Make check pass", "verify": verify(base: base), "tier": "deep"])
        let task = try XCTUnwrap(inbox.load().tasks.first)
        try inbox.resolveGate(taskId: task.id, verdict: Verdict(passed: true, sha: base, exitStatus: 1, reason: nil, stdoutTail: "", stderrTail: ""))
        try inbox.markTaskDelivered(taskId: task.id, sessionId: "s1")
        let worker = server(as: .codex)

        let noSha = try mcpCall(worker, "linkc_complete_task", ["task_id": task.id, "status": "done", "summary": "added marker"])
        XCTAssertTrue(noSha.isError)
        XCTAssertEqual(noSha.text, InboxError.shaRequired.localizedDescription)
        let bogus = try mcpCall(worker, "linkc_complete_task", ["task_id": task.id, "status": "done", "summary": "added marker", "sha": "deadbeef"])
        XCTAssertTrue(bogus.isError)
        XCTAssertTrue(bogus.text.hasPrefix("Error: sha:"), bogus.text)
        XCTAssertEqual(try inbox.task(id: task.id)?.state, .delivered)

        try "ok\n".write(to: tempDir.appendingPathComponent("marker.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "marker.txt"], in: tempDir)
        try runGit(["commit", "-q", "-m", "fix"], in: tempDir)
        let sha = try runGit(["rev-parse", "HEAD"], in: tempDir)
        let reported = try mcpCall(worker, "linkc_complete_task",
                                ["task_id": task.id, "status": "done", "summary": "added marker", "sha": String(sha.prefix(7))])
        XCTAssertFalse(reported.isError, reported.text)
        XCTAssertEqual(reported.text, "Reported. linkC is verifying at \(sha.prefix(7)).")
        let t = try XCTUnwrap(inbox.task(id: task.id))
        XCTAssertEqual(t.state, .reported)
        XCTAssertEqual(t.report?.sha, sha)
    }

    func testCompleteTaskEnforcesTheSummaryLimit() throws {
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "Build", files: [])
        try inbox.markTaskDelivered(taskId: task.id, sessionId: "s1")
        let res = try mcpCall(server(as: .codex), "linkc_complete_task",
                           ["task_id": task.id, "status": "done", "summary": String(repeating: "a", count: 1_001)])
        XCTAssertTrue(res.isError)
        XCTAssertTrue(res.text.contains("the limit is 1,000"), res.text)
        XCTAssertEqual(try inbox.task(id: task.id)?.state, .delivered)
    }

    func testGetTaskShowsVerificationAndVerdict() throws {
        let base = String(repeating: "b", count: 40)
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "Make check pass", files: [],
                                        verification: Verification(branch: "task/x", baseSha: base, command: "./check.sh", testPaths: ["check.sh"]))
        try inbox.resolveGate(taskId: task.id, verdict: Verdict(passed: false, sha: base, exitStatus: 0,
                                                                reason: "tests already pass at bbbbbbb; brief refused",
                                                                stdoutTail: "GATE_STDOUT_MARKER", stderrTail: ""))
        let res = try mcpCall(server(as: .claude), "linkc_get_task", ["task_id": task.id])
        XCTAssertFalse(res.isError, res.text)
        XCTAssertTrue(res.text.contains("## Verification"))
        XCTAssertTrue(res.text.contains("`./check.sh`"))
        XCTAssertTrue(res.text.contains("## Gate"))
        XCTAssertTrue(res.text.contains("tests already pass at bbbbbbb; brief refused"))
        XCTAssertTrue(res.text.contains("GATE_STDOUT_MARKER"))
    }

    func testGetTaskShowsShaAndBaseShaTruncatedToSevenCharacters() throws {
        let base = "1234567890abcdef1234567890abcdef12345678"
        let reportSha = "abcdef1234567890abcdef1234567890abcdef12"
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "Make check pass", files: [],
                                        verification: Verification(branch: "task/x", baseSha: base, command: "./check.sh", testPaths: ["check.sh"]))
        try inbox.resolveGate(taskId: task.id, verdict: Verdict(passed: true, sha: base, exitStatus: 1, reason: nil, stdoutTail: "", stderrTail: ""))
        try inbox.markTaskDelivered(taskId: task.id, sessionId: "s1")
        try inbox.reportTask(taskId: task.id, report: TaskReport(status: "done", summary: "added marker", sha: reportSha))

        let res = try mcpCall(server(as: .claude), "linkc_get_task", ["task_id": task.id])
        XCTAssertFalse(res.isError, res.text)
        XCTAssertTrue(res.text.contains("**Sha:** \(String(reportSha.prefix(7)))\n"), res.text)
        XCTAssertTrue(res.text.contains("**Base:** \(String(base.prefix(7)))\n"), res.text)
        XCTAssertFalse(res.text.contains("**Sha:** \(reportSha)"), "the report sha line must be truncated to 7 chars: \(res.text)")
        XCTAssertFalse(res.text.contains("**Base:** \(base)"), "the base sha line must be truncated to 7 chars: \(res.text)")
    }

    // MARK: - Task ids by prefix

    func testGetAndCancelTaskAcceptTheEightCharacterIdShownToTheDelegator() throws {
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "Build by short id", files: [])
        let delegator = server(as: .claude)

        let get = try mcpCall(delegator, "linkc_get_task", ["task_id": task.shortId.lowercased()])
        XCTAssertFalse(get.isError, get.text)
        XCTAssertTrue(get.text.contains("Build by short id"), get.text)

        let cancel = try mcpCall(delegator, "linkc_cancel_task", ["task_id": task.shortId])
        XCTAssertFalse(cancel.isError, cancel.text)
        XCTAssertEqual(try inbox.task(id: task.id)?.state, .cancelled)
    }

    func testTaskToolsRejectAShortOrAmbiguousPrefix() throws {
        let one = "ABCDEF12-0000-4000-8000-000000000001", two = "ABCDEF12-0000-4000-8000-000000000002"
        try inbox.saveRaw(Inbox(workspacePath: tempDir.path, tasks: [
            TaskRecord(id: one, fromAgent: .claude, toAgent: .codex, prompt: "One"),
            TaskRecord(id: two, fromAgent: .claude, toAgent: .cursor, prompt: "Two"),
        ]))
        let delegator = server(as: .claude)

        let short = try mcpCall(delegator, "linkc_get_task", ["task_id": "ABCDEF1"])
        XCTAssertTrue(short.isError)
        XCTAssertEqual(short.text, InboxError.taskNotFound("ABCDEF1").localizedDescription)

        let ambiguous = try mcpCall(delegator, "linkc_cancel_task", ["task_id": "abcdef12"])
        XCTAssertTrue(ambiguous.isError)
        XCTAssertTrue(ambiguous.text.contains(one) && ambiguous.text.contains(two), ambiguous.text)
        XCTAssertEqual(try inbox.load().tasks.map(\.state), [.queued, .queued], "an ambiguous id cancels nothing")
    }

    // MARK: - Malformed verify

    func testDelegateRejectsAVerifyThatIsNotAnObject() throws {
        let res = try mcpCall(server(as: .claude), "linkc_delegate_task",
                           ["to": "codex", "prompt": "Make check pass", "verify": #"{"branch": "task/x"}"#])
        XCTAssertTrue(res.isError)
        XCTAssertTrue(res.text.contains("verify must be an object"), res.text)
        XCTAssertTrue(try inbox.load().tasks.isEmpty, "a malformed verify creates no task")
    }

    func testDelegateRejectsATimeoutThatIsNotAnInteger() throws {
        let base = try repoWithTests()
        let srv = server(as: .claude)
        for bad: Any in ["600", 600.5, true] {
            var v = verify(base: base)
            v["timeout_seconds"] = bad
            let res = try mcpCall(srv, "linkc_delegate_task", ["to": "codex", "prompt": "Make check pass", "verify": v])
            XCTAssertTrue(res.isError, "\(bad): \(res.text)")
            XCTAssertTrue(res.text.contains("timeout_seconds"), res.text)
        }
        XCTAssertTrue(try inbox.load().tasks.isEmpty, "a malformed timeout creates no task")
    }

    /// JSON null is how some clients send an optional argument they did not set.
    func testDelegateTreatsANullVerifyAsAbsent() throws {
        let res = try mcpCall(server(as: .claude), "linkc_delegate_task", ["to": "codex", "prompt": "Plain", "verify": NSNull(), "tier": "deep"])
        XCTAssertFalse(res.isError, res.text)
        XCTAssertEqual(try inbox.load().tasks.first?.state, .queued)
    }

    // MARK: - An unreadable inbox

    /// An undecodable inbox.json must come back as an `isError` tool result, not a JSON-RPC
    /// -32000 error — in every tool that reads or writes the inbox, including the rate-limit
    /// check inside linkc_delegate_task.
    func testAnUnreadableInboxIsAnIsErrorResultInEveryTool() throws {
        let inboxURL = tempDir.appendingPathComponent(".linkc/inbox.json")
        try FileManager.default.createDirectory(at: inboxURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not valid json".utf8).write(to: inboxURL)

        let srv = server(as: .claude)

        let delegate = try mcpCall(srv, "linkc_delegate_task", ["to": "codex", "prompt": "Make check pass"])
        XCTAssertTrue(delegate.isError, delegate.text)
        XCTAssertTrue(delegate.text.contains("could not be decoded"), delegate.text)

        let send = try mcpCall(srv, "linkc_send_message", ["to": "codex", "message": "hi"])
        XCTAssertTrue(send.isError, send.text)
        XCTAssertTrue(send.text.contains("could not be decoded"), send.text)

        let getInbox = try mcpCall(srv, "linkc_get_inbox")
        XCTAssertTrue(getInbox.isError, getInbox.text)
        XCTAssertTrue(getInbox.text.contains("could not be decoded"), getInbox.text)

        let myTasks = try mcpCall(srv, "linkc_my_tasks")
        XCTAssertTrue(myTasks.isError, myTasks.text)
        XCTAssertTrue(myTasks.text.contains("could not be decoded"), myTasks.text)

        // No modelSwitcher, so linkc_switch_model takes the enqueue path.
        let switchModel = try mcpCall(srv, "linkc_switch_model", ["model": "sonnet"])
        XCTAssertTrue(switchModel.isError, switchModel.text)
        XCTAssertTrue(switchModel.text.contains("could not be decoded"), switchModel.text)

        let getModels = try mcpCall(srv, "linkc_get_models")
        XCTAssertTrue(getModels.isError, getModels.text)
        XCTAssertTrue(getModels.text.contains("could not be decoded"), getModels.text)

        let usageStatus = try mcpCall(srv, "linkc_get_usage_status")
        XCTAssertTrue(usageStatus.isError, usageStatus.text)
        XCTAssertTrue(usageStatus.text.contains("could not be decoded"), usageStatus.text)
    }

    // MARK: - Delegation tiers

    func testDelegateAppliesTheAgentDefaultTierWhenNoneIsGiven() throws {
        // agy, not codex: codex's own default tier ("standard") has no model configured in the
        // seed, so it would refuse here regardless of this mechanism — see the refusal test below.
        let res = try mcpCall(server(as: .claude, models: .seeded), "linkc_delegate_task",
                           ["to": "agy", "prompt": "Rename a file"])
        XCTAssertFalse(res.isError, res.text)
        let task = try XCTUnwrap(inbox.openTasks().first)
        XCTAssertEqual(task.tier, .standard)
    }

    func testDelegateRecordsAnExplicitTier() throws {
        let res = try mcpCall(server(as: .claude, models: .seeded), "linkc_delegate_task",
                           ["to": "agy", "prompt": "Rename a file", "tier": "light"])
        XCTAssertFalse(res.isError, res.text)
        XCTAssertEqual(try XCTUnwrap(inbox.openTasks().first).tier, .light)
    }

    func testDelegateRefusesAnUnknownTier() throws {
        let res = try mcpCall(server(as: .claude, models: .seeded), "linkc_delegate_task",
                           ["to": "codex", "prompt": "Rename a file", "tier": "cheapest"])
        XCTAssertTrue(res.isError)
        XCTAssertTrue(res.text.contains("tier must be light, standard or deep"), res.text)
        XCTAssertTrue(try inbox.openTasks().isEmpty, "A refused delegation creates no task")
    }

    func testANonStringTierIsRefusedRatherThanIgnored() throws {
        let res = try mcpCall(server(as: .claude, models: .seeded), "linkc_delegate_task",
                           ["to": "codex", "prompt": "Rename a file", "tier": 3])
        XCTAssertTrue(res.isError)
        XCTAssertTrue(res.text.contains("tier must be light, standard or deep"), res.text)
    }

    /// An empty string is how some clients send an optional argument they left unset; it must
    /// resolve to the agent's default tier exactly like an omitted `tier`, not be refused.
    func testAnEmptyStringTierIsTreatedAsAbsent() throws {
        // agy, not codex: see testDelegateAppliesTheAgentDefaultTierWhenNoneIsGiven above.
        let res = try mcpCall(server(as: .claude, models: .seeded), "linkc_delegate_task",
                           ["to": "agy", "prompt": "Rename a file", "tier": ""])
        XCTAssertFalse(res.isError, res.text)
        XCTAssertEqual(try XCTUnwrap(inbox.openTasks().first).tier, .standard)
    }

    func testDelegateRefusesATierWithNoModelConfigured() throws {
        var models = AgentModelSettings.seeded
        models.setModel("", for: .codex, tier: .light)
        let res = try mcpCall(server(as: .claude, models: models), "linkc_delegate_task",
                           ["to": "codex", "prompt": "Rename a file", "tier": "light"])
        XCTAssertTrue(res.isError)
        XCTAssertTrue(res.text.contains("no model configured for codex tier light — set it in linkC settings"), res.text)
        XCTAssertTrue(try inbox.openTasks().isEmpty)
    }

    func testDelegateRefusesATieredTaskForCursor() throws {
        let res = try mcpCall(server(as: .claude, models: .seeded), "linkc_delegate_task",
                           ["to": "cursor", "prompt": "Rename a file", "tier": "light"])
        XCTAssertTrue(res.isError)
        XCTAssertTrue(res.text.contains("cursor cannot be pinned to a model"), res.text)
        XCTAssertTrue(try inbox.openTasks().isEmpty)
    }

    func testDelegateToCursorWithNoTierStillWorks() throws {
        let res = try mcpCall(server(as: .claude, models: .seeded), "linkc_delegate_task",
                           ["to": "cursor", "prompt": "Rename a file"])
        XCTAssertFalse(res.isError, res.text)
        let task = try XCTUnwrap(inbox.openTasks().first)
        XCTAssertNil(task.tier)
    }

    func testGetModelsReportsTheConfiguredMapping() throws {
        var models = AgentModelSettings.seeded
        models.setModel("gpt-7-nova", for: .codex, tier: .deep)
        let res = try mcpCall(server(as: .claude, models: models), "linkc_get_models", ["agent": "codex"])
        XCTAssertFalse(res.isError, res.text)
        XCTAssertTrue(res.text.contains("gpt-7-nova"), res.text)
        XCTAssertTrue(res.text.contains("deep"), res.text)
    }

    // MARK: - Usage warning on delegation

    func testADelegationWarnsWhenTheTargetIsNearlyOut() throws {
        let hot = AgentUsage(agent: .codex,
                             windows: [UsageWindow(label: "5h", usedPercent: 86, tokens: nil, resetsAt: Date().addingTimeInterval(3600))],
                             planType: nil, observedAt: Date(), unavailableReason: nil)
        let res = try mcpCall(server(as: .claude, models: .seeded, readers: [.codex: { hot }]),
                           "linkc_delegate_task", ["to": "codex", "prompt": "Rename a file"])
        XCTAssertFalse(res.isError, res.text)
        XCTAssertTrue(res.text.contains("86%"), res.text)
        XCTAssertTrue(res.text.contains("5h"), res.text)
        XCTAssertEqual(try inbox.openTasks().count, 1, "the delegation still happens")
    }

    /// A window whose `resetsAt` is well in the past describes a window that has already moved
    /// on — the reading itself may be fresh, but the number it reports is no longer current, so
    /// delegating to that agent must not carry a warning for it.
    func testADelegationDoesNotWarnWhenTheWindowsResetHasAlreadyPassed() throws {
        let staleWindow = AgentUsage(agent: .codex,
                                     windows: [UsageWindow(label: "5h", usedPercent: 95, tokens: nil,
                                                            resetsAt: Date().addingTimeInterval(-600))],
                                     planType: nil, observedAt: Date(), unavailableReason: nil)
        let res = try mcpCall(server(as: .claude, models: .seeded, readers: [.codex: { staleWindow }]),
                           "linkc_delegate_task", ["to": "codex", "prompt": "Rename a file"])
        XCTAssertFalse(res.isError, res.text)
        XCTAssertFalse(res.text.contains("%"), "a window whose reset already passed must never warn: \(res.text)")
    }

    func testADelegationUnderTheThresholdIsNotAnnotated() throws {
        let calm = AgentUsage(agent: .codex,
                              windows: [UsageWindow(label: "5h", usedPercent: 12, tokens: nil, resetsAt: nil)],
                              planType: nil, observedAt: Date(), unavailableReason: nil)
        let res = try mcpCall(server(as: .claude, models: .seeded, readers: [.codex: { calm }]),
                           "linkc_delegate_task", ["to": "codex", "prompt": "Rename a file"])
        XCTAssertFalse(res.text.contains("%"), "no usage line under the threshold: \(res.text)")
    }

    /// `.claude` is warn-capable by default now (D22b-1 unified its usage source with the
    /// sidebar's status-line reading, which does carry a real `usedPercent`), so its reader is
    /// consulted like any other — but a transcript-shaped reading (token counts, never
    /// `usedPercent`, the shape `ClaudeUsageReader`'s fallback produces) still can never drive a
    /// warning: `windowNeedingWarning` requires `usedPercent` to be present.
    func testADelegationToClaudeWithATranscriptShapedReadingNeverWarns() throws {
        let transcriptShaped = AgentUsage(agent: .claude,
                                          windows: [UsageWindow(label: "5h", usedPercent: nil, tokens: 999, resetsAt: nil)],
                                          planType: nil, observedAt: Date(), unavailableReason: nil)
        let res = try mcpCall(
            server(as: .codex, models: .seeded, readers: [.claude: { transcriptShaped }]),
            "linkc_delegate_task", ["to": "claude", "prompt": "Rename a file"])
        XCTAssertFalse(res.isError, res.text)
        XCTAssertFalse(res.text.contains("%"), "a token-only reading must never warn: \(res.text)")
    }

    /// Which readers can warn must be data (`warnCapableAgents`), not an identity check on
    /// `toAgent`. If the handler special-cased `.claude` directly, a percentage-reporting reader
    /// registered for `.claude` — exactly what is injected here — would still be silently
    /// skipped. Marking `.claude` warn-capable here must be enough to surface its warning.
    func testADelegationWarnsForAnyAgentTheServerMarksWarnCapable() throws {
        let hot = AgentUsage(agent: .claude,
                             windows: [UsageWindow(label: "5h", usedPercent: 92, tokens: nil, resetsAt: nil)],
                             planType: nil, observedAt: Date(), unavailableReason: nil)
        let res = try mcpCall(
            server(as: .codex, models: .seeded, readers: [.claude: { hot }], warnCapableAgents: [.claude]),
            "linkc_delegate_task", ["to": "claude", "prompt": "Rename a file"])
        XCTAssertFalse(res.isError, res.text)
        XCTAssertTrue(res.text.contains("92%"), res.text)
        XCTAssertTrue(res.text.contains("5h"), res.text)
    }

    /// The blackboard-broadcast-failure early return is a second success path, distinct from the
    /// plain return exercised above — it must append the usage note too. `broadcastIntent` only
    /// runs when `files` is non-empty, and the store throws when `.linkc/blackboard.json` exists
    /// but cannot be decoded.
    func testADelegationWithAnUnreadableBlackboardStillAppendsTheUsageNote() throws {
        let linkcDir = tempDir.appendingPathComponent(".linkc")
        try FileManager.default.createDirectory(at: linkcDir, withIntermediateDirectories: true)
        try Data("{\"version\": 1, \"activeAgents\": [{\"incomplete\": tr".utf8)
            .write(to: linkcDir.appendingPathComponent("blackboard.json"))

        let hot = AgentUsage(agent: .codex,
                             windows: [UsageWindow(label: "5h", usedPercent: 91, tokens: nil, resetsAt: nil)],
                             planType: nil, observedAt: Date(), unavailableReason: nil)
        let res = try mcpCall(
            server(as: .claude, models: .seeded, readers: [.codex: { hot }]),
            "linkc_delegate_task", ["to": "codex", "prompt": "Rename a file", "files": ["A.swift"]])

        XCTAssertFalse(res.isError, res.text)
        XCTAssertTrue(res.text.contains("blackboard broadcast failed"), res.text)
        XCTAssertTrue(res.text.contains("91%"), res.text)
        XCTAssertEqual(try inbox.openTasks().count, 1, "the task is still created even though the broadcast failed")
    }

    // MARK: - Closing a worker

    /// A caller in `session`, with linkC's answer to a close request played by `answer` at each
    /// wait instead of a real sleep: the test stands in for the relay pass.
    private func server(
        as agent: AgentKind, session: String?, answer: @escaping @Sendable () -> Void = {}
    ) -> MCPServer {
        var environment = ["LINKC_AGENT": agent.rawValue]
        if let session { environment["LINKC_SESSION"] = session }
        return MCPServer(
            workspaceRoot: tempDir.path, environment: environment,
            ancestorResolver: { _ in nil }, sessionResolver: { nil }, usageReaders: [:],
            closeAnswerWait: MCPServer.CloseAnswerWait(timeout: 1, interval: 0.1, sleep: { _ in answer() }))
    }

    /// A task Claude session "D" delegated, delivered to session "W" and reported.
    private func reportedTask(from session: String? = "D", prompt: String = "carry") throws -> TaskRecord {
        let task = try inbox.createTask(from: .claude, to: .codex, fromSessionId: session, prompt: prompt, files: [])
        try inbox.markTaskDelivered(taskId: task.id, sessionId: "W")
        try inbox.reportTask(taskId: task.id, report: TaskReport(status: "done", summary: "did it"))
        return task
    }

    func testCloseWorkerRecordsARequestAndReportsThatItWasClosed() throws {
        let task = try reportedTask()
        let inbox = self.inbox!
        let srv = server(as: .claude, session: "D") {
            try? inbox.resolveCloseRequest(taskId: task.id, outcome: .closed(at: Date()))
        }

        let res = try mcpCall(srv, "linkc_close_worker", ["task_id": task.id])

        XCTAssertFalse(res.isError, res.text)
        XCTAssertTrue(res.text.contains("Closed"), res.text)
        XCTAssertEqual(try inbox.task(id: task.id)?.closeRequest?.by, .delegator)
    }

    func testCloseWorkerPassesOnWhyLinkCRefused() throws {
        let task = try reportedTask()
        let inbox = self.inbox!
        let srv = server(as: .claude, session: "D") {
            try? inbox.resolveCloseRequest(taskId: task.id, outcome: .refused("it is open on screen"))
        }

        let res = try mcpCall(srv, "linkc_close_worker", ["task_id": task.id])

        XCTAssertTrue(res.isError, res.text)
        XCTAssertTrue(res.text.contains("it is open on screen"), res.text)
    }

    func testCloseWorkerSaysSoWhenLinkCHasNotAnsweredAndKeepsTheRequest() throws {
        let task = try reportedTask()

        let res = try mcpCall(server(as: .claude, session: "D"), "linkc_close_worker", ["task_id": task.id])

        XCTAssertFalse(res.isError, res.text)
        XCTAssertTrue(res.text.contains("not answered"), res.text)
        XCTAssertTrue(try XCTUnwrap(inbox.task(id: task.id)?.closeRequest).isPending)
    }

    /// While the delegator waits, the worker's own request can replace its request on the task
    /// and be answered; that answer is not the delegator's.
    func testCloseWorkerReadsOnlyTheAnswerToItsOwnRequest() throws {
        let task = try reportedTask()
        let inbox = self.inbox!
        let srv = server(as: .claude, session: "D") {
            _ = try? inbox.requestClose(taskId: task.id, by: .worker)
            try? inbox.resolveCloseRequest(taskId: task.id, outcome: .refused("the answer to another request"))
        }

        let res = try mcpCall(srv, "linkc_close_worker", ["task_id": task.id])

        XCTAssertFalse(res.text.contains("the answer to another request"), res.text)
        XCTAssertTrue(res.text.contains("not answered"), res.text)
    }

    func testCloseWorkerRefusesACallerThatDidNotDelegateTheTask() throws {
        let task = try reportedTask()

        let res = try mcpCall(server(as: .codex, session: "W"), "linkc_close_worker", ["task_id": task.id])

        XCTAssertTrue(res.isError, res.text)
        XCTAssertTrue(res.text.contains("delegated"), res.text)
        XCTAssertNil(try inbox.task(id: task.id)?.closeRequest)
    }

    func testCloseWorkerRefusesAnotherSessionOfTheDelegatingKind() throws {
        let task = try reportedTask()

        let res = try mcpCall(server(as: .claude, session: "E"), "linkc_close_worker", ["task_id": task.id])

        XCTAssertTrue(res.isError, res.text)
        XCTAssertTrue(res.text.contains("delegated"), res.text)
        XCTAssertNil(try inbox.task(id: task.id)?.closeRequest)
    }

    func testCloseWorkerAcceptsACallerWithNoSessionForATaskItsKindDelegated() throws {
        let task = try reportedTask(from: nil)

        let res = try mcpCall(server(as: .claude, session: nil), "linkc_close_worker", ["task_id": task.id])

        XCTAssertFalse(res.isError, res.text)
        XCTAssertNotNil(try inbox.task(id: task.id)?.closeRequest)
    }

    func testCloseWorkerRefusesATaskThatIsStillRunning() throws {
        let task = try inbox.createTask(from: .claude, to: .codex, fromSessionId: "D", prompt: "carry", files: [])
        try inbox.markTaskDelivered(taskId: task.id, sessionId: "W")
        try inbox.markTaskStarted(taskId: task.id)

        let res = try mcpCall(server(as: .claude, session: "D"), "linkc_close_worker", ["task_id": task.id])

        XCTAssertTrue(res.isError, res.text)
        XCTAssertTrue(res.text.contains("linkc_cancel_task"), res.text)
        XCTAssertNil(try inbox.task(id: task.id)?.closeRequest)
    }

    func testCloseWorkerRefusesATaskThatWasNeverDelivered() throws {
        let task = try inbox.createTask(from: .claude, to: .codex, fromSessionId: "D", prompt: "carry", files: [])

        let res = try mcpCall(server(as: .claude, session: "D"), "linkc_close_worker", ["task_id": task.id])

        XCTAssertTrue(res.isError, res.text)
        XCTAssertTrue(res.text.contains("never delivered"), res.text)
    }

    func testCloseWorkerRefusesAWorkerThatHoldsAnotherOpenTask() throws {
        let task = try reportedTask()
        let other = try inbox.createTask(from: .claude, to: .codex, fromSessionId: "D", prompt: "next", files: [])
        try inbox.markTaskDelivered(taskId: other.id, sessionId: "W")

        let res = try mcpCall(server(as: .claude, session: "D"), "linkc_close_worker", ["task_id": task.id])

        XCTAssertTrue(res.isError, res.text)
        XCTAssertTrue(res.text.contains(other.shortId), res.text)
        XCTAssertNil(try inbox.task(id: task.id)?.closeRequest)
    }

    func testCloseWorkerRefusesAWorkerThatWaitsOnATaskItDelegated() throws {
        let task = try reportedTask()
        let sub = try inbox.createTask(from: .codex, to: .agy, fromSessionId: "W", prompt: "sub-task", files: [])

        let res = try mcpCall(server(as: .claude, session: "D"), "linkc_close_worker", ["task_id": task.id])

        XCTAssertTrue(res.isError, res.text)
        XCTAssertTrue(res.text.contains(sub.shortId), res.text)
        XCTAssertTrue(res.text.contains("delegated"), res.text)
        XCTAssertNil(try inbox.task(id: task.id)?.closeRequest)
    }

    func testCloseWorkerNeedsATaskId() throws {
        let res = try mcpCall(server(as: .claude, session: "D"), "linkc_close_worker")

        XCTAssertTrue(res.isError, res.text)
        XCTAssertTrue(res.text.contains("task_id"), res.text)
    }

    func testCloseWorkerIsAnErrorResultOnAnUnreadableInbox() throws {
        let inboxURL = tempDir.appendingPathComponent(".linkc/inbox.json")
        try FileManager.default.createDirectory(at: inboxURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not valid json".utf8).write(to: inboxURL)

        let res = try mcpCall(server(as: .claude, session: "D"), "linkc_close_worker", ["task_id": "abcdef12"])

        XCTAssertTrue(res.isError, res.text)
        XCTAssertTrue(res.text.contains("could not be decoded"), res.text)
    }

    func testCompleteTaskWithCloseSessionAsksForTheReportersSessionToClose() throws {
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "Build", files: [])
        try inbox.markTaskDelivered(taskId: task.id, sessionId: "W")

        let res = try mcpCall(server(as: .codex, session: "W"), "linkc_complete_task", [
            "task_id": task.id, "status": "done", "summary": "Implemented.", "close_session": true
        ])

        XCTAssertFalse(res.isError, res.text)
        XCTAssertTrue(res.text.hasPrefix("Reported. Unverified task."), res.text)
        XCTAssertTrue(res.text.contains("Close requested"), res.text)
        let stored = try XCTUnwrap(inbox.task(id: task.id))
        XCTAssertEqual(stored.state, .reported)
        XCTAssertEqual(stored.closeRequest?.by, .worker)
    }

    func testCompleteTaskWithoutCloseSessionAsksForNothing() throws {
        for flag in [nil, false] as [Bool?] {
            let task = try inbox.createTask(from: .claude, to: .codex, prompt: "Build \(String(describing: flag))", files: [])
            try inbox.markTaskDelivered(taskId: task.id, sessionId: "W")
            var args: [String: Any] = ["task_id": task.id, "status": "done", "summary": "Implemented."]
            if let flag { args["close_session"] = flag }

            let res = try mcpCall(server(as: .codex, session: "W"), "linkc_complete_task", args)

            XCTAssertEqual(res.text, "Reported. Unverified task.")
            XCTAssertNil(try inbox.task(id: task.id)?.closeRequest)
            try inbox.cancelTask(taskId: task.id, reason: "next case")
        }
    }

    func testCompleteTaskStillReportsWhenTheSessionCannotBeClosed() throws {
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "Build", files: [])
        try inbox.markTaskDelivered(taskId: task.id, sessionId: "W")
        let other = try inbox.createTask(from: .claude, to: .codex, prompt: "Next", files: [])
        try inbox.markTaskDelivered(taskId: other.id, sessionId: "W")

        let res = try mcpCall(server(as: .codex, session: "W"), "linkc_complete_task", [
            "task_id": task.id, "status": "done", "summary": "Implemented.", "close_session": true
        ])

        XCTAssertFalse(res.isError, "the report itself succeeded: \(res.text)")
        XCTAssertTrue(res.text.contains("Not closing this session"), res.text)
        XCTAssertTrue(res.text.contains(other.shortId), res.text)
        let stored = try XCTUnwrap(inbox.task(id: task.id))
        XCTAssertEqual(stored.state, .reported)
        XCTAssertNil(stored.closeRequest)
    }

    func testCompleteTaskDoesNotAskToCloseASessionThatWaitsOnATaskItDelegated() throws {
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "Build", files: [])
        try inbox.markTaskDelivered(taskId: task.id, sessionId: "W")
        let sub = try inbox.createTask(from: .codex, to: .agy, fromSessionId: "W", prompt: "sub-task", files: [])

        let res = try mcpCall(server(as: .codex, session: "W"), "linkc_complete_task", [
            "task_id": task.id, "status": "done", "summary": "Implemented.", "close_session": true
        ])

        XCTAssertFalse(res.isError, "the report itself succeeded: \(res.text)")
        XCTAssertTrue(res.text.contains("Not closing this session"), res.text)
        XCTAssertTrue(res.text.contains(sub.shortId), res.text)
        XCTAssertNil(try inbox.task(id: task.id)?.closeRequest)
    }

    func testCompleteTaskRefusesACloseSessionThatIsNotABoolean() throws {
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "Build", files: [])
        try inbox.markTaskDelivered(taskId: task.id, sessionId: "W")

        let res = try mcpCall(server(as: .codex, session: "W"), "linkc_complete_task", [
            "task_id": task.id, "status": "done", "summary": "Implemented.", "close_session": "yes"
        ])

        XCTAssertTrue(res.isError, res.text)
        XCTAssertTrue(res.text.contains("close_session"), res.text)
        XCTAssertEqual(try inbox.task(id: task.id)?.state, .delivered, "a malformed call records nothing")
    }

    func testAnotherSessionCannotAskForTheWorkersSessionToClose() throws {
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "Build", files: [])
        try inbox.markTaskDelivered(taskId: task.id, sessionId: "W")

        let res = try mcpCall(server(as: .codex, session: "sibling"), "linkc_complete_task", [
            "task_id": task.id, "status": "done", "summary": "Implemented.", "close_session": true
        ])

        XCTAssertTrue(res.isError, res.text)
        XCTAssertNil(try inbox.task(id: task.id)?.closeRequest)
    }

    func testGetTaskShowsTheCloseRequestAndItsAnswer() throws {
        let task = try reportedTask()
        _ = try inbox.requestClose(taskId: task.id, by: .delegator)
        let srv = server(as: .claude, session: "D")

        let pending = try mcpCall(srv, "linkc_get_task", ["task_id": task.id])
        XCTAssertTrue(pending.text.contains("Close request:** pending"), pending.text)

        try inbox.resolveCloseRequest(taskId: task.id, outcome: .refused("it is open on screen"))
        let refused = try mcpCall(srv, "linkc_get_task", ["task_id": task.id])
        XCTAssertTrue(refused.text.contains("refused — it is open on screen"), refused.text)

        _ = try inbox.requestClose(taskId: task.id, by: .delegator)
        try inbox.resolveCloseRequest(taskId: task.id, outcome: .closed(at: Date()))
        let closed = try mcpCall(srv, "linkc_get_task", ["task_id": task.id])
        XCTAssertTrue(closed.text.contains("Close request:** closed"), closed.text)
    }
}

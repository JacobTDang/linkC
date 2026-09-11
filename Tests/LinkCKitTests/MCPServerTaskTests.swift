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

    func testStartTaskByNonAssigneeIsRejected() throws {
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "Build", files: [])
        try inbox.markTaskDelivered(taskId: task.id, sessionId: "s1")

        let res = try call(server(as: .agy), "linkc_start_task", ["task_id": task.id])

        XCTAssertTrue(res.isError)
        XCTAssertTrue(res.text.contains("assigned to Codex"))
        XCTAssertEqual(try inbox.task(id: task.id)?.state, .delivered)
    }

    func testCompleteTaskRecordsReportAndWritesNothingElse() throws {
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "Build", files: [])
        try inbox.markTaskDelivered(taskId: task.id, sessionId: "s1")
        let srv = server(as: .codex)
        let res = try call(srv, "linkc_complete_task", [
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

        let res = try call(server(as: .agy), "linkc_complete_task", [
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
        let res = try call(server(as: .claude), "linkc_delegate_task",
                           ["to": "codex", "prompt": "Make check pass", "verify": verify(base: String(base.prefix(7)))])
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
        let badBase = try call(srv, "linkc_delegate_task", ["to": "codex", "prompt": "A", "verify": verify(base: "deadbeef")])
        XCTAssertTrue(badBase.isError)
        XCTAssertTrue(badBase.text.contains("verify.base_sha"), badBase.text)

        let missingPath = try call(srv, "linkc_delegate_task", ["to": "codex", "prompt": "B", "verify": verify(base: base, paths: ["nope.sh"])])
        XCTAssertTrue(missingPath.isError)
        XCTAssertTrue(missingPath.text.contains("'nope.sh' does not exist at \(base.prefix(7))"), missingPath.text)

        try runGit(["checkout", "-q", "-b", "other"], in: tempDir)
        try "x\n".write(to: tempDir.appendingPathComponent("extra.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "extra.txt"], in: tempDir)
        try runGit(["commit", "-q", "-m", "moved"], in: tempDir)
        let movedBranch = try call(srv, "linkc_delegate_task", ["to": "codex", "prompt": "C", "verify": verify(base: base, branch: "other")])
        XCTAssertTrue(movedBranch.isError)
        XCTAssertTrue(movedBranch.text.contains("not base \(base.prefix(7))"), movedBranch.text)

        XCTAssertTrue(try inbox.load().tasks.isEmpty, "a rejected verify creates no task")
    }

    func testVerifiedCompleteNeedsTheShaOfARealCommit() throws {
        let base = try repoWithTests()
        _ = try call(server(as: .claude), "linkc_delegate_task", ["to": "codex", "prompt": "Make check pass", "verify": verify(base: base)])
        let task = try XCTUnwrap(inbox.load().tasks.first)
        try inbox.resolveGate(taskId: task.id, verdict: Verdict(passed: true, sha: base, exitStatus: 1, reason: nil, stdoutTail: "", stderrTail: ""))
        try inbox.markTaskDelivered(taskId: task.id, sessionId: "s1")
        let worker = server(as: .codex)

        let noSha = try call(worker, "linkc_complete_task", ["task_id": task.id, "status": "done", "summary": "added marker"])
        XCTAssertTrue(noSha.isError)
        XCTAssertEqual(noSha.text, InboxError.shaRequired.localizedDescription)
        let bogus = try call(worker, "linkc_complete_task", ["task_id": task.id, "status": "done", "summary": "added marker", "sha": "deadbeef"])
        XCTAssertTrue(bogus.isError)
        XCTAssertTrue(bogus.text.hasPrefix("Error: sha:"), bogus.text)
        XCTAssertEqual(try inbox.task(id: task.id)?.state, .delivered)

        try "ok\n".write(to: tempDir.appendingPathComponent("marker.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "marker.txt"], in: tempDir)
        try runGit(["commit", "-q", "-m", "fix"], in: tempDir)
        let sha = try runGit(["rev-parse", "HEAD"], in: tempDir)
        let reported = try call(worker, "linkc_complete_task",
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
        let res = try call(server(as: .codex), "linkc_complete_task",
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
        let res = try call(server(as: .claude), "linkc_get_task", ["task_id": task.id])
        XCTAssertFalse(res.isError, res.text)
        XCTAssertTrue(res.text.contains("## Verification"))
        XCTAssertTrue(res.text.contains("`./check.sh`"))
        XCTAssertTrue(res.text.contains("## Gate"))
        XCTAssertTrue(res.text.contains("tests already pass at bbbbbbb; brief refused"))
        XCTAssertTrue(res.text.contains("GATE_STDOUT_MARKER"))
    }

    // MARK: - Task ids by prefix

    func testGetAndCancelTaskAcceptTheEightCharacterIdShownToTheDelegator() throws {
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "Build by short id", files: [])
        let delegator = server(as: .claude)

        let get = try call(delegator, "linkc_get_task", ["task_id": task.shortId.lowercased()])
        XCTAssertFalse(get.isError, get.text)
        XCTAssertTrue(get.text.contains("Build by short id"), get.text)

        let cancel = try call(delegator, "linkc_cancel_task", ["task_id": task.shortId])
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

        let short = try call(delegator, "linkc_get_task", ["task_id": "ABCDEF1"])
        XCTAssertTrue(short.isError)
        XCTAssertEqual(short.text, InboxError.taskNotFound("ABCDEF1").localizedDescription)

        let ambiguous = try call(delegator, "linkc_cancel_task", ["task_id": "abcdef12"])
        XCTAssertTrue(ambiguous.isError)
        XCTAssertTrue(ambiguous.text.contains(one) && ambiguous.text.contains(two), ambiguous.text)
        XCTAssertEqual(try inbox.load().tasks.map(\.state), [.queued, .queued], "an ambiguous id cancels nothing")
    }

    // MARK: - Malformed verify

    func testDelegateRejectsAVerifyThatIsNotAnObject() throws {
        let res = try call(server(as: .claude), "linkc_delegate_task",
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
            let res = try call(srv, "linkc_delegate_task", ["to": "codex", "prompt": "Make check pass", "verify": v])
            XCTAssertTrue(res.isError, "\(bad): \(res.text)")
            XCTAssertTrue(res.text.contains("timeout_seconds"), res.text)
        }
        XCTAssertTrue(try inbox.load().tasks.isEmpty, "a malformed timeout creates no task")
    }

    /// JSON null is how some clients send an optional argument they did not set.
    func testDelegateTreatsANullVerifyAsAbsent() throws {
        let res = try call(server(as: .claude), "linkc_delegate_task", ["to": "codex", "prompt": "Plain", "verify": NSNull()])
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

        let delegate = try call(srv, "linkc_delegate_task", ["to": "codex", "prompt": "Make check pass"])
        XCTAssertTrue(delegate.isError, delegate.text)
        XCTAssertTrue(delegate.text.contains("could not be decoded"), delegate.text)

        let send = try call(srv, "linkc_send_message", ["to": "codex", "message": "hi"])
        XCTAssertTrue(send.isError, send.text)
        XCTAssertTrue(send.text.contains("could not be decoded"), send.text)

        let getInbox = try call(srv, "linkc_get_inbox")
        XCTAssertTrue(getInbox.isError, getInbox.text)
        XCTAssertTrue(getInbox.text.contains("could not be decoded"), getInbox.text)

        let myTasks = try call(srv, "linkc_my_tasks")
        XCTAssertTrue(myTasks.isError, myTasks.text)
        XCTAssertTrue(myTasks.text.contains("could not be decoded"), myTasks.text)

        // No modelSwitcher, so linkc_switch_model takes the enqueue path.
        let switchModel = try call(srv, "linkc_switch_model", ["model": "sonnet"])
        XCTAssertTrue(switchModel.isError, switchModel.text)
        XCTAssertTrue(switchModel.text.contains("could not be decoded"), switchModel.text)

        let getModels = try call(srv, "linkc_get_models")
        XCTAssertTrue(getModels.isError, getModels.text)
        XCTAssertTrue(getModels.text.contains("could not be decoded"), getModels.text)

        let usageStatus = try call(srv, "linkc_get_usage_status")
        XCTAssertTrue(usageStatus.isError, usageStatus.text)
        XCTAssertTrue(usageStatus.text.contains("could not be decoded"), usageStatus.text)
    }
}

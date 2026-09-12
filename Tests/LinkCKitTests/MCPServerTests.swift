import XCTest
@testable import LinkCKit

final class MCPServerTests: XCTestCase {
    var tempDir: URL!
    var server: MCPServer!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-mcp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        server = MCPServer(workspaceRoot: tempDir.path, environment: ["LINKC_AGENT": "claude"], ancestorResolver: { _ in nil })
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    func testInitializeReturnsProtocolAndCapabilities() throws {
        let req = """
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2024-11-05"}}
        """.data(using: .utf8)!

        let resData = try XCTUnwrap(server.handleMessage(req))
        let resJson = try JSONSerialization.jsonObject(with: resData) as? [String: Any]
        XCTAssertEqual(resJson?["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(resJson?["id"] as? Int, 1)

        let result = resJson?["result"] as? [String: Any]
        XCTAssertEqual(result?["protocolVersion"] as? String, "2024-11-05")
        let serverInfo = result?["serverInfo"] as? [String: Any]
        XCTAssertEqual(serverInfo?["name"] as? String, "linkc-multiplier")
        XCTAssertEqual(serverInfo?["version"] as? String, "0.3.0")
        let caps = result?["capabilities"] as? [String: Any]
        let toolsCap = caps?["tools"] as? [String: Any]
        XCTAssertEqual(toolsCap?["listChanged"] as? Bool, false)
    }

    func testToolsListDeclaresSevenTools() throws {
        let req = """
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list"}
        """.data(using: .utf8)!

        let resData = try XCTUnwrap(server.handleMessage(req))
        let resJson = try JSONSerialization.jsonObject(with: resData) as? [String: Any]
        let result = resJson?["result"] as? [String: Any]
        let tools = result?["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.count, 15)

        let toolNames = Set(tools?.compactMap { $0["name"] as? String } ?? [])
        XCTAssertTrue(toolNames.contains("linkc_broadcast_intent"))
        XCTAssertTrue(toolNames.contains("linkc_get_project_context"))
        XCTAssertTrue(toolNames.contains("linkc_check_conflicts"))
        XCTAssertTrue(toolNames.contains("linkc_post_note"))
        XCTAssertTrue(toolNames.contains("linkc_delegate_task"))
        XCTAssertTrue(toolNames.contains("linkc_send_message"))
        XCTAssertTrue(toolNames.contains("linkc_get_inbox"))
        for name in ["linkc_start_task", "linkc_complete_task", "linkc_cancel_task", "linkc_get_task", "linkc_my_tasks", "linkc_switch_model", "linkc_get_models", "linkc_get_usage_status"] {
            XCTAssertTrue(toolNames.contains(name), "missing \(name)")
        }
    }

    func testDelegateTaskSuccessResponseIsNotErrorAndTaskPersists() throws {
        let inboxStore = InboxStore(workspaceRoot: tempDir.path)
        let delegateReq = """
        {
          "jsonrpc": "2.0",
          "id": 15,
          "method": "tools/call",
          "params": {
            "name": "linkc_delegate_task",
            "arguments": {
              "to": "codex",
              "prompt": "Add unit tests for parser",
              "from": "claude"
            }
          }
        }
        """.data(using: .utf8)!

        let resData = try XCTUnwrap(server.handleMessage(delegateReq))
        let resJson = try JSONSerialization.jsonObject(with: resData) as? [String: Any]
        let result = resJson?["result"] as? [String: Any]
        let content = result?["content"] as? [[String: Any]]
        let text = content?.first?["text"] as? String ?? ""

        XCTAssertFalse(result?["isError"] as? Bool ?? false)
        XCTAssertFalse(text.contains("Warning:"), "Happy path should not include warning: \(text)")
        XCTAssertTrue(text.contains("queued for Codex"), "Expected success confirmation in: \(text)")

        let tasks = try inboxStore.load().tasks
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?.state, .queued)
    }

    func testDelegateTaskEnqueuesAndClaimsFiles() throws {
        let inboxStore = InboxStore(workspaceRoot: tempDir.path)
        let delegateReq = """
        {
          "jsonrpc": "2.0",
          "id": 10,
          "method": "tools/call",
          "params": {
            "name": "linkc_delegate_task",
            "arguments": {
              "to": "codex",
              "prompt": "Implement tokenizer module",
              "files": ["Sources/Tokenizer.swift"],
              "from": "claude",
              "pid": 1111
            }
          }
        }
        """.data(using: .utf8)!

        let resData = try XCTUnwrap(server.handleMessage(delegateReq))
        let resJson = try JSONSerialization.jsonObject(with: resData) as? [String: Any]
        let result = resJson?["result"] as? [String: Any]
        let content = result?["content"] as? [[String: Any]]
        let text = content?.first?["text"] as? String ?? ""

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
    }

    func testDelegateTaskRejectsWhenTargetAgentInCooldown() throws {
        let inboxStore = InboxStore(workspaceRoot: tempDir.path)
        // Mark codex as rate-limited
        try inboxStore.recordLimit(agent: .codex, reason: "429 Too Many Requests", cooldown: 900)

        let delegateReq = """
        {
          "jsonrpc": "2.0",
          "id": 11,
          "method": "tools/call",
          "params": {
            "name": "linkc_delegate_task",
            "arguments": {
              "to": "codex",
              "prompt": "Fix database deadlock",
              "from": "claude"
            }
          }
        }
        """.data(using: .utf8)!

        let resData = try XCTUnwrap(server.handleMessage(delegateReq))
        let resJson = try JSONSerialization.jsonObject(with: resData) as? [String: Any]
        let result = resJson?["result"] as? [String: Any]
        XCTAssertEqual(result?["isError"] as? Bool, true)

        let content = result?["content"] as? [[String: Any]]
        let text = content?.first?["text"] as? String ?? ""
        XCTAssertTrue(text.contains("cooldown"), "Error message should mention cooldown: \(text)")
        XCTAssertTrue(text.contains("429 Too Many Requests"), "Error message should include reason: \(text)")
        XCTAssertTrue(text.contains("Alternative available peer agents"), "Error message should list alternatives: \(text)")
        XCTAssertTrue(text.contains("agy"), "Should include agy as alternative: \(text)")

        // Verify no message was enqueued
        let pending = try inboxStore.fetchPending()
        XCTAssertTrue(pending.isEmpty)
    }

    func testSendMessageEnqueuesPeerNote() throws {
        let inboxStore = InboxStore(workspaceRoot: tempDir.path)
        let sendReq = """
        {
          "jsonrpc": "2.0",
          "id": 12,
          "method": "tools/call",
          "params": {
            "name": "linkc_send_message",
            "arguments": {
              "to": "agy",
              "message": "Please review the memory layout PR",
              "from": "claude"
            }
          }
        }
        """.data(using: .utf8)!

        let resData = try XCTUnwrap(server.handleMessage(sendReq))
        let resJson = try JSONSerialization.jsonObject(with: resData) as? [String: Any]
        let result = resJson?["result"] as? [String: Any]
        let content = result?["content"] as? [[String: Any]]
        let text = content?.first?["text"] as? String ?? ""
        XCTAssertTrue(text.contains("Antigravity"), "Expected queue confirmation in: \(text)")

        let pending = try inboxStore.fetchPending()
        XCTAssertEqual(pending.count, 1)
        let msg = try XCTUnwrap(pending.first)
        XCTAssertEqual(msg.toAgent, .agy)
        XCTAssertEqual(msg.fromAgent, .claude)
        XCTAssertEqual(msg.prompt, "[Peer Note from Claude Code]: Please review the memory layout PR")
        XCTAssertTrue(msg.claimedFiles.isEmpty)
    }

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

    func testGetInboxReturnsMarkdown() throws {
        let inboxStore = InboxStore(workspaceRoot: tempDir.path)
        try inboxStore.recordLimit(agent: .cursor, reason: "Quota exceeded", cooldown: 900)
        let task = try inboxStore.createTask(from: .claude, to: .agy, prompt: "Refactor error types", files: ["Sources/Error.swift"])
        _ = try inboxStore.enqueue(from: .claude, to: .agy, kind: .peerNote, body: "FYI the build is green")

        let inboxReq = """
        {
          "jsonrpc": "2.0",
          "id": 14,
          "method": "tools/call",
          "params": {
            "name": "linkc_get_inbox"
          }
        }
        """.data(using: .utf8)!

        let resData = try XCTUnwrap(server.handleMessage(inboxReq))
        let resJson = try JSONSerialization.jsonObject(with: resData) as? [String: Any]
        let result = resJson?["result"] as? [String: Any]
        let content = result?["content"] as? [[String: Any]]
        let text = content?.first?["text"] as? String ?? ""

        XCTAssertTrue(text.contains("# linkC Message Inbox"), "Expected header in: \(text)")
        XCTAssertTrue(text.contains("## Open Tasks (1)"), "Expected open tasks section in: \(text)")
        XCTAssertTrue(text.contains(task.shortId))
        XCTAssertTrue(text.contains("Refactor error types"))
        XCTAssertTrue(text.contains("Cursor Agent"), "Expected limited agent in: \(text)")
        XCTAssertTrue(text.contains("Quota exceeded"), "Expected limit reason in: \(text)")
        XCTAssertTrue(text.contains("[peerNote]"), "Expected message kind tag in: \(text)")
        XCTAssertTrue(text.contains("FYI the build is green"))
    }

    func testToolsCallBroadcastIntentAndCheckConflicts() throws {
        let broadcastReq = """
        {
          "jsonrpc": "2.0",
          "id": 3,
          "method": "tools/call",
          "params": {
            "name": "linkc_broadcast_intent",
            "arguments": {
              "agent": "claude",
              "pid": 555,
              "goal": "Refactor router",
              "files": ["Sources/Router.swift"]
            }
          }
        }
        """.data(using: .utf8)!

        let resData = try XCTUnwrap(server.handleMessage(broadcastReq))
        let resJson = try JSONSerialization.jsonObject(with: resData) as? [String: Any]
        let result = resJson?["result"] as? [String: Any]
        let content = result?["content"] as? [[String: Any]]
        XCTAssertEqual(content?.first?["type"] as? String, "text")
        let text = content?.first?["text"] as? String ?? ""
        XCTAssertTrue(text.contains("recorded"), "Expected broadcast confirmation in text: \(text)")

        // Now test check_conflicts for the same file from a different PID
        let checkReq = """
        {
          "jsonrpc": "2.0",
          "id": 4,
          "method": "tools/call",
          "params": {
            "name": "linkc_check_conflicts",
            "arguments": {
              "files": ["Sources/Router.swift"],
              "pid": 666
            }
          }
        }
        """.data(using: .utf8)!

        let checkRes = try XCTUnwrap(server.handleMessage(checkReq))
        let checkJson = try JSONSerialization.jsonObject(with: checkRes) as? [String: Any]
        let checkContent = (checkJson?["result"] as? [String: Any])?["content"] as? [[String: Any]]
        let checkText = checkContent?.first?["text"] as? String ?? ""
        XCTAssertTrue(checkText.contains("Collision Warning"), "Expected collision warning in: \(checkText)")
    }

    func testToolsCallPostNoteAndGetContext() throws {
        let noteReq = """
        {
          "jsonrpc": "2.0",
          "id": 5,
          "method": "tools/call",
          "params": {
            "name": "linkc_post_note",
            "arguments": {
              "agent": "agy",
              "title": "Config format",
              "content": "Using yaml instead of json",
              "tags": ["config"]
            }
          }
        }
        """.data(using: .utf8)!

        _ = try XCTUnwrap(server.handleMessage(noteReq))

        let contextReq = """
        {
          "jsonrpc": "2.0",
          "id": 6,
          "method": "tools/call",
          "params": {
            "name": "linkc_get_project_context"
          }
        }
        """.data(using: .utf8)!

        let ctxRes = try XCTUnwrap(server.handleMessage(contextReq))
        let ctxJson = try JSONSerialization.jsonObject(with: ctxRes) as? [String: Any]
        let ctxContent = (ctxJson?["result"] as? [String: Any])?["content"] as? [[String: Any]]
        let ctxText = ctxContent?.first?["text"] as? String ?? ""
        XCTAssertTrue(ctxText.contains("Config format"), "Context should include the note: \(ctxText)")
    }

    func testDelegateTaskValidationErrors() throws {
        // Missing 'to'
        let req1 = """
        {"jsonrpc": "2.0", "id": 20, "method": "tools/call", "params": {"name": "linkc_delegate_task", "arguments": {"prompt": "do something"}}}
        """.data(using: .utf8)!
        let res1 = try XCTUnwrap(server.handleMessage(req1))
        let json1 = try JSONSerialization.jsonObject(with: res1) as? [String: Any]
        let resResult1 = json1?["result"] as? [String: Any]
        XCTAssertEqual(resResult1?["isError"] as? Bool, true)
        let text1 = ((resResult1?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertTrue(text1.contains("Missing required argument 'to'"))

        // Unknown agent
        let req2 = """
        {"jsonrpc": "2.0", "id": 21, "method": "tools/call", "params": {"name": "linkc_delegate_task", "arguments": {"to": "skynet", "prompt": "do something"}}}
        """.data(using: .utf8)!
        let res2 = try XCTUnwrap(server.handleMessage(req2))
        let json2 = try JSONSerialization.jsonObject(with: res2) as? [String: Any]
        let resResult2 = json2?["result"] as? [String: Any]
        XCTAssertEqual(resResult2?["isError"] as? Bool, true)
        let text2 = ((resResult2?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertTrue(text2.contains("Unknown agent 'skynet'"))

        // Missing prompt
        let req3 = """
        {"jsonrpc": "2.0", "id": 22, "method": "tools/call", "params": {"name": "linkc_delegate_task", "arguments": {"to": "codex"}}}
        """.data(using: .utf8)!
        let res3 = try XCTUnwrap(server.handleMessage(req3))
        let json3 = try JSONSerialization.jsonObject(with: res3) as? [String: Any]
        let resResult3 = json3?["result"] as? [String: Any]
        XCTAssertEqual(resResult3?["isError"] as? Bool, true)
        let text3 = ((resResult3?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertTrue(text3.contains("Missing required argument 'prompt'"))

        // Cannot delegate to interactive shell
        let reqShell = """
        {"jsonrpc": "2.0", "id": 23, "method": "tools/call", "params": {"name": "linkc_delegate_task", "arguments": {"to": "shell", "prompt": "run tests"}}}
        """.data(using: .utf8)!
        let resShell = try XCTUnwrap(server.handleMessage(reqShell))
        let jsonShell = try JSONSerialization.jsonObject(with: resShell) as? [String: Any]
        let resResultShell = jsonShell?["result"] as? [String: Any]
        XCTAssertEqual(resResultShell?["isError"] as? Bool, true)
        let textShell = ((resResultShell?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertTrue(textShell.contains("Cannot delegate tasks to interactive terminal shell"))
    }

    func testSendMessageValidationErrors() throws {
        // Missing 'to'
        let req1 = """
        {"jsonrpc": "2.0", "id": 30, "method": "tools/call", "params": {"name": "linkc_send_message", "arguments": {"message": "hello"}}}
        """.data(using: .utf8)!
        let res1 = try XCTUnwrap(server.handleMessage(req1))
        let json1 = try JSONSerialization.jsonObject(with: res1) as? [String: Any]
        let resResult1 = json1?["result"] as? [String: Any]
        XCTAssertEqual(resResult1?["isError"] as? Bool, true)
        let text1 = ((resResult1?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertTrue(text1.contains("Missing required argument 'to'"))

        // Unknown agent
        let req2 = """
        {"jsonrpc": "2.0", "id": 31, "method": "tools/call", "params": {"name": "linkc_send_message", "arguments": {"to": "unknown", "message": "hello"}}}
        """.data(using: .utf8)!
        let res2 = try XCTUnwrap(server.handleMessage(req2))
        let json2 = try JSONSerialization.jsonObject(with: res2) as? [String: Any]
        let resResult2 = json2?["result"] as? [String: Any]
        XCTAssertEqual(resResult2?["isError"] as? Bool, true)
        let text2 = ((resResult2?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertTrue(text2.contains("Unknown agent 'unknown'"))

        // Missing message
        let req3 = """
        {"jsonrpc": "2.0", "id": 32, "method": "tools/call", "params": {"name": "linkc_send_message", "arguments": {"to": "agy"}}}
        """.data(using: .utf8)!
        let res3 = try XCTUnwrap(server.handleMessage(req3))
        let json3 = try JSONSerialization.jsonObject(with: res3) as? [String: Any]
        let resResult3 = json3?["result"] as? [String: Any]
        XCTAssertEqual(resResult3?["isError"] as? Bool, true)
        let text3 = ((resResult3?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertTrue(text3.contains("Missing required argument 'message'"))
    }

    func testDelegateTaskAllPeersLimitedReportsNone() throws {
        let inboxStore = InboxStore(workspaceRoot: tempDir.path)
        try inboxStore.recordLimit(agent: .codex, reason: "Quota", cooldown: 600)
        try inboxStore.recordLimit(agent: .claude, reason: "Usage limit", cooldown: 600)
        try inboxStore.recordLimit(agent: .agy, reason: "ResourceExhausted", cooldown: 600)
        try inboxStore.recordLimit(agent: .cursor, reason: "429", cooldown: 600)

        let req = """
        {"jsonrpc": "2.0", "id": 40, "method": "tools/call", "params": {"name": "linkc_delegate_task", "arguments": {"to": "codex", "prompt": "build feature"}}}
        """.data(using: .utf8)!
        let res = try XCTUnwrap(server.handleMessage(req))
        let json = try JSONSerialization.jsonObject(with: res) as? [String: Any]
        let resResult = json?["result"] as? [String: Any]
        XCTAssertEqual(resResult?["isError"] as? Bool, true)
        let text = ((resResult?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertTrue(text.contains("Alternative available peer agents: none"))
    }

    func testGetInboxEmptyState() throws {
        let req = """
        {"jsonrpc": "2.0", "id": 50, "method": "tools/call", "params": {"name": "linkc_get_inbox"}}
        """.data(using: .utf8)!
        let res = try XCTUnwrap(server.handleMessage(req))
        let json = try JSONSerialization.jsonObject(with: res) as? [String: Any]
        let resResult = json?["result"] as? [String: Any]
        let text = ((resResult?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertTrue(text.contains("No active rate limits recorded"))
        XCTAssertTrue(text.contains("No pending messages in queue"))
    }

    func testSwitchModelCatchesModelSwitcherError() throws {
        let throwingServer = MCPServer(
            workspaceRoot: tempDir.path,
            modelSwitcher: { _, _ in
                throw LinkCError.process("Failed to switch model in session")
            },
            environment: ["LINKC_AGENT": "claude"],
            ancestorResolver: { _ in nil }
        )
        let req = """
        {"jsonrpc": "2.0", "id": 90, "method": "tools/call", "params": {"name": "linkc_switch_model", "arguments": {"agent": "  claude  ", "model": "haiku"}}}
        """.data(using: .utf8)!

        let resData = try XCTUnwrap(throwingServer.handleMessage(req))
        let resJson = try JSONSerialization.jsonObject(with: resData) as? [String: Any]
        XCTAssertNil(resJson?["error"])
        let result = resJson?["result"] as? [String: Any]
        XCTAssertEqual(result?["isError"] as? Bool, true)
        let content = result?["content"] as? [[String: Any]]
        let text = content?.first?["text"] as? String ?? ""
        XCTAssertTrue(text.contains("Failed to switch model in session"))
    }
}


import XCTest
@testable import LinkCKit

final class MCPServerHandoffTests: XCTestCase {
    private var tempDir: URL!
    private var requestStore: OpenRequestStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-mcp-handoff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        requestStore = OpenRequestStore(directory: tempDir.appendingPathComponent("open-requests"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    /// A fake linkC on a simulated clock. Each time the tool waits, the clock moves on and linkC
    /// answers the request once `answerAt` has come, recording it as it found it.
    private final class World: @unchecked Sendable {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        lazy var clock = start
        var answer: OpenResult?
        var answerAt: TimeInterval = 0
        var seen: OpenRequest?
        /// Runs each time the tool reads the clock.
        var onNow: (World) -> Void = { _ in }
    }

    /// The tool's own wait, on `world`'s clock.
    private func wait(_ world: World, store: OpenRequestStore, pollInterval: TimeInterval? = nil) -> MCPServer.HandoffAnswerWait {
        var wait = MCPServer.HandoffAnswerWait(
            now: { world.onNow(world); return world.clock },
            sleep: { seconds in
                world.clock += seconds
                guard let request = store.pending().first else { return }
                if world.seen == nil { world.seen = request }
                if let answer = world.answer, world.clock.timeIntervalSince(world.start) >= world.answerAt {
                    try? store.answer(request.id, with: answer)
                }
            })
        if let pollInterval { wait.pollInterval = pollInterval }
        return wait
    }

    private func makeServer(session: String? = "source-sess-123",
                            store: OpenRequestStore? = nil,
                            world: World = World(),
                            wait handoffWait: MCPServer.HandoffAnswerWait? = nil) -> MCPServer {
        var env: [String: String] = ["LINKC_AGENT": "claude"]
        if let session {
            env["LINKC_SESSION"] = session
        }
        let store = store ?? requestStore!
        return MCPServer(
            workspaceRoot: tempDir.path,
            environment: env,
            ancestorResolver: { _ in nil },
            sessionResolver: { nil },
            usageReaders: [:],
            kiloModels: { _ in [] },
            modelLists: TestModelLists.none,
            handoffRequests: store,
            handoffAnswerWait: handoffWait ?? wait(world, store: store)
        )
    }

    func testToolsListIncludesLinkcHandoff() throws {
        let srv = makeServer()
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": [:]]
        let responseData = try XCTUnwrap(srv.handleMessage(try JSONSerialization.data(withJSONObject: request)))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        let result = try XCTUnwrap(json["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        let handoffTool = try XCTUnwrap(tools.first { ($0["name"] as? String) == "linkc_handoff" })
        XCTAssertEqual(handoffTool["name"] as? String, "linkc_handoff")

        let schema = try XCTUnwrap(handoffTool["inputSchema"] as? [String: Any])
        let props = try XCTUnwrap(schema["properties"] as? [String: Any])
        XCTAssertNotNil(props["to"])
        XCTAssertNotNil(props["tier"])
        XCTAssertNotNil(props["model"])
        XCTAssertNotNil(props["goal"])
        let required = try XCTUnwrap(schema["required"] as? [String])
        XCTAssertEqual(required, ["to"])
    }

    /// The tool writes where only a linkC that knows handoffs reads.
    func testTheToolWritesToTheHandoffFolder() {
        let srv = MCPServer(workspaceRoot: tempDir.path, environment: ["LINKC_AGENT": "claude"])
        XCTAssertEqual(srv.handoffRequests.directory, OpenRequestStore.handoffApplicationSupport.directory)
    }

    /// A linkC that predates handoffs never answers one; the agent hears that it may need updating.
    func testAnUnansweredHandoffSaysLinkCMayNeedUpdating() throws {
        let srv = makeServer()
        let res = try mcpCall(srv, "linkc_handoff", ["to": "codex"])

        XCTAssertTrue(res.isError)
        XCTAssertTrue(res.text.contains("linkC did not answer"), res.text)
        XCTAssertTrue(res.text.contains("update"), res.text)
        XCTAssertTrue(requestStore.pending().isEmpty, "the request is withdrawn")
    }

    /// linkC withdraws a request before it acts on it, and starting a session takes a while: the tool
    /// waits as long as the `linkc` command does, so an answer well past five seconds still arrives.
    func testAnAnswerAfterFiveSecondsStillArrives() throws {
        let world = World()
        world.answer = .opened(sessionId: "S2", message: "Handed off to Codex in a linkC window (p).")
        world.answerAt = 10
        let res = try mcpCall(makeServer(world: world), "linkc_handoff", ["to": "codex"])

        XCTAssertFalse(res.isError, res.text)
    }

    /// An answer that lands as the wait gives up is still reported: the handoff happened, and an agent
    /// told it failed would hand off again.
    func testAnAnswerLandingAsTheWaitEndsIsReported() throws {
        let world = World()
        let store = requestStore!
        let deadline = world.start.addingTimeInterval(MCPServer.HandoffAnswerWait.standard.timeout)
        var planted = false
        // The tool reads the clock right after its last look for an answer: linkC answers then.
        world.onNow = { world in
            guard world.clock >= deadline, !planted, let request = store.pending().first else { return }
            planted = true
            try? store.answer(request.id, with: .opened(sessionId: "S2", message: "Handed off to Codex in a linkC window (p)."))
        }
        let res = try mcpCall(makeServer(store: store, wait: wait(world, store: store, pollInterval: 10)),
                              "linkc_handoff", ["to": "codex"])

        XCTAssertTrue(planted, "the tool never gave up")
        XCTAssertFalse(res.isError, res.text)
    }

    /// Giving up, a request that could not be withdrawn may still open a session: the tool says so.
    func testAFailedWithdrawIsReported() throws {
        let world = World()
        let store = requestStore!
        let deadline = world.start.addingTimeInterval(MCPServer.HandoffAnswerWait.standard.timeout)
        world.onNow = { world in
            guard world.clock >= deadline else { return }
            try? FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: store.directory.path)
        }
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: store.directory.path) }
        let res = try mcpCall(makeServer(store: store, wait: wait(world, store: store, pollInterval: 10)),
                              "linkc_handoff", ["to": "codex"])

        XCTAssertTrue(res.isError)
        XCTAssertTrue(res.text.contains("could not be withdrawn"), res.text)
    }

    /// An answer whose file cannot be removed is still the answer, and the leftover file is named.
    func testAnAnswerFileThatCannotBeRemovedIsReported() throws {
        let world = World()
        let store = requestStore!
        let res = try mcpCall(makeServer(store: store, wait: MCPServer.HandoffAnswerWait(
            now: { world.clock },
            sleep: { seconds in
                world.clock += seconds
                guard let request = store.pending().first else { return }
                try? store.answer(request.id, with: .opened(sessionId: "S2", message: "Handed off to Codex in a linkC window (p)."))
                try? FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: store.directory.path)
            })), "linkc_handoff", ["to": "codex"])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: store.directory.path)

        XCTAssertFalse(res.isError, res.text)
        XCTAssertTrue(res.text.contains("could not be removed"), res.text)
    }

    func testHandoffWithoutCallingSessionFails() throws {
        let srv = makeServer(session: nil)
        let res = try mcpCall(srv, "linkc_handoff", ["to": "codex"])
        XCTAssertTrue(res.isError)
        XCTAssertTrue(res.text.contains("calling session") || res.text.contains("active session") || res.text.contains("LINKC_SESSION"))
    }

    func testHandoffMissingToArgumentFails() throws {
        let srv = makeServer()
        let res = try mcpCall(srv, "linkc_handoff", [:])
        XCTAssertTrue(res.isError)
        XCTAssertTrue(res.text.contains("Missing required argument 'to'"))
    }

    func testHandoffToShellFails() throws {
        let srv = makeServer()
        let res = try mcpCall(srv, "linkc_handoff", ["to": "shell"])
        XCTAssertTrue(res.isError)
        XCTAssertTrue(res.text.contains("shell"))
    }

    func testHandoffBothTierAndModelFails() throws {
        let srv = makeServer()
        let res = try mcpCall(srv, "linkc_handoff", ["to": "codex", "tier": "standard", "model": "o3-mini"])
        XCTAssertTrue(res.isError)
        XCTAssertTrue(res.text.contains("pass tier or model, not both"))
    }

    func testHandoffSubmitsOpenRequestAndReturnsNewSessionIdOnSuccess() throws {
        let store = requestStore!
        // Polling answerer in background
        let srv = makeServer(store: store, wait: MCPServer.HandoffAnswerWait(timeout: 2.0, pollInterval: 0.05))

        let backgroundThread = Thread {
            for _ in 0..<40 {
                let pending = store.pending()
                if let req = pending.first {
                    try? store.answer(req.id, with: .opened(sessionId: "new-sess-999", message: "Handed off to Codex"))
                    break
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        backgroundThread.start()

        let res = try mcpCall(srv, "linkc_handoff", [
            "to": "codex",
            "tier": "standard",
            "goal": "Migrate database"
        ])

        XCTAssertFalse(res.isError, res.text)
        XCTAssertEqual(res.text, "new-sess-999")
    }

    func testHandoffReturnsRefusalTextOnRefusal() throws {
        let store = requestStore!
        let srv = makeServer(store: store, wait: MCPServer.HandoffAnswerWait(timeout: 2.0, pollInterval: 0.05))

        let backgroundThread = Thread {
            for _ in 0..<40 {
                let pending = store.pending()
                if let req = pending.first {
                    try? store.answer(req.id, with: .refused("cursor cannot be pinned to a model"))
                    break
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        backgroundThread.start()

        let res = try mcpCall(srv, "linkc_handoff", [
            "to": "cursor",
            "model": "gpt-4o"
        ])

        XCTAssertTrue(res.isError)
        XCTAssertTrue(res.text.contains("cursor cannot be pinned to a model"))
    }
}

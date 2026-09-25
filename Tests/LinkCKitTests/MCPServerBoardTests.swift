import XCTest
@testable import LinkCKit

final class MCPServerBoardTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-mcp-board-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: tempDir)
    }

    private func server() -> MCPServer {
        MCPServer(workspaceRoot: tempDir.path, environment: ["LINKC_AGENT": "codex"], ancestorResolver: { _ in nil }, sessionResolver: { nil })
    }

    private func call(_ server: MCPServer, _ name: String, _ args: [String: Any] = [:]) throws -> (text: String, isError: Bool) {
        let req: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": args]]
        let res = try XCTUnwrap(server.handleMessage(try JSONSerialization.data(withJSONObject: req)))
        let json = try JSONSerialization.jsonObject(with: res) as? [String: Any]
        let result = json?["result"] as? [String: Any]
        let text = ((result?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        return (text, result?["isError"] as? Bool ?? false)
    }

    private var mapURL: URL { tempDir.appendingPathComponent("system-map.json") }

    func testGetBoardWithNoMapSaysEditCreatesOne() throws {
        let read = try call(server(), "linkc_get_board")
        XCTAssertFalse(read.isError)
        XCTAssertTrue(read.text.contains("no map yet"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mapURL.path), "reading never writes")
    }

    func testEditCreatesTheMapAndGetReadsItBackWithoutLayout() throws {
        let s = server()
        let edit = try call(s, "linkc_edit_board", ["steps": [["place": "Local docker"], ["add": "redis", "kind": "cache", "in": "Local docker"]]])
        XCTAssertFalse(edit.isError, edit.text)
        XCTAssertTrue(edit.text.hasSuffix("Board updated."))
        XCTAssertTrue(edit.text.contains("added redis (cache) in Local docker"))
        let read = try call(s, "linkc_get_board")
        XCTAssertTrue(read.text.contains("\"redis\""))
        XCTAssertFalse(read.text.contains("\"layout\""), "agents never see coordinates")
        XCTAssertTrue(read.text.contains("Verbs: add, update"))
        let onDisk = try XCTUnwrap(try BoardMapStore(workspacePath: tempDir.path).load())
        XCTAssertNotNil(onDisk.map.components.first?.at, "the file carries the placement")
    }

    func testARefusedEditWritesNothing() throws {
        let edit = try call(server(), "linkc_edit_board", ["steps": [["add": "a"], ["connect": "a", "to": "ghost"]]])
        XCTAssertTrue(edit.isError)
        XCTAssertTrue(edit.text.hasPrefix("step 2:"), edit.text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: mapURL.path))
    }

    func testAnUnreadableMapIsRefusedAndLeftAlone() throws {
        let broken = Data("{ not json".utf8)
        try broken.write(to: mapURL)
        XCTAssertTrue(try call(server(), "linkc_get_board").isError)
        XCTAssertTrue(try call(server(), "linkc_edit_board", ["steps": [["add": "a"]]]).isError)
        XCTAssertEqual(try Data(contentsOf: mapURL), broken)
    }

    func testAnUnidentifiedCallerCanReadButNotEdit() throws {
        let s = MCPServer(workspaceRoot: tempDir.path, environment: [:], ancestorResolver: { _ in nil }, sessionResolver: { nil })
        XCTAssertFalse(try call(s, "linkc_get_board").isError)
        XCTAssertTrue(try call(s, "linkc_edit_board", ["steps": [["add": "a"]]]).isError)
    }

    func testProjectContextPointsAtTheBoardTools() throws {
        _ = try call(server(), "linkc_edit_board", ["steps": [["add": "api"]]])
        XCTAssertTrue(try call(server(), "linkc_get_project_context").text.contains("linkc_edit_board"))
    }

    func testBothToolsAreListed() throws {
        let req: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/list"]
        let res = try XCTUnwrap(server().handleMessage(try JSONSerialization.data(withJSONObject: req)))
        let tools = (((try JSONSerialization.jsonObject(with: res) as? [String: Any])?["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
        let names = Set(tools.compactMap { $0["name"] as? String })
        XCTAssertTrue(names.isSuperset(of: ["linkc_get_board", "linkc_edit_board"]))
    }

    /// Agents can only discover the step grammar from the tool schema itself — one line per verb,
    /// naming its fields exactly, plus how `"planned"` shows up on a read.
    func testEditBoardToolDescribesTheStepGrammar() throws {
        let req: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/list"]
        let res = try XCTUnwrap(server().handleMessage(try JSONSerialization.data(withJSONObject: req)))
        let tools = (((try JSONSerialization.jsonObject(with: res) as? [String: Any])?["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
        let tool = try XCTUnwrap(tools.first { $0["name"] as? String == "linkc_edit_board" })
        let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let steps = try XCTUnwrap(properties["steps"] as? [String: Any])
        let description = try XCTUnwrap(steps["description"] as? String)
        for line in [
            #"add: {"add": name, "kind"?, "tech"?, "in"?: place, "does"?, "reached_by"?, "runs"?, "planned"?: bool}"#,
            #"update: {"update": name, same optional fields, "rename"?: new name}"#,
            #"remove: {"remove": name}"#,
            #"connect: {"connect": from, "to": to, "label"?, "style"?: plain|conditional|control|bus, "bits"?: 1-4096 (bus only)}"#,
            #"disconnect: {"disconnect": from, "to": to}"#,
            #"place: {"place": label} or {"place": label, "rename": new label}"#,
            #"remove_place: {"remove_place": label}"#,
            #"note: {"note": text}"#,
            #"remove_note: {"remove_note": exact text}"#,
            #"system: {"system": one line}"#,
        ] {
            XCTAssertTrue(description.contains(line), "missing: \(line)")
        }
        XCTAssertTrue(description.contains("\"planned\": true"), description)
        XCTAssertTrue(description.contains("\"status\": \"planned\""), description)
        XCTAssertTrue(description.contains("System: database, cache, queue, storage, service, host, external"), description)
        XCTAssertTrue(description.contains("kept and drawn as a service"), description)
    }

    /// Agents must be able to discover every kind linkC knows — including the AI-agent and
    /// hardware kinds — from both the step grammar and the `linkc_get_board` footer.
    func testEveryKnownKindAppearsInStepsDescriptionAndGetBoardFooter() throws {
        let s = server()
        _ = try call(s, "linkc_edit_board", ["steps": [["add": "api"]]])
        let read = try call(s, "linkc_get_board")
        XCTAssertFalse(read.isError, read.text)

        let req: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/list"]
        let res = try XCTUnwrap(s.handleMessage(try JSONSerialization.data(withJSONObject: req)))
        let tools = (((try JSONSerialization.jsonObject(with: res) as? [String: Any])?["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
        let tool = try XCTUnwrap(tools.first { $0["name"] as? String == "linkc_edit_board" })
        let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let steps = try XCTUnwrap(properties["steps"] as? [String: Any])
        let description = try XCTUnwrap(steps["description"] as? String)

        for kind in ComponentKind.known {
            XCTAssertTrue(description.contains(kind.raw), "steps description missing \(kind.raw)")
            XCTAssertTrue(read.text.contains(kind.raw), "get_board footer missing \(kind.raw)")
        }
        XCTAssertTrue(description.contains("checkpointer"), description)
        XCTAssertTrue(read.text.contains("checkpointer"), read.text)
        XCTAssertTrue(description.contains("hardware memory"), description)
        XCTAssertTrue(read.text.contains("hardware memory"), read.text)
    }

    /// Styles and the default rule are only discoverable from the tool schema itself.
    func testTheEditToolDescribesStyles() throws {
        let req: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/list"]
        let res = try XCTUnwrap(server().handleMessage(try JSONSerialization.data(withJSONObject: req)))
        let tools = (((try JSONSerialization.jsonObject(with: res) as? [String: Any])?["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
        let tool = try XCTUnwrap(tools.first { $0["name"] as? String == "linkc_edit_board" })
        let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let steps = try XCTUnwrap(properties["steps"] as? [String: Any])
        let description = try XCTUnwrap(steps["description"] as? String)
        XCTAssertTrue(description.contains("conditional"), description)
        XCTAssertTrue(description.contains("bus"), description)
        XCTAssertTrue(description.contains("defaults to conditional"), description)
    }

    /// The `tech` field's known ids are only discoverable from the tool schema itself.
    func testEditBoardToolDescribesTheKnownTechIDs() throws {
        let req: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/list"]
        let res = try XCTUnwrap(server().handleMessage(try JSONSerialization.data(withJSONObject: req)))
        let tools = (((try JSONSerialization.jsonObject(with: res) as? [String: Any])?["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
        let tool = try XCTUnwrap(tools.first { $0["name"] as? String == "linkc_edit_board" })
        let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let steps = try XCTUnwrap(properties["steps"] as? [String: Any])
        let description = try XCTUnwrap(steps["description"] as? String)
        XCTAssertTrue(description.contains("postgresql"), description)
    }

    // MARK: - The retry-once path

    func testEditBoardRetriesOnceWhenTheFileChangesUnderneathIt() throws {
        let store = BoardMapStore(workspacePath: tempDir.path)
        var writes = 0
        let lines = try MCPServer.editBoard(store: store, steps: [.addPlace("Local docker")], beforeSave: {
            writes += 1
            if writes == 1 {
                try BoardMap(system: "someone else's write").encoded().write(to: store.fileURL)
            }
        })
        XCTAssertEqual(lines, ["added place Local docker"])
        let onDisk = try XCTUnwrap(try store.load())
        XCTAssertTrue(onDisk.map.frames.contains { $0.label == "Local docker" }, "the edit still landed")
        XCTAssertEqual(onDisk.map.system, "someone else's write", "the racing write is not lost")
    }

    func testEditBoardGivesUpAfterASecondCollision() throws {
        let store = BoardMapStore(workspacePath: tempDir.path)
        var writes = 0
        XCTAssertThrowsError(try MCPServer.editBoard(store: store, steps: [.addPlace("Local docker")], beforeSave: {
            writes += 1
            try BoardMap(system: "racing write \(writes)").encoded().write(to: store.fileURL)
        })) { error in
            XCTAssertEqual(error as? LinkCError, .server("the map kept changing while this edit was saved — try again"))
        }
    }

    func testAnAgentEditLeavesTheMapArranged() throws {
        _ = try call(server(), "linkc_edit_board", ["steps": [["place": "App"], ["add": "api", "in": "App"], ["add": "db", "kind": "database"], ["connect": "api", "to": "db"]]])
        let onDisk = try XCTUnwrap(try BoardMapStore(workspacePath: tempDir.path).load()).map
        XCTAssertEqual(onDisk, BoardLayout.arranged(onDisk))
    }

    func testBoardDrillDownWorkflowViaMCP() throws {
        let s = server()
        let editResult = try call(s, "linkc_edit_board", [
            "steps": [
                ["add": "engine", "kind": "service"],
                ["add": "api", "kind": "service"],
                ["connect": "api", "to": "engine", "label": "requests"],
                ["detail": "engine"]
            ]
        ])
        XCTAssertFalse(editResult.isError, editResult.text)
        XCTAssertTrue(editResult.text.contains("detail board for engine: engine"))

        let engineFileURL = tempDir.appendingPathComponent("system-map.engine.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: engineFileURL.path))

        // linkc_get_board with board: "engine" shows "outside" for api
        let engineBoard = try call(s, "linkc_get_board", ["board": "engine"])
        XCTAssertFalse(engineBoard.isError, engineBoard.text)
        XCTAssertTrue(engineBoard.text.contains("\"outside\""), engineBoard.text)
        XCTAssertTrue(engineBoard.text.contains("\"api\""), engineBoard.text)

        // linkc_get_board shows a Boards: section listing overview and engine
        let overviewBoard = try call(s, "linkc_get_board")
        XCTAssertFalse(overviewBoard.isError, overviewBoard.text)
        XCTAssertTrue(overviewBoard.text.contains("Boards:"), overviewBoard.text)
        XCTAssertTrue(overviewBoard.text.contains("overview"), overviewBoard.text)
        XCTAssertTrue(overviewBoard.text.contains("engine"), overviewBoard.text)

        // board: "../x" and board: "missing" are refused with isError
        let pathTraversal = try call(s, "linkc_get_board", ["board": "../x"])
        XCTAssertTrue(pathTraversal.isError)
        let missing = try call(s, "linkc_get_board", ["board": "missing"])
        XCTAssertTrue(missing.isError)

        // linkc_edit_board with board: "engine" adds a part inside, and the overview file is unchanged
        let overviewBytesBefore = try Data(contentsOf: mapURL)
        let editEngine = try call(s, "linkc_edit_board", [
            "board": "engine",
            "steps": [
                ["add": "mixer", "kind": "service"]
            ]
        ])
        XCTAssertFalse(editEngine.isError, editEngine.text)
        let overviewBytesAfter = try Data(contentsOf: mapURL)
        XCTAssertEqual(overviewBytesBefore, overviewBytesAfter, "overview file must be unchanged")

        let engineMap = try XCTUnwrap(try BoardMapStore(workspacePath: tempDir.path, board: "engine").load()?.map)
        XCTAssertTrue(engineMap.components.contains { $0.name == "mixer" })
    }

    func testEditBoardFailsWhenDetailFileCannotBeWrittenAndOverviewHasNoDetail() throws {
        let s = server()
        _ = try call(s, "linkc_edit_board", ["steps": [["add": "Engine"]]])

        // Create a directory named system-map.engine.json so writing the detail file fails
        let engineURL = tempDir.appendingPathComponent("system-map.engine.json")
        try FileManager.default.createDirectory(at: engineURL, withIntermediateDirectories: true)

        let editResult = try call(s, "linkc_edit_board", ["steps": [["detail": "Engine"]]])
        XCTAssertTrue(editResult.isError, "Expected edit to fail")
        XCTAssertTrue(editResult.text.contains("engine"), "Expected error message to name the slug: \(editResult.text)")

        // Overview file has no detail key
        let onDisk = try XCTUnwrap(try BoardMapStore(workspacePath: tempDir.path).load()?.map)
        let engineComp = try XCTUnwrap(onDisk.components.first { $0.name == "Engine" })
        XCTAssertNil(engineComp.detail, "Overview should not have saved a detail link when detail file creation failed")
    }

    func testEditBoardListingNonexistentWorkspaceFolderThrows() throws {
        let missingPath = tempDir.appendingPathComponent("nonexistent-\(UUID().uuidString)").path
        let store = BoardMapStore(workspacePath: missingPath)
        XCTAssertThrowsError(try MCPServer.editBoard(store: store, steps: [.add("engine", BoardComponentFields(), place: nil)])) { error in
            guard let serverError = error as? LinkCError, case .server(let msg) = serverError else {
                XCTFail("expected LinkCError.server, got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("could not list"), msg)
            XCTAssertTrue(msg.contains(missingPath), msg)
        }
    }
    func testStepsSchemaDescriptionDocumentsColumnsAndTheColumnStep() {
        let text = MCPServer.stepsSchemaDescription
        XCTAssertTrue(text.contains(#""columns"?"#), text)
        XCTAssertTrue(text.contains(#""op": "column""#), text)
        XCTAssertTrue(text.contains(#""drop""#), text)
        XCTAssertTrue(text.contains("only work on a \"table\" part"), text)
    }

}

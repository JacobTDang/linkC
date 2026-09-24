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
}

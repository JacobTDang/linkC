import XCTest
@testable import LinkCKit

/// `linkc_get_board` and `linkc_get_project_context` take `project` and read that project's files
/// directly (spec 2026-11-11 cross-project §7).
final class MCPServerCrossProjectReadTests: XCTestCase {
    private var tempDir: URL!
    private var home: URL!
    private var away: URL!
    private var file: KnownProjectsFile!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-xproj-read-\(UUID().uuidString)")
        home = tempDir.appendingPathComponent("money-printer")
        away = tempDir.appendingPathComponent("away")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: away, withIntermediateDirectories: true)
        file = KnownProjectsFile(url: tempDir.appendingPathComponent("projects.json"))
        try file.write([
            KnownProject(path: ProjectPath.canonical(home.path), sessions: []),
            KnownProject(path: ProjectPath.canonical(away.path), sessions: [])
        ])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private func homeServer() -> MCPServer {
        MCPServer(workspaceRoot: home.path, environment: ["LINKC_AGENT": "claude"],
                  ancestorResolver: { _ in nil }, modelSettings: { .seeded },
                  sessionResolver: { nil }, usageReaders: [:], modelLists: TestModelLists.none, knownProjects: file)
    }

    private func awayServer() -> MCPServer {
        MCPServer(workspaceRoot: away.path, environment: ["LINKC_AGENT": "codex"],
                  ancestorResolver: { _ in nil }, modelSettings: { .seeded },
                  sessionResolver: { nil }, usageReaders: [:], modelLists: TestModelLists.none, knownProjects: file)
    }

    private func call(_ server: MCPServer, _ tool: String, _ arguments: [String: Any] = [:]) throws -> (text: String, isError: Bool) {
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                      "params": ["name": tool, "arguments": arguments]]
        let response = try XCTUnwrap(server.handleMessage(try JSONSerialization.data(withJSONObject: request)))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: response) as? [String: Any])
        let result = try XCTUnwrap(json["result"] as? [String: Any])
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        return (text, result["isError"] as? Bool ?? false)
    }

    private func seedAwayBoardAndNotes() throws {
        let awayMCP = awayServer()
        let edit = try call(awayMCP, "linkc_edit_board", [
            "steps": [
                ["add": "ledger", "kind": "database"],
                ["add": "engine", "kind": "service"],
                ["detail": "engine"]
            ]
        ])
        XCTAssertFalse(edit.isError, edit.text)
        let board = BlackboardStore(workspaceRoot: away.path)
        _ = try board.postNote(authorAgent: .codex, title: "Rate limits", content: "Codex cools down after 50 asks.")
        _ = try board.postNote(authorAgent: .claude, title: "Auth shape", content: "JWT in the cookie.")
        _ = try board.broadcastIntent(agentKind: .codex, pid: 4242, goal: "Wire the ledger", files: ["Sources/Ledger.swift"])
    }

    // MARK: - linkc_get_board(project:)

    func testGetBoardReadsAnotherProjectsOverviewAndDetail() throws {
        try seedAwayBoardAndNotes()
        let homeMCP = homeServer()
        let awayMCP = awayServer()

        let expectedOverview = try call(awayMCP, "linkc_get_board")
        XCTAssertFalse(expectedOverview.isError, expectedOverview.text)
        let crossOverview = try call(homeMCP, "linkc_get_board", ["project": "away"])
        XCTAssertFalse(crossOverview.isError, crossOverview.text)
        XCTAssertEqual(crossOverview.text, expectedOverview.text)

        let expectedDetail = try call(awayMCP, "linkc_get_board", ["board": "engine"])
        XCTAssertFalse(expectedDetail.isError, expectedDetail.text)
        let crossDetail = try call(homeMCP, "linkc_get_board", ["project": "away", "board": "engine"])
        XCTAssertFalse(crossDetail.isError, crossDetail.text)
        XCTAssertEqual(crossDetail.text, expectedDetail.text)
    }

    // MARK: - linkc_get_project_context(project:, note:)

    func testGetProjectContextListsNoteTitlesWithoutBodies() throws {
        try seedAwayBoardAndNotes()
        let result = try call(homeServer(), "linkc_get_project_context", ["project": "away"])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("Wire the ledger"), result.text)
        XCTAssertTrue(result.text.contains("engine"), "system map should include away's component: \(result.text)")
        XCTAssertTrue(result.text.contains("- Rate limits"), result.text)
        XCTAssertTrue(result.text.contains("- Auth shape"), result.text)
        XCTAssertFalse(result.text.contains("Codex cools down"), "bodies stay out of the title list: \(result.text)")
        XCTAssertFalse(result.text.contains("JWT in the cookie"), result.text)
        XCTAssertEqual(
            result.text.split(separator: "\n", omittingEmptySubsequences: true).last.map(String.init),
            #"Read one with linkc_get_project_context(project: "away", note: "<title>")."#,
            "the hint is the last line: \(result.text)"
        )
    }

    func testCrossProjectContextDoesNotOfferToEditAnotherProjectsBoard() throws {
        try seedAwayBoardAndNotes()
        let result = try call(homeServer(), "linkc_get_project_context", ["project": "away"])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertFalse(result.text.contains("linkc_edit_board"), result.text)
        XCTAssertTrue(result.text.contains(#"linkc_get_board(project: "away")"#), result.text)
        XCTAssertTrue(result.text.contains("read-only"), result.text)
    }

    func testCrossProjectContextOfAProjectWithoutAMapDoesNotOfferToStartOne() throws {
        _ = try BlackboardStore(workspaceRoot: away.path).postNote(authorAgent: .claude, title: "Auth shape", content: "JWT")
        let result = try call(homeServer(), "linkc_get_project_context", ["project": "away"])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertFalse(result.text.contains("linkc_edit_board"), result.text)
        XCTAssertTrue(result.text.contains("No map yet"), result.text)
        XCTAssertEqual(
            result.text.split(separator: "\n", omittingEmptySubsequences: true).last.map(String.init),
            #"Read one with linkc_get_project_context(project: "away", note: "<title>")."#
        )
    }

    func testReadingAnotherProjectWritesNothingInIt() throws {
        try seedAwayBoardAndNotes()
        let board = BlackboardStore(workspaceRoot: away.path)
        var stored = try board.load()
        stored.activeAgents.append(AgentRecord(
            agentId: "gone", agentKind: .claude, pid: 1, goal: "Abandoned goal", claimedFiles: [],
            lastHeartbeat: Date().addingTimeInterval(-3 * 3600)
        ))
        try board.saveRaw(stored)
        let before = try snapshot(of: away)

        let context = try call(homeServer(), "linkc_get_project_context", ["project": "away"])
        XCTAssertFalse(context.isError, context.text)
        XCTAssertFalse(context.text.contains("Abandoned goal"), "a stale agent is not shown as active: \(context.text)")
        XCTAssertTrue(context.text.contains("Wire the ledger"), context.text)
        let note = try call(homeServer(), "linkc_get_project_context", ["project": "away", "note": "auth shape"])
        XCTAssertFalse(note.isError, note.text)
        let overview = try call(homeServer(), "linkc_get_board", ["project": "away"])
        XCTAssertFalse(overview.isError, overview.text)

        XCTAssertEqual(try snapshot(of: away), before)
    }

    func testANonStringNoteIsRefused() throws {
        try seedAwayBoardAndNotes()
        let result = try call(homeServer(), "linkc_get_project_context", ["project": "away", "note": 5])
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.text, "note must be a note title")
    }

    /// Every file and folder under `folder`, by relative path (a folder's ends in "/"), with each file's bytes.
    private func snapshot(of folder: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for relative in try FileManager.default.subpathsOfDirectory(atPath: folder.path) {
            let full = folder.appendingPathComponent(relative)
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: full.path, isDirectory: &isDirectory)
            result[isDirectory.boolValue ? relative + "/" : relative] = isDirectory.boolValue ? Data() : try Data(contentsOf: full)
        }
        return result
    }

    func testGetProjectContextNoteReturnsThatNoteInFull() throws {
        try seedAwayBoardAndNotes()
        let result = try call(homeServer(), "linkc_get_project_context", ["project": "away", "note": "auth shape"])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("Auth shape"), result.text)
        XCTAssertTrue(result.text.contains("JWT in the cookie"), result.text)
        XCTAssertFalse(result.text.contains("Codex cools down"), result.text)
    }

    func testGetProjectContextUnknownNoteIsRefusedWithTitles() throws {
        try seedAwayBoardAndNotes()
        let result = try call(homeServer(), "linkc_get_project_context", ["project": "away", "note": "missing"])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("Rate limits") || result.text.lowercased().contains("rate limits"), result.text)
        XCTAssertTrue(result.text.contains("Auth shape") || result.text.lowercased().contains("auth shape"), result.text)
    }

    func testWithoutProjectBothToolsBehaveAsToday() throws {
        try seedAwayBoardAndNotes()
        let homeBoard = BlackboardStore(workspaceRoot: home.path)
        _ = try homeBoard.postNote(authorAgent: .claude, title: "Local only", content: "stays in home")
        _ = try call(homeServer(), "linkc_edit_board", ["steps": [["add": "home-api", "kind": "service"]]])

        let board = try call(homeServer(), "linkc_get_board")
        XCTAssertFalse(board.isError, board.text)
        XCTAssertTrue(board.text.contains("home-api"), board.text)
        XCTAssertFalse(board.text.contains("ledger"), board.text)

        let context = try call(homeServer(), "linkc_get_project_context")
        XCTAssertFalse(context.isError, context.text)
        XCTAssertTrue(context.text.contains("Local only"), context.text)
        XCTAssertTrue(context.text.contains("stays in home"), "local context still shows note bodies: \(context.text)")
        XCTAssertTrue(context.text.contains("change with `linkc_edit_board`"), context.text)
        XCTAssertFalse(context.text.contains("Auth shape"), context.text)
        XCTAssertFalse(context.text.contains(#"Read one with linkc_get_project_context(project:"#), context.text)
    }

    func testUnknownProjectAndMissingFileAreRefused() throws {
        let unknown = try call(homeServer(), "linkc_get_board", ["project": "ghost"])
        XCTAssertTrue(unknown.isError)
        XCTAssertEqual(unknown.text, ProjectRefError.unknown("ghost", known: ["away"]).errorDescription)

        try file.remove()
        let missing = try call(homeServer(), "linkc_get_project_context", ["project": "away"])
        XCTAssertTrue(missing.isError)
        XCTAssertEqual(missing.text, KnownProjectsError.linkCNotRunning.errorDescription)
    }
}

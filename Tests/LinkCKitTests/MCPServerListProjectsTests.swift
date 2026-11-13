import XCTest
@testable import LinkCKit

final class MCPServerListProjectsTests: XCTestCase {
    private var tempDir: URL!
    private var here: URL!
    private var file: KnownProjectsFile!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-list-projects-\(UUID().uuidString)")
        here = tempDir.appendingPathComponent("money-printer")
        try FileManager.default.createDirectory(at: here, withIntermediateDirectories: true)
        file = KnownProjectsFile(url: tempDir.appendingPathComponent("projects.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private func server(env: [String: String] = ["LINKC_AGENT": "claude"]) -> MCPServer {
        MCPServer(workspaceRoot: here.path, environment: env, ancestorResolver: { _ in nil },
                  modelSettings: { .seeded }, sessionResolver: { nil }, usageReaders: [:], kiloModels: { _ in [] }, modelLists: TestModelLists.none, knownProjects: file)
    }

    private func call(_ server: MCPServer, _ tool: String = "linkc_list_projects",
                      _ arguments: [String: Any] = [:]) throws -> (text: String, isError: Bool) {
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                      "params": ["name": tool, "arguments": arguments]]
        let response = try XCTUnwrap(server.handleMessage(try JSONSerialization.data(withJSONObject: request)))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: response) as? [String: Any])
        let result = try XCTUnwrap(json["result"] as? [String: Any])
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        return (text, result["isError"] as? Bool ?? false)
    }

    func testListsOtherProjectsWithTildePathAndSessions() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let otherDir = home.appendingPathComponent("Projects/nemo_ib-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: otherDir) }
        try FileManager.default.createDirectory(at: otherDir, withIntermediateDirectories: true)
        let other = ProjectPath.canonical(otherDir.path)
        try file.write([
            KnownProject(path: ProjectPath.canonical(here.path), sessions: []),
            KnownProject(path: other, sessions: [
                .init(id: "1", agent: "claude", activity: .idle),
                .init(id: "2", agent: "codex", activity: .busy)
            ])
        ])
        let result = try call(server())
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains(URL(fileURLWithPath: other).lastPathComponent), result.text)
        XCTAssertTrue(result.text.contains("~/Projects/"), result.text)
        XCTAssertTrue(result.text.contains("claude idle"), result.text)
        XCTAssertTrue(result.text.contains("codex busy"), result.text)
        XCTAssertFalse(result.text.contains("money-printer"), result.text)
    }

    func testAProjectWithNoSessionsShowsNoSessions() throws {
        let other = ProjectPath.canonical(tempDir.appendingPathComponent("quiet").path)
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: other), withIntermediateDirectories: true)
        try file.write([
            KnownProject(path: ProjectPath.canonical(here.path), sessions: []),
            KnownProject(path: other, sessions: [])
        ])
        let result = try call(server())
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("no sessions"), result.text)
    }

    func testNoOtherProjectSaysSo() throws {
        try file.write([KnownProject(path: ProjectPath.canonical(here.path), sessions: [])])
        let result = try call(server())
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(result.text, "No other project is known to linkC.")
    }

    func testMissingFileIsLinkCNotRunning() throws {
        let result = try call(server())
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.text, KnownProjectsError.linkCNotRunning.errorDescription)
    }

    func testUnidentifiedCallerMayUseListProjects() throws {
        try file.write([
            KnownProject(path: ProjectPath.canonical(here.path), sessions: []),
            KnownProject(path: "/p/other", sessions: [])
        ])
        let result = try call(server(env: [:]))
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(MCPServer.readOnlyTools.contains("linkc_list_projects"))
    }

    func testOnlyAWholeLeadingComponentIsShortenedToATilde() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let lookalike = home + "-lookalike/proj"
        try file.write([
            KnownProject(path: ProjectPath.canonical(here.path), sessions: []),
            KnownProject(path: lookalike, sessions: []),
            KnownProject(path: home, sessions: [])
        ])

        let lines = try call(server()).text.split(separator: "\n").map(String.init)

        XCTAssertTrue(lines.contains { $0.contains("  \(lookalike)  ") }, "a folder that only starts with the home path keeps its path: \(lines)")
        XCTAssertTrue(lines.contains { $0.contains("  ~  ") }, "the home folder itself is ~: \(lines)")
    }
}

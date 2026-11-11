import XCTest
@testable import LinkCKit

/// `MCPServer.targetProject` reads a tool's `project` argument against `projects.json` (spec
/// 2026-11-11 cross-project §4.2). Every cross-project tool goes through it.
final class MCPServerProjectArgumentTests: XCTestCase {
    private var tempDir: URL!
    private var here: URL!
    private var file: KnownProjectsFile!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-project-arg-\(UUID().uuidString)")
        here = tempDir.appendingPathComponent("money-printer")
        try FileManager.default.createDirectory(at: here, withIntermediateDirectories: true)
        file = KnownProjectsFile(url: tempDir.appendingPathComponent("projects.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private func server() -> MCPServer {
        MCPServer(workspaceRoot: here.path, environment: ["LINKC_AGENT": "claude"], ancestorResolver: { _ in nil },
                  modelSettings: { .seeded }, sessionResolver: { nil }, usageReaders: [:], knownProjects: file)
    }

    func testNoProjectArgumentMeansThisProject() throws {
        XCTAssertNil(try server().targetProject(["to": "codex"]))
    }

    func testAProjectArgumentResolvesAgainstTheFile() throws {
        let other = KnownProject(path: "/p/nemo_ib", sessions: [])
        try file.write([KnownProject(path: ProjectPath.canonical(here.path), sessions: []), other])
        XCTAssertEqual(try server().targetProject(["project": "nemo_ib"]), other)
    }

    func testTheCallersOwnFolderIsRefused() throws {
        try file.write([KnownProject(path: ProjectPath.canonical(here.path), sessions: [])])
        XCTAssertThrowsError(try server().targetProject(["project": "money-printer"])) { error in
            XCTAssertEqual(error as? ProjectRefError, .own("money-printer"))
        }
    }

    func testWithoutTheFileTheCallSaysLinkCIsNotRunning() {
        XCTAssertThrowsError(try server().targetProject(["project": "nemo_ib"])) { error in
            XCTAssertEqual(error as? KnownProjectsError, .linkCNotRunning)
        }
    }

    func testAProjectThatIsNotAStringIsRefused() throws {
        try file.write([])
        XCTAssertThrowsError(try server().targetProject(["project": 7])) { error in
            XCTAssertEqual(error as? LinkCError, .server("project must be a folder name or a full path"))
        }
    }
}

import XCTest
@testable import LinkCKit

/// The folders where linkC's MCP server runs. Each server registers its folder for its lifetime, so
/// linkC can serve a folder where an agent started outside linkC queues tasks.
final class MCPWorkspaceRegistryTests: XCTestCase {
    private var root: URL!
    private var entries: URL { root.appendingPathComponent("mcp-workspaces", isDirectory: true) }
    private var registry: MCPWorkspaceRegistry { MCPWorkspaceRegistry(directory: entries) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-mcp-registry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func folder(_ name: String) throws -> String {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    private func entryFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: entries.path).sorted()
    }

    func testARunningServersFolderIsListed() throws {
        let project = try folder("project")
        try registry.register(workspace: project, pid: 101)

        XCTAssertEqual(registry.liveWorkspaces(isRunning: { $0 == 101 }), [ProjectPath.canonical(project)])
    }

    /// A server killed before it could unregister leaves its entry behind: it is not listed, and the
    /// entry is removed so it is not read again.
    func testAServerThatIsGoneIsNotListedAndItsEntryIsRemoved() throws {
        let gone = try folder("gone"), running = try folder("running")
        try registry.register(workspace: gone, pid: 101)
        try registry.register(workspace: running, pid: 102)

        XCTAssertEqual(registry.liveWorkspaces(isRunning: { $0 == 102 }), [ProjectPath.canonical(running)])
        XCTAssertEqual(try entryFiles(), ["102.json"])
    }

    func testUnregisteringRemovesTheEntry() throws {
        try registry.register(workspace: try folder("project"), pid: 101)
        try registry.unregister(pid: 101)

        XCTAssertEqual(registry.liveWorkspaces(isRunning: { _ in true }), [])
        XCTAssertEqual(try entryFiles(), [])
    }

    func testUnregisteringAServerThatNeverRegisteredIsFine() throws {
        XCTAssertNoThrow(try registry.unregister(pid: 404))
    }

    func testTwoServersInOneFolderListItOnce() throws {
        let project = try folder("project")
        try registry.register(workspace: project, pid: 101)
        try registry.register(workspace: project, pid: 102)

        XCTAssertEqual(registry.liveWorkspaces(isRunning: { _ in true }), [ProjectPath.canonical(project)])
    }

    /// An entry that can't be read names no folder: it is removed (and logged), and the others still count.
    func testAnUnreadableEntryIsRemovedAndTheOthersListed() throws {
        let project = try folder("project")
        try registry.register(workspace: project, pid: 101)
        try Data("not json".utf8).write(to: entries.appendingPathComponent("999.json"))

        XCTAssertEqual(registry.liveWorkspaces(isRunning: { _ in true }), [ProjectPath.canonical(project)])
        XCTAssertEqual(try entryFiles(), ["101.json"])
    }

    /// linkC compares folders in their canonical form, so a server started through a symlink names the
    /// same folder as linkC's own sessions there.
    func testAFolderIsListedInItsCanonicalForm() throws {
        let real = try folder("real")
        let link = root.appendingPathComponent("link").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        try registry.register(workspace: link, pid: 101)

        XCTAssertEqual(registry.liveWorkspaces(isRunning: { _ in true }), [ProjectPath.canonical(real)])
    }

    func testNoRegistryYetListsNothing() {
        XCTAssertEqual(registry.liveWorkspaces(isRunning: { _ in true }), [])
    }

    /// A pid can be reused by an unrelated process after a server dies: only a live `linkc-mcp` counts.
    func testOnlyALiveLinkCMCPServerCountsAsRunning() throws {
        XCTAssertFalse(MCPWorkspaceRegistry.isMCPServerRunning(getpid()), "the test runner is alive but is not linkc-mcp")

        let finished = Process()
        finished.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try finished.run()
        finished.waitUntilExit()
        XCTAssertFalse(MCPWorkspaceRegistry.isMCPServerRunning(finished.processIdentifier), "a process that exited")
    }
}

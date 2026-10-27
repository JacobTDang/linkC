import XCTest
@testable import LinkCKit

/// The folders where linkC's MCP server runs. Each server registers its folder for its lifetime, so
/// linkC can serve a folder where an agent started outside linkC queues tasks.
final class MCPWorkspaceRegistryTests: XCTestCase {
    private var root: URL!
    private var entries: URL { root.appendingPathComponent("mcp-workspaces", isDirectory: true) }
    private var registry: MCPWorkspaceRegistry { MCPWorkspaceRegistry(directory: entries) }
    /// A start time for the made-up pids below; the injected check ignores it.
    private let someStart = MCPWorkspaceRegistry.ProcessStart(seconds: 1_800_000_000, microseconds: 0)

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
        try registry.register(workspace: project, pid: 101, startedAt: someStart)

        XCTAssertEqual(registry.liveWorkspaces(isRunning: { $0.pid == 101 }), [ProjectPath.canonical(project)])
    }

    /// A server killed before it could unregister leaves its entry behind: it is not listed, and the
    /// entry is removed so it is not read again.
    func testAServerThatIsGoneIsNotListedAndItsEntryIsRemoved() throws {
        let gone = try folder("gone"), running = try folder("running")
        try registry.register(workspace: gone, pid: 101, startedAt: someStart)
        try registry.register(workspace: running, pid: 102, startedAt: someStart)

        XCTAssertEqual(registry.liveWorkspaces(isRunning: { $0.pid == 102 }), [ProjectPath.canonical(running)])
        XCTAssertEqual(try entryFiles(), ["102.json"])
    }

    func testUnregisteringRemovesTheEntry() throws {
        try registry.register(workspace: try folder("project"), pid: 101, startedAt: someStart)
        try registry.unregister(pid: 101)

        XCTAssertEqual(registry.liveWorkspaces(isRunning: { _ in true }), [])
        XCTAssertEqual(try entryFiles(), [])
    }

    /// linkC may have removed the entry already (it read the server as gone): nothing to remove is fine.
    func testUnregisteringAServerThatNeverRegisteredIsFine() throws {
        XCTAssertNoThrow(try registry.unregister(pid: 404))
    }

    func testTwoServersInOneFolderListItOnce() throws {
        let project = try folder("project")
        try registry.register(workspace: project, pid: 101, startedAt: someStart)
        try registry.register(workspace: project, pid: 102, startedAt: someStart)

        XCTAssertEqual(registry.liveWorkspaces(isRunning: { _ in true }), [ProjectPath.canonical(project)])
    }

    /// An entry that can't be decoded names no folder: it is removed (and logged), and the others still count.
    func testAnUndecodableEntryIsRemovedAndTheOthersListed() throws {
        let project = try folder("project")
        try registry.register(workspace: project, pid: 101, startedAt: someStart)
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
        try registry.register(workspace: link, pid: 101, startedAt: someStart)

        XCTAssertEqual(registry.liveWorkspaces(isRunning: { _ in true }), [ProjectPath.canonical(real)])
    }

    func testNoRegistryYetListsNothing() {
        XCTAssertEqual(registry.liveWorkspaces(isRunning: { _ in true }), [])
    }

    /// The real check, end to end: the current process registers its folder and is listed by the
    /// default liveness check, then unregisters.
    func testTheCurrentProcessRegistersAndIsListedByTheRealCheck() throws {
        let project = try folder("project")
        try registry.registerCurrentProcess(workspace: project)

        XCTAssertEqual(registry.liveWorkspaces(), [ProjectPath.canonical(project)])

        try registry.unregister(pid: getpid())
        XCTAssertEqual(registry.liveWorkspaces(), [])
    }

    /// A server counts while the process with its pid is the very one that registered. Its start time
    /// tells it apart from a later process given the same pid, and it still holds after the server's
    /// own binary was deleted (a rebuild replacing the app bundle).
    func testAServerIsRunningExactlyWhileItsOwnProcessIs() throws {
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try sleeper.run()
        defer { if sleeper.isRunning { sleeper.terminate() } }
        let pid = sleeper.processIdentifier
        let started = try XCTUnwrap(MCPWorkspaceRegistry.startTime(of: pid))

        XCTAssertTrue(MCPWorkspaceRegistry.isRunning(.init(pid: pid, startedAt: started)))
        let earlier = MCPWorkspaceRegistry.ProcessStart(seconds: started.seconds - 1, microseconds: started.microseconds)
        XCTAssertFalse(MCPWorkspaceRegistry.isRunning(.init(pid: pid, startedAt: earlier)), "another process given the same pid")

        sleeper.terminate()
        sleeper.waitUntilExit()
        XCTAssertFalse(MCPWorkspaceRegistry.isRunning(.init(pid: pid, startedAt: started)), "the process exited")
    }
}

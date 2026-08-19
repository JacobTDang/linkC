import XCTest
@testable import LinkCKit

/// The MCP tracker composed over a fake runner — asserts config load, health refresh, and
/// that runner failures surface loudly instead of vanishing.
@MainActor
final class MCPServerServiceTests: XCTestCase {

    private var configURL: URL!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-mcp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        configURL = dir.appendingPathComponent("claude.json")
        let config = """
        {"mcpServers": {"alpha": {"type": "http", "url": "https://a.example/mcp"}}}
        """
        try config.data(using: .utf8)!.write(to: configURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: configURL.deletingLastPathComponent())
    }

    func testLoadConfigAndRefreshHealth() async {
        let runner = FakeRunner(result: .success("alpha: https://a.example/mcp (HTTP) - ✔ Connected\nclaude.ai Gmail: https://g.example - ! Needs authentication\n"))
        let service = MCPServerService(claudePath: "/fake/claude", configURL: configURL, runner: runner)

        service.loadConfig()
        XCTAssertEqual(service.servers.map(\.name), ["alpha"])
        XCTAssertNil(service.lastError)

        await service.refreshHealth()
        XCTAssertEqual(service.health["alpha"]?.state, .connected)
        // claude.ai connectors aren't in the config — they surface as connected accounts.
        XCTAssertEqual(service.connectedAccounts.map(\.name), ["claude.ai Gmail"])
        XCTAssertFalse(service.isRefreshing)
        XCTAssertEqual(runner.calls.first?.args, ["mcp", "list"])
    }

    func testRunnerFailureSurfacesInLastError() async {
        let runner = FakeRunner(result: .failure(LinkCError.process("claude timed out after 15s")))
        let service = MCPServerService(claudePath: "/fake/claude", configURL: configURL, runner: runner)

        await service.refreshHealth()
        XCTAssertNotNil(service.lastError)
        XCTAssertTrue(service.lastError!.contains("timed out"))
        XCTAssertFalse(service.isRefreshing)
    }

    func testMissingConfigFileFailsLoud() {
        let service = MCPServerService(
            claudePath: "/fake/claude",
            configURL: URL(fileURLWithPath: "/nonexistent/claude.json"),
            runner: FakeRunner(result: .success(""))
        )
        service.loadConfig()
        XCTAssertNotNil(service.lastError)
        XCTAssertTrue(service.servers.isEmpty)
    }
}

/// Shared fake for services that shell out — records calls, returns a canned result.
final class FakeRunner: ProcessRunner, @unchecked Sendable {
    struct Call: Equatable { let executable: String; let args: [String] }
    private let lock = NSLock()
    private var recorded: [Call] = []
    private var _result: Result<String, Error>

    var calls: [Call] { lock.withLock { recorded } }
    /// Swappable mid-test: flip to .failure to simulate a blip after a good first call.
    var result: Result<String, Error> {
        get { lock.withLock { _result } }
        set { lock.withLock { _result = newValue } }
    }

    init(result: Result<String, Error>) { self._result = result }

    func run(_ executable: String, args: [String], cwd: URL?, timeout: TimeInterval) async throws -> String {
        lock.withLock { recorded.append(Call(executable: executable, args: args)) }
        return try result.get()
    }
}

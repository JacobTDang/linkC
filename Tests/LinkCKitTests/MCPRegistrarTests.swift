import XCTest
@testable import LinkCKit

final class MCPRegistrarTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-registrar-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    func testRegisterIntoEmptyConfig() throws {
        let configFile = tempDir.appendingPathComponent("claude.json")
        try MCPRegistrar.registerServer(
            configFile: configFile,
            serverName: "linkc-multiplier",
            binaryPath: "/usr/local/bin/linkc-mcp",
            args: []
        )

        let data = try Data(contentsOf: configFile)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let mcpServers = json?["mcpServers"] as? [String: Any]
        let server = mcpServers?["linkc-multiplier"] as? [String: Any]

        XCTAssertEqual(server?["command"] as? String, "/usr/local/bin/linkc-mcp")
        XCTAssertEqual(server?["args"] as? [String], [])
    }

    func testRegisterPreservesExistingServers() throws {
        let configFile = tempDir.appendingPathComponent("cursor-mcp.json")
        let initial: [String: Any] = [
            "mcpServers": [
                "existing-tool": [
                    "command": "node",
                    "args": ["server.js"]
                ]
            ]
        ]
        let initialData = try JSONSerialization.data(withJSONObject: initial, options: [.prettyPrinted])
        try initialData.write(to: configFile)

        try MCPRegistrar.registerServer(
            configFile: configFile,
            serverName: "linkc-multiplier",
            binaryPath: "/usr/local/bin/linkc-mcp",
            args: []
        )

        let data = try Data(contentsOf: configFile)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let mcpServers = json?["mcpServers"] as? [String: Any]

        XCTAssertNotNil(mcpServers?["existing-tool"])
        XCTAssertNotNil(mcpServers?["linkc-multiplier"])
    }
}

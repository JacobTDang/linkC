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

    func testRegisterTomlIntoEmptyConfig() throws {
        let configFile = tempDir.appendingPathComponent("config.toml")
        try MCPRegistrar.registerTomlServer(
            configFile: configFile,
            serverName: "linkc-multiplier",
            binaryPath: "/usr/local/bin/linkc-mcp",
            args: []
        )

        let content = try String(contentsOf: configFile, encoding: .utf8)
        XCTAssertTrue(content.contains("[mcp_servers.linkc-multiplier]"))
        XCTAssertTrue(content.contains("command = \"/usr/local/bin/linkc-mcp\""))
    }

    func testRegisterTomlPreservesExistingTablesAndUpdates() throws {
        let configFile = tempDir.appendingPathComponent("config.toml")
        let initial = """
        model = "gpt-5"

        [mcp_servers.existing]
        command = "/usr/bin/python"
        args = ["server.py"]

        """
        try initial.write(to: configFile, atomically: true, encoding: .utf8)

        try MCPRegistrar.registerTomlServer(
            configFile: configFile,
            serverName: "linkc-multiplier",
            binaryPath: "/usr/local/bin/linkc-mcp",
            args: ["--verbose"]
        )

        var content = try String(contentsOf: configFile, encoding: .utf8)
        XCTAssertTrue(content.contains("model = \"gpt-5\""))
        XCTAssertTrue(content.contains("[mcp_servers.existing]"))
        XCTAssertTrue(content.contains("[mcp_servers.linkc-multiplier]"))
        XCTAssertTrue(content.contains("command = \"/usr/local/bin/linkc-mcp\""))
        XCTAssertTrue(content.contains("args = [\"--verbose\"]"))

        // Now test updating the existing linkc-multiplier entry
        try MCPRegistrar.registerTomlServer(
            configFile: configFile,
            serverName: "linkc-multiplier",
            binaryPath: "/opt/homebrew/bin/linkc-mcp",
            args: []
        )

        content = try String(contentsOf: configFile, encoding: .utf8)
        XCTAssertTrue(content.contains("model = \"gpt-5\""))
        XCTAssertTrue(content.contains("[mcp_servers.existing]"))
        XCTAssertTrue(content.contains("[mcp_servers.linkc-multiplier]"))
        XCTAssertTrue(content.contains("command = \"/opt/homebrew/bin/linkc-mcp\""))
        XCTAssertFalse(content.contains("/usr/local/bin/linkc-mcp"))
    }

    func testRegisterAllWritesToExpectedConfigFiles() throws {
        try MCPRegistrar.registerAll(home: tempDir, binaryPath: "/custom/bin/linkc-mcp")

        // 1. Claude Code root config ~/.claude.json
        let claudeJson = tempDir.appendingPathComponent(".claude.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: claudeJson.path))
        let claudeData = try Data(contentsOf: claudeJson)
        let claudeParsed = try JSONSerialization.jsonObject(with: claudeData) as? [String: Any]
        XCTAssertNotNil((claudeParsed?["mcpServers"] as? [String: Any])?["linkc-multiplier"])

        // 2. Claude Code directory config ~/.claude/claude.json
        let claudeDirJson = tempDir.appendingPathComponent(".claude/claude.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: claudeDirJson.path))

        // 3. Cursor config ~/.cursor/mcp.json
        let cursorJson = tempDir.appendingPathComponent(".cursor/mcp.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cursorJson.path))

        // 4. Codex config ~/.codex/config.toml
        let codexToml = tempDir.appendingPathComponent(".codex/config.toml")
        XCTAssertTrue(FileManager.default.fileExists(atPath: codexToml.path))
        let codexContent = try String(contentsOf: codexToml, encoding: .utf8)
        XCTAssertTrue(codexContent.contains("[mcp_servers.linkc-multiplier]"))
        XCTAssertTrue(codexContent.contains("command = \"/custom/bin/linkc-mcp\""))
    }

    func testRegisterServerWritesEnv() throws {
        let configFile = tempDir.appendingPathComponent("mcp.json")
        try MCPRegistrar.registerServer(configFile: configFile, binaryPath: "/x/linkc-mcp", env: ["LINKC_AGENT": "cursor"])
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: configFile)) as? [String: Any]
        let server = (json?["mcpServers"] as? [String: Any])?["linkc-multiplier"] as? [String: Any]
        XCTAssertEqual(server?["env"] as? [String: String], ["LINKC_AGENT": "cursor"])
    }

    func testRegisterTomlWritesEnvTableAndRewritesInPlace() throws {
        let configFile = tempDir.appendingPathComponent("config.toml")
        try "model = \"gpt-5\"\n".write(to: configFile, atomically: true, encoding: .utf8)
        try MCPRegistrar.registerTomlServer(configFile: configFile, binaryPath: "/x/linkc-mcp", env: ["LINKC_AGENT": "codex"])
        var content = try String(contentsOf: configFile, encoding: .utf8)
        XCTAssertTrue(content.contains("[mcp_servers.linkc-multiplier]"))
        XCTAssertTrue(content.contains("[mcp_servers.linkc-multiplier.env]"))
        XCTAssertTrue(content.contains("LINKC_AGENT = \"codex\""))

        try MCPRegistrar.registerTomlServer(configFile: configFile, binaryPath: "/y/linkc-mcp", env: ["LINKC_AGENT": "codex"])
        content = try String(contentsOf: configFile, encoding: .utf8)
        XCTAssertEqual(content.components(separatedBy: "[mcp_servers.linkc-multiplier.env]").count - 1, 1, "env table must not duplicate")
        XCTAssertTrue(content.contains("model = \"gpt-5\""))
        XCTAssertFalse(content.contains("/x/linkc-mcp"))
    }

    func testRegisterAllSetsAgentIdentityPerClient() throws {
        try MCPRegistrar.registerAll(home: tempDir, binaryPath: "/custom/bin/linkc-mcp")
        func env(_ rel: String) throws -> [String: String]? {
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: tempDir.appendingPathComponent(rel))) as? [String: Any]
            return ((json?["mcpServers"] as? [String: Any])?["linkc-multiplier"] as? [String: Any])?["env"] as? [String: String]
        }
        XCTAssertEqual(try env(".claude.json")?["LINKC_AGENT"], "claude")
        XCTAssertEqual(try env(".cursor/mcp.json")?["LINKC_AGENT"], "cursor")
        XCTAssertEqual(try env(".codex/mcp.json")?["LINKC_AGENT"], "codex")
        let codexToml = try String(contentsOf: tempDir.appendingPathComponent(".codex/config.toml"), encoding: .utf8)
        XCTAssertTrue(codexToml.contains("LINKC_AGENT = \"codex\""))
    }
}

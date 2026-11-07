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

        // 5. OpenCode config ~/.config/opencode/opencode.json
        let openCodeJson = tempDir.appendingPathComponent(".config/opencode/opencode.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: openCodeJson.path))
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

    /// A dropped `_ = rename(...)` used to tell the caller a write landed when the config file
    /// was actually untouched. An immutable file reads fine, but the real `rename(2)` cannot
    /// replace it (EPERM) — deterministic, no permission bits or timing needed — so this proves
    /// the failure now actually throws instead of returning silently. (A directory in the
    /// destination no longer reaches the rename: reading it fails first.)
    func testRegisterServerThrowsWhenTheRenameDestinationCannotBeReplaced() throws {
        let configFile = tempDir.appendingPathComponent("blocked.json")
        try "{}".write(to: configFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: configFile.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: configFile.path) }

        XCTAssertThrowsError(try MCPRegistrar.registerServer(configFile: configFile, binaryPath: "/usr/local/bin/linkc-mcp")) { error in
            XCTAssertTrue("\(error)".contains("errno"), "\(error)")
        }
    }

    /// Same failure mode as above, for the TOML writer used by Codex's config.
    func testRegisterTomlServerThrowsWhenTheRenameDestinationCannotBeReplaced() throws {
        let configFile = tempDir.appendingPathComponent("blocked.toml")
        try FileManager.default.createDirectory(at: configFile, withIntermediateDirectories: true)

        XCTAssertThrowsError(try MCPRegistrar.registerTomlServer(configFile: configFile, binaryPath: "/usr/local/bin/linkc-mcp")) { error in
            XCTAssertTrue("\(error)".contains("errno"), "\(error)")
        }
    }

    /// One client's config being unwritable must not just get logged — `registerAll` must
    /// surface it, naming which client failed, so `linkc-mcp --install` can exit non-zero
    /// instead of claiming success. Occupies `~/.claude.json` with a directory so its
    /// `rename(2)` deterministically fails with EISDIR, the same trick
    /// `testRegisterServerThrowsWhenTheRenameDestinationCannotBeReplaced` uses, while every
    /// other client's real path is left free to succeed.
    func testRegisterAllThrowsNamingEveryClientWhoseConfigFailed() throws {
        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent(".claude.json"), withIntermediateDirectories: true)

        XCTAssertThrowsError(try MCPRegistrar.registerAll(home: tempDir, binaryPath: "/custom/bin/linkc-mcp")) { error in
            XCTAssertTrue("\(error)".contains("~/.claude.json"), "\(error)")
        }

        // Every other client still got its config written despite the one failure.
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent(".cursor/mcp.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent(".codex/config.toml").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent(".config/opencode/opencode.json").path))
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
        let agyConfigDir = ["." + "g" + "e" + "m" + "i" + "n" + "i"].joined()
        XCTAssertEqual(try env("\(agyConfigDir)/config/mcp_config.json")?["LINKC_AGENT"], "agy")
        XCTAssertEqual(try env("\(agyConfigDir)/antigravity-cli/mcp.json")?["LINKC_AGENT"], "agy")
        let codexToml = try String(contentsOf: tempDir.appendingPathComponent(".codex/config.toml"), encoding: .utf8)
        XCTAssertTrue(codexToml.contains("LINKC_AGENT = \"codex\""))
    }

    /// The writer every other agent's JSON config goes through used to read a file it could not
    /// parse as empty, and overwrite it.
    func testTheSharedWriterLeavesAFileItCannotReadUntouched() throws {
        let configFile = tempDir.appendingPathComponent("mcp.json")
        let commented = "{ // servers\n \"mcpServers\": {} }"
        try commented.write(to: configFile, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try MCPRegistrar.registerServer(configFile: configFile, binaryPath: "/bin/linkc-mcp"))
        XCTAssertEqual(try String(contentsOf: configFile, encoding: .utf8), commented)
    }

    /// Valid JSON, but not an object: there is no table to add to, and nothing safe to replace it with.
    func testAFileHoldingJSONThatIsNotAnObjectIsLeftUntouched() throws {
        let configFile = tempDir.appendingPathComponent("list.json")
        let list = "[1, 2, 3]"
        try list.write(to: configFile, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try MCPRegistrar.registerServer(configFile: configFile, binaryPath: "/bin/linkc-mcp")) { error in
            XCTAssertTrue(String(describing: error).contains(configFile.path), "\(error)")
        }
        XCTAssertEqual(try String(contentsOf: configFile, encoding: .utf8), list)
    }

    func testTheSharedWriterReadsAnEmptyFileAsEmpty() throws {
        let configFile = tempDir.appendingPathComponent("empty.json")
        try " \n".write(to: configFile, atomically: true, encoding: .utf8)

        try MCPRegistrar.registerServer(configFile: configFile, binaryPath: "/bin/linkc-mcp")

        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: configFile)) as? [String: Any])
        XCTAssertNotNil((root["mcpServers"] as? [String: Any])?["linkc-multiplier"])
    }

    // MARK: - OpenCode

    private var openCodeFile: URL { tempDir.appendingPathComponent(".config/opencode/opencode.json") }

    private func openCodeEntry(in file: URL) throws -> [String: Any]? {
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        return (root["mcp"] as? [String: Any])?["linkc-multiplier"] as? [String: Any]
    }

    func testOpenCodeIsRegisteredInItsOwnShapeInAFileThatDidNotExist() throws {
        try MCPRegistrar.registerOpenCodeServer(configFile: openCodeFile, binaryPath: "/Users/someone/.local/bin/linkc-mcp")

        let entry = try XCTUnwrap(try openCodeEntry(in: openCodeFile))
        XCTAssertEqual(entry["type"] as? String, "local")
        XCTAssertEqual(entry["command"] as? [String], ["/Users/someone/.local/bin/linkc-mcp"])
        XCTAssertEqual(entry["environment"] as? [String: String], ["LINKC_AGENT": "opencode"])
        XCTAssertEqual(entry["enabled"] as? Bool, true)
    }

    /// The user's providers, model and other servers stay; the schema URL stays readable.
    func testRegisteringWithOpenCodeKeepsEveryOtherKey() throws {
        try FileManager.default.createDirectory(at: openCodeFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let initial = """
        {
          "$schema": "https://opencode.ai/config.json",
          "model": "ollama/qwen3.8:27b-32k",
          "provider": {"ollama": {"options": {"baseURL": "http://localhost:11434/v1"}}},
          "mcp": {"jobs": {"type": "local", "command": ["python3", "/x/server.py"], "enabled": true}}
        }
        """
        try initial.write(to: openCodeFile, atomically: true, encoding: .utf8)

        try MCPRegistrar.registerOpenCodeServer(configFile: openCodeFile, binaryPath: "/bin/linkc-mcp")

        let text = try String(contentsOf: openCodeFile, encoding: .utf8)
        XCTAssertTrue(text.contains("\"https://opencode.ai/config.json\""), "slashes are not escaped: \(text)")
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(root["model"] as? String, "ollama/qwen3.8:27b-32k")
        XCTAssertNotNil((root["provider"] as? [String: Any])?["ollama"])
        let mcp = try XCTUnwrap(root["mcp"] as? [String: Any])
        XCTAssertEqual((mcp["jobs"] as? [String: Any])?["command"] as? [String], ["python3", "/x/server.py"])
        XCTAssertNotNil(mcp["linkc-multiplier"])
    }

    func testAnUnchangedOpenCodeEntryIsNotRewritten() throws {
        try MCPRegistrar.registerOpenCodeServer(configFile: openCodeFile, binaryPath: "/bin/linkc-mcp")
        // The same content, laid out by hand: a rewrite would reformat it.
        let compact = #"{"mcp":{"linkc-multiplier":{"command":["/bin/linkc-mcp"],"enabled":true,"environment":{"LINKC_AGENT":"opencode"},"type":"local"}}}"#
        try compact.write(to: openCodeFile, atomically: true, encoding: .utf8)

        try MCPRegistrar.registerOpenCodeServer(configFile: openCodeFile, binaryPath: "/bin/linkc-mcp")

        XCTAssertEqual(try String(contentsOf: openCodeFile, encoding: .utf8), compact)
    }

    /// OpenCode also reads JSON with comments. linkC cannot, so it leaves such a file exactly as it is.
    func testAnOpenCodeFileThatIsNotPlainJSONIsLeftByteForByte() throws {
        try FileManager.default.createDirectory(at: openCodeFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let commented = "{\n  // my default\n  \"model\": \"ollama/qwen3.8:27b-32k\",\n}\n"
        try commented.write(to: openCodeFile, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try MCPRegistrar.registerOpenCodeServer(configFile: openCodeFile, binaryPath: "/bin/linkc-mcp")) { error in
            XCTAssertTrue(String(describing: error).contains(self.openCodeFile.path), "\(error)")
        }
        XCTAssertEqual(try String(contentsOf: openCodeFile, encoding: .utf8), commented)
    }

    func testAnOpenCodeMCPTableThatIsNotATableIsRefused() throws {
        try FileManager.default.createDirectory(at: openCodeFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let odd = #"{"mcp":["not","a","table"]}"#
        try odd.write(to: openCodeFile, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try MCPRegistrar.registerOpenCodeServer(configFile: openCodeFile, binaryPath: "/bin/linkc-mcp"))
        XCTAssertEqual(try String(contentsOf: openCodeFile, encoding: .utf8), odd)
    }

    func testRegisterAllRegistersWithOpenCode() throws {
        try MCPRegistrar.registerAll(home: tempDir, binaryPath: "/bin/linkc-mcp")
        let entry = try XCTUnwrap(try openCodeEntry(in: MCPRegistrar.openCodeConfigFile(home: tempDir)))
        XCTAssertEqual(entry["environment"] as? [String: String], ["LINKC_AGENT": "opencode"])
    }

    // MARK: - OpenCode's inline config

    private func inlineEntries(_ content: String) throws -> [String: Any] {
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
        return try XCTUnwrap(root["mcp"] as? [String: Any])
    }

    func testTheInlineConfigCarriesLinkCsServer() throws {
        let content = try MCPRegistrar.openCodeConfigContent(inherited: nil, binaryPath: "/bin/linkc-mcp", model: nil)
        XCTAssertFalse(content.contains("\n"), "one line, so it passes through an environment variable as is")
        let entry = try XCTUnwrap(try inlineEntries(content)["linkc-multiplier"] as? [String: Any])
        XCTAssertEqual(entry["command"] as? [String], ["/bin/linkc-mcp"])
        XCTAssertEqual(entry["environment"] as? [String: String], ["LINKC_AGENT": "opencode"], "no session id: OpenCode passes its own down")
    }

    func testTheInlineConfigKeepsWhatWasAlreadyInTheEnvironment() throws {
        let inherited = #"{"model":"opencode/big-pickle","mcp":{"other":{"type":"remote","url":"https://example.com/mcp"}}}"#
        let content = try MCPRegistrar.openCodeConfigContent(inherited: inherited, binaryPath: "/bin/linkc-mcp", model: nil)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
        XCTAssertEqual(root["model"] as? String, "opencode/big-pickle")
        XCTAssertNotNil(try inlineEntries(content)["other"])
        XCTAssertNotNil(try inlineEntries(content)["linkc-multiplier"])
    }

    func testABlankInheritedConfigIsNone() throws {
        let content = try MCPRegistrar.openCodeConfigContent(inherited: "  ", binaryPath: "/bin/linkc-mcp", model: nil)
        XCTAssertNotNil(try inlineEntries(content)["linkc-multiplier"])
    }

    func testAnInheritedConfigThatIsNotAJSONObjectIsRefused() {
        XCTAssertThrowsError(try MCPRegistrar.openCodeConfigContent(inherited: "model=x", binaryPath: "/bin/linkc-mcp", model: nil)) { error in
            XCTAssertTrue(String(describing: error).contains("OPENCODE_CONFIG_CONTENT"), "\(error)")
        }
    }

    func testTheInlineConfigNamesTheSessionsModel() throws {
        let inherited = #"{"model":"ollama/qwen3.8:27b-32k"}"#
        let content = try MCPRegistrar.openCodeConfigContent(inherited: inherited, binaryPath: "/bin/linkc-mcp", model: "opencode/big-pickle")
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
        XCTAssertEqual(root["model"] as? String, "opencode/big-pickle", "the session's model wins over an inherited one")
    }

    func testWithNoModelTheInlineConfigLeavesTheModelAlone() throws {
        let inherited = #"{"model":"ollama/qwen3.8:27b-32k"}"#
        let content = try MCPRegistrar.openCodeConfigContent(inherited: inherited, binaryPath: "/bin/linkc-mcp", model: nil)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
        XCTAssertEqual(root["model"] as? String, "ollama/qwen3.8:27b-32k")
    }
}

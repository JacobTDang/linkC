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

    func testFreebuffIsRegisteredInAgentsMCPWithoutDroppingOtherServers() throws {
        let configFile = tempDir.appendingPathComponent(".agents/mcp.json")
        try FileManager.default.createDirectory(at: configFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"mcpServers":{"kept":{"command":"kept"}}}"#.write(to: configFile, atomically: true, encoding: .utf8)

        try MCPRegistrar.registerFreebuffServer(configFile: configFile, binaryPath: "/bin/linkc-mcp")

        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: configFile)) as? [String: Any])
        let servers = try XCTUnwrap(root["mcpServers"] as? [String: Any])
        XCTAssertNotNil(servers["kept"])
        let linkc = try XCTUnwrap(servers[MCPRegistrar.serverName] as? [String: Any])
        XCTAssertEqual(linkc["command"] as? String, "/bin/linkc-mcp")
        XCTAssertEqual(linkc["env"] as? [String: String], ["LINKC_AGENT": "freebuff"])
    }

    func testUnreadableFreebuffConfigIsReportedAndLeftUntouched() throws {
        let configFile = tempDir.appendingPathComponent(".agents/mcp.json")
        try FileManager.default.createDirectory(at: configFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let invalid = "{ not json"
        try invalid.write(to: configFile, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try MCPRegistrar.registerFreebuffServer(configFile: configFile, binaryPath: "/bin/linkc-mcp")) { error in
            XCTAssertTrue("\(error)".contains(configFile.path), "\(error)")
        }
        XCTAssertEqual(try String(contentsOf: configFile, encoding: .utf8), invalid)
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

        // 6. Kilo config ~/.config/kilo/kilo.jsonc (created when neither jsonc nor json exists)
        let kiloJsonc = tempDir.appendingPathComponent(".config/kilo/kilo.jsonc")
        XCTAssertTrue(FileManager.default.fileExists(atPath: kiloJsonc.path))
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

    /// Same failure mode as above, for the TOML writer used by Codex's config. (A directory in
    /// the destination no longer reaches the rename here either: reading it fails first, and
    /// `testACodexConfigPathThatIsAFolderIsNamedAndLeftAlone` covers that.)
    func testRegisterTomlServerThrowsWhenTheRenameDestinationCannotBeReplaced() throws {
        let configFile = tempDir.appendingPathComponent("blocked.toml")
        try "model = \"gpt-5\"\n".write(to: configFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: configFile.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: configFile.path) }

        XCTAssertThrowsError(try MCPRegistrar.registerTomlServer(configFile: configFile, binaryPath: "/usr/local/bin/linkc-mcp")) { error in
            XCTAssertTrue("\(error)".contains("errno"), "\(error)")
        }
    }

    /// One client's config being unwritable must not just get logged — `registerAll` must
    /// surface it, naming which client failed, so `linkc-mcp --install` can exit non-zero
    /// instead of claiming success. Occupies `~/.claude.json` with a directory, which cannot be
    /// read as the config, so that client deterministically fails while every other client's
    /// real path is left free to succeed.
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
        let kiloRoot = try JSONSerialization.jsonObject(
            with: Data(contentsOf: tempDir.appendingPathComponent(".config/kilo/kilo.jsonc"))) as? [String: Any]
        let kiloEntry = (kiloRoot?["mcp"] as? [String: Any])?["linkc-multiplier"] as? [String: Any]
        XCTAssertEqual(kiloEntry?["environment"] as? [String: String], ["LINKC_AGENT": "kilo"])
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

    // MARK: - The shared writer's file handling

    private func mode(of file: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        return try XCTUnwrap((attributes[.posixPermissions] as? NSNumber)?.intValue)
    }

    /// Dotfile repos link `opencode.json` to a file they keep: registration updates that file and
    /// leaves the link a link.
    func testASymlinkedConfigStaysALinkAndItsTargetIsUpdated() throws {
        let dotfiles = tempDir.appendingPathComponent("dotfiles")
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        let kept = dotfiles.appendingPathComponent("opencode.json")
        try #"{"model":"ollama/qwen3.8:27b-32k"}"#.write(to: kept, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: openCodeFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: openCodeFile, withDestinationURL: kept)

        try MCPRegistrar.registerOpenCodeServer(configFile: openCodeFile, binaryPath: "/bin/linkc-mcp")

        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: openCodeFile.path), kept.path)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: kept)) as? [String: Any])
        XCTAssertEqual(root["model"] as? String, "ollama/qwen3.8:27b-32k")
        XCTAssertNotNil((root["mcp"] as? [String: Any])?["linkc-multiplier"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dotfiles.path), ["opencode.json"], "no temporary file left beside it")
    }

    /// A config that holds provider keys is often private to its owner; the rewrite keeps it so.
    func testAConfigKeepsItsFileModeThroughARegistration() throws {
        try FileManager.default.createDirectory(at: openCodeFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"provider":{"x":{"options":{"apiKey":"secret"}}}}"#.write(to: openCodeFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: openCodeFile.path)

        try MCPRegistrar.registerOpenCodeServer(configFile: openCodeFile, binaryPath: "/bin/linkc-mcp")

        XCTAssertNotNil(try openCodeEntry(in: openCodeFile))
        XCTAssertEqual(try mode(of: openCodeFile), 0o600)
    }

    /// A rename that fails must not leave its temporary file in the user's config folder.
    func testAFailedRenameLeavesNoTemporaryFileBehind() throws {
        let configFile = tempDir.appendingPathComponent("blocked.json")
        try "{}".write(to: configFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: configFile.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: configFile.path) }

        XCTAssertThrowsError(try MCPRegistrar.registerServer(configFile: configFile, binaryPath: "/bin/linkc-mcp")) { error in
            XCTAssertTrue("\(error)".contains("errno"), "\(error)")
        }

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: tempDir.path).filter { $0.contains(".tmp.") }
        XCTAssertEqual(leftovers, [])
    }

    /// Codex's TOML config used to be read with `try?`: a file that is not UTF-8 read as empty and
    /// was replaced by linkC's section alone.
    func testACodexConfigThatIsNotUTF8IsLeftUntouchedAndNamed() throws {
        let configFile = tempDir.appendingPathComponent("config.toml")
        let bytes = Data([0x6D, 0x6F, 0x64, 0x65, 0x6C, 0x20, 0x3D, 0x20, 0x22, 0xFF, 0xFE, 0x22, 0x0A])
        try bytes.write(to: configFile)

        XCTAssertThrowsError(try MCPRegistrar.registerTomlServer(configFile: configFile, binaryPath: "/bin/linkc-mcp")) { error in
            XCTAssertTrue(String(describing: error).contains(configFile.path), "\(error)")
        }
        XCTAssertEqual(try Data(contentsOf: configFile), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tempDir.path), ["config.toml"])
    }

    /// A config path that holds a folder cannot be read as the config either: the registration
    /// names it and changes nothing.
    func testACodexConfigPathThatIsAFolderIsNamedAndLeftAlone() throws {
        let configFile = tempDir.appendingPathComponent("config.toml")
        try FileManager.default.createDirectory(at: configFile, withIntermediateDirectories: true)

        XCTAssertThrowsError(try MCPRegistrar.registerTomlServer(configFile: configFile, binaryPath: "/bin/linkc-mcp")) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains(configFile.path) && message.contains("cannot be read"), message)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tempDir.path), ["config.toml"])
    }

    /// The TOML writer goes through the same writer as the JSON ones: a linked or private
    /// `config.toml` is updated in place, not swapped for a fresh file.
    func testACodexConfigKeepsItsLinkAndItsModeThroughARegistration() throws {
        let dotfiles = tempDir.appendingPathComponent("dotfiles")
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        let kept = dotfiles.appendingPathComponent("config.toml")
        try "model = \"gpt-5\"\n".write(to: kept, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: kept.path)
        let configFile = tempDir.appendingPathComponent("config.toml")
        try FileManager.default.createSymbolicLink(at: configFile, withDestinationURL: kept)

        try MCPRegistrar.registerTomlServer(configFile: configFile, binaryPath: "/bin/linkc-mcp")

        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: configFile.path), kept.path)
        XCTAssertEqual(try mode(of: kept), 0o600)
        let content = try String(contentsOf: kept, encoding: .utf8)
        XCTAssertTrue(content.contains("model = \"gpt-5\""))
        XCTAssertTrue(content.contains("[mcp_servers.linkc-multiplier]"))
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

    // MARK: - Kilo

    private var kiloDir: URL { tempDir.appendingPathComponent(".config/kilo") }
    private var kiloJsonc: URL { kiloDir.appendingPathComponent("kilo.jsonc") }
    private var kiloJson: URL { kiloDir.appendingPathComponent("kilo.json") }

    private func kiloEntry(in file: URL) throws -> [String: Any]? {
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        return (root["mcp"] as? [String: Any])?["linkc-multiplier"] as? [String: Any]
    }

    /// Prefer `kilo.jsonc` when it is present; otherwise `kilo.json`; otherwise create `kilo.jsonc`.
    func testKiloConfigFilePrefersJsoncThenJsonThenCreatesJsonc() throws {
        try FileManager.default.createDirectory(at: kiloDir, withIntermediateDirectories: true)

        XCTAssertEqual(MCPRegistrar.kiloConfigFile(home: tempDir), kiloJsonc,
                       "with neither file present, register creates kilo.jsonc")

        try "{}".write(to: kiloJson, atomically: true, encoding: .utf8)
        XCTAssertEqual(MCPRegistrar.kiloConfigFile(home: tempDir), kiloJson,
                       "kilo.json is used when it is the only file present")

        try "{}".write(to: kiloJsonc, atomically: true, encoding: .utf8)
        XCTAssertEqual(MCPRegistrar.kiloConfigFile(home: tempDir), kiloJsonc,
                       "kilo.jsonc wins when both are present")
    }

    func testKiloIsRegisteredInOpenCodesShapeInAFileThatDidNotExist() throws {
        try MCPRegistrar.registerKiloServer(configFile: kiloJsonc, binaryPath: "/Users/someone/.local/bin/linkc-mcp")

        let entry = try XCTUnwrap(try kiloEntry(in: kiloJsonc))
        XCTAssertEqual(entry["type"] as? String, "local")
        XCTAssertEqual(entry["command"] as? [String], ["/Users/someone/.local/bin/linkc-mcp"])
        XCTAssertEqual(entry["environment"] as? [String: String], ["LINKC_AGENT": "kilo"])
        XCTAssertEqual(entry["enabled"] as? Bool, true)
    }

    /// The user's providers, model and other servers stay.
    func testRegisteringWithKiloKeepsEveryOtherKey() throws {
        try FileManager.default.createDirectory(at: kiloDir, withIntermediateDirectories: true)
        let initial = """
        {
          "model": "kilo/kilo-auto/free",
          "provider": {"kilo": {"options": {"baseURL": "https://api.kilo.ai"}}},
          "mcp": {"jobs": {"type": "local", "command": ["python3", "/x/server.py"], "enabled": true}}
        }
        """
        try initial.write(to: kiloJsonc, atomically: true, encoding: .utf8)

        try MCPRegistrar.registerKiloServer(configFile: kiloJsonc, binaryPath: "/bin/linkc-mcp")

        let text = try String(contentsOf: kiloJsonc, encoding: .utf8)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(root["model"] as? String, "kilo/kilo-auto/free")
        XCTAssertNotNil((root["provider"] as? [String: Any])?["kilo"])
        let mcp = try XCTUnwrap(root["mcp"] as? [String: Any])
        XCTAssertEqual((mcp["jobs"] as? [String: Any])?["command"] as? [String], ["python3", "/x/server.py"])
        XCTAssertNotNil(mcp["linkc-multiplier"])
    }

    func testAnUnchangedKiloEntryIsNotRewritten() throws {
        try MCPRegistrar.registerKiloServer(configFile: kiloJsonc, binaryPath: "/bin/linkc-mcp")
        let compact = #"{"mcp":{"linkc-multiplier":{"command":["/bin/linkc-mcp"],"enabled":true,"environment":{"LINKC_AGENT":"kilo"},"type":"local"}}}"#
        try compact.write(to: kiloJsonc, atomically: true, encoding: .utf8)

        try MCPRegistrar.registerKiloServer(configFile: kiloJsonc, binaryPath: "/bin/linkc-mcp")

        XCTAssertEqual(try String(contentsOf: kiloJsonc, encoding: .utf8), compact)
    }

    /// Kilo's config is JSONC. linkC cannot rewrite comments, so it leaves such a file exactly as it is.
    func testAKiloFileThatIsNotPlainJSONIsLeftByteForByte() throws {
        try FileManager.default.createDirectory(at: kiloDir, withIntermediateDirectories: true)
        let commented = "{\n  // my default\n  \"model\": \"kilo/kilo-auto/free\",\n}\n"
        try commented.write(to: kiloJsonc, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try MCPRegistrar.registerKiloServer(configFile: kiloJsonc, binaryPath: "/bin/linkc-mcp")) { error in
            XCTAssertTrue(String(describing: error).contains(self.kiloJsonc.path), "\(error)")
        }
        XCTAssertEqual(try String(contentsOf: kiloJsonc, encoding: .utf8), commented)
    }

    func testAKiloMCPTableThatIsNotATableIsRefused() throws {
        try FileManager.default.createDirectory(at: kiloDir, withIntermediateDirectories: true)
        let odd = #"{"mcp":["not","a","table"]}"#
        try odd.write(to: kiloJsonc, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try MCPRegistrar.registerKiloServer(configFile: kiloJsonc, binaryPath: "/bin/linkc-mcp"))
        XCTAssertEqual(try String(contentsOf: kiloJsonc, encoding: .utf8), odd)
    }

    func testRegisterAllRegistersWithKilo() throws {
        try MCPRegistrar.registerAll(home: tempDir, binaryPath: "/bin/linkc-mcp")
        let file = MCPRegistrar.kiloConfigFile(home: tempDir)
        XCTAssertEqual(file.lastPathComponent, "kilo.jsonc")
        let entry = try XCTUnwrap(try kiloEntry(in: file))
        XCTAssertEqual(entry["environment"] as? [String: String], ["LINKC_AGENT": "kilo"])
    }

    func testRegisterAllUsesExistingKiloJsonWhenJsoncIsAbsent() throws {
        try FileManager.default.createDirectory(at: kiloDir, withIntermediateDirectories: true)
        try #"{"model":"kilo/kilo-auto/free"}"#.write(to: kiloJson, atomically: true, encoding: .utf8)

        try MCPRegistrar.registerAll(home: tempDir, binaryPath: "/bin/linkc-mcp")

        XCTAssertFalse(FileManager.default.fileExists(atPath: kiloJsonc.path), "must not create jsonc beside an existing json")
        let entry = try XCTUnwrap(try kiloEntry(in: kiloJson))
        XCTAssertEqual(entry["environment"] as? [String: String], ["LINKC_AGENT": "kilo"])
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: kiloJson)) as? [String: Any])
        XCTAssertEqual(root["model"] as? String, "kilo/kilo-auto/free")
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

    // MARK: - The inline config pins the model past what the user's own files say

    private let kiloModel = "kilo/kilo-auto/free"
    private let kiloSmallModel = "kilo/nvidia/nemotron-3.5-lightning:free"

    private func inlineRoot(_ content: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
    }

    /// Kilo's TUI takes `agent.<name>.model` ahead of the top-level `model`, and the pick persisted in
    /// its state ahead of that, so a top-level `model` alone leaves a paid pick running.
    func testKiloInlineConfigPinsEveryBuiltInAgentToTheSessionsModel() throws {
        let content = try MCPRegistrar.kiloConfigContent(
            inherited: nil, binaryPath: "/bin/linkc-mcp", model: kiloModel, smallModel: kiloSmallModel)
        let root = try inlineRoot(content)
        XCTAssertEqual(root["model"] as? String, kiloModel)
        let agents = try XCTUnwrap(root["agent"] as? [String: [String: Any]])
        XCTAssertEqual(Set(agents.keys), Set(AgentDescriptor.kiloAgents))
        for (name, settings) in agents {
            XCTAssertEqual(settings["model"] as? String, kiloModel, "agent \(name)")
        }
    }

    func testKiloInlineConfigNamesEveryAgentKiloHas() {
        XCTAssertEqual(
            AgentDescriptor.kiloAgents.sorted(),
            ["ask", "code", "compaction", "debug", "explore", "general", "orchestrator", "plan", "summary", "title"],
            "`kilo agent list` on 7.8.27")
    }

    /// Kilo's own default small model, `kilo-auto/small`, is not free.
    func testKiloInlineConfigPinsTheSmallModel() throws {
        let content = try MCPRegistrar.kiloConfigContent(
            inherited: nil, binaryPath: "/bin/linkc-mcp", model: kiloModel, smallModel: kiloSmallModel)
        XCTAssertEqual(try inlineRoot(content)["small_model"] as? String, kiloSmallModel)
    }

    func testKiloInlineConfigOverridesAnInheritedAgentModelAndKeepsItsOtherSettings() throws {
        let inherited = #"{"small_model":"kilo/kilo-auto/small","agent":{"code":{"model":"kilo/anthropic/claude-opus-5","prompt":"be brief"},"mine":{"model":"kilo/x/y:free"}}}"#
        let content = try MCPRegistrar.kiloConfigContent(
            inherited: inherited, binaryPath: "/bin/linkc-mcp", model: kiloModel, smallModel: kiloSmallModel)
        let root = try inlineRoot(content)
        let agents = try XCTUnwrap(root["agent"] as? [String: [String: Any]])
        XCTAssertEqual(agents["code"]?["model"] as? String, kiloModel)
        XCTAssertEqual(agents["code"]?["prompt"] as? String, "be brief")
        XCTAssertEqual(agents["mine"]?["model"] as? String, "kilo/x/y:free", "an agent linkC does not know is left as it was")
        XCTAssertEqual(root["small_model"] as? String, kiloSmallModel)
    }

    func testKiloInlineConfigRefusesAnInheritedAgentThatIsNotATable() {
        XCTAssertThrowsError(try MCPRegistrar.kiloConfigContent(
            inherited: #"{"agent":{"code":"fast"}}"#, binaryPath: "/bin/linkc-mcp",
            model: kiloModel, smallModel: kiloSmallModel)) { error in
            XCTAssertTrue(String(describing: error).contains("KILO_CONFIG_CONTENT"), "\(error)")
        }
    }

    /// OpenCode's TUI takes a user-global `agent.build.model` ahead of the inline top-level `model` too.
    func testOpenCodeInlineConfigPinsEveryAgentThatRunsOnTheSessionsModel() throws {
        let content = try MCPRegistrar.openCodeConfigContent(
            inherited: #"{"agent":{"build":{"model":"anthropic/claude-opus-5","steps":9}}}"#,
            binaryPath: "/bin/linkc-mcp", model: "opencode/big-pickle")
        let root = try inlineRoot(content)
        let agents = try XCTUnwrap(root["agent"] as? [String: [String: Any]])
        XCTAssertEqual(Set(agents.keys), Set(AgentDescriptor.openCodeAgents))
        for (name, settings) in agents {
            XCTAssertEqual(settings["model"] as? String, "opencode/big-pickle", "agent \(name)")
        }
        XCTAssertEqual(agents["build"]?["steps"] as? Int, 9)
    }

    func testOpenCodeAgentsAreTheOnesOpenCodeRunsOnTheSessionsModel() {
        XCTAssertEqual(
            AgentDescriptor.openCodeAgents.sorted(),
            ["build", "compaction", "explore", "general", "plan", "summary"],
            "`opencode debug agents --standalone` on 2.2.5, less `title`, which runs on the user's small model")
    }

    func testWithNoModelOpenCodePinsNoAgent() throws {
        let content = try MCPRegistrar.openCodeConfigContent(
            inherited: #"{"agent":{"build":{"model":"ollama/qwen3.8:27b"}}}"#, binaryPath: "/bin/linkc-mcp", model: nil)
        let agents = try XCTUnwrap(try inlineRoot(content)["agent"] as? [String: [String: Any]])
        XCTAssertEqual(agents["build"]?["model"] as? String, "ollama/qwen3.8:27b")
        XCTAssertEqual(agents.count, 1)
    }
}

import XCTest
@testable import LinkCKit

/// Finding the agent-browser server each agent's own config registers, as linkC reads it before a
/// launch: only a server that is really there gets a browser, and a config linkC cannot read says why.
final class AgentBrowserServerTests: XCTestCase {
    var home: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        home = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-browser-discovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
        try super.tearDownWithError()
    }

    private func write(_ text: String, to relativePath: String) throws {
        let file = home.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    private func server(_ agent: AgentKind, cwd: String = "/tmp/project") throws -> AgentBrowserServer? {
        try MCPRegistrar.agentBrowserServer(for: agent, cwd: cwd, home: home, environment: [:])
    }

    // MARK: - Codex

    func testCodexFindsABareKeyServerByItsCommand() throws {
        try write("""
        [mcp_servers.browser-tools]
        command = "/custom/agent-browser"
        args = ["mcp"]
        """, to: ".codex/config.toml")

        let found = try XCTUnwrap(try server(.codex))
        XCTAssertEqual(found.name, "browser-tools")
        XCTAssertEqual(found.commandLine, ["/custom/agent-browser", "mcp"])
        XCTAssertEqual(found.cliPrefix, ["/custom/agent-browser"])
    }

    /// A server's `env` sub-table that mentions agent-browser is not a server: the old match returned
    /// `other.env`, and Codex then refused to start ("invalid type: map").
    func testCodexSkipsASubTableAndFindsTheRealServerAfterIt() throws {
        try write("""
        [mcp_servers.other]
        command = "/bin/other"

        [mcp_servers.other.env]
        NOTE = "agent-browser"

        [mcp_servers.browser-tools]
        command = "npx"
        args = [
          "-y",
          "agent-browser",
          "mcp",
        ]
        """, to: ".codex/config.toml")

        let found = try XCTUnwrap(try server(.codex))
        XCTAssertEqual(found.name, "browser-tools")
        XCTAssertEqual(found.cliPrefix, ["npx", "-y", "agent-browser"])
    }

    func testCodexIgnoresAgentBrowserInComments() throws {
        try write("""
        # [mcp_servers.agent-browser]
        [mcp_servers.notes]
        command = "/bin/notes" # was agent-browser
        # args = ["agent-browser"]
        """, to: ".codex/config.toml")

        XCTAssertNil(try server(.codex))
    }

    /// `[mcp_servers."agent-browser"]` is the same key as the bare one, and Codex's `-c` override must
    /// name it bare: the quoted name made Codex create a second server and fail ("invalid transport").
    func testCodexReturnsAQuotedNameThatNeedsNoQuotesBare() throws {
        try write("""
        [mcp_servers."agent-browser"]
        command = "agent-browser"
        args = ["mcp"]
        """, to: ".codex/config.toml")

        XCTAssertEqual(try server(.codex)?.name, "agent-browser")
    }

    func testCodexRefusesANameThatNeedsQuotesAndSaysSo() throws {
        try write("""
        [mcp_servers."agent browser"]
        command = "agent-browser"
        """, to: ".codex/config.toml")

        XCTAssertThrowsError(try server(.codex)) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("\"agent browser\""), message)
            XCTAssertTrue(message.contains("config.toml"), message)
        }
    }

    func testCodexSkipsADisabledServer() throws {
        try write("""
        [mcp_servers.agent-browser]
        command = "agent-browser"
        enabled = false
        """, to: ".codex/config.toml")

        XCTAssertNil(try server(.codex))
    }

    // MARK: - OpenCode-style JSON

    func testOpenCodeFindsAServerByItsCommandArrayAndKeepsTheWholeEntry() throws {
        try write(#"{"mcp":{"web":{"type":"local","command":["agent-browser","mcp"],"timeout":9000}}}"#,
                  to: ".config/opencode/opencode.json")

        let found = try XCTUnwrap(try server(.opencode))
        XCTAssertEqual(found.name, "web")
        XCTAssertEqual(found.cliPrefix, ["agent-browser"])
        let entry = try XCTUnwrap(found.entryJSON.flatMap {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        })
        XCTAssertEqual(entry["timeout"] as? Int, 9000)
    }

    /// `kilo.jsonc` may hold comments and trailing commas. Reading it with a plain JSON parser used to
    /// drop browser sharing for Kilo without a word.
    func testKiloReadsAJSONCConfigWithCommentsAndTrailingCommas() throws {
        try write("""
        {
          // the user's browser
          "mcp": {
            "browser": {
              "type": "local", /* local server */
              "command": ["/opt/agent-browser", "mcp"],
              "url": "http://keep//this",
            },
          },
        }
        """, to: ".config/kilo/kilo.jsonc")

        let found = try XCTUnwrap(try server(.kilo))
        XCTAssertEqual(found.name, "browser")
        XCTAssertEqual(found.commandLine, ["/opt/agent-browser", "mcp"])
        XCTAssertTrue(found.entryJSON?.contains("http://keep//this") == true, found.entryJSON ?? "")
    }

    func testAConfigThatIsNotJSONSaysWhichFile() throws {
        try write(#"{"mcp": {"web": "#, to: ".config/opencode/opencode.json")

        XCTAssertThrowsError(try server(.opencode)) { error in
            XCTAssertTrue(error.localizedDescription.contains("opencode.json"), error.localizedDescription)
        }
    }

    func testADisabledOpenCodeServerIsNotFound() throws {
        try write(#"{"mcp":{"web":{"type":"local","command":["agent-browser","mcp"],"enabled":false}}}"#,
                  to: ".config/opencode/opencode.json")

        XCTAssertNil(try server(.opencode))
    }

    // MARK: - mcpServers-shaped JSON

    func testClaudeFindsAUserScopeServer() throws {
        try write(#"{"mcpServers":{"agent-browser":{"command":"/home/bin/agent-browser","args":["mcp"]}}}"#,
                  to: ".claude.json")

        XCTAssertEqual(try server(.claude)?.cliPrefix, ["/home/bin/agent-browser"])
    }

    func testClaudeFindsAServerOfTheSessionsProjectOnly() throws {
        try write(#"""
        {"projects":{
          "/tmp/elsewhere":{"mcpServers":{"other-browser":{"command":"agent-browser","args":["mcp"]}}},
          "/tmp/project":{"mcpServers":{"browser":{"command":"npx","args":["agent-browser@latest","mcp"]}}}
        }}
        """#, to: ".claude.json")

        XCTAssertEqual(try server(.claude, cwd: "/tmp/project")?.name, "browser")
        XCTAssertEqual(try server(.claude, cwd: "/tmp/project")?.cliPrefix, ["npx", "agent-browser@latest"])
        XCTAssertNil(try server(.claude, cwd: "/tmp/third"))
    }

    func testClaudeFindsAServerInTheProjectsMCPFile() throws {
        let project = home.appendingPathComponent("repo")
        try write(#"{"mcpServers":{"browser":{"command":"agent-browser","args":["mcp"]}}}"#, to: "repo/.mcp.json")

        XCTAssertEqual(try server(.claude, cwd: project.path)?.name, "browser")
    }

    func testAgyAndCrushReadTheirOwnConfigs() throws {
        try write(#"{"mcpServers":{"ab":{"command":"agent-browser","args":["mcp"]}}}"#, to: ".gemini/config/mcp_config.json")
        try write(#"{"mcp":{"ab-crush":{"type":"stdio","command":"agent-browser","args":["mcp"]}}}"#, to: ".config/crush/crush.json")

        XCTAssertEqual(try server(.agy)?.name, "ab")
        XCTAssertEqual(try server(.crush)?.name, "ab-crush")
    }

    /// Cursor, Grok and Freebuff start their MCP servers with a fixed handful of variables
    /// (cursor-agent: HOME, LOGNAME, PATH, SHELL, TERM, USER, TMPDIR; Freebuff the same less TMPDIR),
    /// so a browser started for them would never reach their server. Their configs are not read.
    func testAgentsThatCannotPassTheBrowserOnFindNoServer() throws {
        let entry = #"{"mcpServers":{"agent-browser":{"command":"agent-browser","args":["mcp"]}}}"#
        try write(entry, to: ".cursor/mcp.json")
        try write(entry, to: ".cursor-grok/mcp.json")
        try write(entry, to: ".agents/mcp.json")

        XCTAssertNil(try server(.cursor))
        XCTAssertNil(try server(.grok))
        XCTAssertNil(try server(.freebuff))
    }

    func testNoServerIsFoundWhenNoConfigNamesAgentBrowser() throws {
        try write(#"{"mcpServers":{"linkc-multiplier":{"command":"/bin/linkc-mcp","args":[]}}}"#, to: ".claude.json")

        for agent in AgentKind.allCases {
            XCTAssertNil(try server(agent), "\(agent)")
        }
    }

    // MARK: - JSONC

    func testJSONCStripsCommentsAndTrailingCommasButNotStrings() throws {
        let text = #"{"a": "x // y /* z */", /* c */ "b": [1, 2,], // d"# + "\n}"
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(MCPRegistrar.strippingJSONC(text).utf8)) as? [String: Any])
        XCTAssertEqual(object["a"] as? String, "x // y /* z */")
        XCTAssertEqual(object["b"] as? [Int], [1, 2])
    }
}

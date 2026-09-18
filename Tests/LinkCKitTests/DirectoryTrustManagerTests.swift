import XCTest
@testable import LinkCKit

final class DirectoryTrustManagerTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-trust-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    // MARK: Codex — `[projects."<path>"] trust_level = "trusted"` in ~/.codex/config.toml

    func testCodexTrustIsAppendedWithoutTouchingTheRestOfTheFile() throws {
        let url = tempDir.appendingPathComponent("config.toml")
        let existing = """
        model = "gpt-5.6-sol"

        [projects."/Users/developer/projects/other"]
        trust_level = "trusted"

        [mcp_servers.linkc-multiplier]
        command = "/usr/local/bin/linkc-mcp"
        """
        try existing.write(to: url, atomically: true, encoding: .utf8)

        try DirectoryTrustManager.preApproveCodexTrust(workspacePath: "/Users/developer/projects/demo", configURL: url)

        let after = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(after.hasPrefix(existing), "everything already in the file is kept as it was")
        XCTAssertTrue(after.contains("[projects.\"/Users/developer/projects/demo\"]\ntrust_level = \"trusted\"\n"))
    }

    func testCodexTrustLeavesAFolderThatIsAlreadyListedAlone() throws {
        let url = tempDir.appendingPathComponent("config.toml")
        let existing = "[projects.\"/Users/developer/projects/demo\"]\ntrust_level = \"untrusted\"\n"
        try existing.write(to: url, atomically: true, encoding: .utf8)

        try DirectoryTrustManager.preApproveCodexTrust(workspacePath: "/Users/developer/projects/demo", configURL: url)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), existing, "an explicit choice for this folder is never overridden")
    }

    func testCodexTrustCreatesTheConfigWhenMissing() throws {
        let url = tempDir.appendingPathComponent("codex/config.toml")

        try DirectoryTrustManager.preApproveCodexTrust(workspacePath: "/Users/developer/projects/demo/", configURL: url)

        XCTAssertEqual(
            try String(contentsOf: url, encoding: .utf8),
            "[projects.\"/Users/developer/projects/demo\"]\ntrust_level = \"trusted\"\n"
        )
    }

    func testCodexTrustIsNotFooledByTheHeaderInsideAComment() throws {
        let url = tempDir.appendingPathComponent("config.toml")
        try "# see [projects.\"/Users/developer/projects/demo\"] for notes\n".write(to: url, atomically: true, encoding: .utf8)

        try DirectoryTrustManager.preApproveCodexTrust(workspacePath: "/Users/developer/projects/demo", configURL: url)

        XCTAssertTrue(
            try String(contentsOf: url, encoding: .utf8).contains("\n[projects.\"/Users/developer/projects/demo\"]\ntrust_level = \"trusted\"\n"),
            "only a real table header counts as already listed"
        )
    }

    /// TOML rejects a table defined twice, so a folder already listed in any spelling of the same
    /// table must be recognised: appending a duplicate would break Codex's whole config.
    func testCodexTrustRecognisesEquivalentSpellingsOfTheHeader() throws {
        for existing in [
            "[projects.\"/Users/developer/projects/demo\"] # trusted via CLI\ntrust_level = \"trusted\"\n",
            "[projects.'/Users/developer/projects/demo']\ntrust_level = \"trusted\"\n",
            "[ projects . \"/Users/developer/projects/demo\" ]\ntrust_level = \"trusted\"\n",
        ] {
            let url = tempDir.appendingPathComponent("config-\(UUID().uuidString).toml")
            try existing.write(to: url, atomically: true, encoding: .utf8)

            try DirectoryTrustManager.preApproveCodexTrust(workspacePath: "/Users/developer/projects/demo", configURL: url)

            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), existing, "already listed as: \(existing.prefix(55))")
        }
    }

    func testCodexTrustEscapesAQuoteInThePath() throws {
        let url = tempDir.appendingPathComponent("config.toml")

        try DirectoryTrustManager.preApproveCodexTrust(workspacePath: "/Users/developer/my \"app\"", configURL: url)

        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("[projects.\"/Users/developer/my \\\"app\\\"\"]"))
    }

    // MARK: Antigravity — `trustedWorkspaces` in ~/.gemini/antigravity-cli/settings.json

    func testAgyTrustAddsTheFolderAndKeepsOtherSettings() throws {
        let url = tempDir.appendingPathComponent("settings.json")
        try #"{"colorScheme":"dark","trustedWorkspaces":["/Users/developer/projects/other"]}"#
            .write(to: url, atomically: true, encoding: .utf8)

        try DirectoryTrustManager.preApproveAgyTrust(workspacePath: "/Users/developer/projects/demo", settingsURL: url)

        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(json["colorScheme"] as? String, "dark")
        XCTAssertEqual(json["trustedWorkspaces"] as? [String], ["/Users/developer/projects/other", "/Users/developer/projects/demo"])
    }

    func testAgyTrustDoesNotListAFolderTwice() throws {
        let url = tempDir.appendingPathComponent("settings.json")
        let existing = #"{"trustedWorkspaces":["/Users/developer/projects/demo"]}"#
        try existing.write(to: url, atomically: true, encoding: .utf8)

        try DirectoryTrustManager.preApproveAgyTrust(workspacePath: "/Users/developer/projects/demo", settingsURL: url)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), existing, "nothing to add, so the file is not rewritten")
    }

    func testAgyTrustNeverOverwritesSettingsItCannotRead() throws {
        let url = tempDir.appendingPathComponent("settings.json")
        try "not json".write(to: url, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try DirectoryTrustManager.preApproveAgyTrust(workspacePath: "/Users/developer/projects/demo", settingsURL: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "not json", "a file linkC cannot parse is never clobbered")
    }

    func testAgyTrustRefusesATrustListThatIsNotPaths() throws {
        let url = tempDir.appendingPathComponent("settings.json")
        let existing = #"{"trustedWorkspaces":[1,"/Users/developer/projects/other"]}"#
        try existing.write(to: url, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try DirectoryTrustManager.preApproveAgyTrust(workspacePath: "/Users/developer/projects/demo", settingsURL: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), existing, "an unexpected trust list is never replaced")
    }

    func testAgyTrustCreatesTheSettingsWhenMissing() throws {
        let url = tempDir.appendingPathComponent("agy/settings.json")

        try DirectoryTrustManager.preApproveAgyTrust(workspacePath: "/Users/developer/projects/demo", settingsURL: url)

        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(json["trustedWorkspaces"] as? [String], ["/Users/developer/projects/demo"])
    }

    // MARK: Claude

    func testMissingClaudeJsonCreatesValidFileWithTrustedPath() throws {
        let jsonURL = tempDir.appendingPathComponent(".claude.json")
        let workspace = "/Users/developer/projects/demo"

        try DirectoryTrustManager.preApproveTrust(workspacePath: workspace, claudeJsonURL: jsonURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: jsonURL.path))
        let data = try Data(contentsOf: jsonURL)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        let projects = try XCTUnwrap(json["projects"] as? [String: Any])
        let projectConfig = try XCTUnwrap(projects[workspace] as? [String: Any])
        XCTAssertEqual(projectConfig["hasTrustDialogAccepted"] as? Bool, true)

        let trusted = try XCTUnwrap(json["trustedDirectories"] as? [String])
        XCTAssertEqual(trusted, [workspace])
    }

    func testExistingClaudeJsonPreservesOtherProjectsAndAddsTrust() throws {
        let jsonURL = tempDir.appendingPathComponent(".claude.json")
        let existing: [String: Any] = [
            "projects": [
                "/Users/developer/projects/existing": [
                    "hasTrustDialogAccepted": true,
                    "customSetting": "preserved"
                ]
            ],
            "trustedDirectories": ["/Users/developer/projects/existing"],
            "mcpServers": [
                "test-server": ["command": "cat"]
            ]
        ]
        let initialData = try JSONSerialization.data(withJSONObject: existing, options: [.prettyPrinted])
        try initialData.write(to: jsonURL)

        let newWorkspace = "/Users/developer/projects/new-repo"
        try DirectoryTrustManager.preApproveTrust(workspacePath: newWorkspace, claudeJsonURL: jsonURL)

        let data = try Data(contentsOf: jsonURL)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        // Verify existing project is preserved
        let projects = try XCTUnwrap(json["projects"] as? [String: Any])
        let existingConfig = try XCTUnwrap(projects["/Users/developer/projects/existing"] as? [String: Any])
        XCTAssertEqual(existingConfig["hasTrustDialogAccepted"] as? Bool, true)
        XCTAssertEqual(existingConfig["customSetting"] as? String, "preserved")

        // Verify new project is added
        let newConfig = try XCTUnwrap(projects[newWorkspace] as? [String: Any])
        XCTAssertEqual(newConfig["hasTrustDialogAccepted"] as? Bool, true)

        // Verify other keys preserved
        XCTAssertNotNil(json["mcpServers"])

        // Verify trustedDirectories contains both
        let trusted = try XCTUnwrap(json["trustedDirectories"] as? [String])
        XCTAssertTrue(trusted.contains("/Users/developer/projects/existing"))
        XCTAssertTrue(trusted.contains(newWorkspace))
    }

    func testPreApproveIsIdempotentAndDoesNotDuplicate() throws {
        let jsonURL = tempDir.appendingPathComponent(".claude.json")
        let workspace = "/Users/developer/projects/idempotent-test"

        try DirectoryTrustManager.preApproveTrust(workspacePath: workspace, claudeJsonURL: jsonURL)
        try DirectoryTrustManager.preApproveTrust(workspacePath: workspace, claudeJsonURL: jsonURL)

        let data = try Data(contentsOf: jsonURL)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        let trusted = try XCTUnwrap(json["trustedDirectories"] as? [String])
        XCTAssertEqual(trusted.filter { $0 == workspace }.count, 1)

        let projects = try XCTUnwrap(json["projects"] as? [String: Any])
        let config = try XCTUnwrap(projects[workspace] as? [String: Any])
        XCTAssertEqual(config["hasTrustDialogAccepted"] as? Bool, true)
    }

    func testWorkspacePathNormalization() throws {
        let jsonURL = tempDir.appendingPathComponent(".claude.json")
        let pathWithTrailingSlash = "/Users/developer/projects/demo/"
        let normalizedPath = "/Users/developer/projects/demo"

        try DirectoryTrustManager.preApproveTrust(workspacePath: pathWithTrailingSlash, claudeJsonURL: jsonURL)

        let data = try Data(contentsOf: jsonURL)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        let projects = try XCTUnwrap(json["projects"] as? [String: Any])
        XCTAssertNil(projects[pathWithTrailingSlash])
        XCTAssertNotNil(projects[normalizedPath])

        let trusted = try XCTUnwrap(json["trustedDirectories"] as? [String])
        XCTAssertTrue(trusted.contains(normalizedPath))
        XCTAssertFalse(trusted.contains(pathWithTrailingSlash))
    }

    func testAppCoordinatorClaudeLaunchArgsIncludesYoloFlag() {
        let settingsPath = "/tmp/session-test.json"

        let newArgs = AppCoordinator.claudeLaunchArgs(mode: .new, resumeId: nil, settingsPath: settingsPath)
        XCTAssertTrue(newArgs.contains("--dangerously-skip-permissions"))
        XCTAssertEqual(newArgs, ["--dangerously-skip-permissions", "--settings", settingsPath])

        let contArgs = AppCoordinator.claudeLaunchArgs(mode: .continueLast, resumeId: nil, settingsPath: settingsPath)
        XCTAssertTrue(contArgs.contains("--dangerously-skip-permissions"))
        XCTAssertEqual(contArgs, ["--continue", "--dangerously-skip-permissions", "--settings", settingsPath])

        let resumeArgs = AppCoordinator.claudeLaunchArgs(mode: .resume, resumeId: "conv-123", settingsPath: settingsPath)
        XCTAssertTrue(resumeArgs.contains("--dangerously-skip-permissions"))
        XCTAssertEqual(resumeArgs, ["--resume", "conv-123", "--dangerously-skip-permissions", "--settings", settingsPath])
    }

    @MainActor
    func testAppCoordinatorPreApprovesTrustOnLaunch() throws {
        let jsonURL = tempDir.appendingPathComponent(".claude.json")
        let cwd = tempDir.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)

        let coordinator = AppCoordinator(
            terminals: TerminalSessionManager(),
            hookServer: HookServer(port: 0),
            notifications: NotificationManager(sink: RecordingSink(), now: { Date() }),
            claudePath: "/bin/cat",
            settingsDir: tempDir.appendingPathComponent("settings"),
            userSettingsURL: tempDir.appendingPathComponent("no-such-settings.json"),
            manifestDir: tempDir.appendingPathComponent("manifest"),
            claudeJsonURL: jsonURL,
            isWatching: { _ in false }
        )

        let session = try coordinator.newSession(cwd: cwd.path, agent: .claude, mode: .new)
        defer { coordinator.stopSession(session.id) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: jsonURL.path))
        let data = try Data(contentsOf: jsonURL)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        let normCwd = (cwd.path as NSString).standardizingPath
        let projects = try XCTUnwrap(json["projects"] as? [String: Any])
        let projectConfig = try XCTUnwrap(projects[normCwd] as? [String: Any])
        XCTAssertEqual(projectConfig["hasTrustDialogAccepted"] as? Bool, true)

        let trusted = try XCTUnwrap(json["trustedDirectories"] as? [String])
        XCTAssertTrue(trusted.contains(normCwd))
    }
}

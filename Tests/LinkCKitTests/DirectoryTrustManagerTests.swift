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

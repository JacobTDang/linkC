import XCTest
@testable import LinkCKit

/// The per-session Crush config that pins a session's model. Crush reads `crush.json` from the
/// folder `CRUSH_GLOBAL_CONFIG` names, then `crush.json` from its data folder (`CRUSH_GLOBAL_DATA`),
/// which Crush itself writes when a model is picked in the TUI; both are copied per session so
/// neither can override the pin. Nothing here reads or writes the real `~/.config/crush`.
final class CrushSessionConfigTests: XCTestCase {
    private var root: URL!
    private var userConfig: URL!
    private var userData: URL!
    private var sessions: URL!
    private var project: URL!
    private let free = "openrouter/nvidia/nemotron-3.5-super-vl:free"

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-crush-cfg-\(UUID().uuidString)")
        userConfig = root.appendingPathComponent("user-config")
        userData = root.appendingPathComponent("user-data")
        sessions = root.appendingPathComponent("sessions")
        project = root.appendingPathComponent("project")
        for dir in [userConfig!, userData!, project!] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // Every test starts with a user who has a key; the ones about a missing key take it away.
        try writeKeyedUserConfig()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    /// `environment` is empty unless a test says otherwise: the real shell's OPENROUTER_API_KEY must not count.
    private func makeConfig(environment: [String: String] = [:]) -> CrushSessionConfig {
        CrushSessionConfig(user: CrushDirectories(config: userConfig, data: userData), root: sessions, environment: environment)
    }

    /// A user crush.json that holds a key, so a test about something else is not stopped at the key check.
    private func writeKeyedUserConfig() throws {
        try write(#"{"providers":{"openrouter":{"api_key":"sk-or-user-key"}}}"#, to: userConfig.appendingPathComponent("crush.json"))
    }

    private func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func json(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private let userConfigText = """
    {
      "$schema": "https://charm.land/crush.json",
      "providers": { "openrouter": { "api_key": "sk-or-user-key" } },
      "models": { "large": { "provider": "anthropic", "model": "claude-opus-4-5", "max_tokens": 9000 } },
      "options": { "disable_metrics": true }
    }
    """

    // MARK: - Directories

    func testCrushsStandardFoldersOnMacOS() {
        let home = URL(fileURLWithPath: "/Users/someone")
        let standard = CrushDirectories.standard(home: home, environment: [:])
        XCTAssertEqual(standard.config.path, "/Users/someone/.config/crush")
        XCTAssertEqual(standard.data.path, "/Users/someone/.local/share/crush")
    }

    func testCrushsOwnVariablesAndXDGMoveTheFolders() {
        let home = URL(fileURLWithPath: "/Users/someone")
        let xdg = CrushDirectories.standard(home: home, environment: ["XDG_CONFIG_HOME": "/x/cfg", "XDG_DATA_HOME": "/x/data"])
        XCTAssertEqual(xdg.config.path, "/x/cfg/crush")
        XCTAssertEqual(xdg.data.path, "/x/data/crush")
        let own = CrushDirectories.standard(home: home, environment: [
            "CRUSH_GLOBAL_CONFIG": "/c", "CRUSH_GLOBAL_DATA": "/d", "XDG_CONFIG_HOME": "/x/cfg"])
        XCTAssertEqual(own.config.path, "/c")
        XCTAssertEqual(own.data.path, "/d")
    }

    // MARK: - The pin

    func testTheSessionConfigIsTheUsersWithLargeAndSmallSetToTheFreeModel() throws {
        try write(userConfigText, to: userConfig.appendingPathComponent("crush.json"))

        let env = try makeConfig().prepare(sessionId: "S1", cwd: project.path, model: free)

        let configDir = try XCTUnwrap(env["CRUSH_GLOBAL_CONFIG"])
        let config = try json(URL(fileURLWithPath: configDir).appendingPathComponent("crush.json"))
        let pinned = ["provider": "openrouter", "model": "nvidia/nemotron-3.5-super-vl:free"]
        let models = try XCTUnwrap(config["models"] as? [String: Any])
        XCTAssertEqual(models["large"] as? [String: String], pinned, "the user's own large model, max_tokens included, is replaced whole")
        XCTAssertEqual(models["small"] as? [String: String], pinned, "Crush's small model is free too")
        XCTAssertEqual(((config["providers"] as? [String: Any])?["openrouter"] as? [String: String]), ["api_key": "sk-or-user-key"],
                       "the user's providers and key stay")
        XCTAssertEqual(config["$schema"] as? String, "https://charm.land/crush.json")
        XCTAssertEqual((config["options"] as? [String: Bool]), ["disable_metrics": true])
    }

    func testAKeyOnlyUserConfigGivesAConfigWithTheKeyAndThePin() throws {
        let env = try makeConfig().prepare(sessionId: "S1", cwd: project.path, model: free)

        let config = try json(URL(fileURLWithPath: try XCTUnwrap(env["CRUSH_GLOBAL_CONFIG"])).appendingPathComponent("crush.json"))
        XCTAssertEqual(Set(config.keys), ["models", "providers"])
    }

    // MARK: - No OpenRouter key

    private let addKey = "add an OpenRouter key to Crush"

    func testAMissingUserConfigFailsAtOnceTellingJacobToAddAnOpenRouterKey() throws {
        try FileManager.default.removeItem(at: userConfig.appendingPathComponent("crush.json"))
        assertRefuses(containing: addKey)
    }

    func testAConfigWithNoOpenRouterKeyFailsAtOnce() throws {
        try write(#"{"providers":{"anthropic":{"api_key":"sk-ant"}},"options":{}}"#, to: userConfig.appendingPathComponent("crush.json"))
        assertRefuses(containing: addKey)
        try write(#"{"providers":{"openrouter":{"api_key":"  "}}}"#, to: userConfig.appendingPathComponent("crush.json"))
        assertRefuses(containing: addKey)
        try write(#"{"providers":{"openrouter":{"disable":false}}}"#, to: userConfig.appendingPathComponent("crush.json"))
        assertRefuses(containing: addKey)
    }

    func testAKeyInTheConfigLetsThePreparationProceed() throws {
        try write(userConfigText, to: userConfig.appendingPathComponent("crush.json"))
        XCTAssertNoThrow(try makeConfig().prepare(sessionId: "S1", cwd: project.path, model: free))
    }

    /// Crush saves a key typed into its TUI in `<data>/crush.json`.
    func testAKeySavedInTheDataFolderLetsThePreparationProceed() throws {
        try FileManager.default.removeItem(at: userConfig.appendingPathComponent("crush.json"))
        try write(#"{"providers":{"openrouter":{"api_key":"sk-or-saved"}}}"#, to: userData.appendingPathComponent("crush.json"))
        XCTAssertNoThrow(try makeConfig().prepare(sessionId: "S1", cwd: project.path, model: free))
    }

    /// Crush's own OpenRouter entry reads `$OPENROUTER_API_KEY`.
    func testTheEnvironmentsKeyCountsWhenTheConfigNamesNone() throws {
        try FileManager.default.removeItem(at: userConfig.appendingPathComponent("crush.json"))
        XCTAssertNoThrow(try makeConfig(environment: ["OPENROUTER_API_KEY": "sk-or-env"])
            .prepare(sessionId: "S1", cwd: project.path, model: free))
        try FileManager.default.removeItem(at: sessions)
        XCTAssertThrowsError(try makeConfig(environment: ["OPENROUTER_API_KEY": ""]).prepare(sessionId: "S2", cwd: project.path, model: free))
    }

    func testAConfigKeyThatNamesAnEmptyVariableIsMissing() throws {
        try write(#"{"providers":{"openrouter":{"api_key":"$OPENROUTER_API_KEY"}}}"#, to: userConfig.appendingPathComponent("crush.json"))
        assertRefuses(containing: addKey)
        XCTAssertNoThrow(try makeConfig(environment: ["OPENROUTER_API_KEY": "sk-or-env"]).prepare(sessionId: "S1", cwd: project.path, model: free))
    }

    func testAMissingKeyIsReportedBeforeAnythingIsWritten() throws {
        try FileManager.default.removeItem(at: userConfig.appendingPathComponent("crush.json"))
        try write(#"{"options":{}}"#, to: userData.appendingPathComponent("providers.json"))
        assertRefuses(containing: addKey)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessions.path))
    }

    func testTheUsersOwnFilesAreNeverTouched() throws {
        let userFile = userConfig.appendingPathComponent("crush.json")
        try write(userConfigText, to: userFile)
        let dataFile = userData.appendingPathComponent("crush.json")
        try write(#"{"models":{"large":{"provider":"openrouter","model":"anthropic/claude-opus-4.5"}}}"#, to: dataFile)
        let before = try Data(contentsOf: userFile)
        let dataBefore = try Data(contentsOf: dataFile)

        _ = try makeConfig().prepare(sessionId: "S1", cwd: project.path, model: free)

        XCTAssertEqual(try Data(contentsOf: userFile), before)
        XCTAssertEqual(try Data(contentsOf: dataFile), dataBefore)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: userConfig.path), ["crush.json"])
    }

    func testTheSessionHasItsOwnConfigAndDataFolderUnderTheRoot() throws {
        let env = try makeConfig().prepare(sessionId: "S1", cwd: project.path, model: free)

        XCTAssertEqual(env["CRUSH_GLOBAL_CONFIG"], sessions.appendingPathComponent("S1/config").path)
        XCTAssertEqual(env["CRUSH_GLOBAL_DATA"], sessions.appendingPathComponent("S1/data").path)
        XCTAssertEqual(Set(env.keys), ["CRUSH_GLOBAL_CONFIG", "CRUSH_GLOBAL_DATA"])
    }

    // MARK: - The data folder

    /// A model picked in the TUI is saved in `<data>/crush.json`, which Crush reads after the global
    /// config: left in place it would shadow the pin of every later session (checked on Crush 0.101.0).
    func testAModelSavedInTheUsersDataFolderDoesNotShadowThePin() throws {
        try write(#"{"models":{"large":{"provider":"openrouter","model":"anthropic/claude-opus-4.5"}},"providers":{"openrouter":{"api_key":"sk-or-saved"}}}"#,
                  to: userData.appendingPathComponent("crush.json"))
        try write("catalogue", to: userData.appendingPathComponent("providers.json"))

        let env = try makeConfig().prepare(sessionId: "S1", cwd: project.path, model: free)

        let data = URL(fileURLWithPath: try XCTUnwrap(env["CRUSH_GLOBAL_DATA"]))
        let saved = try json(data.appendingPathComponent("crush.json"))
        XCTAssertNil(saved["models"], "the saved model is dropped from the copy")
        XCTAssertEqual((saved["providers"] as? [String: Any])?["openrouter"] as? [String: String], ["api_key": "sk-or-saved"],
                       "a key saved through the TUI stays")
        XCTAssertEqual(try String(contentsOf: data.appendingPathComponent("providers.json"), encoding: .utf8), "catalogue")
    }

    func testAMissingDataFolderGivesAnEmptyOne() throws {
        try FileManager.default.removeItem(at: userData)

        let env = try makeConfig().prepare(sessionId: "S1", cwd: project.path, model: free)

        let data = try XCTUnwrap(env["CRUSH_GLOBAL_DATA"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: data), [])
    }

    // MARK: - Refusals: never an unpinned or non-free session

    private func assertRefuses(_ model: String? = nil, containing text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try makeConfig().prepare(sessionId: "S1", cwd: project.path, model: model ?? free), file: file, line: line) { error in
            XCTAssertTrue(String(describing: error).contains(text), "\(error)", file: file, line: line)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessions.appendingPathComponent("S1").path),
                       "a refusal leaves no folder behind", file: file, line: line)
    }

    func testAModelThatIsNotAFreeOpenRouterModelIsRefused() {
        assertRefuses("openrouter/anthropic/claude-opus-4.5", containing: "is not a free Crush model")
        assertRefuses("anthropic/claude-opus-4.5:free", containing: "is not a free Crush model")
        assertRefuses("openrouter/:free", containing: "is not a free Crush model")
    }

    func testAUserConfigThatIsNotAJSONObjectIsRefusedByName() throws {
        let file = userConfig.appendingPathComponent("crush.json")
        try write("{ \"models\": // comment\n }", to: file)
        assertRefuses(containing: file.path)
        try write("[1, 2]", to: file)
        assertRefuses(containing: file.path)
    }

    func testAnEmptyUserConfigReadsAsNothing() throws {
        try write("  \n", to: userConfig.appendingPathComponent("crush.json"))
        XCTAssertNoThrow(try makeConfig(environment: ["OPENROUTER_API_KEY": "sk-or-env"]).prepare(sessionId: "S1", cwd: project.path, model: free))
    }

    func testADataFileThatIsNotAJSONObjectIsRefusedByName() throws {
        let file = userData.appendingPathComponent("crush.json")
        try write("not json", to: file)
        assertRefuses(containing: file.path)
    }

    /// `crushrc` beats `crush.json` where both exist, so a model line in it would undo the pin.
    func testACrushrcInTheUsersConfigFolderIsRefused() throws {
        let rc = userConfig.appendingPathComponent("crushrc")
        try write("model large openrouter/foo\n", to: rc)
        assertRefuses(containing: rc.path)
    }

    func testAProjectConfigThatSetsAModelIsRefused() throws {
        let local = project.appendingPathComponent("crush.json")
        try write(#"{"models":{"large":{"provider":"openrouter","model":"anthropic/claude-opus-4.5"}}}"#, to: local)
        assertRefuses(containing: local.path)
    }

    func testAConfigInAFolderAboveTheProjectThatSetsAModelIsRefused() throws {
        let nested = project.appendingPathComponent("a/b", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let hidden = project.appendingPathComponent(".crush.json")
        try write(#"{"models":{"small":{"provider":"openrouter","model":"x"}}}"#, to: hidden)

        XCTAssertThrowsError(try makeConfig().prepare(sessionId: "S1", cwd: nested.path, model: free)) { error in
            XCTAssertTrue(String(describing: error).contains(hidden.path), "\(error)")
        }
    }

    func testAProjectCrushrcWithAModelLineIsRefused() throws {
        let rc = project.appendingPathComponent(".crushrc")
        try write("#!/usr/bin/env bash\nmodel large openrouter/foo:free\n", to: rc)
        assertRefuses(containing: rc.path)
    }

    /// A crushrc is a shell script: a model can be set by a sourced file, a function or a variable, none
    /// of which a scan for a `model` line sees. Any crushrc that applies is refused.
    func testAProjectCrushrcThatSetsNoVisibleModelIsStillRefused() throws {
        let rc = project.appendingPathComponent("crushrc")
        try write("#!/usr/bin/env bash\noption skill-path ./skills\n", to: rc)
        assertRefuses(containing: rc.path)
    }

    func testAProjectCrushrcThatSourcesAnotherFileIsRefused() throws {
        let rc = project.appendingPathComponent(".crushrc")
        try write("#!/usr/bin/env bash\nsource ./other-settings.sh\nm=model; $m large openrouter/x\n", to: rc)
        assertRefuses(containing: rc.path)
    }

    func testACrushrcInAFolderAboveTheProjectIsRefused() throws {
        let nested = project.appendingPathComponent("a/b", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let rc = project.appendingPathComponent("crushrc")
        try write("# nothing here\n", to: rc)

        XCTAssertThrowsError(try makeConfig().prepare(sessionId: "S1", cwd: nested.path, model: free)) { error in
            XCTAssertTrue(String(describing: error).contains(rc.path), "\(error)")
        }
    }

    func testProjectConfigsThatSetNoModelAreFine() throws {
        try write(#"{"mcp":{"x":{"type":"stdio","command":"y"}},"models":{}}"#, to: project.appendingPathComponent("crush.json"))
        XCTAssertNoThrow(try makeConfig().prepare(sessionId: "S1", cwd: project.path, model: free))
    }

    // MARK: - A stale session folder

    private func writeStale(_ text: String, under sessionId: String) throws -> URL {
        let data = sessions.appendingPathComponent("\(sessionId)/data", isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let stale = data.appendingPathComponent("crush.json")
        try write(text, to: stale)
        return stale
    }

    private let stalePaid = #"{"models":{"large":{"provider":"openrouter","model":"anthropic/claude-opus-4.5"}}}"#

    /// Makes the stale file impossible to delete: its folder can no longer be written to.
    private func lockStale(_ stale: URL) throws {
        let folder = stale.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        }
    }

    func testAStaleDataFileWithAPaidModelDoesNotSurviveIntoThePreparedFolders() throws {
        _ = try writeStale(stalePaid, under: "S1")

        let env = try makeConfig().prepare(sessionId: "S1", cwd: project.path, model: free)

        let data = URL(fileURLWithPath: try XCTUnwrap(env["CRUSH_GLOBAL_DATA"]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: data.appendingPathComponent("crush.json").path),
                       "the prepared data folder holds only the user's files, and the user has no crush.json there")
    }

    func testAStaleFolderThatCannotBeDeletedFailsThePreparationInsteadOfLaunchingOnIt() throws {
        let stale = try writeStale(stalePaid, under: "S1")
        try lockStale(stale)

        XCTAssertThrowsError(try makeConfig().prepare(sessionId: "S1", cwd: project.path, model: free)) { error in
            XCTAssertTrue(String(describing: error).contains(sessions.appendingPathComponent("S1").path), "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessions.appendingPathComponent("S1/config/crush.json").path),
                       "no pinned config was written beside the stale data")
    }

    // MARK: - Cleanup

    func testRemoveDeletesTheSessionsFolderAndOnlyThat() throws {
        let config = makeConfig()
        _ = try config.prepare(sessionId: "S1", cwd: project.path, model: free)
        _ = try config.prepare(sessionId: "S2", cwd: project.path, model: free)

        try config.remove(sessionId: "S1")

        XCTAssertFalse(FileManager.default.fileExists(atPath: sessions.appendingPathComponent("S1").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessions.appendingPathComponent("S2/config/crush.json").path))
        XCTAssertNoThrow(try config.remove(sessionId: "S1")) // idempotent
    }

    func testSweepRemovesEveryLeftOverSessionFolder() throws {
        let config = makeConfig()
        _ = try config.prepare(sessionId: "S1", cwd: project.path, model: free)
        _ = try config.prepare(sessionId: "S2", cwd: project.path, model: free)

        try config.sweep()

        XCTAssertFalse(FileManager.default.fileExists(atPath: sessions.path))
    }

    func testAFailedRemoveThrowsNamingTheFolderAndTheNextPrepareStillRefusesIt() throws {
        let stale = try writeStale(stalePaid, under: "S1")
        try lockStale(stale)
        let config = makeConfig()

        XCTAssertThrowsError(try config.remove(sessionId: "S1")) { error in
            XCTAssertTrue(String(describing: error).contains(sessions.appendingPathComponent("S1").path), "\(error)")
        }
        XCTAssertThrowsError(try config.prepare(sessionId: "S1", cwd: project.path, model: free),
                             "a folder that could not be deleted is never reused")
    }

    func testAFailedSweepThrowsNamingTheRoot() throws {
        let stale = try writeStale(stalePaid, under: "S1")
        try lockStale(stale)

        XCTAssertThrowsError(try makeConfig().sweep()) { error in
            XCTAssertTrue(String(describing: error).contains(sessions.path), "\(error)")
        }
    }
}

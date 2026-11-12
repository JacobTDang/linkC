import XCTest
@testable import LinkCKit

/// OpenCode through linkC's tool server: its place in every list of agents, and the checks that
/// keep a task off a model OpenCode no longer offers.
final class MCPServerOpenCodeTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-mcp-opencode-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    /// A server whose caller is Claude, on `models`, with no real usage readers. A test that does
    /// not hand it a lister fails if OpenCode's models are listed.
    private func makeServer(models: AgentModelSettings = .seeded,
                            openCodeModels: @escaping MCPServer.OpenCodeModelLister = { _ in
                                XCTFail("OpenCode's models were listed"); return [] }) -> MCPServer {
        MCPServer(workspaceRoot: tempDir.path, inboxStore: InboxStore(workspaceRoot: tempDir.path),
                  environment: ["LINKC_AGENT": "claude"], ancestorResolver: { _ in nil },
                  modelSettings: { models }, sessionResolver: { nil }, usageReaders: [:],
                  openCodeModels: openCodeModels,
                  modelLists: TestModelLists.none)
    }

    /// Records the folders OpenCode's models were listed in.
    final class ModelLister: @unchecked Sendable {
        private let lock = NSLock()
        private var _folders: [String] = []
        let models: [String]
        let failure: Error?
        init(_ models: [String] = [], failure: Error? = nil) { self.models = models; self.failure = failure }
        var folders: [String] { lock.lock(); defer { lock.unlock() }; return _folders }
        func list(_ folder: String) throws -> [String] {
            lock.lock(); _folders.append(folder); lock.unlock()
            if let failure { throw failure }
            return models
        }
    }

    /// The tasks still open in the test workspace. Throws when the store cannot be read, so an
    /// unreadable store never makes "no task is queued" pass.
    private func openTasks() throws -> [TaskRecord] { try InboxStore(workspaceRoot: tempDir.path).openTasks() }

    /// Calls `name` with `arguments`, returning the result's text and whether it is an error.
    private func call(_ server: MCPServer, _ name: String, _ arguments: [String: Any] = [:]) throws -> (text: String, isError: Bool) {
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                      "params": ["name": name, "arguments": arguments]]
        let data = try XCTUnwrap(server.handleMessage(try JSONSerialization.data(withJSONObject: request)))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try XCTUnwrap(json["result"] as? [String: Any], "\(json)")
        let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        return (text, result["isError"] as? Bool ?? false)
    }

    func testAnUnidentifiedCallerIsToldOpenCodeIsAnAgent() {
        XCTAssertTrue(MCPServer.unidentifiedCallerMessage.contains("\"opencode\""), MCPServer.unidentifiedCallerMessage)
    }

    func testTheModelReportListsOpenCodesTiers() throws {
        let report = try call(makeServer(), "linkc_get_models")
        XCTAssertFalse(report.isError, report.text)
        XCTAssertTrue(report.text.contains("## OpenCode\n"), report.text)
        XCTAssertTrue(report.text.contains("- **light**: opencode/deepseek-v4.1-flash-free\n"), report.text)
        XCTAssertTrue(report.text.contains("- **standard**: opencode/big-pickle — default\n"), report.text)
        XCTAssertTrue(report.text.contains("- **deep**: opencode/nemotron-3.5-super-vl-free\n"), report.text)
    }

    func testTheUsageReportHasAnOpenCodeSection() throws {
        let report = try call(makeServer(), "linkc_get_usage_status")
        XCTAssertTrue(report.text.contains("## OpenCode"), report.text)
    }

    func testOpenCodesDefaultUsageReaderSaysWhyItHasNoFigures() throws {
        let usage = try XCTUnwrap(MCPServer.defaultUsageReaders()[.opencode])()
        XCTAssertEqual(usage.agent, .opencode)
        XCTAssertEqual(usage.unavailableReason, "OpenCode's free models publish no quota locally")
    }

    /// Free models are offered for a limited time, and OpenCode runs a session whose model it does
    /// not know on whatever it picks, so a delegation to a model it no longer lists is refused.
    func testADelegationToAModelOpenCodeNoLongerListsIsRefused() throws {
        let lister = ModelLister(["opencode/deepseek-v4.1-flash-free"])
        let result = try call(makeServer(openCodeModels: { try lister.list($0) }), "linkc_delegate_task",
                              ["to": "opencode", "prompt": "Add a test."])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("opencode/big-pickle (opencode tier standard) is not among the models OpenCode lists"), result.text)
        XCTAssertTrue(try openTasks().isEmpty, "no task is queued")
    }

    func testADelegationIsRefusedWhenOpenCodesModelsCannotBeListed() throws {
        let lister = ModelLister(failure: LinkCError.process("`opencode models` exited 1: offline"))
        let result = try call(makeServer(openCodeModels: { try lister.list($0) }), "linkc_delegate_task",
                              ["to": "opencode", "prompt": "Add a test.", "tier": "deep"])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("opencode/nemotron-3.5-super-vl-free"), result.text)
        XCTAssertTrue(result.text.contains("offline"), result.text)
        XCTAssertTrue(try openTasks().isEmpty)
    }

    func testADelegationToAListedModelIsQueuedAndListedInTheWorkspace() throws {
        let lister = ModelLister(["opencode/big-pickle", "opencode/nemotron-3.5-super-vl-free"])
        let result = try call(makeServer(openCodeModels: { try lister.list($0) }), "linkc_delegate_task",
                              ["to": "opencode", "prompt": "Add a test.", "tier": "deep"])
        XCTAssertFalse(result.isError, result.text)
        let tasks = try openTasks()
        XCTAssertEqual(tasks.map(\.toAgent), [.opencode])
        XCTAssertEqual(tasks.first?.tier, .deep)
        XCTAssertEqual(lister.folders, [(tempDir.path as NSString).standardizingPath],
                       "a project's own opencode.json can add models, so the listing runs in the workspace")
    }

    func testADelegationToAnotherAgentNeverListsOpenCodesModels() throws {
        let result = try call(makeServer(), "linkc_delegate_task", ["to": "codex", "prompt": "Add a test."])
        XCTAssertFalse(result.isError, result.text)
    }

    // MARK: - The real listing, run against a stand-in `opencode`

    /// An executable shell script in the test folder, standing in for `opencode`.
    private func stubOpenCode(_ body: String) throws -> String {
        let script = tempDir.appendingPathComponent("stub-opencode.sh")
        try ("#!/bin/sh\n" + body).write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script.path
    }

    private func recorded(_ name: String) throws -> String {
        try String(contentsOf: tempDir.appendingPathComponent(name), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `opencode models --standalone`, so listing never starts OpenCode's shared background service,
    /// in the folder it was asked about (a project's own config can add providers), with the
    /// update dialog off.
    func testTheListingRunsModelsStandaloneInTheFolderWithAutoUpdateOff() throws {
        let stub = try stubOpenCode("""
            printf '%s\\n' "$@" > "$(dirname "$0")/argv"
            pwd -P > "$(dirname "$0")/cwd"
            printf '%s' "$OPENCODE_DISABLE_AUTOUPDATE" > "$(dirname "$0")/autoupdate"
            printf 'opencode/big-pickle\\n'
            """)
        let project = tempDir.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let models = try MCPServer.listOpenCodeModels(in: project.path, executable: stub, home: tempDir)

        XCTAssertEqual(models, ["opencode/big-pickle"])
        XCTAssertEqual(try recorded("argv").split(separator: "\n").map(String.init), ["models", "--standalone"])
        XCTAssertEqual(ProjectPath.canonical(try recorded("cwd")), ProjectPath.canonical(project.path))
        XCTAssertEqual(try recorded("autoupdate"), "1")
    }

    func testAFailedListingThrowsWithTheExitCodeAndOpenCodesOwnWords() throws {
        let stub = try stubOpenCode("echo '  provider offline  ' >&2\nexit 3\n")
        XCTAssertThrowsError(try MCPServer.listOpenCodeModels(in: tempDir.path, executable: stub, home: tempDir)) { error in
            XCTAssertEqual(String(describing: error), "`opencode models` exited 3: provider offline")
        }
    }

    func testAMissingOpenCodeThrows() {
        XCTAssertThrowsError(try MCPServer.listOpenCodeModels(in: tempDir.path, executable: nil, home: tempDir)) { error in
            XCTAssertTrue(String(describing: error).contains("not found"), "\(error)")
        }
        let absent = tempDir.appendingPathComponent("no-such-opencode").path
        XCTAssertThrowsError(try MCPServer.listOpenCodeModels(in: tempDir.path, executable: absent, home: tempDir)) { error in
            XCTAssertTrue(String(describing: error).contains(absent), "\(error)")
        }
    }

    /// A listing with no models is not a listing of models without this one: the refusal that
    /// follows must not blame the tier's model for it.
    func testAListingWithNoModelsThrows() throws {
        for body in ["exit 0\n", "printf '\\n  \\n\\r\\n'\n"] {
            let stub = try stubOpenCode(body)
            XCTAssertThrowsError(try MCPServer.listOpenCodeModels(in: tempDir.path, executable: stub, home: tempDir), body) { error in
                XCTAssertEqual(String(describing: error), "`opencode models` listed no models")
            }
        }
    }

    func testAListingThatDoesNotAnswerInTimeSaysSoInSeconds() throws {
        let stub = try stubOpenCode("sleep 30\n")
        XCTAssertThrowsError(try MCPServer.listOpenCodeModels(in: tempDir.path, executable: stub, home: tempDir, timeout: 2)) { error in
            XCTAssertEqual(String(describing: error), "`opencode models` did not answer within 2 seconds")
        }
    }

    func testTheListingKeepsOnlyTheNonEmptyTrimmedLines() {
        XCTAssertEqual(MCPServer.parseOpenCodeModels("opencode/big-pickle  \r\n\r\n  ollama/qwen3.8:27b-32k\n\n \nopencode/nemotron-3.5-super-vl-free"),
                       ["opencode/big-pickle", "ollama/qwen3.8:27b-32k", "opencode/nemotron-3.5-super-vl-free"])
        XCTAssertEqual(MCPServer.parseOpenCodeModels(""), [])
        XCTAssertEqual(MCPServer.parseOpenCodeModels(" \n\r\n"), [])
    }

    func testOpenCodesModelCannotBeSwitchedInARunningSession() throws {
        let result = try call(makeServer(), "linkc_switch_model", ["agent": "opencode", "model": "opencode/big-pickle"])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("opencode cannot switch a running session's model — delegate at another tier instead"), result.text)
    }

    /// Crush has no `/model <id>` command either, and its running session is pinned to a free model:
    /// the text would go to the model as a prompt.
    func testCrushsModelCannotBeSwitchedInARunningSession() throws {
        let result = try call(makeServer(), "linkc_switch_model",
                              ["agent": "crush", "model": "openrouter/nvidia/nemotron-3.5-lightning:free"])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("crush cannot switch a running session's model — delegate at another tier instead"), result.text)
    }

    func testTheModelReportSaysOpenCodeCannotSwitch() throws {
        let report = try call(makeServer(), "linkc_get_models", ["agent": "opencode"])
        XCTAssertTrue(report.text.contains("- opencode cannot switch a running session's model; delegate at another tier\n"), report.text)
    }
}

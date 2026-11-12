import XCTest
@testable import LinkCKit

/// Kilo through linkC's tool server: free-only checks and `kilo models` listing.
final class MCPServerKiloTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-mcp-kilo-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private func makeServer(models: AgentModelSettings = .seeded,
                            kiloModels: @escaping MCPServer.OpenCodeModelLister = { _ in
                                XCTFail("Kilo's models were listed"); return [] }) -> MCPServer {
        MCPServer(workspaceRoot: tempDir.path, inboxStore: InboxStore(workspaceRoot: tempDir.path),
                  environment: ["LINKC_AGENT": "claude"], ancestorResolver: { _ in nil },
                  modelSettings: { models }, sessionResolver: { nil }, usageReaders: [:],
                  kiloModels: kiloModels,
                  modelLists: TestModelLists.none)
    }

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

    private func openTasks() throws -> [TaskRecord] { try InboxStore(workspaceRoot: tempDir.path).openTasks() }

    private func call(_ server: MCPServer, _ name: String, _ arguments: [String: Any] = [:]) throws -> (text: String, isError: Bool) {
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                      "params": ["name": name, "arguments": arguments]]
        let data = try XCTUnwrap(server.handleMessage(try JSONSerialization.data(withJSONObject: request)))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try XCTUnwrap(json["result"] as? [String: Any], "\(json)")
        let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        return (text, result["isError"] as? Bool ?? false)
    }

    func testAnUnidentifiedCallerIsToldKiloIsAnAgent() {
        XCTAssertTrue(MCPServer.unidentifiedCallerMessage.contains("\"kilo\""), MCPServer.unidentifiedCallerMessage)
    }

    func testTheModelReportListsKilosTiers() throws {
        let report = try call(makeServer(), "linkc_get_models")
        XCTAssertFalse(report.isError, report.text)
        XCTAssertTrue(report.text.contains("## Kilo\n"), report.text)
        XCTAssertTrue(report.text.contains("- **light**: kilo/nvidia/nemotron-3.5-lightning:free\n"), report.text)
        XCTAssertTrue(report.text.contains("- **standard**: kilo/kilo-auto/free — default\n"), report.text)
        XCTAssertTrue(report.text.contains("- **deep**: kilo/nvidia/nemotron-3-ultra-550b-a55b:free\n"), report.text)
    }

    func testTheUsageReportHasAKiloSection() throws {
        let report = try call(makeServer(), "linkc_get_usage_status")
        XCTAssertTrue(report.text.contains("## Kilo"), report.text)
    }

    func testKilosDefaultUsageReaderSaysWhyItHasNoFigures() throws {
        let usage = try XCTUnwrap(MCPServer.defaultUsageReaders()[.kilo])()
        XCTAssertEqual(usage.agent, .kilo)
        XCTAssertEqual(usage.unavailableReason, "Kilo's free models publish no quota locally")
    }

    func testADelegationToAModelKiloNoLongerListsIsRefused() throws {
        let lister = ModelLister(["kilo/nvidia/nemotron-3.5-lightning:free"])
        let result = try call(makeServer(kiloModels: { try lister.list($0) }), "linkc_delegate_task",
                              ["to": "kilo", "prompt": "Add a test."])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("kilo/kilo-auto/free (kilo tier standard) is not among the models Kilo lists"), result.text)
        XCTAssertTrue(try openTasks().isEmpty, "no task is queued")
    }

    func testADelegationIsRefusedWhenKilosModelsCannotBeListed() throws {
        let lister = ModelLister(failure: LinkCError.process("`kilo models` exited 1: offline"))
        let result = try call(makeServer(kiloModels: { try lister.list($0) }), "linkc_delegate_task",
                              ["to": "kilo", "prompt": "Add a test.", "tier": "deep"])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("kilo/nvidia/nemotron-3-ultra-550b-a55b:free"), result.text)
        XCTAssertTrue(result.text.contains("offline"), result.text)
        XCTAssertTrue(try openTasks().isEmpty)
    }

    func testADelegationToAListedModelIsQueuedAndListedInTheWorkspace() throws {
        let lister = ModelLister(["kilo/kilo-auto/free", "kilo/nvidia/nemotron-3-ultra-550b-a55b:free"])
        let result = try call(makeServer(kiloModels: { try lister.list($0) }), "linkc_delegate_task",
                              ["to": "kilo", "prompt": "Add a test.", "tier": "deep"])
        XCTAssertFalse(result.isError, result.text)
        let tasks = try openTasks()
        XCTAssertEqual(tasks.map(\.toAgent), [.kilo])
        XCTAssertEqual(tasks.first?.tier, .deep)
        XCTAssertEqual(lister.folders, [(tempDir.path as NSString).standardizingPath])
    }

    func testADelegationToAnotherAgentNeverListsKilosModels() throws {
        let result = try call(makeServer(), "linkc_delegate_task", ["to": "codex", "prompt": "Add a test."])
        XCTAssertFalse(result.isError, result.text)
    }

    private func stubKilo(_ body: String) throws -> String {
        let script = tempDir.appendingPathComponent("stub-kilo.sh")
        try ("#!/bin/sh\n" + body).write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script.path
    }

    private func recorded(_ name: String) throws -> String {
        try String(contentsOf: tempDir.appendingPathComponent(name), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testTheListingRunsModelsInTheFolder() throws {
        let stub = try stubKilo("""
            printf '%s\\n' "$@" > "$(dirname "$0")/argv"
            pwd -P > "$(dirname "$0")/cwd"
            printf 'kilo/kilo-auto/free\\n'
            """)
        let project = tempDir.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let models = try MCPServer.listKiloModels(in: project.path, executable: stub, home: tempDir)

        XCTAssertEqual(models, ["kilo/kilo-auto/free"])
        XCTAssertEqual(try recorded("argv").split(separator: "\n").map(String.init), ["models"])
        XCTAssertEqual(ProjectPath.canonical(try recorded("cwd")), ProjectPath.canonical(project.path))
    }

    func testAFailedListingThrowsWithTheExitCodeAndKilosOwnWords() throws {
        let stub = try stubKilo("echo '  provider offline  ' >&2\nexit 3\n")
        XCTAssertThrowsError(try MCPServer.listKiloModels(in: tempDir.path, executable: stub, home: tempDir)) { error in
            XCTAssertEqual(String(describing: error), "`kilo models` exited 3: provider offline")
        }
    }

    func testAMissingKiloThrows() {
        XCTAssertThrowsError(try MCPServer.listKiloModels(in: tempDir.path, executable: nil, home: tempDir)) { error in
            XCTAssertTrue(String(describing: error).contains("not found"), "\(error)")
        }
        let absent = tempDir.appendingPathComponent("no-such-kilo").path
        XCTAssertThrowsError(try MCPServer.listKiloModels(in: tempDir.path, executable: absent, home: tempDir)) { error in
            XCTAssertTrue(String(describing: error).contains(absent), "\(error)")
        }
    }

    func testAListingWithNoFreeModelsThrows() throws {
        let stubEmpty = try stubKilo("exit 0\n")
        XCTAssertThrowsError(try MCPServer.listKiloModels(in: tempDir.path, executable: stubEmpty, home: tempDir)) { error in
            XCTAssertEqual(String(describing: error), "`kilo models` listed no free models")
        }
        let stubPaid = try stubKilo("printf 'kilo/anthropic/claude-sonnet-5\\n'\n")
        XCTAssertThrowsError(try MCPServer.listKiloModels(in: tempDir.path, executable: stubPaid, home: tempDir)) { error in
            XCTAssertEqual(String(describing: error),
                           "`kilo models` listed no free models: kilo/anthropic/claude-sonnet-5")
        }
    }

    func testAListingThatDoesNotAnswerInTimeSaysSoInSeconds() throws {
        let stub = try stubKilo("sleep 30\n")
        XCTAssertThrowsError(try MCPServer.listKiloModels(in: tempDir.path, executable: stub, home: tempDir, timeout: 2)) { error in
            XCTAssertEqual(String(describing: error), "`kilo models` did not answer within 2 seconds")
        }
    }

    func testTheListingKeepsOnlyFreeNonEmptyTrimmedLines() {
        XCTAssertEqual(MCPServer.parseKiloModels("kilo/kilo-auto/free  \r\n\r\n  kilo/anthropic/claude-sonnet-5\n\n \nkilo/openrouter/free"),
                       ["kilo/kilo-auto/free", "kilo/openrouter/free"])
        XCTAssertEqual(MCPServer.parseKiloModels(""), [])
        XCTAssertEqual(MCPServer.parseKiloModels(" \n\r\n"), [])
    }

    func testKilosModelCannotBeSwitchedInARunningSession() throws {
        let result = try call(makeServer(), "linkc_switch_model", ["agent": "kilo", "model": "kilo/kilo-auto/free"])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("kilo cannot switch a running session's model — delegate at another tier instead"), result.text)
    }

    func testTheModelReportSaysKiloCannotSwitch() throws {
        let report = try call(makeServer(), "linkc_get_models", ["agent": "kilo"])
        XCTAssertTrue(report.text.contains("- kilo cannot switch a running session's model; delegate at another tier\n"), report.text)
    }
}

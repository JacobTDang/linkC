import XCTest
@testable import LinkCKit

/// A missing Kilo login is reported at once with what to do (`run \`kilo\`, then \`/connect\``).
final class KiloLoginTests: XCTestCase {
    func testMissingLoginPhrasesAreRecognised() {
        for phrase in [
            "Error: not logged in",
            "Unauthorized — please sign in",
            "Connect a provider",
            "run /connect to continue",
            "login required before listing models",
            "not authenticated",
        ] {
            XCTAssertTrue(KiloLogin.looksLikeMissingLogin(phrase), phrase)
        }
        XCTAssertFalse(KiloLogin.looksLikeMissingLogin("`kilo models` exited 1: provider offline"))
        XCTAssertFalse(KiloLogin.looksLikeMissingLogin(""))
    }

    func testReportingAppendsTheConnectRemedyOnce() {
        let raw = "Error: not " + "logged in"
        let reported = KiloLogin.reporting(raw)
        XCTAssertTrue(reported.contains(raw), reported)
        XCTAssertTrue(reported.contains(KiloLogin.remedy), reported)
        XCTAssertEqual(KiloLogin.reporting(reported), reported, "the remedy is not doubled")
        XCTAssertEqual(KiloLogin.reporting("provider offline"), "provider offline")
    }

    func testListKiloModelsAugmentsALoginFailureExit() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-kilo-login-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let stub = temp.appendingPathComponent("stub-kilo.sh")
        try ("#!/bin/sh\necho 'not logged in' >&2\nexit 1\n").write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        XCTAssertThrowsError(try MCPServer.listKiloModels(in: temp.path, executable: stub.path, home: temp)) { error in
            let text = String(describing: error)
            XCTAssertTrue(text.contains("not logged in"), text)
            XCTAssertTrue(text.contains("run `kilo`, then `/connect`"), text)
        }
    }

    func testListKiloModelsAugmentsAnEmptyListThatSaysConnect() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-kilo-login-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let stub = temp.appendingPathComponent("stub-kilo.sh")
        try ("#!/bin/sh\nprintf 'Connect a provider\\n'\n").write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        XCTAssertThrowsError(try MCPServer.listKiloModels(in: temp.path, executable: stub.path, home: temp)) { error in
            let text = String(describing: error)
            XCTAssertTrue(text.contains("Connect a provider"), text)
            XCTAssertTrue(text.contains("run `kilo`, then `/connect`"), text)
        }
    }

    func testADelegationThatCannotListBecauseOfLoginSaysHowToConnect() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-kilo-login-delegate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let server = MCPServer(
            workspaceRoot: temp.path,
            inboxStore: InboxStore(workspaceRoot: temp.path),
            environment: ["LINKC_AGENT": "claude"],
            ancestorResolver: { _ in nil },
            modelSettings: { .seeded },
            sessionResolver: { nil },
            usageReaders: [:],
            kiloModels: { _ in throw LinkCError.process("Error: not " + "logged in") },
            modelLists: TestModelLists.none)

        let request: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": [
                "name": "linkc_delegate_task",
                "arguments": ["to": "kilo", "prompt": "Add a test.", "tier": "standard"],
            ],
        ]
        let data = try XCTUnwrap(server.handleMessage(try JSONSerialization.data(withJSONObject: request)))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try XCTUnwrap(json["result"] as? [String: Any])
        let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertTrue(text.contains("not logged in"), text)
        XCTAssertTrue(text.contains("run `kilo`, then `/connect`"), text)
        XCTAssertTrue(try InboxStore(workspaceRoot: temp.path).openTasks().isEmpty)
    }

    func testListingParserAugmentsALoginStyleEmptyOutput() {
        XCTAssertThrowsError(try ModelListParser.listing("Error: not " + "logged in\n", for: .kilo)) { error in
            let text = String(describing: error)
            XCTAssertTrue(text.contains("not logged in"), text)
            XCTAssertTrue(text.contains("run `kilo`, then `/connect`"), text)
        }
    }

    @MainActor
    func testAvailabilityUncheckableIncludesTheConnectRemedy() {
        let settingsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-kilo-login-avail-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: settingsDir, withIntermediateDirectories: true)
        let coordinator = AppCoordinator(
            terminals: TerminalSessionManager(),
            hookServer: HookServer.forTesting(),
            notifications: NotificationManager(sink: NullSink(), now: { Date() }),
            claudePath: "/x/claude",
            settingsDir: settingsDir,
            userSettingsURL: settingsDir.appendingPathComponent("user-settings.json"),
            manifestDir: settingsDir.appendingPathComponent("manifest"),
            modelSettings: { .seeded },
            modelLists: TestModelLists.none,
            kiloModels: { _ in throw LinkCError.process("Unauthorized") },
            isWatching: { _ in false })

        _ = coordinator.kiloModelAvailability(in: "/tmp", tier: .standard)
        let deadline = Date().addingTimeInterval(2)
        while coordinator.kiloModelCheckCount == 0, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertGreaterThan(coordinator.kiloModelCheckCount, 0)
        let availability = coordinator.kiloModelAvailability(in: "/tmp", tier: .standard)
        guard case .uncheckable(let reason) = availability else {
            return XCTFail("expected uncheckable, got \(availability)")
        }
        XCTAssertTrue(reason.contains("Unauthorized"), reason)
        XCTAssertTrue(reason.contains("run `kilo`, then `/connect`"), reason)
    }

    private struct NullSink: NotificationSink {
        func deliver(id: String, title: String, body: String) {}
    }
}

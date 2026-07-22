import Foundation
import XCTest
@testable import LinkCKit

// MARK: - Fixture loading

/// Loads a real Claude Code hook payload captured under `Fixtures/`. Tries both a flat
/// and a `Fixtures`-nested resource layout, matching the convention used by KittyTests.
private func loadHookFixtureData(_ name: String) throws -> Data {
    let bundle = Bundle.module
    if let url = bundle.url(forResource: name, withExtension: "json") {
        return try Data(contentsOf: url)
    }
    if let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") {
        return try Data(contentsOf: url)
    }
    throw LinkCError.parse("test fixture \(name).json not found in test bundle")
}

// MARK: - HookEventDecoder

final class HookEventDecoderTests: XCTestCase {
    func testDecodesRealStopFixtureWithMatchingHeaders() throws {
        let body = try loadHookFixtureData("hook-Stop")
        let headers = ["X-LinkC-Event": "stop", "X-LinkC-Session": "L1"]

        let event = try XCTUnwrap(HookEventDecoder.decode(headers: headers, body: body))

        XCTAssertEqual(event.kind, .stop)
        XCTAssertEqual(event.linkcSessionId, "L1")
        XCTAssertEqual(event.claudeSessionId, "7a29becc-2776-461b-a720-4c6ed80bb560")
        XCTAssertEqual(event.cwd, "/Users/jacobdang/Desktop/projects/linkC")
        XCTAssertEqual(
            event.transcriptPath,
            "/Users/jacobdang/.claude/projects/-Users-jacobdang-Desktop-projects-linkC/7a29becc-2776-461b-a720-4c6ed80bb560.jsonl",
            "transcript_path feeds the usage tracker"
        )
    }

    func testDecodesRealUserPromptSubmitFixture() throws {
        let body = try loadHookFixtureData("hook-UserPromptSubmit")
        let headers = ["X-LinkC-Event": "user_prompt_submit", "X-LinkC-Session": "L2"]

        let event = try XCTUnwrap(HookEventDecoder.decode(headers: headers, body: body))

        XCTAssertEqual(event.kind, .userPromptSubmit)
        XCTAssertEqual(event.linkcSessionId, "L2")
        XCTAssertEqual(event.claudeSessionId, "7a29becc-2776-461b-a720-4c6ed80bb560")
        XCTAssertEqual(event.cwd, "/Users/jacobdang/Desktop/projects/linkC")
    }

    func testDecodesRealSessionEndFixture() throws {
        let body = try loadHookFixtureData("hook-SessionEnd")
        let headers = ["X-LinkC-Event": "session_end", "X-LinkC-Session": "L3"]

        let event = try XCTUnwrap(HookEventDecoder.decode(headers: headers, body: body))

        XCTAssertEqual(event.kind, .sessionEnd)
        XCTAssertEqual(event.claudeSessionId, "7a29becc-2776-461b-a720-4c6ed80bb560")
        XCTAssertEqual(event.cwd, "/Users/jacobdang/Desktop/projects/linkC")
    }

    func testHeaderLookupIsCaseInsensitive() throws {
        let body = try loadHookFixtureData("hook-Stop")
        let headers = ["x-linkc-event": "stop", "x-linkc-session": "L1"]

        let event = try XCTUnwrap(HookEventDecoder.decode(headers: headers, body: body))

        XCTAssertEqual(event.kind, .stop)
        XCTAssertEqual(event.linkcSessionId, "L1")
    }

    func testUnknownEventHeaderReturnsNil() throws {
        let body = try loadHookFixtureData("hook-Stop")
        let headers = ["X-LinkC-Event": "not_a_real_event", "X-LinkC-Session": "L1"]

        XCTAssertNil(HookEventDecoder.decode(headers: headers, body: body))
    }

    func testMissingEventHeaderReturnsNil() throws {
        let body = try loadHookFixtureData("hook-Stop")

        XCTAssertNil(HookEventDecoder.decode(headers: ["X-LinkC-Session": "L1"], body: body))
    }

    func testEmptySessionHeaderNormalizesToNil() throws {
        let body = try loadHookFixtureData("hook-Stop")
        let headers = ["X-LinkC-Event": "stop", "X-LinkC-Session": ""]

        let event = try XCTUnwrap(HookEventDecoder.decode(headers: headers, body: body))

        XCTAssertNil(event.linkcSessionId, "empty X-LinkC-Session must normalize to nil (external session)")
    }

    func testMalformedBodyStillYieldsEventFromValidHeaders() throws {
        let headers = ["X-LinkC-Event": "session_end", "X-LinkC-Session": "L1"]

        let event = try XCTUnwrap(HookEventDecoder.decode(headers: headers, body: Data("not json at all".utf8)))

        XCTAssertEqual(event.kind, .sessionEnd, "only the event KIND from our header is required")
        XCTAssertEqual(event.linkcSessionId, "L1")
        XCTAssertNil(event.claudeSessionId)
        XCTAssertNil(event.cwd)
    }
}

// MARK: - SettingsComposer

final class SettingsComposerTests: XCTestCase {
    func testLinkcHooksNotificationHasExactlyTwoMatcherEntriesWithRightTokens() throws {
        let hooks = SettingsComposer.linkcHooks(port: 4567, token: "tok-test")

        let notification = try XCTUnwrap(hooks["Notification"] as? [[String: Any]])
        XCTAssertEqual(notification.count, 2)

        let matchers = Set(notification.compactMap { $0["matcher"] as? String })
        XCTAssertEqual(matchers, ["permission_prompt", "idle_prompt"])

        for block in notification {
            let matcher = try XCTUnwrap(block["matcher"] as? String)
            let entries = try XCTUnwrap(block["hooks"] as? [[String: Any]])
            XCTAssertEqual(entries.count, 1)
            let entry = entries[0]
            XCTAssertEqual(entry["type"] as? String, "http")
            XCTAssertEqual(entry["url"] as? String, "http://127.0.0.1:4567/hook")
            XCTAssertEqual(entry["allowedEnvVars"] as? [String], ["LINKC_SESSION"])

            let entryHeaders = try XCTUnwrap(entry["headers"] as? [String: String])
            XCTAssertEqual(entryHeaders["X-LinkC-Session"], "$LINKC_SESSION")
            switch matcher {
            case "permission_prompt": XCTAssertEqual(entryHeaders["X-LinkC-Event"], "notification_permission")
            case "idle_prompt": XCTAssertEqual(entryHeaders["X-LinkC-Event"], "notification_idle")
            default: XCTFail("unexpected matcher \(matcher)")
            }
        }
    }

    func testLinkcHooksSingleEntryEventsPointAtTheGivenPort() throws {
        let hooks = SettingsComposer.linkcHooks(port: 9, token: "tok-test")
        let singleEntryEvents: [(key: String, kind: HookEventKind)] = [
            ("SessionStart", .sessionStart),
            ("UserPromptSubmit", .userPromptSubmit),
            ("Stop", .stop),
            ("SessionEnd", .sessionEnd),
        ]

        for (key, kind) in singleEntryEvents {
            let blocks = try XCTUnwrap(hooks[key] as? [[String: Any]], "\(key) missing")
            XCTAssertEqual(blocks.count, 1)
            XCTAssertNil(blocks[0]["matcher"], "\(key) should have no matcher")

            let entries = try XCTUnwrap(blocks[0]["hooks"] as? [[String: Any]])
            XCTAssertEqual(entries.count, 1)
            XCTAssertEqual(entries[0]["url"] as? String, "http://127.0.0.1:9/hook")
            XCTAssertEqual(entries[0]["allowedEnvVars"] as? [String], ["LINKC_SESSION"])

            let entryHeaders = try XCTUnwrap(entries[0]["headers"] as? [String: String])
            XCTAssertEqual(entryHeaders["X-LinkC-Event"], kind.rawValue)
        }
    }

    func testComposeAppendsLinkcStopHookToExistingUserStopHookAndPreservesModel() throws {
        let userJSON = """
        {
          "model": "claude-opus-4",
          "hooks": {
            "Stop": [
              { "hooks": [ { "type": "command", "command": "echo hi" } ] }
            ]
          }
        }
        """
        let userData = Data(userJSON.utf8)

        let composed = try SettingsComposer.compose(userSettings: userData, projectSettings: nil, port: 4321, token: "tok-test")
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: composed) as? [String: Any])

        XCTAssertEqual(decoded["model"] as? String, "claude-opus-4", "compose must preserve unrelated user settings")

        let hooks = try XCTUnwrap(decoded["hooks"] as? [String: Any])
        let stopBlocks = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        XCTAssertEqual(stopBlocks.count, 2, "the user's Stop hook must survive alongside linkC's, not be clobbered")

        let userBlockSurvived = stopBlocks.contains { block in
            guard let entries = block["hooks"] as? [[String: Any]] else { return false }
            return entries.contains { $0["type"] as? String == "command" && $0["command"] as? String == "echo hi" }
        }
        XCTAssertTrue(userBlockSurvived, "user's original Stop hook must still be present")

        let linkcBlockAppended = stopBlocks.contains { block in
            guard let entries = block["hooks"] as? [[String: Any]] else { return false }
            return entries.contains { $0["type"] as? String == "http" && $0["url"] as? String == "http://127.0.0.1:4321/hook" }
        }
        XCTAssertTrue(linkcBlockAppended, "linkC's Stop hook must be appended")
    }

    func testComposeConcatenatesUserAndProjectHooksForTheSameEventPlusLinkc() throws {
        // Both user AND project define a Stop hook. A naive deep merge would let the
        // project's Stop array clobber the user's; compose must keep BOTH, then append
        // linkC's own — three Stop entries in total.
        let userData = Data(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"user-stop"}]}]}}"#.utf8)
        let projectData = Data(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"project-stop"}]}]}}"#.utf8)

        let composed = try SettingsComposer.compose(userSettings: userData, projectSettings: projectData, port: 4321, token: "tok-test")
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: composed) as? [String: Any])
        let hooks = try XCTUnwrap(decoded["hooks"] as? [String: Any])
        let stopBlocks = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])

        XCTAssertEqual(stopBlocks.count, 3, "user + project + linkC Stop hooks must all survive")

        func hasCommand(_ command: String) -> Bool {
            stopBlocks.contains { block in
                guard let entries = block["hooks"] as? [[String: Any]] else { return false }
                return entries.contains { $0["type"] as? String == "command" && $0["command"] as? String == command }
            }
        }
        XCTAssertTrue(hasCommand("user-stop"), "user's Stop hook must survive when project also defines Stop")
        XCTAssertTrue(hasCommand("project-stop"), "project's Stop hook must survive")

        let linkcAppended = stopBlocks.contains { block in
            guard let entries = block["hooks"] as? [[String: Any]] else { return false }
            return entries.contains { $0["type"] as? String == "http" && $0["url"] as? String == "http://127.0.0.1:4321/hook" }
        }
        XCTAssertTrue(linkcAppended, "linkC's Stop hook must be appended alongside user + project")
    }

    func testComposeWithNilSettingsStillProducesLinkcHooks() throws {
        let composed = try SettingsComposer.compose(userSettings: nil, projectSettings: nil, port: 1111, token: "tok-test")
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: composed) as? [String: Any])
        let hooks = try XCTUnwrap(decoded["hooks"] as? [String: Any])

        XCTAssertNotNil(hooks["Stop"])
        XCTAssertNotNil(hooks["Notification"])
    }

    func testComposeDeepMergesProjectOverUserAndKeepsBothModelAndHooks() throws {
        let userData = Data(#"{"model": "user-model", "other": {"a": 1, "b": 2}}"#.utf8)
        let projectData = Data(#"{"model": "project-model", "other": {"b": 3}}"#.utf8)

        let composed = try SettingsComposer.compose(userSettings: userData, projectSettings: projectData, port: 55, token: "tok-test")
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: composed) as? [String: Any])

        XCTAssertEqual(decoded["model"] as? String, "project-model", "project settings take precedence over user")
        let other = try XCTUnwrap(decoded["other"] as? [String: Any])
        XCTAssertEqual(other["a"] as? Int, 1, "keys only present in user settings must survive the merge")
        XCTAssertEqual(other["b"] as? Int, 3, "project wins on conflicting keys")
    }
}

// MARK: - HookServer (real loopback end-to-end)

final class HookServerTests: XCTestCase {
    /// `onEvent` is a plain synchronous `@Sendable` callback (not `async`), so a
    /// lock-guarded box — rather than an actor hopped into via an unstructured `Task` —
    /// is what preserves the guarantee that recording completes strictly before the
    /// server goes on to send its HTTP response.
    private final class EventBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [HookEvent] = []

        func record(_ event: HookEvent) {
            lock.lock()
            stored.append(event)
            lock.unlock()
        }

        var all: [HookEvent] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    func testEndToEndLoopbackDeliversDecodedEventAndRespondsOKWithEmptyJSONBody() async throws {
        let server = HookServer(port: 0)
        let box = EventBox()
        server.onEvent = { box.record($0) }
        try server.start()
        defer { server.stop() }

        XCTAssertNotEqual(server.port, 0, "start() must resolve the OS-assigned ephemeral port")

        let fixtureBody = try loadHookFixtureData("hook-Stop")
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/hook")!)
        request.httpMethod = "POST"
        request.setValue("stop", forHTTPHeaderField: "X-LinkC-Event")
        request.setValue("L1", forHTTPHeaderField: "X-LinkC-Session")
        request.httpBody = fixtureBody

        let (data, response) = try await URLSession.shared.data(for: request)

        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "{}")

        let events = box.all
        XCTAssertEqual(events.count, 1)
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.kind, .stop)
        XCTAssertEqual(event.linkcSessionId, "L1")
        XCTAssertEqual(event.claudeSessionId, "7a29becc-2776-461b-a720-4c6ed80bb560")
        XCTAssertEqual(event.cwd, "/Users/jacobdang/Desktop/projects/linkC")
    }

    func testUnrecognizedEventStillRespondsOKAndNeverFiresCallback() async throws {
        let server = HookServer(port: 0)
        let box = EventBox()
        server.onEvent = { box.record($0) }
        try server.start()
        defer { server.stop() }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/hook")!)
        request.httpMethod = "POST"
        request.setValue("not_a_real_event", forHTTPHeaderField: "X-LinkC-Event")
        request.httpBody = Data("{}".utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200, "must never deny/block a Claude turn, even for an event we don't recognize")
        XCTAssertEqual(String(data: data, encoding: .utf8), "{}")
        XCTAssertTrue(box.all.isEmpty)
    }

    func testOversizedRequestIsDroppedInsteadOfBufferedUnbounded() async throws {
        // Tight cap so the test needn't send a real megabyte. A request whose body (and
        // declared Content-Length) exceeds the cap must be dropped — no response, no event —
        // rather than buffered without bound.
        let server = HookServer(port: 0, maxRequestBytes: 1024)
        let box = EventBox()
        server.onEvent = { box.record($0) }
        try server.start()
        defer { server.stop() }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/hook")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("stop", forHTTPHeaderField: "X-LinkC-Event")
        request.setValue("L1", forHTTPHeaderField: "X-LinkC-Session")
        request.httpBody = Data(count: 4096) // 4 KiB body ≫ 1 KiB cap

        do {
            _ = try await URLSession.shared.data(for: request)
            XCTFail("server must drop an oversized request, not respond to it")
        } catch {
            // expected: the server cancels the connection, so the client sees it drop.
        }

        XCTAssertTrue(box.all.isEmpty, "an oversized request must never decode into an event")
    }
}

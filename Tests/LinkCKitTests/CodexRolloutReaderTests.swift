import XCTest
@testable import LinkCKit

final class CodexRolloutReaderTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-rollout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".codex/sessions/2026/01/02"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // Made-up rollout lines, in the shapes Codex writes.
    private func started() -> String { #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"t1","model_context_window":200000}}"# }
    private func completed() -> String { #"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"t1"}}"# }
    private func tokens(_ total: Int, window: Int = 200_000) -> String {
        #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":999999},"last_token_usage":{"input_tokens":1,"total_tokens":\#(total)},"model_context_window":\#(window)}}}"#
    }
    private func exec(_ code: String) throws -> String {
        let payload: [String: Any] = ["type": "custom_tool_call", "name": "exec", "call_id": "c1", "input": code]
        let line: [String: Any] = ["type": "response_item", "payload": payload]
        return String(decoding: try JSONSerialization.data(withJSONObject: line), as: UTF8.self)
    }
    private func function(_ name: String, _ arguments: [String: Any]) throws -> String {
        let args = String(decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
        let line: [String: Any] = ["type": "response_item", "payload": ["type": "function_call", "name": name, "arguments": args, "call_id": "c2"]]
        return String(decoding: try JSONSerialization.data(withJSONObject: line), as: UTF8.self)
    }

    private func rollout(_ lines: [String]) throws -> String {
        let url = dir.appendingPathComponent(".codex/sessions/2026/01/02/rollout-2026-01-02T03-04-05-made-up.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    private func read(_ openFiles: [String]) throws -> SessionLiveDetail {
        try CodexRolloutReader().read(LiveSessionTarget(sessionId: "S1", agent: .codex, cwd: "/p", openFiles: openFiles))
    }

    /// The context is the last request's tokens against the model's window, as Codex counts them.
    func testTheContextIsTheLastRequestAgainstTheWindow() throws {
        let path = try rollout([started(), tokens(20_000), tokens(50_000), completed()])
        XCTAssertEqual(try read(["/dev/null", path]).contextPercent, 25)
    }

    /// While a turn runs, its last tool call is the step: a command by its first line.
    func testTheStepIsTheRunningTurnsLastToolCall() throws {
        let path = try rollout([
            started(),
            try exec(#"const r = await tools.exec_command({cmd:"swift build\nswift test", workdir:"/p"}); text(r);"#),
            try exec(#"const r = await tools.exec_command({cmd:"swift test --filter Foo"}); text(r);"#),
        ])
        XCTAssertEqual(try read([path]).step, "$ swift test --filter Foo")
    }

    func testAnEditIsNamedByItsFileAndAJsCallByItsTitle() throws {
        let patch = try exec(#"await tools.apply_patch("*** Begin Patch\n*** Update File: Sources/App/Card.swift\n@@\n-a\n+b\n*** End Patch")"#)
        XCTAssertEqual(try read([try rollout([started(), patch])]).step, "✎ Card.swift")
        let titled = try function("js", ["title": "Check the build", "code": "1"])
        XCTAssertEqual(try read([try rollout([started(), titled])]).step, "Check the build")
    }

    /// A tool call from before the turn ended is not the step of a turn that is not running.
    func testAFinishedTurnHasNoStep() throws {
        let path = try rollout([started(), try exec(#"await tools.exec_command({cmd:"ls"})"#), completed()])
        XCTAssertNil(try read([path]).step)
    }

    /// A session whose process holds no rollout open is not matched to one by guesswork.
    func testASessionHoldingNoRolloutHasNothing() throws {
        _ = try rollout([started(), tokens(50_000)])
        XCTAssertEqual(try read(["/dev/null", dir.appendingPathComponent("other.jsonl").path]), SessionLiveDetail())
    }

    /// A rollout it holds that cannot be read is an error, not an empty card.
    func testARolloutThatCannotBeReadIsAnError() throws {
        let path = dir.appendingPathComponent(".codex/sessions/2026/01/02/rollout-gone.jsonl").path
        XCTAssertThrowsError(try read([path]))
    }
}

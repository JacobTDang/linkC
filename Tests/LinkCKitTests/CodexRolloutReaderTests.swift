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

    /// The context is the last request's tokens against the model's window, as Codex's footer counts
    /// them: 50,000 of 200,000 is 20% once the 12,000 tokens always there come off both.
    func testTheContextIsTheLastRequestAgainstTheWindow() throws {
        let path = try rollout([started(), tokens(20_000), tokens(50_000), completed()])
        XCTAssertEqual(try read(["/dev/null", path]).contextPercent, 20)
    }

    /// The newest token count wins even when the tail holds no turn boundary to stop at, as in a
    /// long turn that has outgrown it.
    func testTheNewestTokenCountWinsWithNoTurnBoundaryInTheTail() throws {
        let path = try rollout([tokens(20_000), tokens(50_000)])
        XCTAssertEqual(try read([path]).contextPercent, 20)
    }

    private func context(_ total: Int, window: Int) throws -> Int? {
        try read([try rollout([started(), tokens(total, window: window)])]).contextPercent
    }

    /// Codex's footer (codex-rs `TokenUsage::percent_of_context_window_remaining`, 0.163.0) takes
    /// 12,000 tokens of prompts and tools off both the tokens used and the window, rounds what is
    /// left, and shows 100 less that: 150,000 of 258,400 is 56%, not the 58% a plain ratio gives.
    func testTheContextIsWhatCodexsFooterShows() throws {
        XCTAssertEqual(try context(150_000, window: 258_400), 56)
        // 41.5% used is 58.5% left, which rounds to 59: the footer shows 41, not 42.
        XCTAssertEqual(try context(95_000, window: 212_000), 41)
    }

    func testTokensUnderTheBaselineAreAnEmptyContext() throws {
        XCTAssertEqual(try context(8_000, window: 200_000), 0)
    }

    /// A window no bigger than the baseline leaves the footer nothing: it shows the context full.
    func testAWindowNoBiggerThanTheBaselineIsFull() throws {
        XCTAssertEqual(try context(5_000, window: 12_000), 100)
    }

    func testAContextOverTheWindowIsFull() throws {
        XCTAssertEqual(try context(300_000, window: 200_000), 100)
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

    /// The rollout is what a read reads: unchanged, it need not be read again.
    func testTheRolloutIsWhatAReadReads() throws {
        let path = try rollout([started(), tokens(50_000)])
        let target = LiveSessionTarget(sessionId: "S1", agent: .codex, cwd: "/p", openFiles: ["/dev/null", path])
        XCTAssertEqual(try CodexRolloutReader().sources(of: target), [path])
        XCTAssertEqual(try CodexRolloutReader().sources(of: LiveSessionTarget(sessionId: "S1", agent: .codex, cwd: "/p")), [])
    }

    /// A rollout it holds that cannot be read is an error, not an empty card.
    func testARolloutThatCannotBeReadIsAnError() throws {
        let path = dir.appendingPathComponent(".codex/sessions/2026/01/02/rollout-gone.jsonl").path
        XCTAssertThrowsError(try read([path]))
    }
}

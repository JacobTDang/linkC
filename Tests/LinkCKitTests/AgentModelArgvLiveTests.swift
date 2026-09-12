import XCTest
@testable import LinkCKit

/// Live guard for per-task model selection: `AgentModelCatalog.launchArguments` had no
/// production caller before that feature, so nothing had ever confirmed a real CLI accepts
/// `--model <id>` the way linkC now passes it. Codex in particular validates nothing locally —
/// an unrecognized id still starts a session that then fails every request with an HTTP 400 —
/// so only a live run can tell "started fine" apart from "started, then silently broken".
@MainActor
final class AgentModelArgvLiveTests: XCTestCase {
    /// Builds the exact argv `AppCoordinator.launch` builds for a new, pinned session
    /// (`AgentDescriptor.arguments` followed by `AgentModelCatalog.launchArguments`) and checks
    /// the real Codex CLI accepts it: the process must start and stay alive, not exit on an
    /// argument error. One agent is enough to guard the argv shape; the model id itself
    /// (`gpt-6-astra`) is the one already verified against this user's `~/.codex/config.toml`.
    func testConfiguredCodexModelArgvStartsAndStaysAlive() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LINKC_LIVE_AGENT_TESTS"] == "1", "Drives the real Codex CLI with a real --model flag; set LINKC_LIVE_AGENT_TESTS=1 to run it.")
        guard let path = AgentDescriptor.resolveExecutable(for: .codex),
              FileManager.default.isExecutableFile(atPath: path) else { return }
        guard let model = AgentModelSettings.seeded.model(for: .codex, tier: .deep) else {
            return XCTFail("codex's deep tier must have a verified model configured")
        }

        let args = AgentDescriptor.arguments(for: .codex, mode: .new)
            + AgentModelCatalog.launchArguments(model: model, for: .codex)

        let session = TerminalSession(id: "test-codex-model-argv", cwd: FileManager.default.currentDirectoryPath, title: "codex", agentKind: .codex)
        var terminated = false
        session.onTerminated = { _ in terminated = true }
        try session.start(executable: path, args: args, env: [:])

        try await Task.sleep(for: .seconds(6))

        XCTAssertFalse(terminated, "codex \(args.joined(separator: " ")) exited instead of staying alive — the model id was rejected")
        session.terminate()
    }
}

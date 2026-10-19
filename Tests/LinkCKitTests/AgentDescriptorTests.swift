import XCTest
@testable import LinkCKit

final class AgentDescriptorTests: XCTestCase {
    func testPillTextForAllCases() {
        XCTAssertEqual(AgentKind.claude.pillText, "CLAUDE")
        XCTAssertEqual(AgentKind.agy.pillText, "AGY")
        XCTAssertEqual(AgentKind.cursor.pillText, "CURSOR")
        XCTAssertEqual(AgentKind.codex.pillText, "CODEX")
        XCTAssertEqual(AgentKind.shell.pillText, "SHELL")
    }

    func testDisplayNameForAllCases() {
        XCTAssertEqual(AgentKind.claude.displayName, "Claude Code")
        XCTAssertEqual(AgentKind.agy.displayName, "Antigravity (agy)")
        XCTAssertEqual(AgentKind.cursor.displayName, "Cursor Agent")
        XCTAssertEqual(AgentKind.codex.displayName, "Codex")
        XCTAssertEqual(AgentKind.shell.displayName, "Terminal (zsh)")
    }

    func testBrandColorsDefined() {
        for kind in AgentKind.allCases {
            XCTAssertTrue(kind.brandColorHex.hasPrefix("#"))
            XCTAssertEqual(kind.brandColorHex.count, 7)
        }
    }

    func testArgumentsIncludeYoloAndModeFlags() {
        // Claude
        let claudeNew = AgentDescriptor.arguments(for: .claude, mode: .new)
        XCTAssertEqual(claudeNew, ["--dangerously-skip-permissions"])
        let claudeContinue = AgentDescriptor.arguments(for: .claude, mode: .continueLast)
        XCTAssertEqual(claudeContinue, ["--dangerously-skip-permissions", "--continue"])
        let claudeResume = AgentDescriptor.arguments(for: .claude, mode: .resume)
        XCTAssertEqual(claudeResume, ["--dangerously-skip-permissions", "--resume"])

        // Antigravity (agy)
        let agyNew = AgentDescriptor.arguments(for: .agy, mode: .new)
        XCTAssertEqual(agyNew, ["--dangerously-skip-permissions"])
        let agyContinue = AgentDescriptor.arguments(for: .agy, mode: .continueLast)
        XCTAssertEqual(agyContinue, ["--dangerously-skip-permissions", "--continue"])
        let agyResume = AgentDescriptor.arguments(for: .agy, mode: .resume)
        XCTAssertEqual(agyResume, ["--dangerously-skip-permissions", "--conversation"])

        // Cursor
        let cursorNew = AgentDescriptor.arguments(for: .cursor, mode: .new)
        XCTAssertEqual(cursorNew, ["agent", "--yolo", "--trust", "--approve-mcps"])
        let cursorContinue = AgentDescriptor.arguments(for: .cursor, mode: .continueLast)
        XCTAssertEqual(cursorContinue, ["agent", "--yolo", "--trust", "--approve-mcps", "--continue"])
        let cursorResume = AgentDescriptor.arguments(for: .cursor, mode: .resume)
        XCTAssertEqual(cursorResume, ["agent", "--yolo", "--trust", "--approve-mcps", "--resume"])

        // Codex
        let codexNew = AgentDescriptor.arguments(for: .codex, mode: .new)
        XCTAssertEqual(codexNew, ["--dangerously-bypass-approvals-and-sandbox"])
        let codexContinue = AgentDescriptor.arguments(for: .codex, mode: .continueLast)
        XCTAssertEqual(codexContinue, ["--dangerously-bypass-approvals-and-sandbox", "resume", "--last"])
        let codexResume = AgentDescriptor.arguments(for: .codex, mode: .resume)
        XCTAssertEqual(codexResume, ["--dangerously-bypass-approvals-and-sandbox", "resume"])

        // Shell
        let shellNew = AgentDescriptor.arguments(for: .shell, mode: .new)
        XCTAssertEqual(shellNew, [])
    }

    /// Codex serves every terminal's MCP servers from one shared daemon, so linkC's tool server
    /// can't find its session by walking up the process tree. Each Codex terminal names its
    /// session to that server through a config override instead, placed before `resume` like
    /// every other flag. No other agent needs it.
    func testCodexNamesItsSessionToLinkCsToolServer() {
        let override = ["-c", #"mcp_servers.linkc-multiplier.env.LINKC_SESSION="S-1""#]
        XCTAssertEqual(AgentDescriptor.arguments(for: .codex, mode: .new, sessionId: "S-1"),
                       ["--dangerously-bypass-approvals-and-sandbox"] + override)
        XCTAssertEqual(AgentDescriptor.arguments(for: .codex, mode: .continueLast, sessionId: "S-1"),
                       ["--dangerously-bypass-approvals-and-sandbox"] + override + ["resume", "--last"])
        XCTAssertEqual(AgentDescriptor.arguments(for: .agy, mode: .new, sessionId: "S-1"), ["--dangerously-skip-permissions"])
    }

    func testExecutableResolutionForKnownBinaries() {
        // At least zsh is always executable on macOS
        let zsh = AgentDescriptor.resolveExecutable(for: .shell)
        XCTAssertNotNil(zsh)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: zsh!))
    }

    /// Grok runs on the Cursor plan through Cursor's own CLI: same binary, same flags.
    func testGrokIsItsOwnAgentRunningCursorsCLI() {
        XCTAssertEqual(AgentKind.grok.pillText, "GROK")
        XCTAssertEqual(AgentKind.grok.displayName, "Grok (via Cursor)")
        XCTAssertEqual(AgentKind.grok.shortName, "Grok")
        XCTAssertEqual(AgentKind.grok.brandColorHex, "#E5E5EA")
        let grok = AgentDescriptor.descriptor(for: .grok)
        let cursor = AgentDescriptor.descriptor(for: .cursor)
        XCTAssertEqual(grok.kind, .grok)
        XCTAssertEqual(grok.binaryName, cursor.binaryName)
        XCTAssertEqual(grok.defaultCandidatePaths, cursor.defaultCandidatePaths)
        for mode in [LaunchMode.new, .continueLast, .resume] {
            XCTAssertEqual(AgentDescriptor.arguments(for: .grok, mode: mode, sessionId: "S-1"),
                           AgentDescriptor.arguments(for: .cursor, mode: mode, sessionId: "S-1"), "\(mode)")
        }
    }

    /// Only Grok gets its own Cursor folder and the mark that tells linkC's tool server it is Grok.
    func testOnlyGrokGetsItsOwnCursorFolderAndWorkerMark() {
        let home = URL(fileURLWithPath: "/Users/someone")
        XCTAssertEqual(AgentKind.workerEnvironmentKey, "LINKC_WORKER")
        XCTAssertEqual(AgentDescriptor.grokConfigFolderName, ".cursor-grok")
        XCTAssertEqual(AgentDescriptor.grokConfigDirectory(home: home).path, "/Users/someone/.cursor-grok")
        XCTAssertEqual(AgentDescriptor.environment(for: .grok, home: home),
                       ["CURSOR_CONFIG_DIR": "/Users/someone/.cursor-grok", "LINKC_WORKER": "grok"])
        for kind in AgentKind.allCases where kind != .grok {
            XCTAssertEqual(AgentDescriptor.environment(for: kind, home: home), [:], "\(kind)")
        }
    }

    func testPeersAreEveryAgentButAShell() {
        XCTAssertEqual(AgentKind.peers, [.claude, .agy, .cursor, .codex, .grok])
        XCTAssertEqual(AgentKind.peerList, "claude, agy, cursor, codex, grok")
    }
}

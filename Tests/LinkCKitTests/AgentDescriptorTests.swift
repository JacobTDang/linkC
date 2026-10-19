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
        let codexFlags = ["--dangerously-bypass-approvals-and-sandbox", "-c", "check_for_update_on_startup=false"]
        let codexNew = AgentDescriptor.arguments(for: .codex, mode: .new)
        XCTAssertEqual(codexNew, codexFlags)
        let codexContinue = AgentDescriptor.arguments(for: .codex, mode: .continueLast)
        XCTAssertEqual(codexContinue, codexFlags + ["resume", "--last"])
        let codexResume = AgentDescriptor.arguments(for: .codex, mode: .resume)
        XCTAssertEqual(codexResume, codexFlags + ["resume"])

        // Shell
        let shellNew = AgentDescriptor.arguments(for: .shell, mode: .new)
        XCTAssertEqual(shellNew, [])
    }

    /// Codex serves every terminal's MCP servers from one shared daemon, so linkC's tool server
    /// can't find its session by walking up the process tree. Each Codex terminal names its
    /// session to that server through a config override instead, placed before `resume` like
    /// every other flag. No other agent needs it.
    func testCodexNamesItsSessionToLinkCsToolServer() {
        let codexFlags = ["--dangerously-bypass-approvals-and-sandbox", "-c", "check_for_update_on_startup=false"]
        let override = ["-c", #"mcp_servers.linkc-multiplier.env.LINKC_SESSION="S-1""#]
        XCTAssertEqual(AgentDescriptor.arguments(for: .codex, mode: .new, sessionId: "S-1"),
                       codexFlags + override)
        XCTAssertEqual(AgentDescriptor.arguments(for: .codex, mode: .continueLast, sessionId: "S-1"),
                       codexFlags + override + ["resume", "--last"])
        XCTAssertEqual(AgentDescriptor.arguments(for: .agy, mode: .new, sessionId: "S-1"), ["--dangerously-skip-permissions"])
    }

    /// Codex opens on an "update available" prompt when a newer release is out. linkC types a
    /// worker's task into the terminal once it is ready, and the Enter that ends it chose "Update
    /// now": Codex updated itself and exited before the task began (0.163.0, 2026-10-19). Every
    /// Codex session linkC starts skips that check, in every launch mode.
    func testCodexSkipsItsStartupUpdateCheck() {
        for mode in [LaunchMode.new, .continueLast, .resume] {
            let args = AgentDescriptor.arguments(for: .codex, mode: mode, sessionId: "S-1")
            XCTAssertEqual(Array(args.prefix(3)),
                           ["--dangerously-bypass-approvals-and-sandbox", "-c", "check_for_update_on_startup=false"], "\(mode)")
        }
    }

    func testExecutableResolutionForKnownBinaries() {
        // At least zsh is always executable on macOS
        let zsh = AgentDescriptor.resolveExecutable(for: .shell)
        XCTAssertNotNil(zsh)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: zsh!))
    }
}

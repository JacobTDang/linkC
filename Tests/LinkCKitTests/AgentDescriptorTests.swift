import XCTest
@testable import LinkCKit

final class AgentDescriptorTests: XCTestCase {
    /// Codex's flags in every linkC launch: no approvals or sandbox, and no startup update check.
    private let codexFlags = ["--dangerously-bypass-approvals-and-sandbox", "-c", "check_for_update_on_startup=false"]

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
            XCTAssertEqual(Array(args.prefix(3)), codexFlags, "\(mode)")
        }
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
        for kind in AgentKind.allCases where kind != .grok && kind != .opencode && kind != .kilo {
            XCTAssertEqual(AgentDescriptor.environment(for: kind, home: home), [:], "\(kind)")
        }
    }

    func testPeersAreEveryAgentButAShell() {
        XCTAssertEqual(AgentKind.peers, [.claude, .agy, .cursor, .codex, .grok, .opencode, .freebuff, .kilo])
        XCTAssertEqual(AgentKind.peerList, "claude, agy, cursor, codex, grok, opencode, freebuff, kilo")
    }

    /// OpenCode runs its own binary, on a private server of its own, with every permission approved. It never gets `--continue`:
    /// that takes the newest session of the whole project, in whatever folder it ran.
    func testOpenCodeIsItsOwnAgentWithEveryPermissionApproved() {
        XCTAssertEqual(AgentKind.opencode.pillText, "OPENCODE")
        XCTAssertEqual(AgentKind.opencode.displayName, "OpenCode")
        XCTAssertEqual(AgentKind.opencode.shortName, "OpenCode")
        XCTAssertEqual(AgentKind.opencode.brandColorHex, "#FAB283")
        let opencode = AgentDescriptor.descriptor(for: .opencode)
        XCTAssertEqual(opencode.kind, .opencode)
        XCTAssertEqual(opencode.binaryName, "opencode")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(opencode.defaultCandidatePaths,
                       ["/opt/homebrew/bin/opencode", "/usr/local/bin/opencode", "\(home)/.opencode/bin/opencode"])
        for mode in [LaunchMode.new, .continueLast, .resume] {
            XCTAssertEqual(AgentDescriptor.arguments(for: .opencode, mode: mode, sessionId: "S-1"), ["--standalone", "--auto"], "\(mode)")
        }
    }

    func testFreebuffUsesItsOwnUntieredCLIAndContinuesWithoutTrustingAgents() {
        XCTAssertEqual(AgentKind.freebuff.pillText, "FREEBUFF")
        XCTAssertEqual(AgentKind.freebuff.displayName, "Freebuff")
        XCTAssertEqual(AgentKind.freebuff.shortName, "Freebuff")
        let descriptor = AgentDescriptor.descriptor(for: .freebuff)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(descriptor.binaryName, "freebuff")
        XCTAssertEqual(descriptor.defaultCandidatePaths,
                       ["\(home)/.local/bin/freebuff", "/opt/homebrew/bin/freebuff", "/usr/local/bin/freebuff"])
        XCTAssertEqual(AgentDescriptor.arguments(for: .freebuff, mode: .new), [])
        XCTAssertEqual(AgentDescriptor.arguments(for: .freebuff, mode: .continueLast), ["--continue"])
        XCTAssertEqual(AgentDescriptor.arguments(for: .freebuff, mode: .resume), ["--continue"])
        for mode in [LaunchMode.new, .continueLast, .resume] {
            XCTAssertFalse(AgentDescriptor.arguments(for: .freebuff, mode: mode).contains("--trust-agents"))
        }
        XCTAssertTrue(AgentKind.freebuff.isLongTaskOnly)
        XCTAssertTrue(AgentKind.allCases.filter { $0 != .freebuff }.allSatisfy { !$0.isLongTaskOnly })
    }

    /// With a newer release out, OpenCode opens on an update dialog, and the first text linkC types
    /// would answer it.
    func testAnOpenCodeTerminalTurnsOffTheUpdateDialog() {
        XCTAssertEqual(AgentDescriptor.openCodeAutoUpdateKey, "OPENCODE_DISABLE_AUTOUPDATE")
        XCTAssertEqual(AgentDescriptor.openCodeConfigContentKey, "OPENCODE_CONFIG_CONTENT")
        XCTAssertEqual(AgentDescriptor.environment(for: .opencode, home: URL(fileURLWithPath: "/Users/someone")),
                       ["OPENCODE_DISABLE_AUTOUPDATE": "1"])
    }

    /// Kilo runs its own binary with `--auto` and never continues a conversation: that would keep
    /// whatever model it last used, which linkC cannot see and which may not be free.
    func testKiloIsItsOwnAgentWithEveryPermissionApproved() {
        XCTAssertEqual(AgentKind.kilo.pillText, "KILO")
        XCTAssertEqual(AgentKind.kilo.displayName, "Kilo")
        XCTAssertEqual(AgentKind.kilo.shortName, "Kilo")
        XCTAssertEqual(AgentKind.kilo.brandColorHex, "#617A91")
        let kilo = AgentDescriptor.descriptor(for: .kilo)
        XCTAssertEqual(kilo.kind, .kilo)
        XCTAssertEqual(kilo.binaryName, "kilo")
        XCTAssertEqual(kilo.defaultCandidatePaths, ["\(NSHomeDirectory())/.kilo/bin/kilo", "/opt/homebrew/bin/kilo", "/usr/local/bin/kilo"])
        XCTAssertEqual(kilo.continueArgs, [])
        XCTAssertEqual(kilo.resumeArgs, [])
        for mode in [LaunchMode.new, .continueLast, .resume] {
            XCTAssertEqual(AgentDescriptor.arguments(for: .kilo, mode: mode, sessionId: "S-1"), ["--auto"], "\(mode)")
        }
    }

    /// With a newer release out, Kilo opens on an update dialog, and the first text linkC types
    /// would answer it. The model is pinned through `KILO_CONFIG_CONTENT`.
    func testAKiloTerminalTurnsOffTheUpdateDialogAndPinsViaConfigContent() {
        XCTAssertEqual(AgentDescriptor.kiloAutoUpdateKey, "KILO_DISABLE_AUTOUPDATE")
        XCTAssertEqual(AgentDescriptor.kiloConfigContentKey, "KILO_CONFIG_CONTENT")
        XCTAssertEqual(AgentDescriptor.environment(for: .kilo, home: URL(fileURLWithPath: "/Users/someone")),
                       ["KILO_DISABLE_AUTOUPDATE": "1"])
        XCTAssertTrue(AgentKind.alwaysNamesModel.contains(.kilo))
    }
}

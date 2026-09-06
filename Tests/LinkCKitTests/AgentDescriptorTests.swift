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
        XCTAssertEqual(cursorNew, ["agent", "--yolo"])
        let cursorContinue = AgentDescriptor.arguments(for: .cursor, mode: .continueLast)
        XCTAssertEqual(cursorContinue, ["agent", "--yolo", "--continue"])
        let cursorResume = AgentDescriptor.arguments(for: .cursor, mode: .resume)
        XCTAssertEqual(cursorResume, ["agent", "--yolo", "--resume"])

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

    func testExecutableResolutionForKnownBinaries() {
        // At least zsh is always executable on macOS
        let zsh = AgentDescriptor.resolveExecutable(for: .shell)
        XCTAssertNotNil(zsh)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: zsh!))
    }
}

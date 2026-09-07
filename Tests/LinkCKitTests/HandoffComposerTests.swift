import XCTest
@testable import LinkCKit

final class HandoffComposerTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("handoff-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try super.tearDownWithError()
    }

    func testComposeWithAllFieldsPopulated() {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let memo = HandoffComposer.compose(
            workspacePath: "/Users/dev/project",
            sourceAgent: .claude,
            lastGoal: "Implement user authentication",
            gitSummary: " M Sources/Auth.swift\n?? Tests/AuthTests.swift",
            recentTerminalOutput: "swift test --filter AuthTests\nExecuted 4 tests with 0 failures",
            timestamp: timestamp
        )

        XCTAssertTrue(memo.contains("# Project Handoff Memo"))
        XCTAssertTrue(memo.contains("**Workspace:** /Users/dev/project"))
        XCTAssertTrue(memo.contains("**Source Agent:** [CLAUDE] Claude Code"))
        XCTAssertTrue(memo.contains("## Goal"))
        XCTAssertTrue(memo.contains("Implement user authentication"))
        XCTAssertTrue(memo.contains("## Git Status Summary"))
        XCTAssertTrue(memo.contains("M Sources/Auth.swift"))
        XCTAssertTrue(memo.contains("## Recent Terminal Output"))
        XCTAssertTrue(memo.contains("````"))
        XCTAssertTrue(memo.contains("Executed 4 tests with 0 failures"))
    }

    func testComposeWithNilOrEmptyFieldsDegradesGracefully() {
        let memoNil = HandoffComposer.compose(
            workspacePath: "/Users/dev/project",
            sourceAgent: nil,
            lastGoal: nil,
            gitSummary: nil,
            recentTerminalOutput: nil
        )

        XCTAssertTrue(memoNil.contains("# Project Handoff Memo"))
        XCTAssertTrue(memoNil.contains("**Workspace:** /Users/dev/project"))
        XCTAssertTrue(memoNil.contains("**Source Agent:** (None recorded)"))
        XCTAssertTrue(memoNil.contains("(None recorded)"))

        // Empty and whitespace-only fields also degrade gracefully
        let memoEmpty = HandoffComposer.compose(
            workspacePath: "   ",
            sourceAgent: nil,
            lastGoal: "   \n  ",
            gitSummary: "",
            recentTerminalOutput: "   \t "
        )

        XCTAssertTrue(memoEmpty.contains("**Workspace:** (None recorded)"))
        XCTAssertTrue(memoEmpty.contains("**Source Agent:** (None recorded)"))
    }

    func testComposeWithDifferentAgentKinds() {
        for agent in AgentKind.allCases {
            let memo = HandoffComposer.compose(
                workspacePath: "/demo",
                sourceAgent: agent,
                lastGoal: "Testing agent",
                gitSummary: nil,
                recentTerminalOutput: nil
            )

            XCTAssertTrue(
                memo.contains("[\(agent.pillText)] \(agent.displayName)"),
                "Expected memo to contain [\(agent.pillText)] \(agent.displayName)"
            )
        }
    }

    func testWriteHandoffCreatesDirectoryAndWritesAtomically() throws {
        let workspacePath = tempDirectory.path
        let linkcDir = tempDirectory.appendingPathComponent(".linkc", isDirectory: true)
        let handoffFile = linkcDir.appendingPathComponent("HANDOFF.md")

        XCTAssertFalse(FileManager.default.fileExists(atPath: linkcDir.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: handoffFile.path))

        let targetURL = try HandoffComposer.writeHandoff(
            workspacePath: workspacePath,
            content: "# Test Content\nHello world"
        )

        XCTAssertEqual(targetURL.standardizedFileURL, handoffFile.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: handoffFile.path))

        let writtenContent = try String(contentsOf: handoffFile, encoding: .utf8)
        XCTAssertEqual(writtenContent, "# Test Content\nHello world")
    }

    func testWriteHandoffSafeOverwrite() throws {
        let workspacePath = tempDirectory.path
        let initialContent = "# Initial Content"
        let updatedContent = "# Updated Content\nNew details added"

        let url1 = try HandoffComposer.writeHandoff(workspacePath: workspacePath, content: initialContent)
        let read1 = try String(contentsOf: url1, encoding: .utf8)
        XCTAssertEqual(read1, initialContent)

        let url2 = try HandoffComposer.writeHandoff(workspacePath: workspacePath, content: updatedContent)
        let read2 = try String(contentsOf: url2, encoding: .utf8)
        XCTAssertEqual(read2, updatedContent)
        XCTAssertEqual(url1.standardizedFileURL, url2.standardizedFileURL)
    }

    func testWriteHandoffSyncComposesAndWrites() throws {
        let workspacePath = tempDirectory.path
        let handoffFile = tempDirectory.appendingPathComponent(".linkc/HANDOFF.md")

        let url = try HandoffComposer.writeHandoffSync(
            workspacePath: workspacePath,
            sourceAgent: .codex,
            lastGoal: "Optimize parser performance",
            gitSummary: " M Sources/Parser.swift",
            recentTerminalOutput: "swift test passed"
        )

        XCTAssertEqual(url.standardizedFileURL, handoffFile.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: handoffFile.path))

        let content = try String(contentsOf: handoffFile, encoding: .utf8)
        XCTAssertTrue(content.contains("# Project Handoff Memo"))
        XCTAssertTrue(content.contains("[CODEX] Codex"))
        XCTAssertTrue(content.contains("Optimize parser performance"))
        XCTAssertTrue(content.contains("M Sources/Parser.swift"))
        XCTAssertTrue(content.contains("swift test passed"))
    }

    func testComposeWithEmbeddedTripleBackticks() {
        let output = "Some output\n```swift\nlet x = 1\n```\nDone."
        let memo = HandoffComposer.compose(
            workspacePath: "/Users/dev/project",
            sourceAgent: .claude,
            lastGoal: "Fix issue",
            gitSummary: nil,
            recentTerminalOutput: output
        )
        XCTAssertTrue(memo.contains("````\n\(output)\n````"))
    }
}

import XCTest
@testable import LinkCKit

final class ClaudeUsageReaderTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("claude-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func write(_ relativePath: String, _ lines: [String], modified: Date) throws {
        let url = dir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A trailing newline after the last line, matching real JSONL transcripts: the tail
        // reader only ever hands out newline-terminated lines, so it can't mistake an
        // in-progress write for a complete one.
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    /// An assistant transcript line carrying a known token total, timestamped recently enough
    /// (relative to real "now") to fall inside both the 5-hour block and the 7-day window
    /// regardless of when the test happens to run.
    private func assistantLine(tokens: Int, secondsAgo: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date().addingTimeInterval(-secondsAgo))
        return """
        {"type":"assistant","timestamp":"\(timestamp)","message":{"model":"claude-opus-4",\
        "usage":{"input_tokens":\(tokens),"output_tokens":0}}}
        """
    }

    func testItComputesBlockAndWeekTotalsFromAllTranscripts() throws {
        let older = Date().addingTimeInterval(-600)
        let newer = Date()
        try write("proj1/session1.jsonl", [assistantLine(tokens: 1000, secondsAgo: 120)], modified: older)
        try write("proj2/session2.jsonl", [assistantLine(tokens: 2000, secondsAgo: 60)], modified: newer)

        let usage = ClaudeUsageReader(projectsDirectory: dir).read()

        XCTAssertNil(usage.unavailableReason)
        XCTAssertNil(usage.planType, "Anthropic publishes no per-plan limit, so no plan is claimed")
        XCTAssertNotNil(usage.observedAt)
        XCTAssertEqual(usage.observedAt!.timeIntervalSince1970, newer.timeIntervalSince1970, accuracy: 2,
                       "observedAt is the newest transcript's modification date")

        XCTAssertEqual(usage.windows.count, 2)
        XCTAssertEqual(usage.windows[0].label, "5h")
        XCTAssertNil(usage.windows[0].usedPercent, "Anthropic publishes no percentage")
        XCTAssertEqual(usage.windows[0].tokens, 3000)
        XCTAssertNotNil(usage.windows[0].resetsAt)

        XCTAssertEqual(usage.windows[1].label, "7d")
        XCTAssertNil(usage.windows[1].usedPercent)
        XCTAssertEqual(usage.windows[1].tokens, 3000)
    }

    func testEachFailureModeNamesItself() throws {
        let missing = ClaudeUsageReader(projectsDirectory: dir.appendingPathComponent("nope")).read()
        XCTAssertNotNil(missing.unavailableReason)
        XCTAssertTrue(missing.windows.isEmpty)

        let empty = ClaudeUsageReader(projectsDirectory: dir).read()
        XCTAssertNotNil(empty.unavailableReason, "a directory with no transcripts says so")

        XCTAssertNotEqual(missing.unavailableReason, empty.unavailableReason)
        XCTAssertEqual(missing.unavailableReason, "no ~/.claude/projects directory")
        XCTAssertEqual(empty.unavailableReason, "no session records found")
    }
}

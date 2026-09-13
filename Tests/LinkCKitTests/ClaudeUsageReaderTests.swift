import XCTest
@testable import LinkCKit

final class ClaudeUsageReaderTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("claude-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// Returns the byte size actually written, so budget tests can size `byteBudget` against
    /// real file sizes instead of guessing at JSON encoding overhead.
    @discardableResult
    private func write(_ relativePath: String, _ lines: [String], modified: Date) throws -> Int {
        let url = dir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A trailing newline after the last line, matching real JSONL transcripts: the tail
        // reader only ever hands out newline-terminated lines, so it can't mistake an
        // in-progress write for a complete one.
        let content = lines.joined(separator: "\n") + "\n"
        try content.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return content.utf8.count
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

    // MARK: - Byte budget

    func testFilesWithinBudgetProduceExactUnmarkedFigures() throws {
        let older = Date().addingTimeInterval(-600)
        let newer = Date()
        try write("proj1/session1.jsonl", [assistantLine(tokens: 1000, secondsAgo: 120)], modified: older)
        try write("proj2/session2.jsonl", [assistantLine(tokens: 2000, secondsAgo: 60)], modified: newer)

        // Both fixtures are a few hundred bytes; this budget comfortably covers both.
        let usage = ClaudeUsageReader(projectsDirectory: dir, byteBudget: 1_000_000).read()

        XCTAssertEqual(usage.windows.count, 2)
        XCTAssertFalse(usage.windows[0].tokensAreLowerBound, "everything fit the budget — 5h is exact")
        XCTAssertFalse(usage.windows[1].tokensAreLowerBound, "everything fit the budget — 7d is exact")
        XCTAssertEqual(usage.windows[0].tokens, 3000)
        XCTAssertEqual(usage.windows[1].tokens, 3000)
    }

    func testBudgetExhaustedBeforeTheWeekIsCoveredMarksOnlyTheWeekWindowALowerBound() throws {
        // Recent file: inside the 5h window, small.
        let recentSize = try write(
            "proj1/recent.jsonl", [assistantLine(tokens: 500, secondsAgo: 60)], modified: Date())
        // Two older-than-5h-but-within-7d files, newest first.
        let older1Size = try write(
            "proj2/older1.jsonl", [assistantLine(tokens: 700, secondsAgo: 2 * 24 * 3600)],
            modified: Date().addingTimeInterval(-2 * 24 * 3600))
        try write(
            "proj3/older2.jsonl", [assistantLine(tokens: 900, secondsAgo: 3 * 24 * 3600)],
            modified: Date().addingTimeInterval(-3 * 24 * 3600))

        // Exactly enough for the recent file plus the newer of the two older files — not
        // the third.
        let budget = recentSize + older1Size
        let usage = ClaudeUsageReader(projectsDirectory: dir, byteBudget: budget).read()

        XCTAssertFalse(usage.windows[0].tokensAreLowerBound, "the 5h window's only file fit the budget")
        XCTAssertEqual(usage.windows[0].tokens, 500)

        XCTAssertTrue(usage.windows[1].tokensAreLowerBound, "the budget ran out before every 7d file was read")
        XCTAssertEqual(usage.windows[1].tokens, 500 + 700, "reflects exactly what was actually read, not a guess")
    }

    func testFiveHourFilesAreReadBeforeOlderOnesEvenWhenTheOlderOnesAreLarger() throws {
        // The older file is deliberately padded far larger than the recent one, so a reader
        // that let file size (rather than recency) drive read order would starve the
        // 5-hour file of budget.
        let padding = String(repeating: "x", count: 5000)
        try write(
            "proj1/older-big.jsonl",
            ["{\"type\":\"filler\",\"pad\":\"\(padding)\"}", assistantLine(tokens: 900, secondsAgo: 3 * 24 * 3600)],
            modified: Date().addingTimeInterval(-3 * 24 * 3600))
        let recentSize = try write(
            "proj2/recent.jsonl", [assistantLine(tokens: 500, secondsAgo: 60)], modified: Date())

        // Enough for the small recent file only — nowhere near enough for the padded older one.
        let usage = ClaudeUsageReader(projectsDirectory: dir, byteBudget: recentSize).read()

        XCTAssertFalse(usage.windows[0].tokensAreLowerBound, "the 5-hour file was read despite being enumerated second")
        XCTAssertEqual(usage.windows[0].tokens, 500, "the recent file's tokens must be present")
        XCTAssertEqual(usage.windows[1].tokens, 500, "the larger, older file must not have consumed the budget first")
        XCTAssertTrue(usage.windows[1].tokensAreLowerBound)
    }
}

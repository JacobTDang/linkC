import XCTest
@testable import LinkCKit

final class ClaudeUsageReaderTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("claude-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// Returns the byte size actually written, so tests can size a reader's constants against
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

    /// Writes pre-built raw content (rather than a line array) verbatim, for fixtures that
    /// need exact control over their own trailing bytes.
    @discardableResult
    private func writeRaw(_ relativePath: String, _ content: String, modified: Date) throws -> Int {
        let url = dir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
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

    // MARK: - Task 10 review fixes: backward, chunked, provably-bounded reads

    /// (a) The reviewer's case: a file bigger than both the reader's chunk size and the old
    /// (now-removed) 4 MB per-file tail cap, carrying its one usage line near the file's
    /// start — well outside any fixed tail cut — with a generous budget.
    func testA_ReviewersCase_EarlyUsageLineInAFileLargerThanTheOldTailCapIsCountedExactly() throws {
        // ~5.9 MB of filler after the usage line — bigger than the old reader's hardcoded
        // 4 MB tail cap, so a tail-only read would miss the usage line entirely.
        let filler = String(repeating: "{\"type\":\"tool_result\",\"pad\":\"filler line\"}\n", count: 150_000)
        let content = assistantLine(tokens: 5000, secondsAgo: 60) + "\n" + filler
        let bytesWritten = try writeRaw("proj/big.jsonl", content, modified: Date())
        XCTAssertGreaterThan(bytesWritten, 4 * 1024 * 1024, "fixture must exceed the old per-file tail cap")

        let usage = ClaudeUsageReader(
            projectsDirectory: dir, byteBudget: 20_000_000,
            fiveHourSafetyCapBytes: 20_000_000, chunkSizeBytes: 256 * 1024
        ).read()

        XCTAssertEqual(usage.windows[0].tokens, 5000, "an early usage line must not be hidden by a tail cut")
        XCTAssertFalse(usage.windows[0].tokensAreLowerBound)
        XCTAssertEqual(usage.windows[1].tokens, 5000)
        XCTAssertFalse(usage.windows[1].tokensAreLowerBound)
    }

    /// (c) The 5-hour exemption: a tiny shared budget, with a 5-hour file whose own
    /// (comfortably large) safety cap lets it read every message inside the 5-hour boundary,
    /// plus — incidentally, while proving that boundary — one message far older than 5 hours.
    /// The ~2-day gap between that older message and the block's own message is itself proof:
    /// nothing was missed in between (both ends were actually read), and nothing further back
    /// than the older message can reach past a block boundary that already restarts at the
    /// newer one. So the block figure stays exact even though the week read never completed.
    func testC_AGapBeforeTheBlocksOnlyMessageKeepsItExactEvenWhenTheWeekIsIncomplete() throws {
        // File order (oldest to newest): padding the 5-hour phase must stop short of, a
        // usage line ~2 days before the 5-hour boundary, then a usage line inside it.
        let padding = String(repeating: "{\"type\":\"tool_result\"}\n", count: 200)
        let content = padding
            + assistantLine(tokens: 700, secondsAgo: 2 * 24 * 3600) + "\n"
            + assistantLine(tokens: 500, secondsAgo: 60) + "\n"
        try writeRaw("proj/mixed.jsonl", content, modified: Date())

        let usage = ClaudeUsageReader(
            projectsDirectory: dir, byteBudget: 0,
            fiveHourSafetyCapBytes: 1_000_000, chunkSizeBytes: 64
        ).read()

        XCTAssertEqual(usage.windows[0].tokens, 500, "the 5-hour safety cap is generous enough to finish")
        XCTAssertFalse(usage.windows[0].tokensAreLowerBound,
                       "a ~2-day quiet gap right before the block's only message proves it, independent of the padding the budget never reached")

        XCTAssertEqual(usage.windows[1].tokens, 1200, "reflects exactly the two lines actually read")
        XCTAssertTrue(usage.windows[1].tokensAreLowerBound, "no shared budget left to read the remaining padding")
    }

    /// (e) The same exhausted shared budget as (c), but with no quiet stretch anywhere in what
    /// was actually read: a second, older file sits entirely unread (the budget is gone before
    /// it's even opened), and the one file that was read is packed with activity right up to
    /// its own start. Nothing proves the unread file couldn't extend that same activity
    /// further back with no gap at all, so the block figure must stay a lower bound.
    func testE_ContinuousActivityWithNoProvenGapLeavesTheBlockFlaggedWhenTheWeekIsIncomplete() throws {
        try write("proj/recent.jsonl", [
            assistantLine(tokens: 100, secondsAgo: 40 * 60),
            assistantLine(tokens: 100, secondsAgo: 20 * 60),
            assistantLine(tokens: 300, secondsAgo: 60)
        ], modified: Date())
        // Old enough to skip the 5-hour exemption entirely, and never even opened once the
        // shared budget below is spent on nothing (0 bytes) — it exists purely to make the
        // week read incomplete without offering any proof about what it might contain.
        try write("proj/older.jsonl", [assistantLine(tokens: 50, secondsAgo: 7 * 3600)],
                  modified: Date().addingTimeInterval(-6 * 3600))

        let usage = ClaudeUsageReader(projectsDirectory: dir, byteBudget: 0).read()

        XCTAssertEqual(usage.windows[0].tokens, 500, "all three recent-file messages chain into one active block")
        XCTAssertTrue(usage.windows[0].tokensAreLowerBound,
                      "nothing proves the unread older file doesn't extend the same unbroken activity further back")
    }

    /// (d) The 5-hour safety cap itself: a tiny cap stops a 5-hour file's read before it can
    /// prove the 5-hour boundary or reach the file's start.
    func testD_FiveHourSafetyCapStoppingEarlyFlagsTheBlock() throws {
        // The usage line sits right at EOF; padding before it has no usage lines at all, so
        // the scan has no evidence to stop on and just keeps going until the cap runs out.
        let padding = String(repeating: "{\"type\":\"tool_result\"}\n", count: 300)
        let content = padding + assistantLine(tokens: 500, secondsAgo: 60) + "\n"
        try writeRaw("proj/capped.jsonl", content, modified: Date())

        let usage = ClaudeUsageReader(
            projectsDirectory: dir, byteBudget: 1_000_000,
            fiveHourSafetyCapBytes: 300, chunkSizeBytes: 64
        ).read()

        XCTAssertEqual(usage.windows[0].tokens, 500, "the one line reachable within the tiny cap is still counted")
        XCTAssertTrue(usage.windows[0].tokensAreLowerBound, "the cap stopped before a boundary was proven")
    }

    /// (b) A 5-hour file's early (older-than-5h) content, encountered for free while proving
    /// the 5-hour boundary, must still be folded into the week figure — not discarded because
    /// it fell outside the 5-hour window that phase's scan was aimed at.
    func testB_OlderThanFiveHourDataFoundProvingTheBlockStillCountsTowardTheWeek() throws {
        try write("proj/mixed.jsonl", [
            assistantLine(tokens: 700, secondsAgo: 6 * 3600),   // outside 5h, inside 7d
            assistantLine(tokens: 2000, secondsAgo: 60)          // inside both
        ], modified: Date())

        let usage = ClaudeUsageReader(
            projectsDirectory: dir, byteBudget: 1_000_000,
            fiveHourSafetyCapBytes: 1_000_000, chunkSizeBytes: 64
        ).read()

        XCTAssertEqual(usage.windows[0].tokens, 2000, "only the line inside the 5h window counts there")
        XCTAssertFalse(usage.windows[0].tokensAreLowerBound)
        XCTAssertEqual(usage.windows[1].tokens, 2700, "the older-than-5h line still counts toward the week")
        XCTAssertFalse(usage.windows[1].tokensAreLowerBound)
    }
}

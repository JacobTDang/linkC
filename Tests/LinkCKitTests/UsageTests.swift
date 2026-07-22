import XCTest
@testable import LinkCKit

/// The usage pipeline's pure core: transcript-line parsing. Lines come from claude's session
/// JSONL; only assistant messages carrying `usage` count, and sidechain (subagent) traffic is
/// flagged so context fill can ignore it while totals include it.
final class TranscriptUsageTests: XCTestCase {

    private let assistantLine = """
    {"type":"assistant","isSidechain":false,"timestamp":"2026-07-22T05:04:03.123Z",\
    "message":{"model":"claude-opus-4-8","usage":{"input_tokens":2,\
    "cache_read_input_tokens":182183,"cache_creation_input_tokens":475,"output_tokens":1182,\
    "cache_creation":{"ephemeral_1h_input_tokens":400,"ephemeral_5m_input_tokens":75}}}}
    """

    func testParsesAssistantUsageLine() throws {
        let u = try XCTUnwrap(TranscriptUsage.parseLine(assistantLine))
        XCTAssertEqual(u.model, "claude-opus-4-8")
        XCTAssertEqual(u.inputTokens, 2)
        XCTAssertEqual(u.cacheReadTokens, 182_183)
        XCTAssertEqual(u.cacheWrite5mTokens, 75)
        XCTAssertEqual(u.cacheWrite1hTokens, 400)
        XCTAssertEqual(u.outputTokens, 1182)
        XCTAssertFalse(u.isSidechain)
        XCTAssertEqual(u.contextTokens, 2 + 182_183 + 475)
        XCTAssertEqual(u.totalTokens, 2 + 182_183 + 475 + 1182)
        XCTAssertEqual(u.timestamp.timeIntervalSince1970, 1_784_696_643.123, accuracy: 0.01)
    }

    func testMissingCacheCreationBreakdownBillsTotalAsFiveMinute() throws {
        let line = """
        {"type":"assistant","timestamp":"2026-07-22T05:04:03Z",\
        "message":{"model":"claude-haiku-4-5","usage":{"input_tokens":10,\
        "cache_read_input_tokens":0,"cache_creation_input_tokens":500,"output_tokens":20}}}
        """
        let u = try XCTUnwrap(TranscriptUsage.parseLine(line))
        XCTAssertEqual(u.cacheWrite5mTokens, 500)
        XCTAssertEqual(u.cacheWrite1hTokens, 0)
        // Whole-second timestamp (no fractional part) must parse too.
        XCTAssertEqual(u.timestamp.timeIntervalSince1970, 1_784_696_643, accuracy: 0.5)
    }

    func testSidechainFlagIsCarried() throws {
        let line = assistantLine.replacingOccurrences(of: "\"isSidechain\":false", with: "\"isSidechain\":true")
        let u = try XCTUnwrap(TranscriptUsage.parseLine(line))
        XCTAssertTrue(u.isSidechain)
    }

    func testNonAssistantMalformedAndUsagelessLinesAreNil() {
        XCTAssertNil(TranscriptUsage.parseLine(#"{"type":"user","message":{"content":"hi"}}"#))
        XCTAssertNil(TranscriptUsage.parseLine("not json at all"))
        XCTAssertNil(TranscriptUsage.parseLine(#"{"type":"assistant","timestamp":"2026-07-22T05:04:03Z","message":{"model":"claude-opus-4-8"}}"#))
        XCTAssertNil(TranscriptUsage.parseLine(""))
    }
}

/// Shared fixture builder for the usage math tests.
private func usage(
    at timestamp: Date = Date(timeIntervalSince1970: 1_784_696_643),
    model: String = "claude-opus-4-8",
    input: Int = 0, cacheRead: Int = 0, write5m: Int = 0, write1h: Int = 0, output: Int = 0,
    sidechain: Bool = false
) -> MessageUsage {
    MessageUsage(
        timestamp: timestamp, model: model, inputTokens: input, cacheReadTokens: cacheRead,
        cacheWrite5mTokens: write5m, cacheWrite1hTokens: write1h, outputTokens: output,
        isSidechain: sidechain
    )
}

/// Dollar estimates come from a built-in $/MTok table; unknown models are excluded (nil),
/// never guessed — a wrong number is worse than none.
final class ModelPricingTests: XCTestCase {

    func testOpusCostArithmetic() throws {
        // Opus tier: in 5, out 25, cache read 0.50, write5m 6.25, write1h 10.00 per MTok.
        let u = usage(input: 1_000_000, cacheRead: 1_000_000, write5m: 1_000_000,
                      write1h: 1_000_000, output: 1_000_000)
        let cost = try XCTUnwrap(ModelPricing.cost(of: u))
        XCTAssertEqual(cost, 5 + 0.50 + 6.25 + 10 + 25, accuracy: 0.0001)
    }

    func testEachFamilyPrefixResolves() {
        for model in ["claude-fable-5", "claude-mythos-5", "claude-opus-4-8", "claude-opus-4-5",
                      "claude-sonnet-5", "claude-sonnet-4-6", "claude-haiku-4-5-20251001"] {
            XCTAssertNotNil(ModelPricing.cost(of: usage(model: model, input: 1)), model)
        }
    }

    func testUnknownModelIsNil() {
        XCTAssertNil(ModelPricing.cost(of: usage(model: "gpt-9", input: 1)))
        XCTAssertNil(ModelPricing.cost(of: usage(model: "claude-opus-4-1", input: 1)),
                     "opus 4.1 has different pricing than 4.5+ — must not match the 4.5–4.8 rows")
    }
}

/// Plan-window math: a ccusage-style 5h block (hour-floored start, reset 5h later) plus a
/// rolling 7-day total. Absolute numbers only — no invented percentages.
final class UsageWindowsTests: XCTestCase {

    // 2026-07-22 05:04:03 UTC — an arbitrary fixed "now".
    private let now = Date(timeIntervalSince1970: 1_784_696_643)
    private func minutesAgo(_ m: Double) -> Date { now.addingTimeInterval(-m * 60) }

    func testActiveBlockFloorsToHourAndSumsItsEntries() {
        // First activity 04:50 UTC → block start floors to 04:00, reset 09:00.
        let w = UsageWindows.compute([
            usage(at: minutesAgo(14), output: 100),
            usage(at: minutesAgo(4), output: 50),
        ], now: now)
        XCTAssertEqual(w.blockTokens, 150)
        // 04:00 UTC + 5h = 09:00 UTC = 1_784_710_800
        XCTAssertEqual(w.blockResetAt?.timeIntervalSince1970, 1_784_710_800)
        XCTAssertEqual(w.weekTokens, 150)
    }

    func testGapOverFiveHoursStartsANewBlock() {
        let w = UsageWindows.compute([
            usage(at: minutesAgo(6 * 60), output: 999),  // old burst, its block expired
            usage(at: minutesAgo(10), output: 25),        // fresh activity → new block
        ], now: now)
        XCTAssertEqual(w.blockTokens, 25, "the expired block's tokens must not leak in")
        XCTAssertEqual(w.weekTokens, 999 + 25)
    }

    func testNoRecentActivityMeansNoActiveBlock() {
        let w = UsageWindows.compute([usage(at: minutesAgo(9 * 60), output: 500)], now: now)
        XCTAssertEqual(w.blockTokens, 0)
        XCTAssertNil(w.blockResetAt)
        XCTAssertEqual(w.weekTokens, 500)
    }

    func testWeekWindowPrunesOlderEntries() {
        let w = UsageWindows.compute([
            usage(at: now.addingTimeInterval(-8 * 24 * 3600), output: 1000),  // beyond 7d
            usage(at: minutesAgo(30), output: 10),
        ], now: now)
        XCTAssertEqual(w.weekTokens, 10)
    }
}

/// Incremental transcript reading: remember a byte offset per file, hand back only complete
/// appended lines, and survive truncation. This is what makes "live" cheap.
final class TranscriptTailReaderTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-tail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func write(_ text: String, to name: String) throws -> String {
        let url = dir.appendingPathComponent(name)
        try text.data(using: .utf8)!.write(to: url)
        return url.path
    }

    private func append(_ text: String, to path: String) throws {
        let handle = FileHandle(forWritingAtPath: path)!
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: text.data(using: .utf8)!)
    }

    func testReadsAllThenOnlyAppended() throws {
        let path = try write("a\nb\n", to: "t.jsonl")
        let reader = TranscriptTailReader()
        XCTAssertEqual(reader.readNewLines(at: path), ["a", "b"])
        XCTAssertEqual(reader.readNewLines(at: path), [])
        try append("c\n", to: path)
        XCTAssertEqual(reader.readNewLines(at: path), ["c"])
    }

    func testPartialTrailingLineWithheldUntilComplete() throws {
        let path = try write("a\npart", to: "t.jsonl")
        let reader = TranscriptTailReader()
        XCTAssertEqual(reader.readNewLines(at: path), ["a"])
        try append("ial\n", to: path)
        XCTAssertEqual(reader.readNewLines(at: path), ["partial"])
    }

    func testTruncationResetsOffset() throws {
        let path = try write("aaaa\nbbbb\ncccc\n", to: "t.jsonl")
        let reader = TranscriptTailReader()
        _ = reader.readNewLines(at: path)
        _ = try write("x\n", to: "t.jsonl") // shrunk: offset now beyond EOF
        XCTAssertEqual(reader.readNewLines(at: path), ["x"])
    }

    func testFirstReadTailCapDropsLeadingPartialLine() throws {
        let path = try write("aaaaaaaaaa\nbbb\nccc\n", to: "t.jsonl")
        let reader = TranscriptTailReader()
        // Cap lands mid-"aaaaaaaaaa" — that partial line is dropped, complete ones kept.
        XCTAssertEqual(reader.readNewLines(at: path, firstReadTailCap: 9), ["bbb", "ccc"])
        try append("d\n", to: path)
        XCTAssertEqual(reader.readNewLines(at: path, firstReadTailCap: 9), ["d"],
                       "the cap applies only to a file's first read")
    }

    func testMissingFileIsEmpty() {
        XCTAssertEqual(TranscriptTailReader().readNewLines(at: dir.appendingPathComponent("no.jsonl").path), [])
    }
}

/// Display formatting for the three usage surfaces — compact, deterministic.
final class UsageFormatTests: XCTestCase {

    func testTokens() {
        XCTAssertEqual(UsageFormat.tokens(0), "0")
        XCTAssertEqual(UsageFormat.tokens(950), "950")
        XCTAssertEqual(UsageFormat.tokens(12_400), "12.4k")
        XCTAssertEqual(UsageFormat.tokens(142_000), "142k")
        XCTAssertEqual(UsageFormat.tokens(3_140_000), "3.1M")
        XCTAssertEqual(UsageFormat.tokens(41_000_000), "41M")
    }

    func testDollars() {
        XCTAssertEqual(UsageFormat.dollars(1.874), "~$1.87")
        XCTAssertEqual(UsageFormat.dollars(0.002), "~$0.01", "positive sub-cent floors at one cent")
        XCTAssertEqual(UsageFormat.dollars(0), "~$0.00")
    }

    func testResetTime() {
        // 09:00 UTC = 2am PDT; 14:30 UTC = 7:30am PDT.
        let tz = TimeZone(identifier: "America/Los_Angeles")!
        XCTAssertEqual(UsageFormat.resetTime(Date(timeIntervalSince1970: 1_784_710_800), timeZone: tz), "~2am")
        XCTAssertEqual(UsageFormat.resetTime(Date(timeIntervalSince1970: 1_784_730_600), timeZone: tz), "~7:30am")
    }
}

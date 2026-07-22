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

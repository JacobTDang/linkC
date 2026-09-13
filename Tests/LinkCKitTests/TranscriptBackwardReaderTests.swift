import XCTest
@testable import LinkCKit

/// Direct tests of the backward, chunked scan primitive `ClaudeUsageReader` is built on —
/// separate from `TranscriptTailReader`, which does the app's forward incremental reads and
/// must not change.
final class TranscriptBackwardReaderTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("backward-reader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func assistantLine(tokens: Int, secondsAgo: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date().addingTimeInterval(-secondsAgo))
        return """
        {"type":"assistant","timestamp":"\(timestamp)","message":{"model":"claude-opus-4",\
        "usage":{"input_tokens":\(tokens),"output_tokens":0}}}
        """
    }

    /// (e) A slightly older line sitting among newer lines, inside one chunk that also
    /// contains a genuinely older-and-earlier-in-the-file line the scan must still reach.
    /// `lineB` is deliberately disordered: chronologically older than the window, but written
    /// (and so positioned in the file) after `lineA`, which is inside the window. A scan that
    /// stopped on the first older line it saw, rather than waiting for a whole chunk of
    /// nothing-but-older evidence, would see `lineB` mixed into the same chunk as `lineC`/
    /// `lineD` and quit before ever reading further back for `lineA` — silently losing tokens
    /// that were genuinely inside the window.
    func testSmallDisorderWithinOneChunkDoesNotEndTheScanEarly() throws {
        let windowStart = Date().addingTimeInterval(-5 * 3600)

        let lineA = assistantLine(tokens: 100, secondsAgo: 3000)          // inside window, earliest in file
        let lineB = assistantLine(tokens: 999, secondsAgo: 5 * 3600 + 600) // OUTSIDE window, disordered
        let lineC = assistantLine(tokens: 200, secondsAgo: 1800)          // inside window
        let lineD = assistantLine(tokens: 300, secondsAgo: 600)          // inside window, nearest EOF

        // Chunk sized to land the read boundary a few bytes inside `lineA`, so the first
        // (EOF-adjacent) physical chunk resolves lineB, lineC and lineD together — mixing the
        // disordered older line in with newer ones inside a single chunk — while lineA still
        // requires a second, further-back read to reach.
        let tail = "\(lineB)\n\(lineC)\n\(lineD)\n"
        let tailBytes = tail.utf8.count
        let overlapIntoLineA = 5
        let chunkSize = tailBytes + overlapIntoLineA

        let content = "\(lineA)\n" + tail
        let url = dir.appendingPathComponent("disorder.jsonl")
        try content.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertGreaterThan(lineA.utf8.count, overlapIntoLineA, "lineA must be longer than the overlap")

        let result = TranscriptBackwardReader.scan(
            path: url.path, windowStart: windowStart, chunkSize: chunkSize, maxBytes: 1_000_000)

        let inWindowTokens = result.usages
            .filter { $0.timestamp >= windowStart }
            .map(\.inputTokens)
            .sorted()
        XCTAssertEqual(inWindowTokens, [100, 200, 300], "lineA must be reached past the mixed chunk")
        XCTAssertFalse(result.usages.contains { $0.inputTokens == 999 && $0.timestamp >= windowStart },
                        "the disordered older line must not be counted as in-window")
        XCTAssertTrue(result.reachedBoundary, "the whole file was read — a proven boundary")
    }
}

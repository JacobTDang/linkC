import XCTest
@testable import LinkCKit

final class CodexUsageReaderTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("codex-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func write(_ name: String, _ lines: [String], modified: Date) throws {
        let url = dir.appendingPathComponent(name)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    private let record = """
    {"timestamp":"2026-09-12T21:09:02.650Z","type":"event_msg","ordinal":46,"payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":210936}},"rate_limits":{"limit_id":"codex","primary":{"used_percent":23.0,"window_minutes":300,"resets_at":1789200270},"secondary":{"used_percent":39.0,"window_minutes":10080,"resets_at":1789500060},"plan_type":"plus"}}}
    """

    func testItReadsTheNewestFileThatCarriesLimits() throws {
        try write("rollout-old.jsonl", ["{\"type\":\"other\"}"], modified: Date().addingTimeInterval(-7200))
        try write("rollout-new.jsonl", ["{\"type\":\"other\"}", record], modified: Date())

        let usage = CodexUsageReader(sessionsDirectory: dir).read()
        XCTAssertNil(usage.unavailableReason)
        XCTAssertEqual(usage.planType, "plus")
        XCTAssertEqual(usage.windows.count, 2)
        XCTAssertEqual(usage.windows[0].label, "5h")
        XCTAssertEqual(usage.windows[0].usedPercent, 23.0)
        XCTAssertEqual(usage.windows[0].resetsAt, Date(timeIntervalSince1970: 1789200270))
        XCTAssertEqual(usage.windows[1].label, "7d")
        XCTAssertEqual(usage.windows[1].usedPercent, 39.0)
    }

    func testItTakesTheLastRecordInAFile() throws {
        let later = record.replacingOccurrences(of: "\"used_percent\":23.0", with: "\"used_percent\":44.0")
        try write("rollout-a.jsonl", [record, later], modified: Date())
        XCTAssertEqual(CodexUsageReader(sessionsDirectory: dir).read().windows[0].usedPercent, 44.0)
    }

    func testEachFailureModeNamesItself() throws {
        let missing = CodexUsageReader(sessionsDirectory: dir.appendingPathComponent("nope")).read()
        XCTAssertNotNil(missing.unavailableReason)
        XCTAssertTrue(missing.windows.isEmpty)

        let empty = CodexUsageReader(sessionsDirectory: dir).read()
        XCTAssertNotNil(empty.unavailableReason, "a directory with no rollout files says so")

        try write("rollout-a.jsonl", ["{\"type\":\"other\"}"], modified: Date())
        let noLimits = CodexUsageReader(sessionsDirectory: dir).read()
        XCTAssertNotNil(noLimits.unavailableReason,
                        "files with no rate-limit record say so")

        // Each situation gets its own sentence — not just "something went wrong" three times.
        XCTAssertNotEqual(missing.unavailableReason, empty.unavailableReason)
        XCTAssertNotEqual(empty.unavailableReason, noLimits.unavailableReason)
        XCTAssertNotEqual(missing.unavailableReason, noLimits.unavailableReason)
        XCTAssertEqual(missing.unavailableReason, "no ~/.codex/sessions directory")
        XCTAssertEqual(empty.unavailableReason, "no session records found")
        XCTAssertEqual(noLimits.unavailableReason, "no rate-limit record in the 5 newest sessions")
    }

    func testARecordNearTheTailBoundaryIsStillFound() throws {
        let filler = String(repeating: "{\"type\":\"filler\"}\n", count: 4000)
        try write("rollout-big.jsonl", [filler, record], modified: Date())
        XCTAssertEqual(CodexUsageReader(sessionsDirectory: dir).read().windows.first?.usedPercent, 23.0)
    }

    /// The 64 KB tail read seeks to a raw byte offset that has no idea where character
    /// boundaries fall. Padding the file with two-byte "é" characters up to a byte offset
    /// that is provably odd forces the cut to land on a UTF-8 continuation byte — the tail
    /// buffer can only decode once that byte is skipped, not before.
    func testATailCutInsideAMultiByteCharacterStillFindsTheRecord() throws {
        let tailCap = 64 * 1024
        var filler = String(repeating: "é", count: tailCap)
        let recordLine = record + "\n"

        func cutOffset(for filler: String) -> Int {
            let totalSize = (filler + "\n").utf8.count + recordLine.utf8.count
            return totalSize - tailCap
        }

        // Each "é" is exactly two UTF-8 bytes (0xC3 0xA9); the run starts at byte 0, so an
        // odd cut offset always lands on the second byte of some "é" — a continuation byte,
        // never a valid decode start. Nudge the filler by one ASCII byte if parity is wrong.
        if cutOffset(for: filler) % 2 == 0 {
            filler += "x"
        }
        let start = cutOffset(for: filler)
        XCTAssertEqual(start % 2, 1, "the cut offset must split a two-byte character")
        XCTAssertLessThan(start, filler.utf8.count, "the cut must land inside the filler run, not the record")

        let fullText = filler + "\n" + recordLine
        let fullBytes = Array(fullText.utf8)
        XCTAssertEqual((0x80...0xBF).contains(fullBytes[start]), true,
                       "the byte at the cut offset is a UTF-8 continuation byte, not a character start")

        let url = dir.appendingPathComponent("rollout-split.jsonl")
        try Data(fullBytes).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)

        let usage = CodexUsageReader(sessionsDirectory: dir).read()
        XCTAssertNil(usage.unavailableReason, "a mid-character cut must not be mistaken for a missing record")
        XCTAssertEqual(usage.windows.first?.usedPercent, 23.0)
    }

    private let nullWindowRecord = """
    {"timestamp":"2026-09-12T21:09:05.000Z","type":"event_msg","ordinal":48,"payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":210940}},"rate_limits":{"limit_id":"codex","primary":null,"secondary":null,"plan_type":"plus"}}}
    """

    func testANullWindowRecordDoesNotHideTheLastRealReading() throws {
        let populated = record
            .replacingOccurrences(of: "\"used_percent\":23.0", with: "\"used_percent\":22.0")
            .replacingOccurrences(of: "\"used_percent\":39.0", with: "\"used_percent\":100.0")
        try write("rollout-a.jsonl", [populated, nullWindowRecord, nullWindowRecord], modified: Date())

        let usage = CodexUsageReader(sessionsDirectory: dir).read()
        XCTAssertNil(usage.unavailableReason)
        XCTAssertEqual(usage.windows.count, 2)
        XCTAssertEqual(usage.windows[0].label, "5h")
        XCTAssertEqual(usage.windows[0].usedPercent, 22.0)
        XCTAssertEqual(usage.windows[1].label, "7d")
        XCTAssertEqual(usage.windows[1].usedPercent, 100.0)
    }

    func testAFileWithOnlyNullWindowRecordsFallsThroughToTheNextFile() throws {
        try write("rollout-new.jsonl", [nullWindowRecord, nullWindowRecord], modified: Date())
        try write("rollout-old.jsonl", [record], modified: Date().addingTimeInterval(-7200))

        let usage = CodexUsageReader(sessionsDirectory: dir).read()
        XCTAssertNil(usage.unavailableReason)
        XCTAssertEqual(usage.windows.first?.usedPercent, 23.0)
    }
}

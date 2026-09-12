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
}

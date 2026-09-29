import XCTest
@testable import LinkCKit

/// What the status-line command's file gives back: one complete report, or a named reason it
/// gives none — never a half-written report taken for a real one.
final class StatusLineFileTests: XCTestCase {
    private let arrived = Date(timeIntervalSince1970: 1_789_970_000)
    private let report = #"{"session_id":"c1","rate_limits":{"five_hour":{"used_percentage":66,"resets_at":1789980000},"seven_day":{"used_percentage":92,"resets_at":1790017200}}}"#
    private var file: URL!

    override func setUpWithError() throws {
        file = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-status-file-\(UUID().uuidString).line")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: file)
    }

    private func write(_ text: String) throws {
        try Data(text.utf8).write(to: file)
    }

    func testACompleteLineIsAReportWithItsReading() throws {
        try write(report + "\n")

        guard case .report(let body, let reading) = StatusLineFile.read(at: file, receivedAt: arrived) else {
            return XCTFail("a complete line must read as a report")
        }
        XCTAssertEqual(body, Data(report.utf8), "the line end is not part of the body")
        XCTAssertEqual(reading?.windows.map(\.usedPercent), [66, 92])
        XCTAssertEqual(reading?.observedAt, arrived)
    }

    func testAReportWithNoWindowsIsStillAReportButHasNoReading() throws {
        try write(#"{"session_id":"c1"}"# + "\n")

        guard case .report(_, let reading) = StatusLineFile.read(at: file, receivedAt: arrived) else {
            return XCTFail("a report with no rate limits is normal, not an error")
        }
        XCTAssertNil(reading)
    }

    /// Two runs of the command can overlap: the later, shorter report ends where the earlier,
    /// longer one still has bytes, so its tail follows the shorter report's line end. Only the first
    /// line counts.
    func testBytesAfterTheFirstLineEndAreTheTailOfAnOverlappingWriteAndAreIgnored() throws {
        try write(report + "\n" + #"ds":{"used_percentage":12}}}"# + "\n")

        guard case .report(let body, _) = StatusLineFile.read(at: file, receivedAt: arrived) else {
            return XCTFail("the first line is a complete report")
        }
        XCTAssertEqual(body, Data(report.utf8))
    }

    /// A read that lands in the middle of the command's write sees a prefix: bytes with no line end.
    func testAHalfWrittenLineIsTornNotAReport() throws {
        try write(String(report.prefix(40)))

        XCTAssertEqual(StatusLineFile.read(at: file, receivedAt: arrived), .torn)
    }

    /// A read between the command opening the file (which empties it) and writing into it.
    func testAnEmptyFileIsEmpty() throws {
        try write("")

        XCTAssertEqual(StatusLineFile.read(at: file, receivedAt: arrived), .empty)
    }

    func testAMissingFileIsUnreadableAndNamesThePath() {
        guard case .unreadable(let message) = StatusLineFile.read(at: file, receivedAt: arrived) else {
            return XCTFail("a missing file must not read as empty")
        }
        XCTAssertTrue(message.contains(file.path), message)
    }

    func testACompleteLineThatIsNotJSONIsGarbage() throws {
        try write("this is not json\n")

        guard case .garbage(let message) = StatusLineFile.read(at: file, receivedAt: arrived) else {
            return XCTFail("a complete line that is not JSON must be named as garbage, not as torn")
        }
        XCTAssertFalse(message.isEmpty)
    }

    /// The feed logs a failure once and stays quiet while the same one repeats, by comparing
    /// messages. A message that reads differently each time — an error printed with its userInfo
    /// dictionary, whose order is not fixed — makes one bad file look like a new failure on every
    /// refresh.
    func testTheSameGarbageAlwaysGivesTheSameMessage() throws {
        try write("this is not json\n")

        let messages = Set((0..<200).map { _ -> String in
            guard case .garbage(let message) = StatusLineFile.read(at: file, receivedAt: arrived) else {
                return "not garbage"
            }
            return message
        })

        XCTAssertEqual(messages.count, 1, "\(messages)")
    }

    func testTheSameUnreadableFileAlwaysGivesTheSameMessage() {
        let messages = Set((0..<200).map { _ -> String in
            guard case .unreadable(let message) = StatusLineFile.read(at: file, receivedAt: arrived) else {
                return "not unreadable"
            }
            return message
        })

        XCTAssertEqual(messages.count, 1, "\(messages)")
    }
}

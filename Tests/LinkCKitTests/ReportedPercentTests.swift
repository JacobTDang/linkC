import XCTest
@testable import LinkCKit

final class ReportedPercentTests: XCTestCase {
    /// Not a number, not finite, or outside 0–100: refused, with the figure in the message.
    func testAFigureNoWindowCanHaveIsRefused() {
        for value in [Double.nan, .infinity, -.infinity, 1e30, -5, 250, 100.5, -0.5] {
            XCTAssertThrowsError(try ReportedPercent.whole(value), "\(value)") { error in
                XCTAssertEqual(error as? LinkCError, .parse("\(value) is not a percentage from 0 to 100"))
            }
        }
    }

    func testAFigureInRangeIsRoundedToAWholePercent() throws {
        XCTAssertEqual(try ReportedPercent.whole(0), 0)
        XCTAssertEqual(try ReportedPercent.whole(-0.0), 0)
        XCTAssertEqual(try ReportedPercent.whole(41.4), 41)
        XCTAssertEqual(try ReportedPercent.whole(41.5), 42)
        XCTAssertEqual(try ReportedPercent.whole(100), 100)
    }

    /// A provider's own rounding can put a full window a hair past 100, or an empty one a hair below
    /// 0. That is still a reading, and it must not cost the whole status report it came in.
    func testAFigureWithinRoundingOfTheRangeIsHeldToIt() throws {
        XCTAssertEqual(try ReportedPercent.whole(100.4), 100)
        XCTAssertEqual(try ReportedPercent.whole(-0.4), 0)
    }

    /// A status report whose limit reads a hair past full is still read, model and all.
    func testAStatusReportWithALimitAHairPastFullIsStillRead() throws {
        let body = Data(#"{"model":{"id":"claude-opus-5-5"},"rate_limits":{"five_hour":{"used_percentage":100.4,"resets_at":1795560237}}}"#.utf8)
        let reading = try XCTUnwrap(try ClaudeRateLimits.decode(body, receivedAt: Date(timeIntervalSince1970: 1_795_550_000)))
        XCTAssertEqual(reading.windows.first?.usedPercent, 100.4)
    }
}

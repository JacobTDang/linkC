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
}

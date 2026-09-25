import XCTest
@testable import LinkCKit

final class CommandLineSplitTests: XCTestCase {
    func testWordsSplitOnSpacesAndTabs() throws {
        XCTAssertEqual(try CommandLineSplit.split("uv run python run_ui.py --port {port}"),
                       ["uv", "run", "python", "run_ui.py", "--port", "{port}"])
        XCTAssertEqual(try CommandLineSplit.split("  a \t b  "), ["a", "b"])
        XCTAssertEqual(try CommandLineSplit.split(""), [])
    }

    func testQuotesAndBackslashesGroup() throws {
        XCTAssertEqual(try CommandLineSplit.split(#"python3 -m "http server""#), ["python3", "-m", "http server"])
        XCTAssertEqual(try CommandLineSplit.split("a 'b c' d"), ["a", "b c", "d"])
        XCTAssertEqual(try CommandLineSplit.split(#"a\ b"#), ["a b"])
        XCTAssertEqual(try CommandLineSplit.split(#""a\"b""#), [#"a"b"#])
        XCTAssertEqual(try CommandLineSplit.split(#"'' x"#), ["", "x"])
    }

    func testAnUnclosedQuoteOrATrailingBackslashIsAnError() {
        XCTAssertThrowsError(try CommandLineSplit.split("a 'b"))
        XCTAssertThrowsError(try CommandLineSplit.split(#"a "b"#))
        XCTAssertThrowsError(try CommandLineSplit.split(#"a \"#))
    }

    func testJoinRoundTrips() throws {
        let argv = ["uv", "run", "a b", "it's", "", "--port", "{port}"]
        XCTAssertEqual(try CommandLineSplit.split(CommandLineSplit.join(argv)), argv)
        XCTAssertEqual(CommandLineSplit.join(["uv", "run", "--port", "{port}"]), "uv run --port {port}")
    }
}

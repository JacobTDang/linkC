import AppKit
import XCTest
@testable import LinkCKit

final class AgentLogoTests: XCTestCase {
    /// Every agent but a plain shell has a logo, and each one loads as a real SVG image at the
    /// icons' 24-point grid — a broken embed fails here, not as a blank square in the panel.
    func testEveryAgentButShellHasALogoThatLoads() throws {
        for kind in AgentKind.allCases {
            guard kind != .shell else {
                XCTAssertNil(kind.logo, "a plain shell keeps its terminal symbol")
                continue
            }
            let logo = try XCTUnwrap(kind.logo, "\(kind) has no logo")
            let image = try XCTUnwrap(NSImage(data: Data(logo.svg.utf8)), "\(kind)'s logo does not load")
            XCTAssertTrue(image.isValid, "\(kind)")
            XCTAssertTrue(image.representations.contains { String(describing: type(of: $0)).contains("SVG") },
                          "\(kind)'s logo must load as SVG, not a bitmap")
            XCTAssertEqual(image.size, NSSize(width: 24, height: 24), "\(kind)'s logo keeps the 24-point grid")
        }
    }

    /// Only Cursor's mark is one colour (the file draws in `currentColor`); the rest are drawn as
    /// they are.
    func testOnlyCursorIsTintedByTheApp() {
        XCTAssertEqual(AgentKind.allCases.filter { $0.logo?.isTemplate == true }, [.cursor])
    }
}

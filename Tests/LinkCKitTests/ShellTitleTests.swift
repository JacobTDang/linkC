import XCTest
@testable import LinkCKit

final class ShellTitleTests: XCTestCase {
    func testHomeShowsAsTilde() {
        XCTAssertEqual(ShellTitle.name(forDirectory: "/Users/j", home: "/Users/j"), "~")
        XCTAssertEqual(ShellTitle.name(forDirectory: "/Users/j/", home: "/Users/j"), "~")
    }

    func testRootShowsAsSlash() {
        XCTAssertEqual(ShellTitle.name(forDirectory: "/", home: "/Users/j"), "/")
    }

    func testAFolderShowsItsLastComponent() {
        XCTAssertEqual(ShellTitle.name(forDirectory: "/Users/j/Projects/linkC", home: "/Users/j"), "linkC")
        XCTAssertEqual(ShellTitle.name(forDirectory: "/Users/j/Projects/linkC/", home: "/Users/j"), "linkC")
    }
}

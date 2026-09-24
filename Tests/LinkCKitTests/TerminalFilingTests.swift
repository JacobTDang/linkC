import XCTest
@testable import LinkCKit

final class TerminalFilingTests: XCTestCase {
    func testFiledThenMatchingFolderThenNone() {
        let projects: Set<String> = ["/p/june", "/p/linkc"]
        XCTAssertEqual(TerminalFiling.project(forTerminal: "t1", cwd: "/Users/j/school", filed: ["t1": "/p/june"], projects: projects), "/p/june")
        XCTAssertEqual(TerminalFiling.project(forTerminal: "t2", cwd: "/p/linkc/", filed: [:], projects: projects), "/p/linkc")
        XCTAssertNil(TerminalFiling.project(forTerminal: "t3", cwd: "/Users/j/school", filed: [:], projects: projects))
        XCTAssertEqual(TerminalFiling.project(forTerminal: "t4", cwd: "/p/linkc", filed: ["t4": "/p/june"], projects: projects), "/p/june", "a filing beats the folder")
    }

    func testAFilingComesBackStandardized() {
        XCTAssertEqual(TerminalFiling.project(forTerminal: "t1", cwd: "/Users/j/school", filed: ["t1": "/p/june/./"], projects: []), "/p/june")
    }

    func testATerminalInASubfolderIsNotInItsParentProject() {
        XCTAssertNil(TerminalFiling.project(forTerminal: "t1", cwd: "/p/linkc/Sources", filed: [:], projects: ["/p/linkc"]))
        XCTAssertEqual(
            TerminalFiling.project(forTerminal: "t1", cwd: "/p/linkc/Sources", filed: [:], projects: ["/p/linkc", "/p/linkc/Sources"]),
            "/p/linkc/Sources")
    }

    func testASimilarlyNamedFolderIsNotTheProject() {
        XCTAssertNil(TerminalFiling.project(forTerminal: "t1", cwd: "/p/linkc2", filed: [:], projects: ["/p/linkc"]))
    }

    func testAFilingBeatsAnyFolder() {
        XCTAssertEqual(
            TerminalFiling.project(forTerminal: "t1", cwd: "/p/linkc/Sources", filed: ["t1": "/p/june"], projects: ["/p/linkc"]),
            "/p/june")
    }
}

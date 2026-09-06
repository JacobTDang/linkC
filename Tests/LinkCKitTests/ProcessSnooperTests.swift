import XCTest
@testable import LinkCKit

final class ProcessSnooperTests: XCTestCase {
    func testDetectAgentInPath() {
        XCTAssertEqual(ProcessSnooper.detectAgent(inPath: "/opt/homebrew/bin/claude"), .claude)
        XCTAssertEqual(ProcessSnooper.detectAgent(inPath: "/usr/local/bin/claude"), .claude)
        XCTAssertEqual(ProcessSnooper.detectAgent(inPath: "claude"), .claude)

        XCTAssertEqual(ProcessSnooper.detectAgent(inPath: "/Users/user/.local/bin/agy"), .agy)
        XCTAssertEqual(ProcessSnooper.detectAgent(inPath: "/opt/homebrew/bin/agy"), .agy)
        XCTAssertEqual(ProcessSnooper.detectAgent(inPath: "agy"), .agy)

        XCTAssertEqual(ProcessSnooper.detectAgent(inPath: "/Applications/Cursor.app/Contents/Resources/app/bin/cursor"), .cursor)
        XCTAssertEqual(ProcessSnooper.detectAgent(inPath: "/usr/local/bin/cursor"), .cursor)
        XCTAssertEqual(ProcessSnooper.detectAgent(inPath: "cursor"), .cursor)

        XCTAssertEqual(ProcessSnooper.detectAgent(inPath: "/opt/homebrew/bin/codex"), .codex)
        XCTAssertEqual(ProcessSnooper.detectAgent(inPath: "codex"), .codex)

        XCTAssertNil(ProcessSnooper.detectAgent(inPath: "/bin/zsh"))
        XCTAssertNil(ProcessSnooper.detectAgent(inPath: "/usr/bin/git"))
        XCTAssertNil(ProcessSnooper.detectAgent(inPath: "/usr/bin/vim"))
        XCTAssertNil(ProcessSnooper.detectAgent(inPath: ""))
    }

    func testProcessTreeInspectionReturnsNilForEmptyChildren() {
        // PID 0 (kernel task) or invalid negative PID has no child agent
        XCTAssertNil(ProcessSnooper.detectAgent(inProcessTreeOf: -1))
    }
}

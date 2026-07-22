import XCTest
@testable import LinkCKit

/// Parses `claude mcp list` stdout — the live-health source. Fixture is the exact real output
/// captured on this machine (names can contain spaces and colons appear in URLs, so the
/// parser splits on the LAST " - " and the FIRST ": ").
final class MCPHealthCheckTests: XCTestCase {

    private let realOutput = """
    Checking MCP server health...

    claude.ai Google Drive: https://drivemcp.googleapis.com/mcp/v1 - ! Needs authentication
    claude.ai Gmail: https://gmailmcp.googleapis.com/mcp/v1 - ! Needs authentication
    github: https://api.githubcopilot.com/mcp/ (HTTP) - ✔ Connected
    code-review-graph: uvx code-review-graph serve - ✔ Connected
    vercel: https://mcp.vercel.com (HTTP) - ! Needs authentication
    firecrawl: npx -y firecrawl-mcp@3.22.4 - ✔ Connected

    """

    func testParsesRealOutput() {
        let statuses = MCPHealthCheck.parse(realOutput)
        XCTAssertEqual(statuses.count, 6, "banner and blank lines must be dropped")

        XCTAssertEqual(statuses[0].name, "claude.ai Google Drive")
        XCTAssertEqual(statuses[0].target, "https://drivemcp.googleapis.com/mcp/v1")
        XCTAssertEqual(statuses[0].state, .needsAuth)
        XCTAssertFalse(statuses[0].isHTTP, "no (HTTP) marker on this line")

        let github = statuses[2]
        XCTAssertEqual(github.name, "github")
        XCTAssertEqual(github.target, "https://api.githubcopilot.com/mcp/")
        XCTAssertTrue(github.isHTTP)
        XCTAssertEqual(github.state, .connected)

        let graph = statuses[3]
        XCTAssertEqual(graph.target, "uvx code-review-graph serve")
        XCTAssertFalse(graph.isHTTP)
    }

    func testUnknownStatusTextIsPreservedNotGuessed() {
        let statuses = MCPHealthCheck.parse("srv: cmd - ✗ Failed to connect\nother: cmd2 - ◐ Half-open\n")
        XCTAssertEqual(statuses[0].state, .failed("Failed to connect"))
        XCTAssertEqual(statuses[1].state, .unknown("◐ Half-open"))
    }

    func testEmptyAndGarbageInputIsEmpty() {
        XCTAssertTrue(MCPHealthCheck.parse("").isEmpty)
        XCTAssertTrue(MCPHealthCheck.parse("no separators here").isEmpty)
    }
}

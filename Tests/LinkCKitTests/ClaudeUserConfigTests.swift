import XCTest
@testable import LinkCKit

/// The one `~/.claude.json` decoder. The critical contract: secret VALUES (headers, env) are
/// discarded at parse time — only key names survive — so no downstream code can leak them.
final class ClaudeUserConfigTests: XCTestCase {

    private func loadFixture() throws -> Data {
        let bundle = Bundle.module
        if let url = bundle.url(forResource: "claude-user-config-sample", withExtension: "json") {
            return try Data(contentsOf: url)
        }
        if let url = bundle.url(forResource: "claude-user-config-sample", withExtension: "json", subdirectory: "Fixtures") {
            return try Data(contentsOf: url)
        }
        throw LinkCError.parse("fixture missing")
    }

    func testParsesGlobalServersWithStructuralRedaction() throws {
        let config = try ClaudeUserConfig.parse(loadFixture())

        XCTAssertEqual(config.mcpServers.count, 2)
        let github = try XCTUnwrap(config.mcpServers.first { $0.name == "github" })
        XCTAssertEqual(github.scope, .global)
        XCTAssertEqual(github.transport, .http(url: "https://api.githubcopilot.com/mcp/", headerKeys: ["Authorization"]))

        let firecrawl = try XCTUnwrap(config.mcpServers.first { $0.name == "firecrawl" })
        XCTAssertEqual(
            firecrawl.transport,
            .stdio(command: "npx", args: ["-y", "firecrawl-mcp@3.22.4"],
                   envKeys: ["FIRECRAWL_API_KEY", "FIRECRAWL_API_URL"])
        )

        // The load-bearing assertion: no secret value survives anywhere in the parsed model.
        let dump = String(describing: config)
        XCTAssertFalse(dump.contains("SECRET"), "a header/env value leaked into the model")
    }

    func testParsesProjectServersWithDisabledFlag() throws {
        let config = try ClaudeUserConfig.parse(loadFixture())

        XCTAssertEqual(config.projectMCPServers.count, 1)
        let playwright = try XCTUnwrap(config.projectMCPServers.first)
        XCTAssertEqual(playwright.name, "playwright")
        XCTAssertEqual(playwright.scope, .project(path: "/Users/x/proj"))
        XCTAssertTrue(playwright.isDisabledForProject)
    }

    func testParsesUsageStatsWithMillisecondEpochs() throws {
        let config = try ClaudeUserConfig.parse(loadFixture())

        let research = try XCTUnwrap(config.skillUsage["deep-research"])
        XCTAssertEqual(research.usageCount, 7)
        XCTAssertEqual(research.lastUsedAt?.timeIntervalSince1970 ?? 0, 1_784_696_643, accuracy: 1)
        XCTAssertEqual(config.pluginUsage["superpowers@superpowers-marketplace"]?.usageCount, 12)
    }

    func testMissingSectionsAndUnknownKeysAreTolerated() throws {
        let minimal = #"{"numStartups": 1}"#.data(using: .utf8)!
        let config = try ClaudeUserConfig.parse(minimal)
        XCTAssertTrue(config.mcpServers.isEmpty)
        XCTAssertTrue(config.projectMCPServers.isEmpty)
        XCTAssertTrue(config.skillUsage.isEmpty)
    }

    func testMalformedJSONThrows() {
        XCTAssertThrowsError(try ClaudeUserConfig.parse("not json".data(using: .utf8)!))
    }
}

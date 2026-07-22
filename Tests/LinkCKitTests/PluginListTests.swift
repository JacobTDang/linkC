import XCTest
@testable import LinkCKit

/// Parses `claude plugin list --json` — the authoritative installed/enabled/scope source.
final class PluginListTests: XCTestCase {

    private func loadFixture() throws -> Data {
        let bundle = Bundle.module
        if let url = bundle.url(forResource: "plugin-list-sample", withExtension: "json") {
            return try Data(contentsOf: url)
        }
        if let url = bundle.url(forResource: "plugin-list-sample", withExtension: "json", subdirectory: "Fixtures") {
            return try Data(contentsOf: url)
        }
        throw LinkCError.parse("fixture missing")
    }

    func testParsesRealShape() throws {
        let plugins = try PluginList.parse(loadFixture())
        XCTAssertEqual(plugins.count, 4)

        let superpowers = try XCTUnwrap(plugins.first { $0.id == "superpowers@superpowers-marketplace" })
        XCTAssertEqual(superpowers.version, "6.1.1")
        XCTAssertEqual(superpowers.scope, "user")
        XCTAssertTrue(superpowers.enabled)
        XCTAssertNil(superpowers.projectPath)

        // The real dual-scope case: same plugin at user + project scope.
        let frontends = plugins.filter { $0.id == "frontend-design@claude-plugins-official" }
        XCTAssertEqual(frontends.count, 2)
        XCTAssertEqual(frontends.compactMap(\.projectPath), ["/Users/x/Desktop/projects/Sprout"])

        let clangd = try XCTUnwrap(plugins.first { $0.id.hasPrefix("clangd") })
        XCTAssertFalse(clangd.enabled)
    }

    func testMalformedThrows() {
        XCTAssertThrowsError(try PluginList.parse("{}".data(using: .utf8)!))
    }
}

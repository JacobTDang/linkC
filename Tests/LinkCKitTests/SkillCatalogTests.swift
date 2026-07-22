import XCTest
@testable import LinkCKit

/// Pure merge/sort of user + plugin skills with usage stats: usage-count descending, then
/// name; dedupe by path (dual-scope installs of the same plugin collapse).
final class SkillCatalogTests: XCTestCase {

    private func plugin(_ id: String, scope: String = "user", path: String) -> InstalledPlugin {
        InstalledPlugin(id: id, version: "1.0.0", scope: scope, enabled: true,
                        installPath: path, projectPath: nil)
    }

    func testMergeSortsByUsageThenName() {
        let merged = SkillCatalog.merge(
            userSkills: [
                (path: "/skills/zeta", frontmatter: SkillFrontmatter(name: "zeta", description: "z")),
                (path: "/skills/alpha", frontmatter: SkillFrontmatter(name: "alpha", description: "a")),
            ],
            pluginSkills: [
                (plugin: plugin("power@mkt", path: "/cache/power"),
                 path: "/cache/power/skills/beta", frontmatter: SkillFrontmatter(name: "beta", description: "b")),
            ],
            usage: [
                "zeta": .init(usageCount: 5, lastUsedAt: nil),
                "power:beta": .init(usageCount: 9, lastUsedAt: Date(timeIntervalSince1970: 1_784_000_000)),
            ]
        )
        XCTAssertEqual(merged.map(\.name), ["beta", "zeta", "alpha"])
        XCTAssertEqual(merged[0].usageCount, 9)
        XCTAssertNotNil(merged[0].lastUsedAt)
        XCTAssertEqual(merged[2].usageCount, 0)
    }

    func testDualScopeSamePathCollapses() {
        let userScope = plugin("dual@mkt", scope: "user", path: "/cache/dual")
        let projScope = plugin("dual@mkt", scope: "project", path: "/cache/dual")
        let fm = SkillFrontmatter(name: "s", description: "d")
        let merged = SkillCatalog.merge(
            userSkills: [],
            pluginSkills: [
                (plugin: userScope, path: "/cache/dual/skills/s", frontmatter: fm),
                (plugin: projScope, path: "/cache/dual/skills/s", frontmatter: fm),
            ],
            usage: [:]
        )
        XCTAssertEqual(merged.count, 1, "same skill path must not render twice")
    }

    func testSourceBadgesAndUsageKeying() throws {
        let merged = SkillCatalog.merge(
            userSkills: [(path: "/skills/mine", frontmatter: SkillFrontmatter(name: "mine", description: "m"))],
            pluginSkills: [
                (plugin: plugin("kit@mkt", path: "/cache/kit"),
                 path: "/cache/kit/skills/tool", frontmatter: SkillFrontmatter(name: "tool", description: "t")),
            ],
            usage: ["mine": .init(usageCount: 2, lastUsedAt: nil)]
        )
        let mine = try XCTUnwrap(merged.first { $0.name == "mine" })
        XCTAssertEqual(mine.source, .user)
        XCTAssertEqual(mine.usageCount, 2)
        let tool = try XCTUnwrap(merged.first { $0.name == "tool" })
        if case .plugin(let p) = tool.source { XCTAssertEqual(p.id, "kit@mkt") }
        else { XCTFail("expected plugin source") }
    }
}

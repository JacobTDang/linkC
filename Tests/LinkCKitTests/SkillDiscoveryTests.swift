import XCTest
@testable import LinkCKit

/// Filesystem skill enumeration: SKILL.md presence is the filter — real skill dirs sit next
/// to non-skill workspaces on this machine, and only the former may appear in the UI.
final class SkillDiscoveryTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-skills-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default

        // User skills: one real, one workspace dir with no SKILL.md, one file (not a dir).
        let skills = root.appendingPathComponent("skills")
        try fm.createDirectory(at: skills.appendingPathComponent("alpha"), withIntermediateDirectories: true)
        try "---\nname: alpha\ndescription: does alpha things\n---\n"
            .write(to: skills.appendingPathComponent("alpha/SKILL.md"), atomically: true, encoding: .utf8)
        try fm.createDirectory(at: skills.appendingPathComponent("workspace"), withIntermediateDirectories: true)
        try "notes".write(to: skills.appendingPathComponent("stray.txt"), atomically: true, encoding: .utf8)

        // Plugin layout: <installPath>/skills/<skill>/SKILL.md
        let plugin = root.appendingPathComponent("plugin-install")
        try fm.createDirectory(at: plugin.appendingPathComponent("skills/beta"), withIntermediateDirectories: true)
        try "---\nname: beta\ndescription: plugin skill\n---\n"
            .write(to: plugin.appendingPathComponent("skills/beta/SKILL.md"), atomically: true, encoding: .utf8)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func testUserSkillsFilterOnSkillMd() {
        let found = SkillDiscovery(userSkillsDir: root.appendingPathComponent("skills")).userSkills()
        XCTAssertEqual(found.map(\.frontmatter.name), ["alpha"])
        XCTAssertTrue(found[0].path.hasSuffix("/alpha"))
    }

    func testPluginSkillsWalkInstallPath() {
        let discovery = SkillDiscovery(userSkillsDir: root.appendingPathComponent("skills"))
        let found = discovery.pluginSkills(installPath: root.appendingPathComponent("plugin-install").path)
        XCTAssertEqual(found.map(\.frontmatter.name), ["beta"])
    }

    func testMissingDirectoriesAreEmptyNotFatal() {
        let discovery = SkillDiscovery(userSkillsDir: root.appendingPathComponent("nope"))
        XCTAssertTrue(discovery.userSkills().isEmpty)
        XCTAssertTrue(discovery.pluginSkills(installPath: "/no/such/place").isEmpty)
    }
}

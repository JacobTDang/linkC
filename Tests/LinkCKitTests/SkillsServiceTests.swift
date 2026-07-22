import XCTest
@testable import LinkCKit

/// The skills tracker over a fake runner + temp filesystem: refresh composition, the
/// enable/disable CLI contract, and loud errors.
@MainActor
final class SkillsServiceTests: XCTestCase {

    private var root: URL!
    private var configURL: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-skillsvc-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        let skills = root.appendingPathComponent("skills/local")
        try fm.createDirectory(at: skills, withIntermediateDirectories: true)
        try "---\nname: local\ndescription: user skill\n---\n"
            .write(to: skills.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let pluginSkills = root.appendingPathComponent("plug/skills/packaged")
        try fm.createDirectory(at: pluginSkills, withIntermediateDirectories: true)
        try "---\nname: packaged\ndescription: plugin skill\n---\n"
            .write(to: pluginSkills.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        configURL = root.appendingPathComponent("claude.json")
        try #"{"skillUsage": {"local": {"usageCount": 4, "lastUsedAt": 1784696643000}}}"#
            .data(using: .utf8)!.write(to: configURL)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func pluginJSON() -> String {
        """
        [{"id": "plug@mkt", "version": "1.0.0", "scope": "user", "enabled": true,
          "installPath": "\(root.appendingPathComponent("plug").path)"}]
        """
    }

    private func makeService(runner: FakeRunner) -> SkillsService {
        SkillsService(
            claudePath: "/fake/claude",
            configURL: configURL,
            discovery: SkillDiscovery(userSkillsDir: root.appendingPathComponent("skills")),
            runner: runner
        )
    }

    func testRefreshComposesCatalog() async {
        let runner = FakeRunner(result: .success(pluginJSON()))
        let service = makeService(runner: runner)

        await service.refresh()

        XCTAssertNil(service.lastError)
        XCTAssertEqual(service.skills.map(\.name), ["local", "packaged"], "usage sorts local first")
        XCTAssertEqual(service.skills[0].usageCount, 4)
        XCTAssertEqual(runner.calls.first?.args, ["plugin", "list", "--json"])
    }

    func testSetPluginEnabledShellsCLIThenRefreshes() async throws {
        let runner = FakeRunner(result: .success(pluginJSON()))
        let service = makeService(runner: runner)
        await service.refresh()
        let plugin = InstalledPlugin(id: "plug@mkt", version: "1.0.0", scope: "user",
                                     enabled: true, installPath: root.appendingPathComponent("plug").path,
                                     projectPath: nil)

        try await service.setPluginEnabled(plugin, enabled: false)

        let args = runner.calls.map(\.args)
        XCTAssertTrue(args.contains(["plugin", "disable", "plug@mkt", "--scope", "user"]))
        XCTAssertEqual(args.last, ["plugin", "list", "--json"], "must re-read authoritative state")
        XCTAssertNil(service.togglingPluginId)
    }

    func testRunnerFailureSurfacesLoud() async {
        let runner = FakeRunner(result: .failure(LinkCError.process("claude plugin list timed out after 15s")))
        let service = makeService(runner: runner)

        await service.refresh()

        XCTAssertNotNil(service.lastError)
        XCTAssertTrue(service.lastError!.contains("timed out"))
    }
}

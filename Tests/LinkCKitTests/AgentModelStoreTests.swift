import XCTest
@testable import LinkCKit

final class AgentModelStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-models-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testMissingFileLoadsTheSeededMapping() {
        XCTAssertEqual(AgentModelStore(directory: dir).load(), AgentModelSettings.seeded)
    }

    func testSavedEditsAreReadBack() throws {
        let store = AgentModelStore(directory: dir)
        var settings = AgentModelSettings.seeded
        settings.setModel("gpt-7-nova", for: .codex, tier: .deep)
        store.save(settings)
        XCTAssertEqual(AgentModelStore(directory: dir).load().model(for: .codex, tier: .deep), "gpt-7-nova")
    }

    func testAnUnreadableFileLoadsTheSeededMappingAndKeepsTheBadFile() throws {
        let store = AgentModelStore(directory: dir)
        try "{ not json".write(toFile: store.path, atomically: true, encoding: .utf8)
        XCTAssertEqual(store.load(), AgentModelSettings.seeded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.path), "A corrupt file is never deleted under the user")
    }

    func testACorruptFileIsNotOverwrittenBySave() throws {
        let store = AgentModelStore(directory: dir)
        let corrupt = Data("{ not json".utf8)
        try corrupt.write(to: URL(fileURLWithPath: store.path))
        _ = store.load()

        var edited = AgentModelSettings.seeded
        edited.setModel("gpt-7-nova", for: .codex, tier: .deep)
        store.save(edited)

        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: store.path)), corrupt,
                       "a file we could not read is never replaced under the user")
    }

    func testASavedFileKeepsAnUnknownTopLevelKeyFromANewerBuild() throws {
        let store = AgentModelStore(directory: dir)
        let newerBuildJSON = """
        {"models":{"codex":{"light":"gpt-5.6-luna","standard":"gpt-5.6-sol","deep":"gpt-6-astra"}},
         "defaultTiers":{"codex":"standard"},
         "futureField":"futureValue"}
        """
        try newerBuildJSON.write(toFile: store.path, atomically: true, encoding: .utf8)

        var settings = store.load()
        settings.setModel("gpt-7-nova", for: .codex, tier: .deep)
        guard case .success = store.save(settings) else {
            return XCTFail("expected the save to succeed")
        }

        let raw = try JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: store.path))) as? [String: Any]
        XCTAssertEqual(raw?["futureField"] as? String, "futureValue",
                       "an unknown key from a newer build survives a save")
        XCTAssertEqual(AgentModelStore(directory: dir).load().model(for: .codex, tier: .deep), "gpt-7-nova")
    }

    func testAFileMissingAnOptionalFieldLoadsWithItsDefault() throws {
        let store = AgentModelStore(directory: dir)
        // "deep" is deliberately NOT the seeded value, so a wholesale fallback to `.seeded`
        // (the bug this guards against) is distinguishable from correctly keeping "models" and
        // only defaulting the missing "defaultTiers".
        let json = """
        {"models":{"codex":{"light":"gpt-5.6-luna","standard":"gpt-5.6-sol","deep":"gpt-9-testonly"}}}
        """
        try json.write(toFile: store.path, atomically: true, encoding: .utf8)

        let settings = store.load()
        XCTAssertEqual(settings.model(for: .codex, tier: .deep), "gpt-9-testonly",
                       "the field that IS present still loads, rather than falling back to seeded entirely")
        XCTAssertEqual(settings.defaultTier(for: .codex), .standard,
                       "the missing \"defaultTiers\" field takes its default")
    }

    func testAnUnreadableFileRefusesTheSaveWithTheExactMessage() throws {
        let store = AgentModelStore(directory: dir)
        try "{ not json".write(toFile: store.path, atomically: true, encoding: .utf8)

        guard case .failure(let refusal) = store.save(AgentModelSettings.seeded) else {
            return XCTFail("expected the save to be refused")
        }
        XCTAssertTrue(refusal.description.hasPrefix("models.json can't be read: "), refusal.description)
        XCTAssertTrue(refusal.description.hasSuffix(". Fix or move the file."), refusal.description)
    }

    func testAFileWithNoReadPermissionIsNeitherMisreadNorOverwritten() throws {
        guard getuid() != 0 else {
            throw XCTSkip("root ignores POSIX read permissions, so this cannot be exercised as root")
        }
        let store = AgentModelStore(directory: dir)
        var original = AgentModelSettings.seeded
        original.setModel("gpt-hand-edited", for: .codex, tier: .deep)
        let originalBytes = try JSONEncoder().encode(original)
        try originalBytes.write(to: URL(fileURLWithPath: store.path))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: store.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.path) }

        XCTAssertEqual(store.load(), AgentModelSettings.seeded,
                       "a file that exists but cannot be read still yields a usable mapping")

        var edited = AgentModelSettings.seeded
        edited.setModel("gpt-7-nova", for: .codex, tier: .deep)
        store.save(edited)

        // Restore read permission ourselves before verifying — the deferred restore is only a
        // cleanup safety net and runs after this point.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.path)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: store.path)), originalBytes,
                       "a file we have no permission to read is never replaced under the user")
    }
}

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
}

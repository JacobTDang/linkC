import XCTest
@testable import LinkCKit

/// Locating a compose file in a picked folder (compose's documented lookup order) and
/// parsing the slice of `docker compose config --format json` linkC needs.
final class ComposeDiscoveryTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-compose-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func touch(_ name: String) throws {
        try Data("services: {}\n".utf8).write(to: dir.appendingPathComponent(name))
    }

    func testLocateFollowsComposePrecedence() throws {
        try touch("docker-compose.yml")
        try touch("compose.yaml")
        XCTAssertEqual(
            ComposeFile.locate(in: dir.path),
            dir.appendingPathComponent("compose.yaml").path,
            "compose.yaml wins over docker-compose.yml, matching compose's own order"
        )
    }

    func testLocateFindsLegacyName() throws {
        try touch("docker-compose.yml")
        XCTAssertEqual(ComposeFile.locate(in: dir.path), dir.appendingPathComponent("docker-compose.yml").path)
    }

    func testLocateReturnsNilWhenAbsent() {
        XCTAssertNil(ComposeFile.locate(in: dir.path))
    }

    func testLocateIgnoresADirectoryNamedLikeAComposeFile() throws {
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("compose.yaml"), withIntermediateDirectories: true)
        XCTAssertNil(ComposeFile.locate(in: dir.path))
    }

    func testParseExtractsNameAndSortedServices() throws {
        let json = Data("""
        {"name":"firecrawl","services":{"worker":{"image":"w"},"api":{"image":"a"}},"networks":{}}
        """.utf8)
        let config = try ComposeConfig.parse(json)
        XCTAssertEqual(config.name, "firecrawl")
        XCTAssertEqual(config.services, ["api", "worker"])
    }

    func testParseWithoutNameThrows() {
        let json = Data(#"{"services":{"api":{}}}"#.utf8)
        XCTAssertThrowsError(try ComposeConfig.parse(json))
    }

    func testParseGarbageThrows() {
        XCTAssertThrowsError(try ComposeConfig.parse(Data("not json".utf8)))
    }
}

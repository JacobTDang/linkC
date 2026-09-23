import XCTest
@testable import LinkCKit

final class SystemMapTests: XCTestCase {
    private let sample = Data("""
    {
      "version": 1,
      "components": [
        { "name": "postgres", "kind": "database", "reached_by": "DATABASE_URL",
          "runs": "docker compose (db)", "used_by": ["api", "worker"], "at": { "x": 0, "y": 0 } },
        { "name": "redis", "kind": "cache", "reached_by": "REDIS_URL", "intended": true },
        { "name": "mystery", "kind": "quantum-flux" }
      ]
    }
    """.utf8)

    func testAFullFileDecodes() throws {
        let map = try SystemMap.decode(sample)
        XCTAssertEqual(map.version, 1)
        XCTAssertEqual(map.components.map(\.name), ["postgres", "redis", "mystery"])

        let postgres = map.components[0]
        XCTAssertEqual(postgres.kind, .database)
        XCTAssertEqual(postgres.reachedBy, "DATABASE_URL")
        XCTAssertEqual(postgres.runs, "docker compose (db)")
        XCTAssertEqual(postgres.usedBy, ["api", "worker"])
        XCTAssertFalse(postgres.intended)
        XCTAssertEqual(postgres.at, GridPoint(x: 0, y: 0))

        XCTAssertTrue(map.components[1].intended)
        XCTAssertNil(map.components[1].at, "a component may carry no position")
    }

    func testAnUnknownKindIsKeptVerbatim() throws {
        let kind = try SystemMap.decode(sample).components[2].kind
        XCTAssertEqual(kind.raw, "quantum-flux")
        XCTAssertFalse(kind.isKnown)
        XCTAssertTrue(ComponentKind.database.isKnown)
        XCTAssertEqual(ComponentKind.known.map(\.raw),
                       ["database", "cache", "queue", "storage", "service", "host", "external"])
    }

    /// A field linkC does not know — a future one, or a note added by hand — must survive an
    /// edit made on the board.
    func testUnknownKeysSurviveARoundTrip() throws {
        let data = Data("""
        { "version": 1, "notes": "hand written", "components": [
            { "name": "api", "kind": "service", "owner": "jacob", "tags": ["public"] } ] }
        """.utf8)
        var map = try SystemMap.decode(data)
        map.components[0].reachedBy = "API_URL"

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try map.encoded()) as? [String: Any])
        XCTAssertEqual(object["notes"] as? String, "hand written")
        let component = try XCTUnwrap((object["components"] as? [[String: Any]])?.first)
        XCTAssertEqual(component["owner"] as? String, "jacob")
        XCTAssertEqual(component["tags"] as? [String], ["public"])
        XCTAssertEqual(component["reached_by"] as? String, "API_URL", "the edit still lands")
    }

    /// Written keys use the file's own spelling, and nothing empty is written.
    func testEncodingWritesTheFilesSpellingAndOmitsEmptyFields() throws {
        let map = SystemMap(version: 1, components: [
            SystemComponent(name: "redis", kind: .cache, reachedBy: "REDIS_URL", intended: true),
        ])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try map.encoded()) as? [String: Any])
        let component = try XCTUnwrap((object["components"] as? [[String: Any]])?.first)
        XCTAssertEqual(component["name"] as? String, "redis")
        XCTAssertEqual(component["reached_by"] as? String, "REDIS_URL")
        XCTAssertEqual(component["intended"] as? Bool, true)
        XCTAssertNil(component["runs"], "an absent field is not written as null")
        XCTAssertNil(component["used_by"], "an empty list is not written")
        XCTAssertNil(component["at"])
    }

    func testAMalformedFileFailsWithAReason() {
        for (json, hint) in [
            ("not json at all", "JSON"),
            (#"{"version": 1}"#, "components"),
            (#"{"version": 1, "components": [{"kind": "cache"}]}"#, "name"),
            (#"{"version": 1, "components": [{"name": "a"}, {"name": "A"}]}"#, "twice"),
        ] {
            XCTAssertThrowsError(try SystemMap.decode(Data(json.utf8)), json) { error in
                XCTAssertTrue("\(error)".contains(hint), "\(error) should mention \(hint)")
            }
        }
    }

    func testAMissingVersionReadsAsVersionOne() throws {
        let map = try SystemMap.decode(Data(#"{"components": []}"#.utf8))
        XCTAssertEqual(map.version, 1)
        XCTAssertTrue(map.components.isEmpty)
    }
}

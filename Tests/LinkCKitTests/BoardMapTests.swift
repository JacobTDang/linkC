import XCTest
@testable import LinkCKit

final class BoardMapTests: XCTestCase {
    private let june = Data("""
    {
      "version": 2,
      "system": "June — audio journaling",
      "places": {
        "Local docker": {
          "api": { "kind": "service", "does": "HTTP api", "reached_by": "API_URL", "runs": "docker compose (api)",
                   "uses": { "postgres": "reads and writes entries", "redis": "" } },
          "postgres": { "kind": "database", "reached_by": "DATABASE_URL" },
          "redis": { "kind": "cache", "status": "planned" }
        },
        "Oracle box": { "june-audio": { "kind": "host", "does": "serves mp3s" } },
        "Not placed": {}
      },
      "notes": ["Redis is for the session cache.", "Stream uploads."],
      "layout": {
        "components": { "api": [64, 128], "postgres": [232, 128] },
        "frames": { "Local docker": [40, 96, 344, 200], "Oracle box": [408, 96, 192, 112] },
        "notes": [[640, 112], null],
        "texts": [{ "text": "June", "style": "title", "at": [32, 32], "w": 64 }]
      }
    }
    """.utf8)

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testAVersionTwoFileDecodes() throws {
        let map = try BoardMap.decode(june)
        XCTAssertEqual(map.sourceVersion, 2)
        XCTAssertEqual(map.system, "June — audio journaling")
        XCTAssertEqual(map.frames.map(\.label), ["Local docker", "Oracle box"])
        XCTAssertEqual(map.frames.first?.rect, BoardRect(x: 40, y: 96, w: 344, h: 200))

        let api = try XCTUnwrap(map.components.first { $0.name == "api" })
        XCTAssertEqual(api.place, "Local docker")
        XCTAssertEqual(api.kind, .service)
        XCTAssertEqual(api.does, "HTTP api")
        XCTAssertEqual(api.runs, "docker compose (api)")
        XCTAssertEqual(api.uses, ["postgres": "reads and writes entries", "redis": ""])
        XCTAssertEqual(api.at, BoardPoint(x: 64, y: 128))
        XCTAssertFalse(api.planned)

        let redis = try XCTUnwrap(map.components.first { $0.name == "redis" })
        XCTAssertTrue(redis.planned)
        XCTAssertNil(redis.at, "a component with no layout entry has no position yet")
        XCTAssertEqual(map.components.first { $0.name == "june-audio" }?.place, "Oracle box")

        XCTAssertEqual(map.notes.map(\.text), ["Redis is for the session cache.", "Stream uploads."])
        XCTAssertEqual(map.notes.map(\.at), [BoardPoint(x: 640, y: 112), nil])
        XCTAssertEqual(map.texts.map(\.text), ["June"])
        XCTAssertEqual(map.texts.first?.style, .title)
        XCTAssertEqual(map.texts.first?.width, 64)
    }

    /// Read top to bottom the file is the architecture; the layout sits in one block of its own.
    func testEncodingWritesTheArchitectureFirstShape() throws {
        let root = try object(try BoardMap.decode(june).encoded())
        XCTAssertEqual(root["version"] as? Int, 2)
        let places = try XCTUnwrap(root["places"] as? [String: Any])
        XCTAssertEqual(Set(places.keys), ["Local docker", "Oracle box", "Not placed"])
        let docker = try XCTUnwrap(places["Local docker"] as? [String: Any])
        let redis = try XCTUnwrap(docker["redis"] as? [String: Any])
        XCTAssertEqual(redis["status"] as? String, "planned")
        XCTAssertNil(redis["intended"])
        let api = try XCTUnwrap(docker["api"] as? [String: Any])
        XCTAssertNil(api["name"], "a component's name is its key, never a field")
        XCTAssertNil(api["at"], "positions live only in the layout block")
        XCTAssertEqual(api["uses"] as? [String: String], ["postgres": "reads and writes entries", "redis": ""])
        let layout = try XCTUnwrap(root["layout"] as? [String: Any])
        XCTAssertEqual((layout["components"] as? [String: [Int]])?["api"], [64, 128])
        XCTAssertEqual((layout["frames"] as? [String: [Int]])?["Oracle box"], [408, 96, 192, 112])
    }

    /// "Not placed" is reserved and always written, even when empty, so an agent never
    /// wonders where the rest went.
    func testAnEmptyMapStillWritesNotPlaced() throws {
        let root = try object(try BoardMap.empty.encoded())
        XCTAssertEqual(root["version"] as? Int, 2)
        XCTAssertEqual((root["places"] as? [String: Any]).map { Set($0.keys) }, ["Not placed"])
        XCTAssertEqual(root["notes"] as? [String], [])
        XCTAssertNil(root["system"])
    }

    func testKeysLinkCDoesNotKnowSurviveEveryLevel() throws {
        let data = Data("""
        { "version": 2, "owner": "jacob",
          "places": { "Not placed": { "api": { "kind": "service", "team": "core" } } },
          "notes": [],
          "layout": { "zoom_hint": 1.5 } }
        """.utf8)
        var map = try BoardMap.decode(data)
        map.components[0].does = "HTTP api"
        let root = try object(try map.encoded())
        XCTAssertEqual(root["owner"] as? String, "jacob")
        let api = try XCTUnwrap(((root["places"] as? [String: Any])?["Not placed"] as? [String: Any])?["api"] as? [String: Any])
        XCTAssertEqual(api["team"] as? String, "core")
        XCTAssertEqual(api["does"] as? String, "HTTP api", "the edit still lands")
        XCTAssertEqual((root["layout"] as? [String: Any])?["zoom_hint"] as? Double, 1.5)
    }

    /// Encoding is stable: a decode of what was written writes the same bytes again.
    func testARoundTripIsByteStable() throws {
        let once = try BoardMap.decode(june).encoded()
        let twice = try BoardMap.decode(once).encoded()
        XCTAssertEqual(once, twice)
    }

    func testCoordinatesAreSnappedToEight() throws {
        var map = BoardMap.empty
        map.components = [BoardComponent(name: "api", kind: .service, at: BoardPoint(x: 13, y: 21))]
        let layout = try XCTUnwrap(try object(try map.encoded())["layout"] as? [String: Any])
        XCTAssertEqual((layout["components"] as? [String: [Int]])?["api"], [16, 24])
    }

    func testAVersionOneFileUpgrades() throws {
        let v1 = Data("""
        { "version": 1, "note": "kept",
          "components": [
            { "name": "postgres", "kind": "database", "used_by": ["api", "ios app"], "at": { "x": 1, "y": 2 } },
            { "name": "api", "kind": "service", "intended": true, "owner": "jacob" }
          ] }
        """.utf8)
        let map = try BoardMap.decode(v1)
        XCTAssertEqual(map.sourceVersion, 1)
        XCTAssertTrue(map.components.allSatisfy { $0.place == BoardMap.notPlaced })
        let postgres = try XCTUnwrap(map.components.first { $0.name == "postgres" })
        XCTAssertEqual(postgres.at, BoardPoint(x: 160, y: 128), "cells become points: x × 160, y × 64")
        XCTAssertEqual(postgres.legacyUsedBy, ["ios app"], "a user that is not a component is kept")
        let api = try XCTUnwrap(map.components.first { $0.name == "api" })
        XCTAssertTrue(api.planned)
        XCTAssertEqual(api.uses, ["postgres": ""], "used_by becomes uses on the user")

        let root = try object(try map.encoded())
        XCTAssertEqual(root["version"] as? Int, 2)
        XCTAssertNil(root["components"], "the version-1 list is gone once written")
        XCTAssertEqual(root["note"] as? String, "kept")
        let apiOut = try XCTUnwrap(((root["places"] as? [String: Any])?["Not placed"] as? [String: Any])?["api"] as? [String: Any])
        XCTAssertEqual(apiOut["owner"] as? String, "jacob")
        XCTAssertNil(apiOut["intended"])
        XCTAssertNil(apiOut["name"])
    }

    func testAFileThatCannotBeTrustedIsRefusedWithAReason() {
        let cases: [(String, String)] = [
            ("not json", "JSON"),
            ("[1, 2]", "object"),
            (#"{"version": 2}"#, "places"),
            (#"{"notes": []}"#, "neither"),
            (#"{"version": 3, "places": {}}"#, "newer"),
            (#"{"version": 2, "places": {"A": {"api": {}}, "B": {"API": {}}}}"#, "twice"),
            (#"{"version": 2, "places": {"Docker": {}, "docker": {}}}"#, "twice"),
            (#"{"version": 2, "places": {"Not placed": {"api": {"kind": 4}}}}"#, "kind"),
            (#"{"version": 2, "places": {"Not placed": {"api": {"uses": ["db"]}}}}"#, "uses"),
            (#"{"version": 2, "places": {"Not placed": {"api": {"status": "done"}}}}"#, "status"),
            (#"{"version": 2, "places": {"Not placed": {}}, "notes": [3]}"#, "notes"),
            (#"{"version": 2, "places": {"Not placed": {}}, "layout": {"frames": {"A": [1, 2]}}}"#, "frames"),
            (#"{"version": 2, "places": {"Not placed": {}}, "layout": {"components": {"api": [1]}}}"#, "components"),
        ]
        for (json, hint) in cases {
            XCTAssertThrowsError(try BoardMap.decode(Data(json.utf8)), json) { error in
                XCTAssertTrue("\(error)".contains(hint), "\(json): \(error) should mention \(hint)")
            }
        }
    }

    func testAPlaceNamedLikeNotPlacedInAnotherCaseIsTheSameBucket() throws {
        let map = try BoardMap.decode(Data(#"{"version": 2, "places": {"not placed": {"api": {}}}}"#.utf8))
        XCTAssertEqual(map.components.first?.place, BoardMap.notPlaced)
        XCTAssertTrue(map.frames.isEmpty)
    }

    func testRectGeometry() {
        let a = BoardRect(x: 0, y: 0, w: 100, h: 50)
        XCTAssertTrue(a.intersects(BoardRect(x: 99, y: 49, w: 10, h: 10)))
        XCTAssertFalse(a.intersects(BoardRect(x: 100, y: 0, w: 10, h: 10)), "touching edges do not overlap")
        XCTAssertTrue(a.contains(BoardRect(x: 10, y: 10, w: 20, h: 20)))
        XCTAssertFalse(a.contains(BoardRect(x: 90, y: 10, w: 20, h: 20)))
        XCTAssertEqual(a.center, BoardPoint(x: 50, y: 25))
        XCTAssertEqual(BoardRect(x: 5, y: 11, w: 150, h: 57).snapped, BoardRect(x: 8, y: 8, w: 152, h: 56))
    }
}

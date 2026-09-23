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

    /// The exact bytes `encoded()` writes: architecture-first key order at the top, every other
    /// object's keys sorted the way `.sortedKeys` gives them, 2-space indent, number arrays kept
    /// to one line, `/` never escaped, and a single trailing newline. This is what pins order —
    /// the shape test above only parses into a dictionary, so it can't see it.
    private var goldenSource: Data {
        Data("""
        {
          "version": 2,
          "system": "June — audio journaling",
          "owner": "jacob",
          "places": {
            "Local docker": {
              "api": {
                "kind": "service",
                "does": "HTTP api",
                "reached_by": "https://api.example.com/v1",
                "status": "planned",
                "uses": { "postgres": "reads and writes entries" },
                "team": "core"
              }
            },
            "Not placed": {}
          },
          "notes": ["Redis is for the session cache."],
          "layout": {
            "components": { "api": [64, 128] },
            "frames": { "Local docker": [40, 96, 344, 200] },
            "notes": [[640, 112]],
            "texts": [{ "text": "June", "style": "title", "at": [32, 32], "w": 64 }]
          }
        }
        """.utf8)
    }

    private var goldenBytes: Data {
        Data("""
        {
          "version": 2,
          "system": "June — audio journaling",
          "places": {
            "Local docker": {
              "api": {
                "does": "HTTP api",
                "kind": "service",
                "reached_by": "https://api.example.com/v1",
                "status": "planned",
                "team": "core",
                "uses": {
                  "postgres": "reads and writes entries"
                }
              }
            },
            "Not placed": {}
          },
          "notes": [
            "Redis is for the session cache."
          ],
          "owner": "jacob",
          "layout": {
            "components": {
              "api": [64, 128]
            },
            "frames": {
              "Local docker": [40, 96, 344, 200]
            },
            "notes": [
              [640, 112]
            ],
            "texts": [
              {
                "at": [32, 32],
                "style": "title",
                "text": "June",
                "w": 64
              }
            ]
          }
        }
        """.utf8) + Data("\n".utf8)
    }

    func testEncodedMatchesTheGoldenBytesExactly() throws {
        let map = try BoardMap.decode(goldenSource)
        XCTAssertEqual(try map.encoded(), goldenBytes)
    }

    /// Decoding what was just written and encoding it again lands on the exact same bytes.
    func testDecodingTheEncodedGoldenMapReencodesToTheSameBytes() throws {
        let once = try BoardMap.decode(goldenSource).encoded()
        let decodedAgain = try BoardMap.decode(once)
        XCTAssertEqual(try decodedAgain.encoded(), once)
    }

    /// Keys sort the same on every Mac: case-insensitively, numbers by value, never by locale.
    func testKeysSortCaseInsensitivelyWithNumbersByValue() throws {
        let source = Data("""
        { "version": 2, "places": { "Not placed": {
          "api-10": { "kind": "service" }, "Beta": { "kind": "service" },
          "api-2": { "kind": "service" }, "alpha": { "kind": "service" } } } }
        """.utf8)
        let text = String(decoding: try BoardMap.decode(source).encoded(), as: UTF8.self)
        let placed = try XCTUnwrap(text.range(of: "\"Not placed\""))
        let order = ["alpha", "api-2", "api-10", "Beta"].map { name in
            text.range(of: "\"\(name)\": {", range: placed.upperBound..<text.endIndex)?.lowerBound
        }
        XCTAssertFalse(order.contains(nil), "every component is written under Not placed")
        XCTAssertEqual(order.compactMap { $0 }, order.compactMap { $0 }.sorted(), "alpha, api-2, api-10, Beta")
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

    /// Spec §3: unknown keys survive "in `layout`" — including one carried by a single entry of
    /// `layout.texts`, the same as a component's own unknown keys.
    func testAnUnknownKeyInATextEntrySurvivesARoundTrip() throws {
        let data = Data("""
        { "version": 2, "places": { "Not placed": {} }, "notes": [],
          "layout": { "texts": [ { "text": "June", "style": "title", "at": [32, 32], "w": 64, "color": "blue" } ] } }
        """.utf8)
        let map = try BoardMap.decode(data)
        XCTAssertEqual(map.texts.first?.text, "June")

        let root = try object(try map.encoded())
        let texts = try XCTUnwrap((root["layout"] as? [String: Any])?["texts"] as? [[String: Any]])
        let first = try XCTUnwrap(texts.first)
        XCTAssertEqual(first["color"] as? String, "blue", "an unknown key inside a text entry survives, the same as a component's")
        XCTAssertEqual(first["text"] as? String, "June")
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

    func testRectContainsPoint() {
        let a = BoardRect(x: 10, y: 20, w: 100, h: 50)
        XCTAssertTrue(a.contains(BoardPoint(x: 10, y: 20)), "the near corner is inside")
        XCTAssertTrue(a.contains(BoardPoint(x: 109, y: 69)), "just inside the far edges")
        XCTAssertFalse(a.contains(BoardPoint(x: 110, y: 40)), "the far x edge itself is outside")
        XCTAssertFalse(a.contains(BoardPoint(x: 50, y: 70)), "the far y edge itself is outside")
        XCTAssertFalse(a.contains(BoardPoint(x: 9, y: 20)), "left of the near edge is outside")
        XCTAssertFalse(a.contains(BoardPoint(x: 10, y: 19)), "above the near edge is outside")
    }

    func testRectOffsetBy() {
        let a = BoardRect(x: 10, y: 20, w: 100, h: 50)
        XCTAssertEqual(a.offsetBy(dx: 5, dy: -3), BoardRect(x: 15, y: 17, w: 100, h: 50))
    }

    func testAComponentWithNoKindIsAService() throws {
        let data = Data(#"{"version": 2, "places": {"Not placed": {"api": {}}}}"#.utf8)
        let map = try BoardMap.decode(data)
        XCTAssertEqual(map.components.first?.kind, .service)
    }

    // MARK: - Version-1 upgrade keeps every version-2 field

    func testAVersionOneComponentsDoesSurvives() throws {
        let v1 = Data("""
        { "version": 1, "components": [ { "name": "api", "kind": "service", "does": "HTTP api" } ] }
        """.utf8)
        let map = try BoardMap.decode(v1)
        XCTAssertEqual(map.components.first?.does, "HTTP api")
        let root = try object(try map.encoded())
        let api = try XCTUnwrap(((root["places"] as? [String: Any])?[BoardMap.notPlaced] as? [String: Any])?["api"] as? [String: Any])
        XCTAssertEqual(api["does"] as? String, "HTTP api", "does survives the upgrade instead of landing in extras")
    }

    func testAVersionOneComponentsStatusSurvives() throws {
        let v1 = Data("""
        { "version": 1, "components": [ { "name": "redis", "kind": "cache", "status": "planned" } ] }
        """.utf8)
        let map = try BoardMap.decode(v1)
        XCTAssertTrue(try XCTUnwrap(map.components.first).planned)
        let root = try object(try map.encoded())
        let redis = try XCTUnwrap(((root["places"] as? [String: Any])?[BoardMap.notPlaced] as? [String: Any])?["redis"] as? [String: Any])
        XCTAssertEqual(redis["status"] as? String, "planned")
    }

    func testAVersionOneComponentsInvalidStatusIsRefusedWithTheSameMessageAsVersionTwo() {
        let v1 = Data(#"{"version": 1, "components": [{"name": "api", "status": "done"}]}"#.utf8)
        let v2 = Data(#"{"version": 2, "places": {"Not placed": {"api": {"status": "done"}}}}"#.utf8)
        var v1Message = ""
        var v2Message = ""
        XCTAssertThrowsError(try BoardMap.decode(v1)) { v1Message = "\($0)" }
        XCTAssertThrowsError(try BoardMap.decode(v2)) { v2Message = "\($0)" }
        XCTAssertEqual(v1Message, v2Message, "version 1 refuses a bad status with the same reason version 2 gives")
    }

    func testAVersionOneComponentsUsesMergesWithUsedByAndWinsOnAClash() throws {
        let v1 = Data("""
        { "version": 1, "components": [
            { "name": "postgres", "kind": "database", "used_by": ["api"] },
            { "name": "redis", "kind": "cache", "used_by": ["api"] },
            { "name": "api", "kind": "service", "uses": { "postgres": "reads and writes entries" } }
          ] }
        """.utf8)
        let map = try BoardMap.decode(v1)
        let api = try XCTUnwrap(map.components.first { $0.name == "api" })
        XCTAssertEqual(
            api.uses, ["postgres": "reads and writes entries", "redis": ""],
            "used_by fills in redis, but the explicit label for postgres wins over what used_by would give")
        let root = try object(try map.encoded())
        let apiOut = try XCTUnwrap(((root["places"] as? [String: Any])?[BoardMap.notPlaced] as? [String: Any])?["api"] as? [String: Any])
        XCTAssertEqual(apiOut["uses"] as? [String: String], ["postgres": "reads and writes entries", "redis": ""])
    }

    func testAVersionOneRootsSystemSurvives() throws {
        let v1 = Data(#"{"version": 1, "system": "June", "components": []}"#.utf8)
        let map = try BoardMap.decode(v1)
        XCTAssertEqual(map.system, "June")
        let root = try object(try map.encoded())
        XCTAssertEqual(root["system"] as? String, "June")
    }

    func testAVersionOneRootsNotesSurvive() throws {
        let v1 = Data(#"{"version": 1, "notes": ["kept"], "components": []}"#.utf8)
        let map = try BoardMap.decode(v1)
        XCTAssertEqual(map.notes.map(\.text), ["kept"])
        let root = try object(try map.encoded())
        XCTAssertEqual(root["notes"] as? [String], ["kept"])
    }

    func testAVersionOneFileWithLayoutIsRefused() {
        let v1 = Data(#"{"version": 1, "components": [], "layout": {"components": {}}}"#.utf8)
        XCTAssertThrowsError(try BoardMap.decode(v1)) { error in
            let message = "\(error)"
            XCTAssertTrue(message.contains("version 1"), "\(message) should name version 1")
            XCTAssertTrue(message.contains("version 2"), "\(message) should name version 2")
        }
    }

    // MARK: - Orphaned layout entries

    func testAnOrphanedLayoutEntryIsDroppedWhileRealOnesAreKept() throws {
        let data = Data("""
        { "version": 2,
          "places": { "Local docker": { "api": { "kind": "service" } }, "Not placed": {} },
          "notes": [],
          "layout": {
            "components": { "api": [64, 128], "ghost": [999, 999] },
            "frames": { "Local docker": [40, 96, 344, 200], "Ghost frame": [1, 2, 3, 4] },
            "notes": []
          } }
        """.utf8)
        let map = try BoardMap.decode(data)
        XCTAssertEqual(map.components.first?.at, BoardPoint(x: 64, y: 128), "the real position is kept")
        XCTAssertEqual(map.frames.map(\.label), ["Local docker"], "only real places became frames")
        XCTAssertEqual(map.frames.first?.rect, BoardRect(x: 40, y: 96, w: 344, h: 200), "the real frame's rect is kept")

        let root = try object(try map.encoded())
        let layout = try XCTUnwrap(root["layout"] as? [String: Any])
        XCTAssertEqual((layout["components"] as? [String: [Int]])?.keys.sorted(), ["api"], "the orphaned position never resurfaces")
        XCTAssertNil((layout["frames"] as? [String: [Int]])?["Ghost frame"], "the orphaned frame rect never resurfaces")
    }
}

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

    func testARootThatIsAnArrayFailsToDecode() {
        XCTAssertThrowsError(try SystemMap.decode(Data("[]".utf8))) { error in
            XCTAssertTrue("\(error)".contains("object"), "\(error) should say the root is not an object")
        }
    }

    /// A known key that is present but the wrong type must refuse the whole file — never decode
    /// with the value silently dropped, which would then erase it on the next save.
    func testAWrongTypedKnownFieldIsRefusedRatherThanSilentlyChanged() throws {
        let data = Data(#"""
        { "components": [
            { "name": "api", "kind": "service", "reached_by": 123 } ] }
        """#.utf8)
        XCTAssertThrowsError(try SystemMap.decode(data)) { error in
            let message = "\(error)"
            XCTAssertTrue(message.contains("api"), "\(message) should name the component")
            XCTAssertTrue(message.contains("reached_by"), "\(message) should name the key")
        }
    }

    func testEachWrongTypedKnownKeyIsRefused() {
        let cases: [(json: String, key: String, namesComponent: Bool)] = [
            (#"{"components": [{"name": "api", "kind": "service", "reached_by": 123}]}"#, "reached_by", true),
            (#"{"components": [{"name": "api", "kind": "service", "at": {"x": 5}}]}"#, "at", true),
            (#"{"components": [{"name": "api", "kind": "service", "used_by": ["api", 7]}]}"#, "used_by", true),
            (#"{"components": [{"name": "api", "kind": "service", "intended": "yes"}]}"#, "intended", true),
            (#"{"components": [{"name": "api", "kind": 4}]}"#, "kind", true),
            (#"{"version": "1", "components": []}"#, "version", false),
        ]
        for testCase in cases {
            XCTAssertThrowsError(try SystemMap.decode(Data(testCase.json.utf8)), testCase.json) { error in
                let message = "\(error)"
                XCTAssertTrue(message.contains(testCase.key), "\(message) should mention \(testCase.key)")
                if testCase.namesComponent {
                    XCTAssertTrue(message.contains("api"), "\(message) should name the component")
                }
            }
        }
    }

    /// An absent key keeps its current meaning: only `true` is ever written, but reading one
    /// back that was never written must still default correctly, and encoding it must not
    /// write `false` explicitly.
    func testIntendedFalseIsOmittedWhenEncoded() throws {
        let map = SystemMap(components: [SystemComponent(name: "redis", kind: .cache, intended: false)])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try map.encoded()) as? [String: Any])
        let component = try XCTUnwrap((object["components"] as? [[String: Any]])?.first)
        XCTAssertNil(component["intended"], "intended: false is not written")
    }

    /// `extras` blobs must serialize deterministically (sorted keys), the same way the file
    /// write does, or two logically-equal maps can compare unequal.
    func testExtrasAreSerializedWithSortedKeysForStableEquality() throws {
        let data = Data(#"{"components": [{"name": "api", "kind": "service", "zeta": "z", "alpha": "a"}]}"#.utf8)
        let map = try SystemMap.decode(data)
        let extras = try XCTUnwrap(map.components[0].extras)
        let text = try XCTUnwrap(String(data: extras, encoding: .utf8))
        let alphaRange = try XCTUnwrap(text.range(of: "alpha"))
        let zetaRange = try XCTUnwrap(text.range(of: "zeta"))
        XCTAssertLessThan(alphaRange.lowerBound, zetaRange.lowerBound,
                           "extras should be serialized with sorted keys so equal maps compare equal")
    }

    /// `version` lives on the struct itself; the encoder always writes it back, so a stale copy
    /// left in root extras would just be dead weight nobody prunes.
    func testDecodeDropsTheStaleVersionKeyFromRootExtras() throws {
        let data = Data(#"{"version": 3, "notes": "n", "components": []}"#.utf8)
        let map = try SystemMap.decode(data)
        let extras = try XCTUnwrap(map.extras)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: extras) as? [String: Any])
        XCTAssertNil(object["version"], "version lives on the struct; it should not linger in extras")
        XCTAssertEqual(object["notes"] as? String, "n")
    }

    // MARK: - Unknown keys surviving is a guarantee, so reading `extras` back must fail loud

    /// Encoding used to read a component's stored `extras` back with `try?`, defaulting to an
    /// empty object on failure — silently dropping every unknown key the file carried, while
    /// still writing the file. That must fail loud instead.
    func testEncodingFailsLoudWhenAComponentsExtrasCannotBeRead() {
        var component = SystemComponent(name: "api", kind: .service)
        component.extras = Data("not json".utf8)
        let map = SystemMap(components: [component])
        XCTAssertThrowsError(try map.encoded())
    }

    /// The same guarantee at the top level: the map's own `extras` must fail loud rather than
    /// silently encoding as if no unknown top-level keys had ever existed.
    func testEncodingFailsLoudWhenTheMapsOwnExtrasCannotBeRead() {
        var map = SystemMap(components: [SystemComponent(name: "api", kind: .service)])
        map.extras = Data("not json".utf8)
        XCTAssertThrowsError(try map.encoded())
    }
}

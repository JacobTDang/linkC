import XCTest
@testable import LinkCKit

final class BoardEditTests: XCTestCase {
    /// June, laid out: api and postgres in Local docker; june-audio not placed.
    private func june() throws -> BoardMap {
        try BoardMap.decode(Data("""
        { "version": 2, "places": {
            "Local docker": { "api": { "kind": "service", "uses": { "postgres": "" } },
                              "postgres": { "kind": "database" } },
            "Not placed": { "june-audio": { "kind": "host" } } },
          "notes": ["Stream uploads."],
          "layout": { "components": { "api": [48, 48], "postgres": [232, 48], "june-audio": [600, 48] },
                      "frames": { "Local docker": [40, 40, 360, 200] }, "notes": [[600, 200]] } }
        """.utf8))
    }

    private func apply(_ json: Any, to map: BoardMap) throws -> (map: BoardMap, lines: [String]) {
        try BoardEdit.apply(try BoardEdit.steps(from: json), to: map)
    }

    private func refusal(_ json: Any, on map: BoardMap) -> BoardEditRefusal? {
        do { _ = try apply(json, to: map); return nil } catch let error as BoardEditRefusal { return error } catch {
            XCTFail("unexpected \(error)"); return nil
        }
    }

    private func assertNoOverlaps(_ map: BoardMap, file: StaticString = #filePath, line: UInt = #line) {
        let all = map.components.compactMap { $0.at.map(BoardGeometry.rect(ofComponentAt:)) }
            + map.notes.compactMap { $0.at.map(BoardGeometry.rect(ofNoteAt:)) }
        for i in all.indices { for j in all.indices where j > i {
            XCTAssertFalse(all[i].intersects(all[j]), "\(all[i]) overlaps \(all[j])", file: file, line: line)
        } }
    }

    func testAddPlacesAComponentInsideTheNamedFrame() throws {
        let result = try apply([["add": "redis", "kind": "cache", "in": "local docker", "does": "session cache", "planned": true]], to: june())
        let redis = try XCTUnwrap(result.map.components.first { $0.name == "redis" })
        XCTAssertEqual(redis.kind, .cache)
        XCTAssertEqual(redis.place, "Local docker", "places match regardless of case")
        XCTAssertTrue(redis.planned)
        XCTAssertEqual(redis.does, "session cache")
        let frame = try XCTUnwrap(result.map.frames.first { $0.label == "Local docker" }?.rect)
        XCTAssertTrue(BoardGeometry.interior(of: frame).contains(BoardGeometry.rect(ofComponentAt: try XCTUnwrap(redis.at))))
        assertNoOverlaps(result.map)
        XCTAssertEqual(result.lines, ["added redis (planned, cache) in Local docker"])
    }

    func testAddWithNoPlaceGoesToTheRightOfEverything() throws {
        let result = try apply([["add": "cdn"]], to: june())
        let cdn = try XCTUnwrap(result.map.components.first { $0.name == "cdn" })
        XCTAssertEqual(cdn.kind, .service)
        XCTAssertEqual(cdn.place, BoardMap.notPlaced)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(cdn.at).x, 600 + BoardGeometry.componentSize.x)
        assertNoOverlaps(result.map)
    }

    func testAnUnknownPlaceIsRefusedWithThePlacesThatExist() throws {
        let refused = refusal([["add": "redis", "in": "Dockr"]], on: try june())
        XCTAssertEqual(refused?.description, #"step 1: no place "Dockr" — places: Local docker"#)
    }

    func testAPlaceCreatedEarlierInTheCallCanBeUsed() throws {
        let result = try apply([["place": "Oracle box"], ["update": "june-audio", "in": "Oracle box"]], to: june())
        let audio = try XCTUnwrap(result.map.components.first { $0.name == "june-audio" })
        XCTAssertEqual(audio.place, "Oracle box")
        let frame = try XCTUnwrap(result.map.frames.first { $0.label == "Oracle box" }?.rect)
        XCTAssertTrue(BoardGeometry.interior(of: frame).contains(BoardGeometry.rect(ofComponentAt: try XCTUnwrap(audio.at))))
        assertNoOverlaps(result.map)
    }

    func testUpdatingAMissingNameIsRefusedWithTheNamesThatExist() throws {
        XCTAssertEqual(refusal([["update": "apii", "does": "x"]], on: try june())?.description,
                       #"step 1: no component "apii" — components: api, june-audio, postgres"#)
    }

    func testAllOrNothing() throws {
        let map = try june()
        let refused = refusal([["add": "redis"], ["connect": "api", "to": "redis"], ["remove": "nope"]], on: map)
        XCTAssertEqual(refused?.step, 3)
        // The caller's map is a value; the only way to "write" is the returned map, and none came back.
    }

    func testRenameCarriesArrows() throws {
        let result = try apply([["update": "postgres", "rename": "db"]], to: june())
        XCTAssertEqual(result.map.components.first { $0.name == "api" }?.uses, ["db": ""])
        XCTAssertEqual(result.lines, ["renamed postgres → db"])
    }

    func testConnectAddsThenRelabels() throws {
        var result = try apply([["connect": "june-audio", "to": "API"]], to: june())
        XCTAssertEqual(result.map.components.first { $0.name == "june-audio" }?.uses, ["api": ""])
        result = try apply([["connect": "api", "to": "postgres", "label": "reads and writes"]], to: result.map)
        XCTAssertEqual(result.map.components.first { $0.name == "api" }?.uses, ["postgres": "reads and writes"])
        XCTAssertEqual(result.lines, [#"api → postgres "reads and writes""#])
    }

    func testAnArrowToItselfIsRefused() throws {
        XCTAssertNotNil(refusal([["connect": "api", "to": "api"]], on: try june()))
    }

    // MARK: - connect carries style and bits; a router or control unit defaults theirs

    func testConnectCarriesAStyleAndBits() throws {
        let base = try apply([["add": "regs", "kind": "register"], ["add": "alu", "kind": "alu"]], to: .empty).map
        let result = try apply([["connect": "regs", "to": "alu", "style": "bus", "bits": 32]], to: base)
        XCTAssertEqual(result.map.components.first { $0.name == "regs" }?.uses["alu"], BoardArrow(style: .bus, bits: 32))
        XCTAssertEqual(result.lines, ["regs → alu (bus, 32-bit)"])
    }

    func testArrowsFromARouterOrAControlUnitDefaultToTheirStyle() throws {
        let base = try apply([["add": "route", "kind": "router"], ["add": "done", "kind": "end"], ["add": "cu", "kind": "control"], ["add": "mux", "kind": "mux"]], to: .empty).map
        var result = try apply([["connect": "route", "to": "done", "label": "done"], ["connect": "cu", "to": "mux", "label": "ALUSrc"]], to: base)
        XCTAssertEqual(result.map.components.first { $0.name == "route" }?.uses["done"]?.style, .conditional)
        XCTAssertEqual(result.map.components.first { $0.name == "cu" }?.uses["mux"]?.style, .control)
        result = try apply([["connect": "route", "to": "done", "style": "plain"]], to: result.map)
        XCTAssertEqual(result.map.components.first { $0.name == "route" }?.uses["done"], BoardArrow(label: "done"), "an explicit style wins, the label stays")
    }

    func testBadStylesAreRefusedWithTheStep() throws {
        let base = try apply([["add": "a"], ["add": "b"]], to: .empty).map
        XCTAssertEqual(refusal([["connect": "a", "to": "b", "style": "wavy"]], on: base)?.step, 1)
        XCTAssertNotNil(refusal([["connect": "a", "to": "b", "bits": 8]], on: base), "bits need bus")
        XCTAssertNotNil(refusal([["connect": "a", "to": "b", "style": "bus", "bits": 0]], on: base))
    }

    /// `"bits": 12.7` must not silently truncate to 12 — a non-integer is refused like any other
    /// bad value, with the step's number.
    func testNonIntegerBitsIsRefused() throws {
        let base = try apply([["add": "a"], ["add": "b"]], to: .empty).map
        let refused = refusal([["connect": "a", "to": "b", "style": "bus", "bits": 12.7]], on: base)
        XCTAssertEqual(refused?.step, 1)
        XCTAssertEqual(refused?.reason, "\"bits\" must be a whole number")
    }

    func testRenameAndRemoveCarryStyledArrows() throws {
        var m = try apply([["add": "r", "kind": "router"], ["add": "x", "kind": "end"], ["connect": "r", "to": "x", "label": "done"]], to: .empty).map
        m = try apply([["update": "x", "rename": "finish"]], to: m).map
        XCTAssertEqual(m.components.first { $0.name == "r" }?.uses["finish"]?.style, .conditional)
        m = try apply([["remove": "finish"]], to: m).map
        XCTAssertEqual(m.components.first { $0.name == "r" }?.uses, [:])
    }

    func testRemoveTakesItsArrows() throws {
        let result = try apply([["remove": "postgres"]], to: june())
        XCTAssertNil(result.map.components.first { $0.name == "postgres" })
        XCTAssertEqual(result.map.components.first { $0.name == "api" }?.uses, [:])
    }

    func testRemovingAPlaceKeepsItsComponentsWhereTheyAre() throws {
        let before = try june()
        let result = try apply([["remove_place": "Local docker"]], to: before)
        XCTAssertTrue(result.map.frames.isEmpty)
        let api = try XCTUnwrap(result.map.components.first { $0.name == "api" })
        XCTAssertEqual(api.place, BoardMap.notPlaced)
        XCTAssertEqual(api.at, BoardPoint(x: 48, y: 48))
    }

    func testNotesAndTheSummary() throws {
        let result = try apply([["note": "Redis is only for sessions."], ["remove_note": "Stream uploads."], ["system": "June — audio journaling"]], to: june())
        XCTAssertEqual(result.map.notes.map(\.text), ["Redis is only for sessions."])
        XCTAssertNotNil(result.map.notes.first?.at)
        XCTAssertEqual(result.map.system, "June — audio journaling")
        assertNoOverlaps(result.map)
    }

    func testMalformedStepsAreRefused() throws {
        XCTAssertEqual(refusal([["add": "x", "planned": "yes"]], on: .empty)?.description, #"step 1: "planned" must be true or false"#)
        XCTAssertNotNil(refusal([["ad": "x"]], on: .empty), "no verb")
        XCTAssertNotNil(refusal([["add": "x", "remove": "y"]], on: .empty), "two verbs")
        XCTAssertNotNil(refusal([["add": "x", "kidn": "cache"]], on: .empty), "an unknown field")
        XCTAssertNotNil(refusal([["add": "x", "kind": ""]], on: .empty))
        XCTAssertNotNil(refusal([["add": "  "]], on: .empty))
        XCTAssertNotNil(refusal([["place": "not placed"]], on: .empty), "reserved")
        XCTAssertThrowsError(try BoardEdit.steps(from: [] as [Any]))
        XCTAssertThrowsError(try BoardEdit.steps(from: Array(repeating: ["note": "n"], count: 51)))
        XCTAssertThrowsError(try BoardEdit.steps(from: "add redis"))
    }

    // MARK: - The steps-list refusal names no step number; a per-verb unknown field lists what is allowed

    func testTheStepsListRefusalNamesNoStepNumber() throws {
        XCTAssertThrowsError(try BoardEdit.steps(from: [] as [Any])) { error in
            let description = (error as? BoardEditRefusal)?.description ?? ""
            XCTAssertFalse(description.lowercased().contains("step 0"), description)
            XCTAssertTrue(description.contains("1"), description)
            XCTAssertTrue(description.contains("50"), description)
        }
        XCTAssertThrowsError(try BoardEdit.steps(from: Array(repeating: ["note": "n"], count: 51))) { error in
            let description = (error as? BoardEditRefusal)?.description ?? ""
            XCTAssertFalse(description.lowercased().contains("step 0"), description)
        }
    }

    /// A field that is a real key for *some* verb — just not this one — must still be refused:
    /// the check is against what this verb takes, not against the whole global set of field keys.
    func testUnknownFieldRefusalCatchesAFieldAnotherVerbTakes() throws {
        XCTAssertEqual(refusal([["add": "redis", "to": "api"]], on: try june())?.description,
                       #"step 1: unknown field "to" — add takes: kind, tech, in, does, reached_by, runs, planned"#)
        XCTAssertEqual(refusal([["connect": "api", "to": "postgres", "rename": "db"]], on: try june())?.description,
                       #"step 1: unknown field "rename" — connect takes: to, label, style, bits"#)
        XCTAssertEqual(refusal([["remove": "postgres", "in": "Local docker"]], on: try june())?.description,
                       #"step 1: unknown field "in" — remove takes: (none)"#)
    }

    func testUnknownFieldRefusalListsTheVerbsAllowedFields() throws {
        XCTAssertEqual(refusal([["add": "x", "name": "y"]], on: .empty)?.description,
                       #"step 1: unknown field "name" — add takes: kind, tech, in, does, reached_by, runs, planned"#)
        XCTAssertEqual(refusal([["update": "x", "name": "y"]], on: try june())?.description,
                       #"step 1: unknown field "name" — update takes: kind, tech, in, does, reached_by, runs, planned, rename"#)
        XCTAssertEqual(refusal([["connect": "api", "to": "postgres", "foo": "bar"]], on: try june())?.description,
                       #"step 1: unknown field "foo" — connect takes: to, label, style, bits"#)
        XCTAssertEqual(refusal([["place": "x", "foo": "bar"]], on: .empty)?.description,
                       #"step 1: unknown field "foo" — place takes: rename"#)
        XCTAssertEqual(refusal([["remove": "x", "foo": "bar"]], on: .empty)?.description,
                       #"step 1: unknown field "foo" — remove takes: (none)"#)
    }

    func testAnEmptyMapStartsFromNothing() throws {
        let result = try apply([["place": "Local docker"], ["add": "api", "in": "Local docker"], ["add": "db", "kind": "database", "in": "Local docker"], ["connect": "api", "to": "db"]], to: .empty)
        XCTAssertEqual(Set(result.map.components.map(\.place)), ["Local docker"])
        assertNoOverlaps(result.map)
    }

    // MARK: - "planned": 1 must not decode as true

    func testJSONNumberOneIsNotAcceptedAsABool() throws {
        let json = try JSONSerialization.jsonObject(with: Data(#"[{"add":"x","planned":1}]"#.utf8))
        XCTAssertThrowsError(try BoardEdit.steps(from: json)) { error in
            XCTAssertEqual((error as? BoardEditRefusal)?.description, #"step 1: "planned" must be true or false"#)
        }
    }

    func testJSONBooleansDecodeCorrectlyThroughTheWirePath() throws {
        let json = try JSONSerialization.jsonObject(with: Data(#"[{"add":"x","planned":true},{"add":"y","planned":false}]"#.utf8))
        let result = try apply(json, to: BoardMap.empty)
        XCTAssertEqual(result.map.components.first { $0.name == "x" }?.planned, true)
        XCTAssertEqual(result.map.components.first { $0.name == "y" }?.planned, false)
    }

    // MARK: - connect / remove / disconnect match arrow keys case-insensitively

    /// A component whose own arrow key was hand-edited to a different case than the real name.
    private func apiUsingLegacyCasedPostgres() throws -> BoardMap {
        try BoardMap.decode(Data("""
        { "version": 2, "places": {
            "Not placed": { "api": { "kind": "service", "uses": { "Postgres": "" } },
                            "postgres": { "kind": "database" } } } }
        """.utf8))
    }

    func testConnectRelabelsAnExistingArrowEvenWhenItsKeyCaseDiffers() throws {
        let result = try apply([["connect": "api", "to": "postgres", "label": "reads"]], to: try apiUsingLegacyCasedPostgres())
        let api = try XCTUnwrap(result.map.components.first { $0.name == "api" })
        XCTAssertEqual(api.uses, ["postgres": "reads"], "the legacy-cased key is relabelled, not duplicated")
    }

    func testRemoveDropsArrowsRegardlessOfKeyCase() throws {
        let result = try apply([["remove": "postgres"]], to: try apiUsingLegacyCasedPostgres())
        XCTAssertEqual(result.map.components.first { $0.name == "api" }?.uses, [:])
    }

    func testDisconnectDropsAnArrowRegardlessOfKeyCase() throws {
        let result = try apply([["disconnect": "api", "to": "postgres"]], to: try apiUsingLegacyCasedPostgres())
        XCTAssertEqual(result.map.components.first { $0.name == "api" }?.uses, [:])
    }

    // MARK: - disconnect

    func testDisconnectRemovesTheArrowAndReportsIt() throws {
        let result = try apply([["disconnect": "api", "to": "postgres"]], to: june())
        XCTAssertEqual(result.map.components.first { $0.name == "api" }?.uses, [:])
        XCTAssertEqual(result.lines, ["disconnected api → postgres"])
    }

    func testDisconnectIsRefusedWhenThereIsNoSuchArrow() throws {
        XCTAssertEqual(refusal([["disconnect": "api", "to": "june-audio"]], on: try june())?.description,
                       #"step 1: no arrow api → june-audio"#)
    }

    // MARK: - renamePlace

    func testRenamePlaceMovesItsComponentsAndReportsIt() throws {
        let result = try apply([["place": "Local docker", "rename": "Docker Compose"]], to: june())
        XCTAssertEqual(result.map.frames.map(\.label), ["Docker Compose"])
        let api = try XCTUnwrap(result.map.components.first { $0.name == "api" })
        XCTAssertEqual(api.place, "Docker Compose")
        XCTAssertEqual(result.lines, ["renamed place Local docker → Docker Compose"])
    }

    func testRenamePlaceIsRefusedOnADuplicateLabel() throws {
        let withTwoPlaces = try apply([["place": "Oracle box"]], to: june()).map
        XCTAssertNotNil(refusal([["place": "Local docker", "rename": "Oracle box"]], on: withTwoPlaces))
    }

    func testRenamePlaceIsRefusedOnNotPlaced() throws {
        XCTAssertNotNil(refusal([["place": "Local docker", "rename": "not placed"]], on: try june()))
    }

    // MARK: - duplicate-name refusals

    func testAddIsRefusedOnADuplicateName() throws {
        XCTAssertNotNil(refusal([["add": "api"]], on: try june()))
    }

    func testAddPlaceIsRefusedOnADuplicateLabel() throws {
        XCTAssertNotNil(refusal([["place": "Local docker"]], on: try june()))
    }

    // MARK: - update clearing fields with ""

    func testUpdateWithEmptyStringsClearsDoesReachedByAndRuns() throws {
        let filled = try apply(
            [["update": "api", "does": "handles requests", "reached_by": "PORT", "runs": "compose"]], to: june()
        ).map
        let before = try XCTUnwrap(filled.components.first { $0.name == "api" })
        XCTAssertEqual(before.does, "handles requests")
        XCTAssertEqual(before.reachedBy, "PORT")
        XCTAssertEqual(before.runs, "compose")

        let result = try apply([["update": "api", "does": "", "reached_by": "", "runs": ""]], to: filled)
        let api = try XCTUnwrap(result.map.components.first { $0.name == "api" })
        XCTAssertNil(api.does)
        XCTAssertNil(api.reachedBy)
        XCTAssertNil(api.runs)
    }

    // MARK: - a same-name rename is an update, not a rename

    func testUpdateWithRenameEqualToTheCurrentNameIsReportedAsAnUpdate() throws {
        let result = try apply([["update": "api", "rename": "api"]], to: june())
        XCTAssertEqual(result.lines, ["updated api"])
    }

    // MARK: - "(none)" wording when a refusal lists an empty set

    func testComponentRefusalListsNoneWhenTheMapIsEmpty() throws {
        XCTAssertEqual(refusal([["remove": "ghost"]], on: .empty)?.description,
                       #"step 1: no component "ghost" — components: (none)"#)
    }

    func testPlaceRefusalListsNoneWhenTheMapIsEmpty() throws {
        XCTAssertEqual(refusal([["add": "x", "in": "Nowhere"]], on: .empty)?.description,
                       #"step 1: no place "Nowhere" — places: (none)"#)
    }

    // MARK: - summary lines, asserted exactly

    func testPlaceSummaryLine() throws {
        let result = try apply([["place": "Oracle box"]], to: june())
        XCTAssertEqual(result.lines, ["added place Oracle box"])
    }

    func testRemovePlaceSummaryLine() throws {
        let result = try apply([["remove_place": "Local docker"]], to: june())
        XCTAssertEqual(result.lines, ["removed place Local docker"])
    }

    func testNoteSummaryLine() throws {
        let result = try apply([["note": "hello"]], to: june())
        XCTAssertEqual(result.lines, ["added a note"])
    }

    func testRemoveNoteSummaryLine() throws {
        let result = try apply([["remove_note": "Stream uploads."]], to: june())
        XCTAssertEqual(result.lines, ["removed a note"])
    }

    func testSystemSummaryLine() throws {
        let result = try apply([["system": "June — audio journaling"]], to: june())
        XCTAssertEqual(result.lines, ["set the summary"])
    }

    // MARK: - tech

    func testTechOnAddAndUpdateAndClearing() throws {
        var result = try apply([["add": "db", "kind": "database", "tech": "postgres", "planned": true]], to: .empty)
        XCTAssertEqual(result.map.components.first?.tech, "postgres")
        XCTAssertEqual(result.lines, ["added db (planned, postgres)"])
        result = try apply([["update": "db", "tech": ""]], to: result.map)
        XCTAssertNil(result.map.components.first?.tech)
        XCTAssertNotNil(refusal([["connect": "db", "to": "x", "tech": "y"]], on: result.map), "connect takes no tech")
    }
}

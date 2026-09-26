import XCTest
@testable import LinkCKit

final class BoardColumnTests: XCTestCase {
    private let schema = Data("""
    {
      "version": 2,
      "places": {
        "Not placed": {
          "profiles": { "kind": "table", "columns": [
            { "name": "id", "type": "uuid", "pk": true, "references": "auth.users.id" },
            { "name": "handle", "type": "character varying(40)", "nullable": false, "unique": true },
            { "name": "status", "type": "text", "default": "'active'::text" },
            { "name": "avatar_url", "type": "text", "status": "planned" }
          ] }
        }
      }
    }
    """.utf8)

    private let expected: [BoardColumn] = [
        BoardColumn(name: "id", type: "uuid", pk: true, references: BoardColumnReference(table: "auth.users", column: "id")),
        BoardColumn(name: "handle", type: "character varying(40)", nullable: false, unique: true),
        BoardColumn(name: "status", type: "text", defaultValue: "'active'::text"),
        BoardColumn(name: "avatar_url", type: "text", planned: true),
    ]

    func testColumnsDecodeInOrder() throws {
        let map = try BoardMap.decode(schema)
        XCTAssertEqual(map.components.first?.columns, expected)
    }

    func testColumnsRoundTripByteStable() throws {
        let once = try BoardMap.decode(schema).encoded()
        XCTAssertEqual(try BoardMap.decode(once).components.first?.columns, expected)
        XCTAssertEqual(try BoardMap.decode(once).encoded(), once)
    }

    func testColumnsWriteOnlyWhatIsSet() throws {
        let text = String(decoding: try BoardMap.decode(schema).encoded(), as: UTF8.self)
        XCTAssertTrue(text.contains("""
                  {
                    "name": "id",
                    "pk": true,
                    "references": "auth.users.id",
                    "type": "uuid"
                  }
        """), text)
        XCTAssertTrue(text.contains("""
                  {
                    "default": "'active'::text",
                    "name": "status",
                    "type": "text"
                  }
        """), text)
        XCTAssertTrue(text.contains(#""status": "planned""#), text)
    }

    func testAComponentWithoutColumnsWritesNoColumnsKey() throws {
        let data = Data(#"{"version":2,"places":{"Not placed":{"api":{"kind":"service"}}}}"#.utf8)
        let text = String(decoding: try BoardMap.decode(data).encoded(), as: UTF8.self)
        XCTAssertFalse(text.contains("columns"), text)
    }

    func testAReferenceSplitsAtTheLastDot() {
        XCTAssertEqual(BoardColumnReference(parsing: "auth.users.id"), BoardColumnReference(table: "auth.users", column: "id"))
        XCTAssertEqual(BoardColumnReference(parsing: "users.id")?.text, "users.id")
        XCTAssertNil(BoardColumnReference(parsing: "users"))
        XCTAssertNil(BoardColumnReference(parsing: "users."))
        XCTAssertNil(BoardColumnReference(parsing: ".id"))
    }

    func testAPrimaryKeyIsNeverNullable() {
        XCTAssertFalse(BoardColumn(name: "id", type: "uuid", pk: true, nullable: true).nullable)
    }

    func testBadColumnsAreRefusedWithAReason() {
        let cases: [(String, String)] = [
            (#""columns": 5"#, #"has "columns" but it is not a list of objects"#),
            (#""columns": [5]"#, #"has "columns" but it is not a list of objects"#),
            (#""columns": [{"type": "uuid"}]"#, #"has a column with no "name""#),
            (#""columns": [{"name": "id"}]"#, #"column "id" has no "type""#),
            (#""columns": [{"name": "id", "type": "uuid"}, {"name": "ID", "type": "int"}]"#, #"names column "ID" twice"#),
            (#""columns": [{"name": "org", "type": "uuid", "references": "orgs"}]"#, #"column "org" has "references" "orgs" but it is not table.column"#),
            (#""columns": [{"name": "id", "type": "uuid", "pk": true, "nullable": true}]"#, #"column "id" is a primary key, so it can't be nullable"#),
            (#""columns": [{"name": "id", "type": "uuid", "size": 4}]"#, #"column "id" has an unknown key "size""#),
            (#""columns": [{"name": "id", "type": "uuid", "pk": "yes"}]"#, #"has "pk" but it is not true or false"#),
            (#""columns": [{"name": "id", "type": "uuid", "status": "live"}]"#, #"the only status is "planned""#),
        ]
        for (columns, hint) in cases {
            let json = #"{"version":2,"places":{"Not placed":{"t":{"kind":"table","#+columns+#"}}}}"#
            XCTAssertThrowsError(try BoardMap.decode(Data(json.utf8)), json) { error in
                XCTAssertTrue("\(error)".contains(hint), "\(json): \(error) should mention \(hint)")
                XCTAssertTrue("\(error)".contains(#"component "t""#), "\(error) should name the component")
            }
        }
    }

    func testNextColumnNameStartsAtOne() {
        XCTAssertEqual(BoardColumn.nextColumnName(avoiding: []), "column_1")
    }

    func testNextColumnNameSkipsUsedNamesIgnoringCase() {
        let existing = [
            BoardColumn(name: "column_1", type: "text"),
            BoardColumn(name: "COLUMN_2", type: "text"),
            BoardColumn(name: "id", type: "uuid"),
        ]
        XCTAssertEqual(BoardColumn.nextColumnName(avoiding: existing), "column_3")
    }

    func testReferenceOptionsListsOtherTablesColumnsSortedByTableThenColumn() {
        var map = BoardMap()
        map.components = [
            BoardComponent(name: "Orders", kind: .table, columns: [
                BoardColumn(name: "id", type: "uuid", pk: true),
                BoardColumn(name: "total", type: "numeric"),
            ]),
            BoardComponent(name: "accounts", kind: .table, columns: [BoardColumn(name: "id", type: "uuid", pk: true)]),
            BoardComponent(name: "svc", kind: .service),
        ]
        XCTAssertEqual(BoardColumn.referenceOptions(in: map, excludingTable: "Orders"), ["accounts.id"])
        XCTAssertEqual(BoardColumn.referenceOptions(in: map, excludingTable: "accounts"), ["Orders.id", "Orders.total"])
    }

    func testReferenceOptionsExcludesTheNamedTableCaseInsensitively() {
        var map = BoardMap()
        map.components = [BoardComponent(name: "Orders", kind: .table, columns: [BoardColumn(name: "id", type: "uuid", pk: true)])]
        XCTAssertEqual(BoardColumn.referenceOptions(in: map, excludingTable: "orders"), [])
    }
}

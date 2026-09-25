import XCTest
@testable import LinkCKit

final class BoardSchemaImportTests: XCTestCase {
    private func apply(_ json: Any, to map: BoardMap) throws -> (map: BoardMap, lines: [String]) {
        try BoardEdit.apply(BoardEdit.steps(from: json), to: map)
    }

    func testAFreshImportAddsTables() throws {
        let parsed = try SQLSchema.parse("create table orgs (id bigint primary key, name text not null);")
        let steps = BoardSchemaImport.steps(for: parsed, into: .empty)
        XCTAssertEqual(steps, [.add("orgs", BoardComponentFields(kind: .table, columns: parsed.tables[0].columns), place: nil)])

        let applied = try BoardEdit.apply(steps, to: .empty)
        let orgs = try XCTUnwrap(applied.map.components.first { $0.name == "orgs" })
        XCTAssertEqual(orgs.kind, .table)
        XCTAssertEqual(orgs.columns, parsed.tables[0].columns)
        XCTAssertFalse(orgs.planned)
    }

    func testAReImportKeepsDesignOnlyTablesAndColumnsAsPlanned() throws {
        let parsed = try SQLSchema.parse("create table orgs (id bigint primary key);")
        var map = try BoardEdit.apply(BoardSchemaImport.steps(for: parsed, into: .empty), to: .empty).map
        map = try apply([
            ["op": "column", "table": "orgs", "column": "notes", "set": ["type": "text"]],
            ["add": "wishlist", "kind": "table", "columns": [["name": "id", "type": "uuid"]]],
        ], to: map).map

        let steps = BoardSchemaImport.steps(for: parsed, into: map)
        let applied = try BoardEdit.apply(steps, to: map).map

        let orgs = try XCTUnwrap(applied.components.first { $0.name == "orgs" })
        XCTAssertFalse(orgs.planned)
        XCTAssertEqual(orgs.columns.map(\.name), ["id", "notes"])
        XCTAssertFalse(orgs.columns[0].planned, "the database column")
        XCTAssertTrue(orgs.columns[1].planned, "the design-only column")

        let wishlist = try XCTUnwrap(applied.components.first { $0.name == "wishlist" })
        XCTAssertTrue(wishlist.planned, "missing from the SQL, so it's planned")
        XCTAssertTrue(wishlist.columns.allSatisfy(\.planned))
    }

    /// A column the design adds is marked planned by the next import that doesn't find it, and
    /// loses planned on the import that does.
    func testAColumnThatReappearsLosesPlanned() throws {
        let firstParsed = try SQLSchema.parse("create table orgs (id bigint primary key);")
        var map = try BoardEdit.apply(BoardSchemaImport.steps(for: firstParsed, into: .empty), to: .empty).map
        map = try apply([["op": "column", "table": "orgs", "column": "name", "set": ["type": "text"]]], to: map).map
        map = try BoardEdit.apply(BoardSchemaImport.steps(for: firstParsed, into: map), to: map).map
        let designOnly = try XCTUnwrap(map.components.first { $0.name == "orgs" }?.columns.first { $0.name == "name" })
        XCTAssertTrue(designOnly.planned, "an import that lacks the column marks it planned")

        let secondParsed = try SQLSchema.parse("create table orgs (id bigint primary key, name text not null);")
        let applied = try BoardEdit.apply(BoardSchemaImport.steps(for: secondParsed, into: map), to: map).map
        let name = try XCTUnwrap(applied.components.first { $0.name == "orgs" }?.columns.first { $0.name == "name" })
        XCTAssertFalse(name.planned)
        XCTAssertEqual(name.type, "text")
        XCTAssertFalse(name.nullable)
    }

    func testImportStepsApplyCleanlyThroughBoardEdit() throws {
        let parsed = try SQLSchema.parse("""
        create table orgs (id bigint primary key);
        create table users (id uuid primary key, org_id bigint references orgs (id));
        """)
        let applied = try BoardEdit.apply(BoardSchemaImport.steps(for: parsed, into: .empty), to: .empty)
        XCTAssertEqual(Set(applied.map.components.map(\.name)), ["orgs", "users"])
        XCTAssertEqual(applied.lines.count, 2)
    }
}

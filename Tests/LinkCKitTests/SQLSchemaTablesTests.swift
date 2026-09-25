import XCTest
@testable import LinkCKit

final class SQLSchemaTablesTests: XCTestCase {
    func testTablesAreReturnedInLowercasedNameOrderWithTheirColumns() {
        var map = BoardMap()
        map.components = [
            BoardComponent(name: "Users", kind: .table, columns: [BoardColumn(name: "id", type: "uuid", pk: true)]),
            BoardComponent(name: "accounts", kind: .table, columns: [BoardColumn(name: "id", type: "bigint", pk: true)]),
            BoardComponent(name: "api", kind: .service),
        ]
        XCTAssertEqual(SQLSchema.tables(in: map), [
            SQLSchema.Table(name: "accounts", columns: [BoardColumn(name: "id", type: "bigint", pk: true)]),
            SQLSchema.Table(name: "Users", columns: [BoardColumn(name: "id", type: "uuid", pk: true)]),
        ])
    }

    func testPlannedTablesAndColumnsAreIncluded() {
        var map = BoardMap()
        map.components = [BoardComponent(name: "wishlist", kind: .table, planned: true, columns: [
            BoardColumn(name: "id", type: "uuid", pk: true, planned: true),
        ])]
        let tables = SQLSchema.tables(in: map)
        XCTAssertEqual(tables.count, 1)
        XCTAssertTrue(tables[0].columns[0].planned)
    }

    func testAnEmptyMapExportsNoTables() {
        XCTAssertEqual(SQLSchema.tables(in: .empty), [])
    }

    /// Round trip: a table's columns survive export → `createStatements` → `parse`.
    func testExportedTablesReadBackTheSame() throws {
        var map = BoardMap()
        map.components = [BoardComponent(name: "orgs", kind: .table, columns: [
            BoardColumn(name: "id", type: "bigint", pk: true),
            BoardColumn(name: "name", type: "text", nullable: false),
        ])]
        let tables = SQLSchema.tables(in: map)
        let parsed = try SQLSchema.parse(SQLSchema.createStatements(for: tables))
        XCTAssertEqual(parsed.tables, tables)
    }
}

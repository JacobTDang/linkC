import XCTest
@testable import LinkCKit

final class BoardForeignKeyTests: XCTestCase {
    func testAllListsEveryColumnWithAReferenceSortedByTableThenColumn() {
        var map = BoardMap()
        map.components = [
            BoardComponent(name: "Orders", kind: .table, columns: [
                BoardColumn(name: "id", type: "uuid", pk: true),
                BoardColumn(name: "customer_id", type: "bigint", references: BoardColumnReference(table: "customers", column: "id")),
            ]),
            BoardComponent(name: "accounts", kind: .table, columns: [
                BoardColumn(name: "org_id", type: "bigint", references: BoardColumnReference(table: "orgs", column: "id")),
                BoardColumn(name: "owner_id", type: "bigint", references: BoardColumnReference(table: "Orders", column: "id")),
            ]),
            BoardComponent(name: "plain", kind: .service),
        ]
        XCTAssertEqual(BoardForeignKey.all(in: map), [
            BoardForeignKey(table: "accounts", column: "org_id", refTable: "orgs", refColumn: "id"),
            BoardForeignKey(table: "accounts", column: "owner_id", refTable: "Orders", refColumn: "id"),
            BoardForeignKey(table: "Orders", column: "customer_id", refTable: "customers", refColumn: "id"),
        ])
    }

    func testATableWithNoReferencesContributesNothing() {
        var map = BoardMap()
        map.components = [BoardComponent(name: "t", kind: .table, columns: [BoardColumn(name: "id", type: "uuid", pk: true)])]
        XCTAssertEqual(BoardForeignKey.all(in: map), [])
    }

    /// A non-table kind never carries columns in practice, but the filter here is by `kind`, not
    /// by an empty-columns check — guard it explicitly so a future bug can't slip a service's
    /// stray columns into the list.
    func testANonTablePartsColumnsAreNeverListedEvenIfPresent() {
        var map = BoardMap()
        map.components = [BoardComponent(name: "svc", kind: .service, columns: [
            BoardColumn(name: "x", type: "int", references: BoardColumnReference(table: "t", column: "id")),
        ])]
        XCTAssertEqual(BoardForeignKey.all(in: map), [])
    }
}

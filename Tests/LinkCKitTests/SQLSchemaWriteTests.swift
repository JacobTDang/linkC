import XCTest
@testable import LinkCKit

final class SQLSchemaWriteTests: XCTestCase {
    private let orgs = SQLSchema.Table(name: "orgs", columns: [
        BoardColumn(name: "id", type: "bigint", pk: true),
        BoardColumn(name: "name", type: "text", nullable: false, defaultValue: "'unnamed'"),
    ])
    private let users = SQLSchema.Table(name: "Users", columns: [
        BoardColumn(name: "id", type: "uuid", pk: true, defaultValue: "gen_random_uuid()"),
        BoardColumn(name: "org_id", type: "bigint", nullable: false, references: BoardColumnReference(table: "orgs", column: "id")),
        BoardColumn(name: "email", type: "text", nullable: false, unique: true),
        BoardColumn(name: "order", type: "integer"),
        BoardColumn(name: "auth_id", type: "uuid", references: BoardColumnReference(table: "auth.users", column: "id")),
    ])
    private let memberships = SQLSchema.Table(name: "memberships", columns: [
        BoardColumn(name: "org_id", type: "bigint", pk: true, references: BoardColumnReference(table: "orgs", column: "id")),
        BoardColumn(name: "user_id", type: "uuid", pk: true, references: BoardColumnReference(table: "Users", column: "id")),
    ])

    func testTablesComeAfterWhatTheyReference() {
        XCTAssertEqual(SQLSchema.createStatements(for: [memberships, users, orgs]), """
        CREATE TABLE orgs (
          id bigint PRIMARY KEY,
          name text NOT NULL DEFAULT 'unnamed'
        );

        CREATE TABLE "Users" (
          id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
          org_id bigint NOT NULL REFERENCES orgs (id),
          email text NOT NULL UNIQUE,
          "order" integer,
          auth_id uuid REFERENCES auth.users (id)
        );

        CREATE TABLE memberships (
          org_id bigint REFERENCES orgs (id),
          user_id uuid REFERENCES "Users" (id),
          PRIMARY KEY (org_id, user_id)
        );

        """)
    }

    func testACycleAddsItsForwardKeysAfterwards() {
        let a = SQLSchema.Table(name: "a", columns: [
            BoardColumn(name: "id", type: "integer", pk: true),
            BoardColumn(name: "b_id", type: "integer", references: BoardColumnReference(table: "b", column: "id")),
        ])
        let b = SQLSchema.Table(name: "b", columns: [
            BoardColumn(name: "id", type: "integer", pk: true),
            BoardColumn(name: "a_id", type: "integer", references: BoardColumnReference(table: "a", column: "id")),
            BoardColumn(name: "parent_id", type: "integer", references: BoardColumnReference(table: "b", column: "id")),
        ])
        XCTAssertEqual(SQLSchema.createStatements(for: [b, a]), """
        CREATE TABLE a (
          id integer PRIMARY KEY,
          b_id integer
        );

        CREATE TABLE b (
          id integer PRIMARY KEY,
          a_id integer REFERENCES a (id),
          parent_id integer REFERENCES b (id)
        );

        ALTER TABLE a ADD FOREIGN KEY (b_id) REFERENCES b (id);

        """)
    }

    func testNothingToWriteIsEmpty() {
        XCTAssertEqual(SQLSchema.createStatements(for: []), "")
    }

    /// Reading back what was written gives the same tables, with nothing skipped or left out.
    func testWrittenSQLReadsBackToTheSameTables() throws {
        let parsed = try SQLSchema.parse(SQLSchema.createStatements(for: [memberships, users, orgs]))
        let byName: (SQLSchema.Table, SQLSchema.Table) -> Bool = { $0.name.lowercased() < $1.name.lowercased() }
        XCTAssertEqual(parsed.tables.sorted(by: byName), [memberships, users, orgs].sorted(by: byName))
        XCTAssertEqual(parsed.skipped, [])
        XCTAssertEqual(parsed.notModelled, [])
    }

    func testACycleReadsBackToTheSameTables() throws {
        let a = SQLSchema.Table(name: "a", columns: [
            BoardColumn(name: "id", type: "integer", pk: true),
            BoardColumn(name: "b_id", type: "integer", references: BoardColumnReference(table: "b", column: "id")),
        ])
        let b = SQLSchema.Table(name: "b", columns: [
            BoardColumn(name: "id", type: "integer", pk: true),
            BoardColumn(name: "a_id", type: "integer", references: BoardColumnReference(table: "a", column: "id")),
        ])
        let parsed = try SQLSchema.parse(SQLSchema.createStatements(for: [a, b]))
        XCTAssertEqual(parsed.tables, [a, b])
    }
}


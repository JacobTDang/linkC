import XCTest
@testable import LinkCKit

final class SQLSchemaParseTests: XCTestCase {
    /// A Supabase / pg_dump schema: tables first, keys added afterwards by ALTER TABLE.
    private let dump = """
    --
    -- PostgreSQL database dump
    --
    SET statement_timeout = 0;
    SELECT pg_catalog.set_config('search_path', '', false);

    CREATE SCHEMA IF NOT EXISTS "public";

    CREATE OR REPLACE FUNCTION "public"."touch_updated_at"() RETURNS "trigger"
        LANGUAGE "plpgsql"
        AS $$
    BEGIN
      NEW.updated_at = now();
      RETURN NEW;
    END;
    $$;

    CREATE TABLE IF NOT EXISTS "public"."entries" (
        "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
        "user_id" "uuid" NOT NULL,
        "body" "text",
        "mood" "public"."mood",
        "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
        CONSTRAINT "entries_body_check" CHECK ((length("body") < 10000))
    );

    ALTER TABLE "public"."entries" OWNER TO "postgres";

    CREATE TABLE IF NOT EXISTS "public"."profiles" (
        "id" "uuid" NOT NULL,
        "handle" character varying(40) NOT NULL,
        "status" "text" DEFAULT 'active'::"text"
    );

    ALTER TABLE ONLY "public"."entries"
        ADD CONSTRAINT "entries_pkey" PRIMARY KEY ("id");

    ALTER TABLE ONLY "public"."profiles"
        ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("id");

    ALTER TABLE ONLY "public"."profiles"
        ADD CONSTRAINT "profiles_handle_key" UNIQUE ("handle");

    ALTER TABLE ONLY "public"."entries"
        ADD CONSTRAINT "entries_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;

    ALTER TABLE ONLY "public"."profiles"
        ADD CONSTRAINT "profiles_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id");

    CREATE POLICY "own entries" ON "public"."entries" USING (("auth"."uid"() = "user_id"));

    GRANT ALL ON TABLE "public"."entries" TO "anon";

    CREATE FUNCTION public.stamp() RETURNS trigger LANGUAGE plpgsql AS $fn$ BEGIN RETURN NEW; END; $fn$;
    """

    func testADumpReadsItsTablesColumnsAndKeys() throws {
        let parsed = try SQLSchema.parse(dump)
        XCTAssertEqual(parsed.tables, [
            SQLSchema.Table(name: "entries", columns: [
                BoardColumn(name: "id", type: "uuid", pk: true, defaultValue: "gen_random_uuid()"),
                BoardColumn(name: "user_id", type: "uuid", nullable: false, references: BoardColumnReference(table: "profiles", column: "id")),
                BoardColumn(name: "body", type: "text"),
                BoardColumn(name: "mood", type: "mood"),
                BoardColumn(name: "created_at", type: "timestamp with time zone", nullable: false, defaultValue: "now()"),
            ]),
            SQLSchema.Table(name: "profiles", columns: [
                BoardColumn(name: "id", type: "uuid", pk: true, references: BoardColumnReference(table: "auth.users", column: "id")),
                BoardColumn(name: "handle", type: "character varying(40)", nullable: false, unique: true),
                BoardColumn(name: "status", type: "text", defaultValue: "'active'::text"),
            ]),
        ])
    }

    func testADumpReportsWhatItSkippedAndDidNotModel() throws {
        let parsed = try SQLSchema.parse(dump)
        XCTAssertEqual(parsed.skipped, [
            .init(line: 4, text: "SET STATEMENT_TIMEOUT"),
            .init(line: 5, text: "SELECT PG_CATALOG"),
            .init(line: 7, text: "CREATE SCHEMA"),
            .init(line: 9, text: "CREATE FUNCTION"),
            .init(line: 27, text: "ALTER TABLE entries OWNER"),
            .init(line: 50, text: "CREATE POLICY"),
            .init(line: 52, text: "GRANT ALL"),
            .init(line: 54, text: "CREATE FUNCTION"),
        ])
        XCTAssertEqual(parsed.notModelled, [.init(line: 24, text: "CHECK on entries")])
    }

    /// A hand-written migration: lowercase keywords, inline keys, a composite primary key, a
    /// reference that names no column, and ALTER TABLE adding columns and a default.
    private let migration = """
    -- 2026-09-01 create orgs and users
    create table orgs (
      id bigint generated always as identity primary key,
      name text not null
    );

    create table "Users" (
      id uuid primary key default gen_random_uuid(),
      org_id bigint not null references orgs,
      email text unique not null,
      "displayName" text,
      manager_id uuid references "Users" (id) on delete set null,
      created_at timestamptz default now(),
      check (email like '%@%')
    );

    create table memberships (
      org_id bigint references orgs (id),
      user_id uuid references "Users",
      role text default 'member',
      primary key (org_id, user_id),
      unique (org_id, role)
    );

    alter table memberships add column joined_at timestamptz, add column note text default 'x;y';
    alter table orgs alter column name set default 'unnamed';
    create index memberships_role on memberships (role);
    """

    func testAMigrationReadsInlineKeysAndAlterations() throws {
        let parsed = try SQLSchema.parse(migration)
        XCTAssertEqual(parsed.tables, [
            SQLSchema.Table(name: "orgs", columns: [
                BoardColumn(name: "id", type: "bigint", pk: true),
                BoardColumn(name: "name", type: "text", nullable: false, defaultValue: "'unnamed'"),
            ]),
            SQLSchema.Table(name: "Users", columns: [
                BoardColumn(name: "id", type: "uuid", pk: true, defaultValue: "gen_random_uuid()"),
                BoardColumn(name: "org_id", type: "bigint", nullable: false, references: BoardColumnReference(table: "orgs", column: "id")),
                BoardColumn(name: "email", type: "text", nullable: false, unique: true),
                BoardColumn(name: "displayName", type: "text"),
                BoardColumn(name: "manager_id", type: "uuid", references: BoardColumnReference(table: "Users", column: "id")),
                BoardColumn(name: "created_at", type: "timestamptz", defaultValue: "now()"),
            ]),
            SQLSchema.Table(name: "memberships", columns: [
                BoardColumn(name: "org_id", type: "bigint", pk: true, references: BoardColumnReference(table: "orgs", column: "id")),
                BoardColumn(name: "user_id", type: "uuid", pk: true, references: BoardColumnReference(table: "Users", column: "id")),
                BoardColumn(name: "role", type: "text", defaultValue: "'member'"),
                BoardColumn(name: "joined_at", type: "timestamptz"),
                BoardColumn(name: "note", type: "text", defaultValue: "'x;y'"),
            ]),
        ])
        XCTAssertEqual(parsed.notModelled, [
            .init(line: 3, text: "GENERATED on orgs.id"),
            .init(line: 14, text: "CHECK on Users"),
            .init(line: 22, text: "UNIQUE (org_id, role) on memberships"),
        ])
        XCTAssertEqual(parsed.skipped, [.init(line: 27, text: "CREATE INDEX")])
    }

    func testAReferenceToATableNotHereWithNoColumnIsReported() throws {
        let parsed = try SQLSchema.parse("create table profiles (id uuid primary key references auth.users);")
        XCTAssertEqual(parsed.tables.first?.columns.first?.references, nil)
        XCTAssertEqual(parsed.notModelled, [
            .init(line: 1, text: "REFERENCES auth.users on profiles.id names no column, and auth.users has no single primary key here"),
        ])
    }

    func testStringsAndCommentsNeverSplitAStatement() throws {
        let sql = """
        /* outer /* inner; */ still a comment; */
        create table t (
          note text default E'it\\'s;fine', -- a comment; with a semicolon
          body text default $x$a;b$x$
        );
        """
        let parsed = try SQLSchema.parse(sql)
        XCTAssertEqual(parsed.tables, [SQLSchema.Table(name: "t", columns: [
            BoardColumn(name: "note", type: "text", defaultValue: "E'it\\'s;fine'"),
            BoardColumn(name: "body", type: "text", defaultValue: "$x$a;b$x$"),
        ])])
        XCTAssertEqual(parsed.skipped, [])
    }

    func testDefaultNullMeansNoDefault() throws {
        let parsed = try SQLSchema.parse("create table t (a text default null not null);")
        XCTAssertEqual(parsed.tables.first?.columns, [BoardColumn(name: "a", type: "text", nullable: false)])
    }

    func testQuotingIsOnlyForNamesThatNeedIt() {
        XCTAssertEqual(SQLSchema.quotedIfNeeded("users"), "users")
        XCTAssertEqual(SQLSchema.quotedIfNeeded("user"), "\"user\"")
        XCTAssertEqual(SQLSchema.quotedIfNeeded("Users"), "\"Users\"")
        XCTAssertEqual(SQLSchema.quotedIfNeeded("display name"), "\"display name\"")
        XCTAssertEqual(SQLSchema.quotedIfNeeded("a\"b"), "\"a\"\"b\"")
        XCTAssertEqual(SQLSchema.quotedIfNeeded("_x1"), "_x1")
    }

    func testAlterTableAddWithoutColumnAddsAColumn() throws {
        let parsed = try SQLSchema.parse("create table t (id int);\nalter table t add email text not null;")
        XCTAssertEqual(parsed.tables.first?.columns, [
            BoardColumn(name: "id", type: "int"),
            BoardColumn(name: "email", type: "text", nullable: false),
        ])
        XCTAssertEqual(parsed.skipped, [])
    }

    func testAlterColumnDefaultAndNullabilityActionsDoNotConsumeEachOther() throws {
        let sql = "create table t (id int, a text default 'x', b text not null);\n"
            + "alter table t alter column a drop default, alter a set not null, alter column b drop not null;"
        let parsed = try SQLSchema.parse(sql)
        XCTAssertEqual(parsed.tables.first?.columns, [
            BoardColumn(name: "id", type: "int"),
            BoardColumn(name: "a", type: "text", nullable: false),
            BoardColumn(name: "b", type: "text"),
        ])
        XCTAssertEqual(parsed.skipped, [])
    }

    func testMalformedAndUnrecognisedAlterInputIsNeverSilent() throws {
        let parsed = try SQLSchema.parse("create table t (id int, note text not null mystery option);\nalter table t add 5, alter 6;")
        XCTAssertEqual(parsed.notModelled, [.init(line: 1, text: "MYSTERY on t.note")])
        XCTAssertEqual(parsed.skipped, [
            .init(line: 2, text: "ALTER TABLE t ADD"),
            .init(line: 2, text: "ALTER TABLE t ALTER"),
        ])

        for sql in [
            "create table t (a int, foreign key (a));",
            "create table t (a int, foreign key (a) references);",
        ] {
            XCTAssertThrowsError(try SQLSchema.parse(sql), sql) { error in
                XCTAssertTrue("\(error)".contains("line 1"), "\(error)")
                XCTAssertTrue("\(error)".contains("table t has a foreign key that names no table"), "\(error)")
            }
        }
    }

    func testIdentifierRulesAreASCIIOnly() {
        XCTAssertEqual(SQLSchema.quotedIfNeeded("é"), "\"é\"")
    }

    func testUnreadableSQLIsRefusedNamingItsLine() {
        let cases: [(String, [String])] = [
            ("create table broken (\n  id int,\n  ,\n  name text\n);", ["line 3", "table broken has an empty column entry"]),
            ("create table t (note text default 'oops);", ["line 1", "a quoted string never ends"]),
            ("create table t (id int);\ncreate table t (id int);", ["line 2", "table t is created twice"]),
            ("create table t (id int, ID int);", ["line 1", "table t names column id twice"]),
            ("create table t (id int);\nalter table t add primary key (nope);", ["line 2", "table t has no column nope"]),
            ("create table t (id);", ["line 1", "column id has no type"]),
            ("create table t (id int", ["line 1", "table t's column list never closes"]),
            ("/* never closed", ["line 1", "a comment never ends"]),
            ("create table \"t (id int);", ["line 1", "a quoted name never ends"]),
            ("create table t (id int);\nalter table t add column id int;", ["line 2", "table t already has column id"]),
        ]
        for (sql, hints) in cases {
            XCTAssertThrowsError(try SQLSchema.parse(sql), sql) { error in
                for hint in hints {
                    XCTAssertTrue("\(error)".contains(hint), "\(sql): \(error) should mention \(hint)")
                }
            }
        }
    }
}

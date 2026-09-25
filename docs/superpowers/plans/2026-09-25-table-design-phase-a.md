# Table design, phase A: columns in the board file, and SQL both ways

> **For agentic workers:** work task by task, test first. Each task ends with one commit.

**Goal:** a table's columns can live in the board file, Postgres CREATE TABLE SQL can be read into tables, and tables can be written back out as SQL. Everything here is pure LinkCKit code: no UI, no processes, no files other than the board file's encoding.

**Spec:** `docs/superpowers/specs/2026-09-25-table-design-design.md` (§1, §4, §6).

**Architecture:**
- `BoardColumn` is the column model, and `BoardComponent` gains `columns`.
- `SQLSchema` is the public face of the SQL layer:
  - `SQLSchema.parse(_:)` reads SQL through an internal tokenizer and parser;
  - `SQLSchema.createStatements(for:)` writes SQL through an internal writer.
- Both sides share one identifier-quoting rule.

**Tech:** Swift 6, macOS 14, XCTest. No new dependencies.

## Global Constraints

- **Where to work:** the worktree `/Users/jacobdang/Projects/linkC/.worktrees/table-design`, branch `feat/table-design`. Never edit, build or run git in `/Users/jacobdang/Projects/linkC` itself or in any other `.worktrees` folder. Other agents work there.
- **Test first:** write the test, add a stub so it compiles, see it fail on an assertion (never a compile error), implement, see it pass. Copy the red and green lines into your report.
- **Fail loud:** refuse bad input with `LinkCError.parse("…")` naming what's wrong. Never swallow an error or quietly drop input. Anything the SQL reader doesn't keep goes into `skipped` or `notModelled`.
- **Determinism:** the same input always gives the same output. There's no locale-dependent casing: use `lowercased()` and `uppercased()` on ASCII input only.
- **Build:** `swift build 2>&1 | tail -1`. `swift build --build-tests 2>&1 | grep -E "warning:"` must print nothing.
- **Suite:** `swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1` must report 0 failures after every task. Main is at 1478 tests.
- **Existing behaviour:** `BoardMapTests.testEncodedMatchesTheGoldenBytesExactly` and every other existing test must stay green. A board file with no `columns` must encode byte for byte as before.
- **Commits:**
  - one per task, with the message the task gives;
  - stage files by name, never `git add -A` or `git add .`;
  - **no trailers of any kind:** no Co-Authored-By, no "Generated with", no session links;
  - the word "claude" never appears in a message, in any case;
  - never push, merge or rebase.
- **Clean finish:** no scratch files, debug prints or commented-out code. `git status --short` is empty when you finish.

---

### Task 1: `BoardColumn`, and `columns` in the board file

**Files:**
- Create: `Sources/LinkCKit/Board/BoardColumn.swift`
- Modify: `Sources/LinkCKit/Board/BoardMap.swift`. It adds the `columns` field on `BoardComponent` and its init. It also covers decoding in `decodeVersionTwo`, plus `componentKeys` and `versionOneComponentKeys`, and encoding in `rootObject()`.
- Test: create `Tests/LinkCKitTests/BoardColumnTests.swift`

**Produces (later tasks and phase B rely on these exact names):**

```swift
public struct BoardColumnReference: Equatable, Hashable, Sendable {
    public var table: String
    public var column: String
    public init(table: String, column: String)
    /// "table.column", split at the LAST "." — so "auth.users.id" is table "auth.users", column
    /// "id". nil when there is no "." or either side is empty.
    public init?(parsing text: String)
    /// "table.column".
    public var text: String { get }
}

public struct BoardColumn: Equatable, Sendable {
    public var name: String
    public var type: String
    public var pk: Bool
    public var nullable: Bool
    public var unique: Bool
    public var defaultValue: String?
    public var references: BoardColumnReference?
    public var planned: Bool
    /// A primary key is never nullable: `nullable` is stored false whenever `pk` is true.
    public init(name: String, type: String, pk: Bool = false, nullable: Bool = true, unique: Bool = false,
                defaultValue: String? = nil, references: BoardColumnReference? = nil, planned: Bool = false)
}
```

`BoardComponent` gains `public var columns: [BoardColumn]`. It is added as the last init parameter, `columns: [BoardColumn] = []`, so every existing call site keeps compiling.

**The file format** (spec §1): a component's object may carry `"columns"`, a list of column objects.

- **Reading:**
  - `"columns"` must be a list of objects, or it's refused.
  - Each column object's keys:
    - `name` (text, required, not empty after trimming);
    - `type` (text, required, not empty after trimming);
    - `pk` (true/false);
    - `nullable` (true/false);
    - `unique` (true/false);
    - `default` (text);
    - `references` (text, parsed with `BoardColumnReference(parsing:)`);
    - `status` (only `"planned"`, with the same rule and message as a component's status).
  - Any other key is refused.
  - A duplicate column name within one component (ignoring case) is refused.
  - A column with `"pk": true` and `"nullable": true` is refused.
  - Reuse the existing `string`, `bool` and `plannedStatus` helpers so type errors read like the rest of the file's errors.
- **Writing:**
  - `columns` is written only when not empty, as a list of objects in column order;
  - `name` and `type` are always written;
  - `pk: true` only when true;
  - `nullable: false` only when the column isn't nullable and isn't a primary key;
  - `unique: true` only when true;
  - `default` when set;
  - `references` as `text` when set;
  - `status: "planned"` when planned.
  - `BoardMapJSON` already sorts the keys inside each object; leave it alone.
- **Refusal messages:** each includes the component's context string (`component "<name>" in system-map.json`) and:

  | case | message contains |
  |---|---|
  | `columns` isn't a list of objects | `has "columns" but it is not a list of objects` |
  | no name | `has a column with no "name"` |
  | no type | `column "<name>" has no "type"` |
  | duplicate | `names column "<name>" twice` |
  | bad reference | `column "<name>" has "references" "<text>" but it is not table.column` |
  | pk + nullable true | `column "<name>" is a primary key, so it can't be nullable` |
  | unknown key | `column "<name>" has an unknown key "<key>"` |

- [ ] **Step 1: Write the failing tests.** Create `Tests/LinkCKitTests/BoardColumnTests.swift`:

```swift
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

    /// Only what differs from a plain nullable column is written: a primary key never writes
    /// "nullable", and a plain column writes only its name and type.
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
}
```

- [ ] **Step 2: Stub.** Add `BoardColumn.swift` with the types above. `init?(parsing:)` returns nil, and `text` returns `""`. Add `columns` to `BoardComponent`, always `[]`: nothing is decoded or encoded yet. Run `swift test --filter BoardColumnTests` and confirm it fails on assertions.
- [ ] **Step 3: Implement** the reference parsing, the decoding and the encoding described above.
- [ ] **Step 4: Run** `swift test --filter "BoardColumnTests|BoardMapTests"` and see it pass. Then run the full suite and the warnings check.
- [ ] **Step 5: Commit.** Message: `feat(board): a table's columns live in the board file`

---

### Task 2: Reading SQL, `SQLSchema.parse`

**Files:**
- Create:
  - `Sources/LinkCKit/SQL/SQLSchema.swift`: the public types and `quotedIfNeeded`;
  - `Sources/LinkCKit/SQL/SQLTokenizer.swift` (internal);
  - `Sources/LinkCKit/SQL/SQLSchemaParser.swift` (internal).
- Test: create `Tests/LinkCKitTests/SQLSchemaParseTests.swift`.

**Consumes:** `BoardColumn`, `BoardColumnReference` (Task 1).

**Produces:**

```swift
public enum SQLSchema {
    public struct Table: Equatable, Sendable {
        public var name: String
        public var columns: [BoardColumn]
        public init(name: String, columns: [BoardColumn])
    }
    /// Something in the SQL that wasn't kept, and the line it starts on (1-based).
    public struct Note: Equatable, Sendable {
        public var line: Int
        public var text: String
        public init(line: Int, text: String)
    }
    public struct Parsed: Equatable, Sendable {
        /// In the order their CREATE TABLE statements appear.
        public var tables: [Table]
        /// Whole statements (or ALTER TABLE actions) that were read past.
        public var skipped: [Note]
        /// Clauses inside a table that aren't kept.
        public var notModelled: [Note]
    }
    public static func parse(_ sql: String) throws -> Parsed
    /// `name` bare when it's a plain lowercase identifier (`^[a-z_][a-z0-9_]*$`) and not a reserved
    /// word; otherwise in double quotes, with any `"` inside doubled.
    public static func quotedIfNeeded(_ name: String) -> String
}
```

**The reserved words** for `quotedIfNeeded`. Put this set in `SQLSchema.swift` verbatim:
`all analyse analyze and any array as asc asymmetric both case cast check collate column constraint create current_catalog current_date current_role current_time current_timestamp current_user default deferrable desc distinct do else end except false fetch for foreign from grant group having in initially intersect into lateral leading limit localtime localtimestamp not null offset on only or order placing primary references returning select session_user some symmetric table then to trailing true union unique user using variadic when where window with`

**The tokenizer:**
- **Tokens:** each token records the line (1-based) of its first character, and its exact source text.
  - **word:** `[A-Za-z_][A-Za-z0-9_$]*`;
  - **quoted name:** `"…"`, where `""` inside means one `"`; its value is unescaped;
  - **string:** its whole source text, quotes included, in three forms:
    - `'…'`, where `''` inside means one `'`;
    - `E'…'` or `e'…'`, where a backslash escapes the next character;
    - `$tag$…$tag$`, where the tag is empty or `[A-Za-z_][A-Za-z0-9_]*`;
  - **number:** `[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?`;
  - **punctuation:** `::` as one token, and `(` `)` `,` `;` `.` `[` `]`;
  - **operator:** a run of `+ - * / < > = ~ ! @ # % ^ & | ` ?`. The run stops before a `--` or `/*`;
  - any other single character is a one-character token.
- **Skipped:** whitespace; `--` to the end of the line; `/* … */`, which nests.
- **Errors:**
  - an unterminated string or dollar quote gives `line N: a quoted string never ends`;
  - an unterminated quoted name gives `line N: a quoted name never ends`;
  - an unterminated block comment gives `line N: a comment never ends`.

  N is the line where the construct starts.

**Statements:** split the tokens at `;` and ignore empty statements. A trailing statement without a `;` still counts. Then, for each statement:

1. **`CREATE [UNLOGGED] TABLE [IF NOT EXISTS] <name> ( … )`** is a table.
   - A CREATE TABLE whose name isn't followed by `(` (`AS …`, `PARTITION OF …`) is skipped.
   - A table created twice is refused: `line N: table <name> is created twice`.
   - If the column list never closes: `line N: table <name>'s column list never closes`, with N the line of `CREATE`.
2. **`ALTER TABLE [ONLY] [IF EXISTS] <name> <action>[, <action>…]`**
   - On a table not created earlier in this SQL, the whole statement is skipped. Its note text is `ALTER TABLE <name>`.
   - Otherwise each action is applied, or skipped (§ below).
3. **Anything else** is skipped.

**Names:**
- A name is `part[.part]`. A word part is lowercased; a quoted part keeps its value exactly.
- A two-part name whose first part is `public` drops it (`"public"."entries"` → `entries`). Any other schema stays, joined by `.` (`"auth"."users"` → `auth.users`).
- Column names are one part, lowercased when unquoted.

**Rendering a type or a default** from its tokens, so the stored text is canonical:
- **words:** lowercased;
- **quoted names:** passed through `quotedIfNeeded` (`"uuid"` → `uuid`, `"Users"` stays `"Users"`);
- **strings and numbers:** their source text;
- **`public` schemas:** a `public` (word or quoted) followed by `.` drops both tokens;
- **spacing:**
  - no space before `(` when the previous token is a word, a quoted name, `]`, `)`, `(`, `::` or `.`, and no space when `(` is the first token;
  - no space after `(`, `[`, `::` or `.`;
  - no space before `)`, `]`, `,`, `[`, `::` or `.`;
  - one space after `,`;
  - one space between any other two tokens.
- **Examples:**
  - `"gen_random_uuid"()` → `gen_random_uuid()`
  - `'active'::"text"` → `'active'::text`
  - `character varying(40)` → `character varying(40)`
  - `timestamp with time zone` → `timestamp with time zone`
  - `"public"."mood"` → `mood`
  - `numeric(10,2)` → `numeric(10, 2)`
  - `text[]` → `text[]`

**Inside `( … )`:** split the elements at `,` at bracket depth 0. An empty element is refused: `line N: table <name> has an empty column entry`, where N is the line of the second comma.
- **A table constraint** starts with an unquoted `CONSTRAINT`, `PRIMARY`, `FOREIGN`, `UNIQUE`, `CHECK`, `EXCLUDE` or `LIKE`. `CONSTRAINT <n>` is skipped first.
  - `PRIMARY KEY (a[, b…])`: each named column gets `pk = true` and `nullable = false`.
  - `FOREIGN KEY (a) REFERENCES t [(c)] …`: one column gets its reference (§ references). With more than one column, it's not modelled: `FOREIGN KEY (a, b) on <table>`.
  - `UNIQUE (a)`: `unique = true`. With more than one column, it's not modelled: `UNIQUE (a, b) on <table>`. Column names in these notes are joined with `, `.
  - `CHECK …`, `EXCLUDE …` and `LIKE …` aren't modelled: `CHECK on <table>`, `EXCLUDE on <table>`, `LIKE on <table>`.
  - A constraint naming a column the table doesn't have is refused: `line N: table <table> has no column <column>`.
- **A column** is `<name> <type…> <constraints…>`.
  - The type is every token up to the first unquoted column-constraint keyword at depth 0 (`CONSTRAINT NOT NULL PRIMARY UNIQUE DEFAULT REFERENCES CHECK COLLATE GENERATED`), or up to the end. An empty type is refused: `line N: column <name> has no type`.
  - The constraints, in any order and repeatable:
    - `CONSTRAINT <n>` is skipped;
    - `NOT NULL` sets `nullable = false`, and `NULL` sets `nullable = true`;
    - `PRIMARY KEY` sets `pk = true` and `nullable = false`;
    - `UNIQUE` sets `unique = true`;
    - `DEFAULT <expr>`:
      - the expression runs up to the next unquoted column-constraint keyword at depth 0 (as listed for the type), or the end, and is rendered as above;
      - `DEFAULT NULL` means no default;
    - `REFERENCES t [(c)]` sets the reference (§ references). Consume the whole clause, so its words are never read as column constraints:
      - `MATCH FULL|PARTIAL|SIMPLE`;
      - `ON DELETE|UPDATE` followed by `CASCADE`, `RESTRICT`, `NO ACTION`, `SET NULL [(…)]` or `SET DEFAULT [(…)]`;
      - `DEFERRABLE` or `NOT DEFERRABLE`;
      - `INITIALLY DEFERRED|IMMEDIATE`;
    - `CHECK (…)` isn't modelled: `CHECK on <table>.<column>`;
    - `GENERATED …` runs up to the next column-constraint keyword at depth 0 or the end, and isn't modelled: `GENERATED on <table>.<column>`;
    - `COLLATE <name>` is skipped, and no note is written.
  - A duplicate column name in one table is refused: `line N: table <table> names column <name> twice`.
- **ALTER TABLE actions:**
  - `ADD [CONSTRAINT n] PRIMARY KEY | FOREIGN KEY | UNIQUE | CHECK | EXCLUDE …`: the same as a table constraint.
  - `ADD [COLUMN] [IF NOT EXISTS] <column>`: appends a column.
    - With `IF NOT EXISTS`, adding a column that already exists changes nothing.
    - Without it: `line N: table <table> already has column <name>`.
  - `ALTER [COLUMN] <c>` followed by one of:
    - `SET DEFAULT <expr>`;
    - `DROP DEFAULT`;
    - `SET NOT NULL`;
    - `DROP NOT NULL` (this sets `nullable = true` unless the column is a primary key).

    An unknown column is refused: `line N: table <table> has no column <c>`.
  - Any other action is skipped, with the note text `ALTER TABLE <table> <FIRST ACTION WORD, uppercased>` (e.g. `ALTER TABLE entries OWNER`), at the line of the action's first token.
- **References:**
  - `REFERENCES t (c)` gives `BoardColumnReference(table: t, column: c)`, with names as in § Names.
  - `REFERENCES t` with no column is settled after every statement is read:
    - if `t` was created in this SQL with exactly one primary-key column, that column is used;
    - otherwise it isn't modelled: `REFERENCES <t> on <table>.<column> names no column, and <t> has no single primary key here`, at the line of `REFERENCES`.
- **A skipped statement's note text** is its first word, uppercased, then its second token, uppercased, when that is a word. After a leading `CREATE`, the words `OR REPLACE` are passed over first. Examples:
  - `CREATE OR REPLACE FUNCTION …` → `CREATE FUNCTION`;
  - `SET statement_timeout = 0` → `SET STATEMENT_TIMEOUT`;
  - `GRANT ALL ON …` → `GRANT ALL`;
  - `CREATE POLICY "x" …` → `CREATE POLICY`.

  The note's line is the statement's first token's line.

- [ ] **Step 1: Write the failing tests.** Create `Tests/LinkCKitTests/SQLSchemaParseTests.swift`:

```swift
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
```

Line numbers count from the first line inside the `"""` literal, as Swift strips the indentation. Before implementing, check each expected line in `testADumpReportsWhatItSkippedAndDidNotModel` and `testAMigrationReadsInlineKeysAndAlterations` against the literal. If one is off, fix the number in the test and note it in your report. Never change the SQL.

- [ ] **Step 2: Stub.** Add the public types, a `parse` that returns an empty `Parsed`, and a `quotedIfNeeded` that returns its input. Run `swift test --filter SQLSchemaParseTests` and confirm it fails on assertions.
- [ ] **Step 3: Implement** the tokenizer, then the parser, following the rules above. Keep the tokenizer and the parser internal (not `public`). No regular-expression engine is needed: scan characters and tokens directly.
- [ ] **Step 4: Run** `swift test --filter SQLSchemaParseTests` and see it pass. Then run the full suite and the warnings check.
- [ ] **Step 5: Commit.** Message: `feat(sql): read Postgres CREATE TABLE SQL into tables, reporting what isn't kept`

---

### Task 3: Writing SQL, `SQLSchema.createStatements`

**Files:**
- Create: `Sources/LinkCKit/SQL/SQLSchemaWriter.swift` (internal), with `SQLSchema.createStatements(for:)` as a public static function (in an extension there, or in `SQLSchema.swift`).
- Test: create `Tests/LinkCKitTests/SQLSchemaWriteTests.swift`

**Consumes:** `SQLSchema.Table`, `SQLSchema.quotedIfNeeded`, `SQLSchema.parse` (Task 2), and `BoardColumn` (Task 1).

**Produces:** `public static func createStatements(for tables: [SQLSchema.Table]) -> String`

**Rules:**
- **Order.** Emit tables in rounds:
  - Each round emits the ready table with the smallest name, lowercased. A table is ready once every table it references, among the given tables, has been emitted. A self-reference, or a reference to a table that isn't given, never blocks.
  - If nothing is ready, it's a cycle. Emit the smallest-named remaining table, and leave out each of its references to a table not yet emitted. Those become `ALTER TABLE` statements after all the CREATE TABLEs, in emission order, then column order.
- **A table:**
  ```
  CREATE TABLE <table> (
    <column>,
    …
    [PRIMARY KEY (<a>, <b>)]
  );
  ```
  Each element sits on its own line with 2-space indentation. The last line is the composite primary key, present only when more than one column is a primary key.
- **A column:**
  - the parts, in this order: `<name> <type>`, then ` PRIMARY KEY` (only when it's the table's single primary-key column), ` NOT NULL` (only when not nullable and not a primary key), ` UNIQUE`, ` DEFAULT <default>`, ` REFERENCES <table> (<column>)`;
  - the type and the default are written verbatim;
  - a planned column is written like any other.
- **A deferred key:** `ALTER TABLE <table> ADD FOREIGN KEY (<column>) REFERENCES <table> (<column>);`
- **Names:**
  - A column name goes through `quotedIfNeeded`.
  - A table name is split at its first `.`. If both parts are non-empty, each part goes through `quotedIfNeeded` and they're joined with `.`. Otherwise the whole name goes through `quotedIfNeeded`.
  - References follow the same rules.
- **Layout:** statements are separated by one blank line, and the text ends with exactly one `\n`. An empty list of tables gives `""`.

- [ ] **Step 1: Write the failing tests.** Create `Tests/LinkCKitTests/SQLSchemaWriteTests.swift`:

```swift
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
```

- [ ] **Step 2: Stub.** `createStatements` returns `""`. Run `swift test --filter SQLSchemaWriteTests` and confirm it fails on assertions. `testNothingToWriteIsEmpty` passes on the stub, which is expected.
- [ ] **Step 3: Implement** the rules above.
- [ ] **Step 4: Run** `swift test --filter "SQLSchemaWriteTests|SQLSchemaParseTests"` and see it pass. Then run the full suite and the warnings check.
- [ ] **Step 5: Commit.** Message: `feat(sql): write tables as CREATE TABLE SQL in foreign-key order`

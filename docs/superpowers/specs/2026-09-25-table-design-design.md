# Table design: an ER diagram inside a database's detail board

Jacob, 2026-09-25: "for databases, i would like the option for table design, i feel like that would be super useful."

**His decisions:**
- **Where it lives:** inside the database. Going deeper into a database part opens its schema as that part's detail board. This builds on Board drill-down.
- **Import and export:** SQL both ways. A `.sql` file or a Supabase schema dump comes in, and CREATE TABLE SQL goes out.
- **The rest:** he approved everything below.

Codex builds the LinkCKit half. The app half follows once Board drill-down is in.

## 1 · The data

- **A new kind, `table`.** It belongs to the System group and is drawn as a table box (§2). Any board can hold tables. They're meant for a database's detail board, where the services that use the database show as ghost neighbours at the edges.
- **Columns.** A table carries an ordered `columns` list in its board file entry. Each column is an object:

  | key | value | written |
  |---|---|---|
  | `name` | text, unique in its table (ignoring case) | always |
  | `type` | SQL type text, kept verbatim: `uuid`, `character varying(255)`, `timestamp with time zone`, `numeric(10,2)`, `text[]` | always |
  | `pk` | `true` for a primary-key column | only when true |
  | `nullable` | `false` for NOT NULL | only when false, and never for a primary key, which is never nullable |
  | `unique` | `true` for a single-column UNIQUE | only when true |
  | `default` | the default expression's SQL text, e.g. `now()`, `'active'::text` | only when set |
  | `references` | `"table.column"`, split at the last `.` so `auth.users.id` works | only when set |
  | `status` | `"planned"`: in the design, not yet in the database | only when planned |

  - An unknown key, a missing name or type, a duplicate name, a malformed `references`, or a primary key marked `nullable: true` is refused with a reason, like other bad board entries.
  - A file with no `columns` encodes byte for byte as it does today.
- **Foreign keys aren't stored twice.** A table's foreign-key lines come from its columns' `references`, never from `uses`. A service's arrow to a table stays an ordinary `uses` arrow.
- **Table names:** a table in Postgres's `public` schema is named without the schema (`users`). Any other schema keeps it (`auth.users`). References and types follow the same rule.

## 2 · How it looks (app half)

- **The table box:** a header with the table's name, then one row per column. A row shows:
  - a key mark, 🔑 for a primary key and 🔗 for a foreign key;
  - the column's name;
  - its type, dimmed and right-aligned.

  Nullable columns draw fainter, and planned tables and columns draw the way planned parts do today.
- **Foreign-key lines** run from the foreign-key column's row to the referenced column's row. A reference to a table or column that isn't on the board draws as a short stub with the reference's text.
- **Box size depends on the part.** Today every box is 176×84. A table box is as tall as its columns and as wide as its longest row allows, so layout, routing, pills and hit-testing all take their size from the part.

## 3 · Editing

- **In the app:** a pinned table's inspector turns its columns into an editable grid. You can add, remove and reorder columns, and set each one's name, type (common Postgres types are suggested), primary key, nullable, unique, default, and reference (picked from the board's tables and columns). A column added to a table that isn't planned is planned, until an import finds it in the database.
- **For agents:** `add` and `update` accept `columns` (the whole list). A new step, `{"op": "column", "table": "<name>", "column": "<name>", …}`, adds, changes (`set`) or drops (`drop: true`) one column. `columns` or a `column` step on a part that isn't a table is refused with the step's number.

## 4 · Import and export

- **Reading SQL (LinkCKit, pure).** It reads Postgres's CREATE TABLE subset, the way `pg_dump` and hand-written migrations write it:
  - Statements handled:
    - `CREATE [UNLOGGED] TABLE [IF NOT EXISTS] name (…)`;
    - `ALTER TABLE [ONLY] [IF EXISTS] name`, followed by `ADD [CONSTRAINT n] PRIMARY KEY | FOREIGN KEY | UNIQUE`, `ADD [COLUMN] [IF NOT EXISTS] <column>` or `ALTER [COLUMN] c SET DEFAULT expr`.
  - Clauses kept:
    - column types;
    - NOT NULL / NULL;
    - PRIMARY KEY, both on a column and table-level (composite too);
    - single-column UNIQUE;
    - DEFAULT;
    - REFERENCES and FOREIGN KEY, with or without the referenced column (without it, the referenced table's single primary key is used).
  - Parsing rules: comments, quoted identifiers, and single-, `E'…'`- and dollar-quoted strings parse correctly. Unquoted names are lowercased, as Postgres does.
  - What isn't kept is reported, not hidden:
    - every other statement (functions, policies, grants, `OWNER TO`, and so on) is listed as *skipped*;
    - clauses inside a table that aren't kept (CHECK, a composite UNIQUE, EXCLUDE, GENERATED, and so on) are listed as *not modelled*.
  - A CREATE TABLE that can't be read is an error that names its line.
- **Writing SQL (LinkCKit, pure):**
  - Output is CREATE TABLE statements in foreign-key order: a table comes after the tables it references, and ties go by name.
  - Tables in a reference cycle are created in name order. The foreign keys that point forward are added afterwards with `ALTER TABLE … ADD FOREIGN KEY`.
  - Identifiers are quoted only when they need it.
  - Reading back what was written gives the same tables.
- **Import into the board (LinkCKit):**
  - The result of reading SQL becomes one ordinary board edit, so it's one undo step and goes through the Board's own placement.
  - Tables and columns in the SQL are added or updated, and lose `planned`.
  - A table or column that's only in the design stays, marked planned. Nothing is deleted.
- **Import sources (app half):**
  - a `.sql` file you pick;
  - **Supabase:** linkC runs your own `supabase db dump --schema-only` in the project folder through your login shell, and reads its output. linkC never holds database credentials. If the command fails, its error is shown.
- **Export (app half):** the tables of the current board as SQL, to the clipboard or to a migration file you choose. linkC never runs SQL against your database.

## 5 · Pieces

- **LinkCKit, phase A (Codex, now):**
  - `BoardColumn` and `BoardColumnReference`: the column model, and `columns` on `BoardComponent`, read and written in the board file (§1).
  - `SQLSchema.parse(_:) throws -> SQLSchema.Parsed`: the tables read, plus `skipped` and `notModelled`.
  - `SQLSchema.createStatements(for:) -> String`: writing SQL (§4).
- **LinkCKit, phase B (after Board drill-down phase 1 merges; it touches the same files):**
  - `ComponentKind.table`;
  - box size from the part;
  - foreign-key routes from `references`;
  - the edit steps (§3);
  - the import merge as a board edit;
  - the Supabase dump runner, behind the process seam.
- **App:**
  - the table box and its rows;
  - foreign-key lines between rows;
  - the column grid in the inspector;
  - the Import SQL… and Export SQL… menus.

## 6 · Testing (test-first, LinkCKit)

- **Columns in the file:**
  - a round trip;
  - a file without `columns` stays byte for byte the same;
  - each refusal in §1, with its reason.
- **Reading SQL:**
  - a `pg_dump`-style schema, where tables are created first and keys are added by `ALTER TABLE`;
  - a hand-written migration with inline keys;
  - composite primary keys;
  - a reference that doesn't name its column;
  - quoted and schema-qualified names;
  - dollar-quoted function bodies containing `;`;
  - comments;
  - what's skipped and what's not modelled;
  - an unreadable CREATE TABLE naming its line.
- **Writing SQL:**
  - foreign-key order;
  - a reference cycle;
  - quoting;
  - a composite primary key;
  - reading back what was written gives the same tables.

**Checked by hand (after the app half):**
- import June's Supabase schema;
- edit a column;
- export, and diff the result against the dump.

## Out of scope

- Running SQL against a database.
- Indexes, views, enums' values, RLS policies and triggers (these are skipped and reported).
- Composite UNIQUE and composite foreign keys, beyond reporting them as not modelled.
- Databases other than Postgres.

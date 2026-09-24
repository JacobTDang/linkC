# Agents on the Board: MCP tools and a live Board

Jacob, after the Project Board shipped: "what about the MCP tooling, to allow Claude or any other
agents to use this". And: "make sure it's simple and easy to use so agents can design along with
the user and the experience is seamless."

Before this change, agents could only *read* the map. They could use `linkc_get_project_context`'s
System section, or `cat system-map.json`. An agent that hand-edited the JSON left the open Board
stale, and the user's next edit hit the "changed on disk" lock.

This spec adds two MCP tools to linkC's server, which every agent it hosts already has (Claude,
Codex, Cursor, Antigravity). It also makes the open Board follow its file live.

Decisions Jacob made:
- read **and** edit;
- **file-first**: the tools edit `system-map.json`, and the Board follows the file;
- edits are a **list of steps**.

## 1 · The tools

Both act on the calling session's own project: the workspace the MCP server was started for, as
`linkc_get_project_context` does. There is no `project` argument.

### `linkc_get_board`

Returns the project's architecture: the file's `version`, `system`, `places` and `notes`, as exact
JSON (the file without `layout`). It is followed by one line naming the edit tool's verbs and the
known kinds:
- service
- database
- cache
- queue
- storage
- host
- external

Any other kind is kept verbatim and drawn as a service.

With no map, it says: "This project has no map yet — `linkc_edit_board` creates one."

An unreadable map is refused with the parse error, escaped as the project report escapes it.

### `linkc_edit_board`

Takes `steps`, 1–50 of them, applied in order. **All or nothing**: if any step is refused, nothing
is written.

| Step | Does |
|---|---|
| `{ "add": "redis", "kind": "cache", "in": "Local docker", "does": "…", "reached_by": "…", "runs": "…", "planned": true }` | Adds a component. Only `add` is required. `kind` defaults to `service`; with no `in`, the component is Not placed. |
| `{ "update": "api", "kind"?, "does"?, "reached_by"?, "runs"?, "planned"?, "in"?, "rename"? }` | Changes the fields given. `in` moves the component to that place. `rename` renames it, and arrows follow. `does`, `reached_by` or `runs` given as `""` clears that field; an empty `kind` is refused. |
| `{ "remove": "redis" }` | Deletes the component and every arrow to or from it. |
| `{ "connect": "api", "to": "redis", "label": "session cache" }` | Adds the arrow, or relabels it if it exists. `label` is optional. |
| `{ "disconnect": "api", "to": "redis" }` | Removes the arrow. |
| `{ "place": "Local docker" }` | Adds a frame. |
| `{ "place": "Local docker", "rename": "Docker" }` | Renames a frame; its components move with it. |
| `{ "remove_place": "Local docker" }` | Removes a frame. Its components become Not placed and stay where they are, as on the Board. |
| `{ "note": "…" }` | Adds a sticky note. |
| `{ "remove_note": "…" }` | Removes the note with exactly that text. |
| `{ "system": "…" }` | Sets the one-line summary (`""` clears it). |

**Rules.** These are the Board's own rules, shared, not copied:
- Names and labels are trimmed and must not be empty.
- Component names are unique, and so are place labels.
- `"Not placed"` is reserved.
- There are no arrows from a component to itself.
- Names, places and arrow ends match regardless of case.
- `in` must name an existing place, or one created earlier in the same call. A typo can never
  create a second frame.
- A step that has the wrong type for a known field is refused, as is an unknown verb, or a step
  that names two verbs.

**Refusals** stop the call and name the step, the reason, and the names that exist:
`step 2: no component "apii" — components: api, postgres, redis`.

**Layout is automatic, through the Board's placement code:**
- A component added to, or moved into, a place lands inside that frame at the nearest free spot.
  If the frame is full, it grows, as "Add what's running" grows Local docker.
- A Not-placed component, and a new frame, go to the right of everything already on the Board.
- Nothing ever overlaps.

Agents never set coordinates.

**The reply** gives one line per step, then "Board updated.". For example:

```
added redis (planned) in Local docker
api → redis "session cache"
added a note
Board updated.
```

**Races.** If the file changed between the tool's read and its write, the tool re-reads and
re-applies its steps once; the steps are by name. If that also collides, it fails loud with the
reason. No map yet → the first successful call creates the file.

**Telling agents.**
- The edit tool's description says: when you add or change infrastructure (a service, database,
  cache, queue, host…), reflect it on the project's Board.
- The System section of `linkc_get_project_context` gains one line: "Read with `linkc_get_board`;
  change with `linkc_edit_board`."

**One implementation.** `BoardEdit.apply(_ steps: [BoardEditStep], to map: BoardMap) throws -> BoardMap`
lives in LinkCKit. It is pure and reuses `BoardModel`'s placement and rule helpers, so the Board
and the tools cannot drift. The MCP tool:
1. decodes the steps;
2. loads the map;
3. applies the steps;
4. saves, expecting the bytes it read.

## 2 · The live Board

**Watching.** While a Board is open, linkC watches its project folder for `system-map.json`
changing. The store writes atomically, by rename, so the folder is watched rather than the file.
- The watch is event-driven, with no polling.
- It exists only while that Board is visible.
- A change is confirmed by reading the file's bytes. Bytes equal to what the Board last read or
  wrote are the Board's own write, and are ignored.

**Taking an outside change:**
- **Nothing pending on the Board:** the new map is taken. The map it replaces becomes **one undo
  step**: ⌘Z restores it and writes it back, which undoes the agent's whole change; redo reapplies
  it. Anything without a position is laid out as on load.
- **An edit pending on the Board** (not yet written; the Board writes 600 ms after the last edit):
  the two versions merge **element by element**. The inputs are:
  - base: what the Board last read or wrote;
  - theirs: the file;
  - mine: the Board.

  Each component, component field, arrow, frame, note and position comes from the side that
  changed it. If both changed the same thing, **mine wins**. A deletion counts as a change. The
  merged map is written once, as one undo step.
- **An unreadable file** (e.g. git conflict markers): the Board locks and says why, as today. When the file becomes readable again, the Board takes it as a fresh load, with undo cleared.

**Saves stop locking.** A save that finds the file changed since the Board last read it merges,
by the same rule, instead of refusing. The "changed on disk → Reload" state remains only for a file
that can't be read.

A save that collides again straight after merging, with a file that keeps changing under it, falls back to the existing lock with Reload, as a last resort.

This supersedes the Project Board spec's rule that such a save is refused and the Board locked
until reload.

**Glow.** Elements the outside change added or changed get a soft accent outline that fades over
about 2 seconds. It is one short animation per change, with no idle cost.

**Not only MCP.** A `git pull`, or an agent hand-editing the JSON, take the same path.

## 3 · Testing (LinkCKit, TDD)

- **`BoardEditTests`:**
  - each verb's effect, and its refusal, with the message listing existing names;
  - all or nothing: a bad step 3 leaves the map untouched;
  - placement: inside the named frame, the frame growing when full, never overlapping, Not-placed
    and new frames to the right;
  - renames carry arrows;
  - case-insensitive matching;
  - `in` naming a place created earlier in the same call;
  - the step cap;
  - malformed steps.
- **`BoardMergeTests`:** a table of cases:
  - only theirs changed;
  - only mine changed;
  - both changed different elements;
  - both changed the same element (mine wins);
  - a deletion on either side against an edit on the other;
  - positions;
  - notes;
  - arrows.
- **`BoardModel` outside-change tests,** driven through a seam (a method the watcher calls with new
  bytes):
  - its own write is ignored;
  - an outside change is taken as one undo step, and undo writes the old map back;
  - an outside change with an edit pending merges;
  - a save that finds the file changed merges instead of locking;
  - an unreadable file locks.
- **MCP tests,** on a temporary project:
  - `linkc_get_board` with no map, a map, and an unreadable map;
  - `linkc_edit_board` creating the file;
  - a refused call writes nothing;
  - the re-read-once retry;
  - the project context line.

The folder watcher itself is a thin wrapper over a dispatch source. It is checked by hand: an agent
edit shows on the open Board within a moment.

## Out of scope

- Free text labels on the canvas (decoration), and positions: agents never set coordinates.
- Showing which agent made a change.
- Undo history across launches.

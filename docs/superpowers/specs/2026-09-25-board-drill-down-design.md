# Board drill-down: an overview and detail boards

Jacob, 2026-09-25: "I would like to be able to … create multiple boards in a project … I'm working on June right now. I need to see multiple different designs … a general view one, and then also another one where I can go deeper into a component that I want to customize."

**His decisions:**
- **Model:** overview + drill-down, where any part can open its own detail board, and detail boards nest.
- **A detail board's context:** ghost neighbours at the edges (mockup `drill-down.html`, option A, in `.superpowers/brainstorm/16187-1790352036/content/`).
- **The rest:** he approved everything below.

This builds on Board inspect (hover cards, the docked inspector, lenses), which must merge first. Antigravity implements it on Gemini 3.8 Flash (the standard tier).

## 1 · Files and links

- **The overview board** stays `system-map.json` at the project root. Nothing about it changes for projects that never go deeper.
- **Each detail board** is a sibling file, `system-map.<slug>.json`.
  - A slug is the chain of part names from the overview, each turned into lowercase words joined by `-`, with the parts joined by `.`. For example, `audio-engine` for "Audio engine" on the overview, and `audio-engine.mixer` for "Mixer" inside it.
  - Characters other than `a-z`, `0-9` and `-` are dropped from each name's slug.
  - When a new slug is already taken by an existing file, a suffix `-2`, `-3`, and so on is added.
- **The link:** a part with a detail board carries `"detail": "<slug>"` in its board file. The link goes by the slug, so renaming the part keeps it.
  - Older linkC builds keep the unknown key, as `BoardComponent.extras` already does.
- **Unlinked detail files:** deleting a part, or its `detail` key, leaves the detail file on disk. linkC keeps stale data. Such a file shows as **unlinked** in the Boards menu, and deleting it is up to the user.
- **The file format:** a detail file uses the same format as `system-map.json` (version 2), plus the ghost entries in §2. Its `system` text is the drilled part's name.

## 2 · Ghost neighbours

- **Storage:** a detail board holds one **ghost** for each overview neighbour of the part it details. A ghost is a component entry marked `"outside": true`. Its name and kind are copied from the neighbour on the parent board.
- **Ghosts from arrows into the part** sit in a column at the left edge of the board. **Ghosts from the part's arrows out** sit in a column at the right edge. Each column is ordered by name, lowercased.
  - Tidy up and the layout keep ghosts in those columns. The user can't drag a ghost.
- **How a ghost draws:**
  - faint, as a transparent fill with a dashed outline;
  - its name, with no sub-line;
  - never a ↳ badge.
- **Read-only:** a ghost's name and kind can't be edited in the inspector, and the inspector says *"From the overview · <parent board name>"*.
- **Wiring:** the user wires ghosts to inner parts with ordinary arrows. The arrows are stored on whichever end is the source, as usual: an arrow from API into Decoder lives on the ghost API. Arrows between two ghosts are refused with a reason.
- **Sync** runs every time a detail board opens (in the app, and through the agent tools):
  - an overview neighbour with no ghost gets one;
  - a ghost whose neighbour no longer exists (or is no longer connected to the detailed part) keeps its entry, with `"stale": true`, and draws with a warning mark. It is never deleted silently; the user removes it;
  - a ghost whose neighbour came back loses `stale`.
  Sync writes the file only if something changed.

## 3 · Moving around

- **Everything happens in the one Board tab of the project:** ⌘1 still opens the overview.
- **The breadcrumb.** At the top left of the Board, it shows the path: *June › Audio engine › Mixer*. Each earlier crumb opens that board, and ⌘↑ goes up one level.
- **The Boards ▾ menu,** next to the breadcrumb:
  - lists every board of the project as an indented tree: the overview first, then each part's detail boards under it, in name order;
  - lists unlinked detail files last, under *Unlinked*.
- **↳ Go deeper,** in the docked inspector for a pinned part, and in the part's context menu:
  - for a part with a detail board, it opens that board;
  - for a part without one, it creates the detail file (with its ghosts synced and nothing else in it), sets the part's `detail`, and opens it. It is one undo step on the parent board.
- **The ↳ badge:** a part that has a detail board shows **↳** at its top right.
- **Per-board view state:** each board remembers its own viewport and lens, keyed by project and slug.

## 4 · Agents

- **`linkc_get_board`** gains an optional `board`: a slug, or `"overview"` (the default). Its output adds a `boards` list: every slug, with its breadcrumb path and whether it is linked. A detail board's output marks ghosts with `outside` and, where it applies, `stale`.
- **`linkc_edit_board`** gains an optional `board`, with the same meaning.
  - The steps apply to that board's file. Editing a ghost's name or kind, or adding an arrow between two ghosts, is refused with the step's number, as other refusals are.
  - A new step, `{"op": "detail", "component": "<name>"}`, works on the current board. It creates the part's detail board if needed (the same slug rule and ghost sync as the app) and reports its slug. A following call with `board: <slug>` then builds the inside.
- **The tool descriptions** name the new parameter and step, and describe ghosts.

## 5 · Pieces

- **LinkCKit, pure and tested:**
  - `BoardSlug`: the slug from a path of part names, with the suffix rule.
  - `BoardGhosts.sync(detail:parentBoard:part:) -> BoardMap?`: the detail map with its ghosts synced (added, marked stale, or un-staled). It returns nil when nothing changed. It also gives the ghosts' layout positions (the left and right columns).
  - `BoardCatalog`: every board file of a project (overview, detail files and unlinked ones), with its path and slug, from the directory listing and the `detail` links.
  - `BoardComponent` gains `detail: String?`, `outside: Bool` and `stale: Bool`. They are encoded only when set, so existing files and diffs don't change.
  - `BoardMapStore` gains `init(workspacePath:board:)` for a slug. The overview keeps the current initializer and file.
  - `BoardEdit`: the `detail` step, and the ghost refusals.
  - The MCP tools: the `board` parameter and the `boards` list.
- **App target:**
  - one `BoardModel` for each (project, slug);
  - the Board pane shows the current board's model;
  - the breadcrumb, the Boards menu and ⌘↑;
  - Go deeper in the inspector and the context menu;
  - the ↳ badge;
  - drawing ghosts, and refusing to drag them.

## 6 · Testing (test-first, LinkCKit)

- **`BoardSlugTests`:** names to slugs (spaces, symbols, case), nested paths, and the suffix when taken.
- **`BoardGhostsTests`:**
  - a first sync adds a ghost for each neighbour, in the left or right column, in name order;
  - a removed neighbour's ghost becomes stale and isn't deleted;
  - a returning neighbour loses stale;
  - no change gives nil;
  - arrows are wired to ghosts and kept through a sync.
- **`BoardCatalogTests`:** the overview plus linked and unlinked detail files from a temp directory; the tree order.
- **`BoardMapTests`:**
  - `detail`, `outside` and `stale` round-trip;
  - a file without them encodes byte for byte the same as today.
- **`BoardEditTests`:**
  - the `detail` step creates the file and link, and reopening it is idempotent;
  - a ghost rename is refused with the step number;
  - an arrow between two ghosts is refused.
- **`MCPServerBoardTests`:** `board` routes to the right file, `boards` is listed, and an unknown slug is refused with a reason.

**Checked by hand on June:**
- go deeper into a part;
- wire ghosts inside;
- rename the part on the overview (the link holds) and remove a neighbour (its ghost goes stale);
- use the breadcrumb, ⌘↑ and the Boards menu;
- have an agent build a detail board.

## Out of scope

- Moving parts between boards.
- Showing a detail board's contents inside the overview (collapsing and expanding in place).
- Links between two detail boards other than through the overview chain.

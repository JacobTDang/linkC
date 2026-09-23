# Project board: a whiteboard tab for each project — design

**Date:** 2026-09-23
**Status:** approved section by section in conversation, with mockups; awaiting written review
**Replaces** the board, the band and the file format of `2026-09-22-project-workbench-design.md`. That spec's reasons stand — a map of each project, in its repository, that any agent can read — and so do its store, its "what's running" discovery and its MCP route. What changes is where the map is drawn, what you can draw, and how the file is laid out.

## Why

Jacob, on the workbench as shipped: "this is not how I imagined it. I want it like a separate entity — a tab on the top like in Chrome, above the terminal. I also want it to be an empty canvas and I can add stuff to it." Then: "put some more work into it", "I would also like to avoid collisions", "I don't want this to consume a lot of power", and "format it in a way where an agent can read and understand the high-level architecture a lot easier."

The shipped version was a strip of grid tiles, hidden behind a hover menu labelled "Blackboard & handoff". This replaces it with a real whiteboard in its own tab.

## 1 · The tab strip

A Chrome-style strip across the top of the right pane, above the terminal, for the project selected in the sidebar:

- **Board** — pinned first, never shrinks, never closes.
- **One tab per session in the project** — agent sessions, then plain terminals, whose folder is the project's, each group in the order it was opened. Each tab carries the agent's colour mark and the session title.
- **＋** — opens the same "add an agent" menu as the sidebar row.

Behaviour:

- The sidebar's project row still expands and collapses. Picking any of its sessions shows that project's strip with that tab selected; the Board is its first tab. (A sidebar Board row shipped first and was removed — see `2026-09-23-panel-polish-design.md`.)
- Whatever was showing last — a session or a project's Board — is what linkC reopens after a relaunch, extending how it already restores the last selected session.
- **✕ stops that session**, through the same path as the sidebar's stop. If the session is mid-turn (working), a confirmation asks first; an idle one closes at once. The Board tab has no ✕.
- **Overflow:** tabs shrink toward a minimum width, then the strip scrolls sideways. The Board tab keeps its width.
- **Keys:** ⌘1 selects the Board; ⌘2–⌘9 select sessions in order; ⌃Tab and ⌃⇧Tab cycle.
- **Narrow panel:** below the width where the sidebar folds away, the strip stays, with the back button to its left.
- The session header strip (title, cost, context bar) stays under the tabs, for the session showing.
- The **SYSTEM band** in the project dashboard sheet is removed, and the sheet goes back to its earlier 600×520.

## 2 · The canvas

An empty, pannable, zoomable canvas with a quiet dot grid. Five kinds of thing go on it.

| Thing | What it is | What it tells agents |
|---|---|---|
| **Component** | A box: database, cache, queue, storage, service, host or external. Name, what it does, how it's reached. | A part of the system. |
| **Arrow** | Drawn from one component to another, with an optional label. | The first uses the second ("api uses postgres — reads and writes entries"). |
| **Frame** | A labelled region: "Local docker", "Oracle box", "Supabase". | Where the components inside it live. |
| **Note** | A sticky note. | A fact or decision every agent should know. |
| **Text** | A heading or label on the canvas. | Nothing — visual only. |

No freehand drawing or free shapes: they are pixels, not facts.

### Components

- Fixed size, 152 × 56. The box shows the kind's glyph, the name, and `reached_by` beneath it.
- **Present** — a solid box. A green dot means linkC sees it running now.
- **Planned** — a dashed outline, so a plan never looks like a fact.
- **Missing** — dimmed: it should be running where linkC can look, and it isn't.
- **Unchecked** — solid with no dot; its tooltip says linkC cannot check it.

### Tools and gestures

A floating toolbar at the bottom centre, each tool with a key:

- **V · Select** (default). Click selects; ⇧-click adds to the selection; dragging empty space draws a selection box; dragging a selected element moves the selection.
- **C · Component** — a small menu picks the kind (the last kind is remembered); click to place.
- **A · Arrow** — drag from one component to another. Arrows can also be drawn in Select mode: hovering a component shows a handle on each side, and dragging from a handle onto another component draws an arrow.
- **F · Frame** — drag out a rectangle; type its label.
- **N · Note** — click to place; type.
- **T · Text** — click to place; type.

Also:

- Double-clicking empty canvas opens a quick-add menu at the pointer: every component kind, a note, a text, a frame.
- **Esc** returns to Select. **⌫** deletes the selection. **⌘Z / ⇧⌘Z** undo and redo, up to 100 steps.
- **Pan:** two-finger scroll, or hold Space and drag. **Zoom:** pinch, or ⌘-scroll, from 25% to 200%. **⇧1** fits everything in view. Zoom and pan are remembered per project, on this Mac only — never in the file.

### Editing

Clicking a component opens a small card beside it:

- **Name**, **kind**, **what it does** (one line), **reached by**, **runs** (free text; used to find it among running containers), and a **still planned** switch.
- **Lives in** — read-only, from the frame the box sits in ("Not placed" outside any frame).
- **Uses** — read-only, from its arrows, with each label.

Other elements are edited in place: a frame's label, a note's text and a text's words by double-clicking them; an arrow's label by double-clicking the arrow.

- Renaming a component carries its arrows, its layout and anything that uses it along with it. Renaming a frame moves its components to the new place name.
- A name, or a frame label, already in use is refused. The card stays open with what you typed and says why.
- Deleting a component deletes its arrows. Deleting a frame keeps its components; they become "Not placed".
- An arrow from a component to itself, or a second arrow between the same two components in the same direction, is refused — editing the existing arrow's label is how that is done.

### Collisions

Nothing ever sits on top of anything:

- **Components, notes and texts never overlap each other.** One dropped where it would overlap slides to the nearest free spot: the smallest move on the 8-point grid, and on a tie, right, then down, then left, then up — so the result is the same every time.
- **Frames never overlap each other.** An element sits either wholly inside a frame or wholly outside it. One dropped across a frame's edge goes inside if its centre is inside, and outside otherwise.
- **Moving a frame carries its components.** A frame cannot be dropped partly over things that are not its own; it slides to the nearest free spot instead.
- **Resizing a frame** cannot shrink it past its own components or grow it over anything else; it stops at the edge.
- **Arrows** leave from the side of each box that faces the other. When a straight path would cross another component or note, the arrow bends around it with an elbow above or below, whichever is shorter. If no simple route exists, it takes the direct path rather than failing.

## 3 · The file

The board saves to `system-map.json` at the project root. Version 2 is written so that, read top to bottom, it *is* the architecture; everything only the board needs sits in one `layout` block at the end.

```json
{
  "version": 2,
  "system": "June — audio journaling: iOS app, api, mp3 server",
  "places": {
    "Local docker": {
      "api": {
        "kind": "service",
        "does": "HTTP api for the iOS app: auth, entries, uploads",
        "reached_by": "API_URL",
        "runs": "docker compose (api)",
        "uses": {
          "postgres": "reads and writes entries",
          "june-audio": "uploads mp3",
          "redis": "session cache"
        }
      },
      "postgres": { "kind": "database", "does": "users and journal entries", "reached_by": "DATABASE_URL" },
      "redis": { "kind": "cache", "status": "planned", "does": "session cache", "reached_by": "REDIS_URL" }
    },
    "Oracle box": {
      "june-audio": { "kind": "host", "does": "stores and serves mp3s", "reached_by": "AUDIO_BASE_URL" }
    },
    "Not placed": {}
  },
  "notes": [
    "Redis is for the session cache — don't add a second one.",
    "Stream uploads to june-audio instead of buffering the whole file."
  ],
  "layout": {
    "components": { "api": [64, 128], "postgres": [232, 128], "redis": [232, 216], "june-audio": [432, 136] },
    "frames": { "Local docker": [40, 96, 344, 200], "Oracle box": [408, 96, 192, 112] },
    "notes": [[640, 112], [640, 248]],
    "texts": [{ "text": "June", "style": "title", "at": [32, 32], "w": 64 }]
  }
}
```

### Fields

- **`system`** — one line saying what the whole project is. Optional; edited in a one-line field pinned to the top left of the Board ("What is this project?" until filled).
- **`places`** — every frame's label, plus `"Not placed"` for components outside any frame. Each maps component names to components. Frame labels are unique. `"Not placed"` is reserved and always present, even when empty, so an agent never wonders where the rest went.
- **A component** — `kind` (the known set, or any other string, kept verbatim and drawn as a service); `does`; `reached_by`; `runs`; `status: "planned"` when it does not exist yet (absent means it exists); `uses`, mapping each component it uses to the arrow's label (`""` when unlabelled). Component names are unique across the whole file.
- **`notes`** — every note's text, in order.
- **`layout`** — positions in points: a component's `[x, y]`; a frame's `[x, y, w, h]`; each note's `[x, y]`, by the same index as `notes`; each text's words, style (`title` or `label`), position and measured width. Every coordinate is snapped to 8.

### Rules

- **One source of truth.** Relationships live only in `uses`; where a component lives only in which place it is listed under. Nothing is stored twice.
- **Round-tripping.** Keys linkC does not know are kept and written back unchanged — at the top level, in a component, and in `layout`.
- **Written only for an edit.** Opening the Board, panning, zooming, selecting or reconciling never writes. The first thing added to a project with no map creates the file.
- **Failing loud.** A file that is not valid JSON, names something twice, or has a known field of the wrong type is refused: the Board shows why and refuses to write until it parses.
- **Changed on disk.** Before writing, linkC checks the file is still what it read. If something else changed it — a `git pull`, a hand edit — the write is refused, the Board says the map changed on disk, and offers to reload. linkC never overwrites a change it has not seen.
- **Readable diffs.** Pretty-printed, sorted keys, coordinates snapped to 8, so moving a box changes one line.
- **Upgrading version 1.** A version-1 file is read and shown; it is written as version 2 on the first edit. Components move under `"Not placed"`; `intended: true` becomes `status: "planned"`; `used_by` becomes `uses` on each user where that user is a component, and names that are not components are kept under `used_by` on the component that listed them; grid cells become points (cell × 160 across, × 64 down).

## 4 · Checking against what's running

This reuses what the workbench built. linkC compares the map against running containers and the compose services of a stack it knows for the project folder — never anything else, never by starting a process.

- A component matches a running thing when, ignoring case, its name equals the container or compose service name, or its `runs` text names it in brackets.
- A component is **checkable** when its `runs`, or the label of the place it lives in, mentions docker or compose. A checkable component with no match is **missing**; one that is not checkable is **unchecked**; a planned one is never missing.
- **"Add what's running"** on an empty board creates a "Local docker" frame and adds each running container inside it, with a kind guessed from its image — so what it adds is checkable at once.
- On a board that already has a map, a chip at the top right says "N running, not on the map". Each can be added with one click, into the "Local docker" frame, creating that frame if needed.
- Reconciling happens when the Board tab opens and when linkC's container list changes. Nothing polls.

## 5 · What agents get

- **Any agent, anywhere:** `cat system-map.json` — committed, in every clone and on every server.
- **linkC-hosted agents:** `linkc_get_project_context` gains a System section rendered from the file as markdown: the `system` line, then each place as a heading with its components beneath — kind, what it does, how it's reached, what it uses (with labels), "planned" when it is — then the notes, word for word. No coordinates, no sizes. A line under the heading says the section reports no live status and points to linkC's Board for what is running. Text taken from the file is escaped so it cannot forge structure, as now.

Agents read the map; they do not write it.

## 6 · Power

Hard requirements, not aims:

- **Nothing runs while the Board tab is not showing** — no timers, no polling, no observation work.
- **The Board starts no process.** It reads the container list linkC already keeps.
- **Redraw only on change.** No animation loops; a short settle when something is dropped, and none under Reduce Motion.
- **One drawing pass** for the dot grid, the frames and every arrow, in a single `Canvas`. Components, notes and texts are lightweight views on one layer; panning and zooming move that layer, never the elements one by one.
- **Nothing off screen is built.** Only elements intersecting the visible area become views.
- **A drag moves one element.** Its arrows follow it live; collision sliding and arrow routing run once, on release.
- **Arrow routes are computed on change** and kept until something they depend on moves.
- **One write per burst of edits**, as now.

Checked by: geometry tests that time collision resolution and routing on a 200-component board against a fixed budget; and by hand in the running app — the Board sitting idle shows no CPU use in Activity Monitor, and a 200-component fixture pans and zooms smoothly.

## Architecture

Pure types in LinkCKit carry the rules; the app target draws them.

**LinkCKit, `Sources/LinkCKit/Board/`:**

- `SystemMap` (version 2) — `system`, `places`, `notes`, `layout`, and the unknown keys kept for round-tripping. `decode` reads versions 1 and 2; `encoded` writes version 2. Replaces the workbench's `SystemMap`.
- `BoardGeometry` — rectangles for every element; which frame a rectangle belongs to; the nearest free spot for a moved or resized element; arrow anchors and routes; which elements intersect a viewport. Pure maths, no UI.
- `BoardModel` — `@MainActor @Observable`: the map, the selection, the current tool, undo and redo, the last reconcile, the pending write and the on-disk check. Every edit goes through it, and it derives each component's place and its `uses` from the drawing.
- `ProjectTabs` — the tabs of a project (Board first, then agent sessions, then plain terminals, each in opening order) and the key mapping for ⌘1–⌘9 and ⌃Tab. `BoardKeyMap` — the canvas's keys, mapped to commands, pure.
- `BoardReport` — the markdown the MCP tool returns. Replaces `SystemMapReport`.
- Carried over, moved into this folder: `SystemMapStore` (plus the on-disk check) and `SystemReconciler` (reading the place label as well as `runs`).
- Removed: the workbench's `WorkbenchLayout` and `WorkbenchModel`, superseded.

**App, `Sources/linkc/Board/`:**

- `ProjectTabStrip` — the strip, its overflow, its keys and the ✕ confirmation.
- `BoardCanvas` — the `Canvas` layer, the element views, gestures, the toolbar, the inspector card, the empty state and the chip.
- Removed: `WorkbenchBand.swift` and its mount in `ProjectDashboardSheet`.

Local preferences — the viewport per project — live beside the sidebar's, never in the file.

## Testing

- `SystemMapTests` — a version-2 file decodes; unknown keys survive a round trip at every level; a version-1 file upgrades as described; malformed files, duplicate names and duplicate frame labels are refused with a reason; `"Not placed"` is always written.
- `BoardGeometryTests` — containment by centre; nearest-free-spot including the tie order; frames never overlapping; a frame move carrying its components; resize limits; arrow anchors and elbow routes around a blocking box; viewport culling; a timed 200-component case against a budget.
- `BoardModelTests` — each edit and its undo; rename carrying arrows and layout; delete rules; refusal keeping state; no write without an edit; one write per burst; the changed-on-disk refusal; a failed read locking; a failed write retryable.
- `ProjectTabsTests` — order, a project with no sessions, a session closing, the ⌘-number mapping.
- `BoardReportTests` — grouping by place, planned marking, uses with labels, notes, escaping, the no-live-status line, no coordinates.
- `SystemReconcilerTests` — matching through a place's label.
- Views are not unit-tested — the app target has no SwiftUI harness — which is why they hold no rules.

## Out of scope

- Freehand drawing and free shapes.
- Provisioning, dispatching, and agents writing to the map.
- Copy, paste and duplicate.
- Images on the canvas.
- A view across projects.
- Live reload while the Board is open: the file is re-read when the Board tab opens, and a change underneath an open Board is caught by the on-disk check before any write.

## Decisions made while writing this

1. **Notes and components have fixed sizes** (176 × 120 and 152 × 56), so collisions never depend on measuring text; a long note clamps on the canvas and shows in full on hover and when opened for editing — it never grows in place, since that would break the collision rules. Texts store their measured width.
2. **Deleting a frame keeps its contents.** Losing boxes because their container went would be a surprise.
3. **The viewport is personal**, kept on this Mac, so opening a board never produces a diff.
4. **Version 1 is upgraded on the first edit**, not on open, which keeps the "no write without an edit" rule intact.
5. **The Board is the strip's first tab.** The project row itself only expands and collapses; the Board is reached by opening one of the project's sessions and selecting its Board tab.

## Known gaps

- Discovery covers containers and compose services only; anything else is unchecked.
- A workspace reached through a symlink matches no containers (systemic to linkC's path matching).
- Two people editing the same map concurrently get the changed-on-disk refusal, not a merge.

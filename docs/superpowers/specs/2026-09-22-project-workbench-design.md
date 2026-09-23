# Project workbench: a system map agents can read — design

**Date:** 2026-09-22
**Status:** approved in conversation, awaiting written review

## Why

Jacob: "A lot of my projects now are getting to the point where they are large and use multiple components, like June for example. I want to be able to drag, add components — database, redis, cloud stuff — this would help a lot with designing."

June's parts live in different places: a Supabase project, an mp3 server on an Oracle box, containers under compose. An agent starting work there has no straight answer to "what is this system made of, and how is each part reached", so it greps, guesses, or duplicates something that already exists. The purpose of this feature is that answer, written down once, in the repo, where any agent can read it — and a board where changing it is faster than describing it.

The board is the face. The map is the point.

## The map file

`system-map.json` at the project root, committed. JSON, so Foundation parses it and linkC adds no dependency. It lives at the root rather than inside `.linkc/`, which every repo's `.gitignore` already excludes — a map kept there would never be committed, defeating the point of a file any agent, on any machine, can read.

```json
{
  "version": 1,
  "components": [
    {
      "name": "postgres",
      "kind": "database",
      "reached_by": "DATABASE_URL",
      "runs": "docker compose (db)",
      "used_by": ["api", "worker"],
      "at": { "x": 0, "y": 0 }
    },
    {
      "name": "june-audio",
      "kind": "host",
      "reached_by": "https://audio.example/mp3",
      "runs": "Oracle box",
      "used_by": ["api"]
    },
    {
      "name": "redis",
      "kind": "cache",
      "reached_by": "REDIS_URL",
      "intended": true,
      "at": { "x": 2, "y": 0 }
    }
  ]
}
```

- **`name`** identifies the component. Unique within the file, and what linkC matches discovery against. Renaming a component is the same as replacing it.
- **`kind`** drives the tile's glyph and colour. The known set: `database`, `cache`, `queue`, `storage`, `service`, `host`, `external`. Any other value is kept verbatim and drawn like `service`, so a kind linkC doesn't know yet never breaks the file.
- **`reached_by`** is how code reaches it — an env var name, a URL, a host. One line, free text.
- **`runs`** is where it lives. Free text, but when it names a compose service (`docker compose (db)`) linkC uses that for matching.
- **`used_by`** names what talks to it. Entries may name other components or parts of the codebase that are not components; unresolved names are fine and are not drawn as errors.
- **`intended`** marks a component that does not exist yet. Absent means it exists.
- **`at`** is the tile's place on the board, in whole grid cells. Absent means linkC lays it out; the file is valid without any positions.

**Round-tripping.** linkC preserves keys it does not know, per component and at the top level, and writes them back unchanged. A future field, or a note someone adds by hand, survives an edit made on the board.

**Failing loud.** A file that is not valid JSON, or that has duplicate names, is an error: the band shows the reason, the board stays empty, and linkC refuses to write over it until it parses. It never silently rewrites a file it could not read.

## The board

A band across the top of the project dashboard sheet — under its header, above its tabs, which is the one place in linkC wide enough to hold a board. Each project has its own; the band collapses, and its collapsed state is remembered per project the way sidebar sections already are.

Tiles carry the name, the kind's glyph, and `reached_by` as secondary text. Three states:

- **Present** — in the file, not intended. A solid tile.
- **Intended** — `intended: true`. An outlined tile, so a plan never looks like a fact.
- **Missing** — in the file as present, but discovery looked for it and did not find it. Dimmed, with the tooltip saying what linkC looked for.

A component linkC has no way to check — an external API, a host it does not manage — is drawn present with no live marker at all, and its tooltip says linkC cannot check it. Absence of evidence is never drawn as absence.

Editing:

- Drag a tile: its `at` moves, snapped to the grid, written back after a short settle so a drag is one write, not fifty.
- Add: drag a kind from a small palette, type a name. New components start `intended: true` — you are describing something you mean to build, and it becomes present when discovery finds it or you clear the flag.
- Edit: click a tile to change name, kind, `reached_by`, `runs`, `used_by`, intended.
- Remove: a tile's context menu. Git is the undo.

A project with no `system-map.json` shows an empty band with one action: start a map. That first write is the only time linkC creates the file.

## Discovery and reconciliation

linkC already finds real components, and this feature adds no new discovery. Two sources can be tied to a project folder, so only these two are checked: running containers (`DockerPS` through `ToolServerService`, matched by the compose working directory) and the compose services of a stack linkC knows for that folder (`KnownStacksStore`). The Supabase and Oracle services know nothing about which project folder uses them, so components living there are never reported missing — they are unchecked until linkC learns that link.

**Matching.** A component matches a discovered thing when, ignoring case, its `name` equals a compose service name or a container name, or its `runs` names that compose service. Nothing else is guessed.

**What the band reports.** One chip: "2 running that aren't on the map". Opening it lists them with an Add button each, and a proposed kind derived from the image name — `postgres`/`mysql`/`mariadb` → database, `redis`/`memcached` → cache, `rabbitmq`/`nats`/`kafka` → queue, `minio` → storage, anything else → service. Nothing is added without the click: the file stays yours.

Discovery runs when the dashboard sheet opens and when the band is expanded, reusing the reads the sheet already performs. It never writes to the map.

## What agents get

- **Any agent, anywhere:** `cat system-map.json`. It is committed, so it is there on a server, in CI, and in a fresh clone, with no linkC running.
- **linkC-hosted agents:** the existing `linkc_get_project_context` MCP tool gains a `system` section carrying the components as the file holds them, plus each one's live status when linkC knows it.

Agents read the map; they do not write it. Architecture changes by your hand, not as a side effect of a task.

## Out of scope

- **No provisioning.** Dropping a component never creates infrastructure. linkC keeps holding no credentials and wrapping tools it does not own.
- **No dispatching.** Adding an intended component does not start an agent or draft a task. You raise it when you're ready.
- **No hand-drawn edges.** `used_by` carries relationships; drawn arrows rot.
- **No agent writes** to the map.
- **No auto-adding** of discovered components.
- **No cross-project view.** One project, one board.

## Architecture

Pure, tested types in LinkCKit, with the app target holding only the view:

- `SystemMap` (`Sources/LinkCKit/Workbench/`): the file's model — `components`, `version`, and the unknown keys kept for round-tripping. `SystemMap.decode(_:)` and `.encode()`, both total and both failing loud on a file they cannot represent.
- `SystemComponent`: one component, with `ComponentKind` as a known-value-plus-raw-string enum.
- `WorkbenchLayout`: positions for components without `at`, deterministic for a given set of names so two machines lay an unpositioned map out the same way.
- `SystemReconciler`: takes the map plus what discovery found, and returns each component's status (present, missing, unchecked) and the discovered things that no component matches, each with a proposed kind. Pure; discovery results go in as values.
- `WorkbenchModel` (main actor, observable): holds the loaded map, the last reconcile, and the pending write; applies an edit and schedules the debounced save. Everything the band does lives here so it is testable without SwiftUI.
- The band view in `Sources/linkc/`, reading `WorkbenchModel` and drawing tiles — no logic beyond drawing and gestures, and no side effects in view bodies.

## Testing

- `SystemMapTests`: a full file decodes; unknown component and top-level keys survive a decode/encode round trip; malformed JSON, a duplicate name, and a missing `name` each fail with a reason; a file with no positions decodes and lays out deterministically.
- `SystemReconcilerTests`, table-driven: a component matching a compose service; one matching a container by name; one matching through `runs`; one present in the file but not found; one of a kind nothing can check; a discovered container with no component, with the proposed kind for each image in the table above; case differences.
- `WorkbenchModelTests`: an edit marks the map dirty and writes once after the settle; a parse failure leaves the model in the error state and refuses to write; a reload after an external edit replaces the map.
- No SwiftUI tests — the app target has no test harness, which is why the model carries the behavior.

## Decisions made while writing this

1. **Kinds are a known set plus anything.** A fixed vocabulary would force `other` on things that don't fit; a free-for-all would make tiles meaningless. Unknown kinds are preserved and drawn plainly.
2. **Agents read, not write.** Letting an agent add components would mean architecture drifting without you, and the map's value is that it is deliberate.
3. **Positions live in the file.** You chose a single committed file; a separate local layout file would be a second source of truth. Positions are whole grid cells so a drag produces a one-line diff.

## Known gaps

- Discovery only covers running containers and the compose services of a known stack; everything else, including anything on Supabase or the Oracle box, is unchecked until linkC learns to tie it to a project folder.
- A renamed component loses its live match and its position until the map is edited to match.
- `linkc_get_usage_status`-style consumers elsewhere in linkC are untouched; this feature adds one MCP section and nothing else.

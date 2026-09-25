# Board inspect: hover, a docked inspector, lenses and calmer lines

Jacob, 2026-09-25, on his RISC-V single-cycle datapath Board (`~/Projects/rars-mcp/system-map.json`): "It's very messy, the information is scattered and unorganized … if I hover over them, it should show more details like how big the bit bus is … this can apply to … larger scale projects, like network protocols."

He chose **inspect + calmer lines + lenses** as the first slice (routing trunks and named ports come later), and approved the mockups in `.superpowers/brainstorm/16187-1790352036/content/`: `calmer-lines.html`, `component-card.html` and `labels-v2.html`. He also approved a **docked** inspector.

**The information is already in the map.** Of that Board's 48 arrows, 43 have labels and all 29 buses have a width. The problems are all in how the map is drawn:
- 25 of its 27 parts are `planned`, and an arrow into a planned part draws dashed, so almost every line is dashed.
- Pills hide below 45 % zoom.
- A clicked part force-draws pills that the placer had no room for, so they collide.
- Unbundled arrows share one entry point on a side, so their pills stack.
- Each bus's width number is drawn beside its slash mark, near the source, so two numbers stack there ("3232").

## 1 · Hover

- **Hovering an arrow or a part** for about 150 ms lights its path in the accent colour and dims everything else to about 22 %. A **hover card** appears near the pointer. Moving away clears both. Hover never changes the map or the selection.
- **The hit-test** takes the arrow whose drawn route passes within 6 pt (screen) of the pointer, preferring the nearest. It falls back to the part under the pointer. An arrow wins over a part only within 6 pt of its line.
- **An arrow's card:**
  - the endpoints, *From → To*;
  - the label, the width (as *32-bit*) and the kind (*bus*, *control*, *conditional*, *plain*);
  - a note naming any end whose status is `planned`.
- **A part's card:**
  - its name, kind and status;
  - its `does` text;
  - an **IN** list and an **OUT** list. Each row shows the signal (the arrow's label, or the other end's name when there is none), its width, and the other end with ← or →. Control and conditional rows use the gold colour.
  - Rows are ordered by the other end's name, lowercased, so the order is deterministic.

## 2 · Pin and the docked inspector

- **Clicking** an arrow or a part pins it. The highlight stays, and a docked **inspector** opens at the right edge of the Board pane. It is about 260 pt wide, shows the same content as the hover card, and never covers the canvas.
- **Clicking** another arrow or part switches the inspector. Clicking empty canvas, pressing Esc, or ✕ closes it.
- **What it replaces:** today's click-to-focus, which highlights without showing details. The existing behaviours tied to selection (dragging, editing a label, deleting) stay as they are.
- **While something is pinned,** hover still shows cards for other items, but the pinned highlight stays.

## 3 · Lenses and focus

Chips at the top left of the Board canvas:
- **All / Data / Control.**
  - **Data** means `bus` and `plain` arrows. **Control** means `control` and `conditional` arrows, so it also serves agent graphs.
  - Arrows outside the lens draw at about 10 % opacity, with no pill, and ignore hover. Parts stay fully visible.
- **◎ Focus** is enabled only while something is pinned.
  - With a pinned part, it shows only that part and the parts one arrow away from it. With a pinned arrow, it shows only its two ends.
  - Every other part and arrow is hidden. Press Focus again, or Esc, to leave.
- **Remembered state:** the lens is saved per project with the Board viewport. Focus isn't saved.

## 4 · Calmer lines

- **Planned** shows on the part's dashed outline only. Arrows no longer dash because an end is planned.
- **Dashes** mean `control` and `conditional` only. `bus` and `plain` arrows draw solid.
- **The bus slash mark** stays, but draws without its number. The width moves into the pill (§5).

## 5 · Pills

- **One pill per arrow:**
  - an arrow with a label and a width shows the label, then the width in bold (*rs1 data  32*);
  - a bus with no label shows the width alone (*32*);
  - any other arrow shows its label or nothing.
- **Placement:** the existing placer (`BoardLabels.placed`) places every pill, using the combined text for its width. It never overlaps a part, a frame title or another pill.
- **No forced pills:** a highlighted, pinned or hovered arrow draws its pill only if the placer placed it. Otherwise, the label is in the card and the inspector.
- **The zoom threshold** below which pills hide is unchanged.

## 6 · Spread ends

In `BoardRouter`, unbundled arrows that attach to the same side of the same part get separate attach points on that side.
- **Spacing:** the points are spaced evenly, with at least 12 pt between them and 8 pt from each corner.
- **Order:** the points are ordered by the position of each arrow's other end along that side's axis, so the arrows don't cross near the part.
- **Bundles are unchanged:** arrows that share a label still share one trunk and one anchor. A bundle counts as one arrow when spreading.
- **Determinism:** the same map always gives the same routes, with ties broken by the arrow key, as today.

## 7 · Pieces

- **LinkCKit, pure and tested:**
  - `BoardLens`: `.all`, `.data` or `.control`, with `includes(_ style: BoardArrowStyle) -> Bool`. It is Codable, and stored in `BoardViewport` as an optional field, decoded when present, `.all` by default.
  - `BoardInspection`: the card contents for an arrow (endpoints, label, width, kind, planned ends) and for a part (name, kind, status, does, IN and OUT rows), built from a `BoardMap`.
  - `BoardHitTest`: `arrow(at:routes:tolerance:)` returns the nearest arrow key within the tolerance of its route polyline. `component(at:frames:)` returns the part whose frame contains the point.
  - `BoardFocus`: the set of part names and arrow keys that stay visible for a pinned part or arrow.
  - `BoardLabels.pillText(for:)` gives the combined label and width. The width calculation uses it.
  - `BoardRouter` spreads ends as in §6.
- **App target (`Sources/linkc/Board`):**
  - the canvas drawing changes (§4, §5, the lens opacity, the hover and pin highlight);
  - hover tracking (`onContinuousHover`), with a 150 ms delay;
  - the hover card overlay, the docked inspector view, and the lens and Focus chips;
  - Esc handling.

## 8 · Testing (test-first, LinkCKit)

- **`BoardLensTests`:** the style membership for each lens. A viewport saved without `lens` decodes as `.all`.
- **`BoardInspectionTests`:** built from a small map shaped like the Register File example.
  - IN and OUT rows with label, width, other end and control marking, in the right order;
  - a planned note on an arrow card;
  - an arrow without a label shows the other end's name.
- **`BoardHitTestTests`:**
  - the nearest arrow within the tolerance wins;
  - nothing is returned beyond the tolerance;
  - a part is found when no arrow is near;
  - a point near both an arrow and a part picks the arrow.
- **`BoardFocusTests`:** the neighbourhood of a part (one hop, both directions), and the two ends of an arrow.
- **`BoardLabelsTests`:**
  - pill text for each case (label and width, width only, label only, none);
  - placement uses the combined width;
  - two arrows into one part's side get non-overlapping pills.
- **`BoardRouterTests`:**
  - two unbundled arrows into the same side get distinct attach points, at least 12 pt apart, ordered by their sources' positions;
  - a bundle still shares one anchor;
  - routes stay deterministic.

Checked by hand in the app on the RISC-V Board:
- hovering buses and parts;
- pinning, switching and closing the inspector;
- each lens and Focus;
- no dashed buses;
- no stacked pills or numbers at the ALU and at Instruction Memory.

## Out of scope

- Routing trunks with junction dots, and a separate lane for control signals.
- Named ports on parts.
- Editing in the inspector (it is read-only; editing stays as today).
- Protocol-specific lenses.

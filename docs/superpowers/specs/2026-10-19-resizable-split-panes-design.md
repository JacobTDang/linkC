# Resizable Split Panes

**Date:** 2026-10-19
**Status:** Implemented (branch feat/resizable-split-panes)

## 1. Problem

A project's Split tab lays its terminals out in an even grid: one or two rows (`SplitLayout.rows`), each pane in a row the same width, both rows the same height. A terminal that needs room, such as a log tail beside a short shell, can't have more of it. The panel and torn-off windows already resize by their edges; the panes inside them don't.

## 2. Goals

- Drag the gap between two panes in a row to make one wider and the other narrower.
- Drag the gap between the two rows to make one taller and the other shorter.
- Double-click a gap to even it out again.
- Sizes stay with the project's split, across restarts and in a torn-off window showing the same split, until a terminal joins or leaves the split.

## 3. Non-goals

- Resizing the sidebar, or the text inside a terminal.
- Grid shapes other than `SplitLayout.rows` (a pane spanning two rows, three rows).
- Keeping sizes when a terminal joins or leaves. The grid evens out then.

## 4. The size model (LinkCKit)

`SplitSizes`, a pure `Codable, Equatable, Sendable` value in `Sources/LinkCKit/Terminal/SplitSizes.swift`:

- `paneCount: Int` — the number of panes the sizes were made for.
- `rows: [Double]` — each row's share of the grid's height, top to bottom.
- `columns: [[Double]]` — per row, each pane's share of the row's width, left to right.

Each share list holds positive fractions that add up to 1, and has the length `SplitLayout.rows(for: paneCount)` gives. `SplitSizes.even(for:)` builds the even grid. Sizes belong to positions, not terminals.

Operations, all pure and all clamped so that no pane falls below its minimum:

- `resizingColumns(inRow:divider:by:rowWidth:minWidth:)` moves the boundary between pane `divider` and pane `divider + 1` of a row by a distance in points. Only those two panes change.
- `resizingRows(by:gridHeight:minHeight:)` moves the boundary between the two rows. A one-row grid has nothing to resize and returns itself.
- `evenedRow(_:)` evens one row's panes; `evenedRows()` evens the row heights.
- `fits(paneCount:)` says whether these sizes describe a grid of that many panes.

The minimums are 120 pt wide and 80 pt tall, the smallest a terminal stays usable at. When a drag would push a pane below its minimum, the boundary stops there. When the space is too small for both minimums, the boundary does not move.

Decoding repairs or refuses. Share lists of the wrong length, a share that is not positive, or shares that do not add up to 1 within 0.001 decode as nil (an even grid), and the repair is logged, as `ProjectSplit` already does for its members.

## 5. Where the sizes live

`ProjectSplit` gains `sizes: SplitSizes?`, nil meaning even. It is encoded with the split, so it survives restarts through `SidebarState` like the members do. Old files have no `sizes` key and decode as even. An older build reading a newer file ignores the key.

Membership changes clear the sizes. Every path that changes a split's members:

| Path | Effect on `sizes` |
|---|---|
| `adding` — a terminal joins | cleared |
| `adding` — a member moves to another position | kept (positions keep their sizes) |
| `adding` — dropped on itself | unchanged |
| `dropping` — a new split from `target` | none (a new split) |
| `removing` | cleared |
| `pruned(keeping:)` when it removes a member | cleared; otherwise unchanged |
| `focusing` | unchanged |
| decode repair that changes `members` | cleared |

A new `resized(_ sizes: SplitSizes)` sets the sizes.

## 6. The view (`SplitPane`)

The grid renders live members (`liveMembers(in:)`). Sizes apply only when `sizes.fits(paneCount:)` matches the number of live panes. Otherwise the grid renders even, and the stored sizes are kept for when the missing member comes back, such as a session that is still relaunching.

The 6 pt gaps between panes, and between the rows, become handles:

- The pointer shows `NSCursor.resizeLeftRight` over a gap between panes and `resizeUpDown` over the gap between the rows.
- Dragging a handle resizes the panes live, using the grid's measured width and height and the minimums from §4. The view holds the in-progress sizes. When the drag ends, `AppModel` stores them in the project's split, which writes it once rather than on every mouse movement.
- A double-click evens that row, or the rows.

Pane frames come from the shares: the grid's size, less its gaps, multiplied by each share. The terminal in a resized pane reflows exactly as it does when the window resizes. A torn-off window showing the same split draws the same sizes, because both read the project's one split.

## 7. Errors

There are no new failure paths. Out-of-range drags clamp (§4). Sizes that don't fit the live pane count render even (§6). Bad stored sizes decode as even and are logged (§4).

## 8. Testing

Unit tests in LinkCKit, written first:

- `SplitSizes`:
  - even grids for 2 to 8 panes;
  - a column drag moves only its two panes, both ways;
  - a drag stops at the minimum width, and nothing moves when the row is too narrow for two minimums;
  - row drags, including clamping, and a one-row grid ignoring them;
  - evening a row, and evening the rows;
  - `fits`;
  - decoding repairs (wrong lengths, non-positive shares, shares not adding up to 1).
- `ProjectSplit`:
  - every row of the table in §5;
  - an old file without `sizes` decodes as even;
  - sizes round-trip through encode and decode.

Manual, after the update:

- In a 2-pane and a 5-pane split, drag every gap; the cursor changes over it, and no pane goes below its minimum.
- Double-click a gap and it evens out.
- Quit and reopen linkC: the sizes are back.
- Tear the split off into a window: it shows the same sizes.
- Add or remove a terminal: the grid evens out.

# Board scrolling: arrow keys and a horizontal scroll bar

A mouse wheel only pans the Board up and down, so moving sideways needs a trackpad. This adds two
ways to move sideways (and arrow keys for every direction).

## Behavior

### Arrow keys
- ← → ↑ ↓ pan the Board by a step of 48 screen points per press. → shows what is further right,
  ↓ what is further down. Holding a key repeats at the system's key-repeat rate.
- ⇧ + arrow pans by a page: 80% of the canvas's visible width (← →) or height (↑ ↓).
- ⌘↑ still goes up a level. An arrow with ⌘ (other than ⌘↑), ⌃ or ⌥ is not the Board's: it is
  left to the rest of the app.
- While a text field has the keyboard, arrows belong to the field (the Board's existing rule for
  every key).
- Arrows pan whatever is selected; nothing on the Board uses them today.

### Horizontal scroll bar
- A thin bar along the bottom edge of the canvas, below the toolbar.
- Its track spans the board's content, with 48 screen points of margin either side, joined with
  what is on screen — so the track always covers where the view is. The thumb is the visible part;
  zooming changes its length.
- Drag the thumb to slide sideways. While a drag lasts, the track keeps the span it had when the
  drag started, and the thumb stays on the track.
- Click the track off the thumb to centre the view on that spot; keep holding and the drag
  continues from there.
- Hidden when the view already shows all of the content across (nothing to slide), and on an
  empty board.
- Quiet look: no track fill; a faint thumb (`Theme.textPrimary` at low opacity) that brightens on
  hover and while dragging.

Panning through either path goes through the same `viewport` the wheel and trackpad move, so the
saved per-board view position keeps working.

## Architecture

### LinkCKit (pure, unit-tested)
- `KeyPress.Key` gains `.down`, `.left`, `.right` (it has `.up`).
- `BoardPan { direction: left/right/up/down, page: Bool }` and `BoardCommand.pan(BoardPan)`.
  `BoardKeyMap` maps the arrows (⇧ = page), keeps ⌘↑ = `.goUp`, and returns nil for an arrow with
  ⌘/⌃/⌥ or while text is being edited.
- `BoardViewport.panned(_ pan: BoardPan, width:height:)`: the step (`arrowStep = 48`) or the page
  (`arrowPage = 0.8` of the width/height), in the arrow's direction, through `panned(byScreenDX:dy:)`.
- `BoardScrollbar.horizontal(viewport:content:width:margin:)` → `BoardScrollbar?`: the track's
  canvas span (`minX`, `span`) and the thumb as track fractions (`thumbStart`, `thumbLength`); nil
  when there is no content or the view already covers it. Inverses: `originX(thumbStart:)` (kept
  on the track) and `originX(centredOn:)`.

### App target (`linkc`)
- `BoardInput.press(from:)` reads key codes 123 (←), 124 (→), 125 (↓).
- `BoardCanvas.perform(.pan)` sets `viewport = viewport.panned(pan, width:height:)` with the
  canvas `size`.
- `BoardScrollBar` (new SwiftUI view, `Sources/linkc/Board/BoardScrollBar.swift`): binds the
  viewport, reads the content bounds and canvas width, draws the thumb, and handles the drag and
  the track click as above. It sits in the canvas's `ZStack`, above the overlays, at the bottom
  edge, so its gesture wins over the canvas's own in its strip.

## Testing
- Unit tests: the key map (each arrow, ⇧ page, ⌘↑ still `goUp`, modifiers declined, typing
  declined); `BoardViewport.panned(_:)` for each direction, step and page, at zoom ≠ 1;
  `BoardScrollbar` hidden with no content / when everything fits, thumb fractions, the track
  growing to include a view beyond the content, `originX(thumbStart:)` clamping at both ends,
  `originX(centredOn:)`.
- Manual checks (no app-target harness): arrows and ⇧-arrows pan; arrows type in a field instead;
  ⌘↑ goes up; the bar appears only when content is wider than the view; dragging the thumb slides
  and stays on the track; clicking the track centres there; zooming resizes the thumb; the bar
  doesn't cover the toolbar.

# Split terminals

Show several of a project's terminals at once, in an even grid of up to 8 panes, by dragging them together.

Tearing a terminal or a grid off into its own window is a separate, later piece. It reuses the grid this spec builds.

## Behavior

- **Making a split:** drag a session or shell terminal onto the left, right, top or bottom edge of the terminal you are viewing. You can drag from the sidebar or from the project's tab strip. A **⊞ Split** tab appears in the tab strip right after Board, holding both terminals. A project has at most one split.
- **Growing it:** drag more of the project's terminals onto the Split tab's panes. The edge you drop on decides the position, and the grid reflows. Dropping a terminal already in the split moves it. The cap is 8 panes. A drop the split can't take (a ninth terminal, or one from another project) is refused, and linkC's error bar says why. A drop onto a terminal outside a split that is showing is refused too, and the error bar says to drop onto one of its panes or close the Split tab first; a split with fewer than two live members isn't showing, so a drop elsewhere replaces it. The dragged terminal's id is only available once it is dropped, so the refusal can't be shown while hovering.
- **Layout:** panes form an even grid with these panes per row:

  | Panes | Per row |
  |---|---|
  | 2 | [2] |
  | 3 | [2, 1] |
  | 4 | [2, 2] |
  | 5 | [3, 2] |
  | 6 | [3, 3] |
  | 7 | [4, 3] |
  | 8 | [4, 4] |

  A shorter last row spreads its panes across the full width.
- **Panes:** each pane has a small title row (the session's title and its state dot) and a hover ×.
  - Clicking a pane focuses it, so keyboard input goes there. The focused pane has a thin outline.
  - In the Split tab, "the selected session" means the focused pane. Sidebar highlighting and seen-marking follow it.
- **Removing a pane:** click its ×, or drag it onto the tab strip. That only takes it out of the split; the session keeps running.
  - If the removed pane had focus, focus moves to its neighbor.
  - When fewer than two panes are left, the Split tab disappears and the remaining terminal shows on its own.
- **Ended sessions:** a session that ends, or that linkC closes (an idle worker, #49), drops out of the grid and the grid reflows.
- **Single tabs still work:** each session's own tab still shows it full-size. Going back to Split shows the grid.
- **Opening a member:** opening a session or shell terminal from anywhere outside the tab strip shows the Split tab with that pane focused, when it is a live pane of an active split. That covers its sidebar row, its notification, the project dashboard, and a screen's Open. Its own tab chip, and ⌘-digit or ⌃Tab to it, still show it full-size. Opening something that turns out to select nothing (a session that has ended) never opens a split.
- **Persistence:** each project's split is kept across relaunch. Members are stored by linkC session id, and a split's members are the project's live terminals.
  - Members are kept across relaunch: the sessions linkC relaunches at start-up keep their ids and rejoin.
  - A member that ends drops out of the split, as "Ended sessions" says. It no longer counts toward the cap of 8.
  - Restoring an Earlier card later starts a new session that is not in the split.
- **Scope:** only terminals that belong to the project can join its split. That means its sessions, plus shell terminals filed under it, which are exactly what its tab strip lists. A terminal from another project can't be dropped there.
- **Panel size:** the panel doesn't grow by itself (one consistent size). Many panes in a small panel are cramped, so you resize it. The future tear-off window is where large grids live.

## Architecture

Each session keeps exactly one live terminal view (`LocalProcessTerminalView`). The view moves between its single tab's host and its grid cell. It is never duplicated.

### LinkCKit (pure, unit-tested)

- `SplitLayout`:
  - `rows(for count: Int) -> [Int]`: panes per row, as in the table above. Empty for 0 or 1.
  - `insertionIndex(droppingOn index: Int, edge: SplitEdge, count: Int) -> Int`:
    - `.left` and `.top` give `index`.
    - `.right` and `.bottom` give `index + 1`.
    - When the dragged terminal is already a member, the result accounts for it being removed first.
  - `maxPanes = 8`.
- `ProjectSplit`: a value type holding `members: [String]`, the ordered terminal ids, and `focused: String?`.
  - `adding(_:at:)`: no duplicates. A member already present moves.
  - Refuses a ninth member with a typed error.
  - `removing(_:)`, which moves focus to the neighbor.
  - `pruned(keeping:)`, which drops ids not in a given live set.
  - `liveMembers(in:)`.
  - `isActive(liveIDs:)`: 2 or more live members.
- `SidebarState`:
  - Persists `splits: [canonicalProjectPath: ProjectSplit]` as a new optional `Stored` field, so older builds ignore it and older files decode with no splits.
  - Exposes `split(for:)`, `setSplit(_:for:)` and `clearSplit(for:)`.
- `ProjectTabs.tabs`:
  - Adds a `ProjectTab` of kind `.split` right after Board when the project's split is active, with id `split:<canonical path>`.
  - Its `isWorking` is false. Closing it only dissolves the split and stops nothing, so its × never asks first.

### App target (`linkc`)

- `SplitPane`: a SwiftUI view that lays out rows of cells using `SplitLayout.rows`. Each cell is a `TerminalContainer(session:)` with:
  - a title row (title and state dot);
  - a hover × that calls `model.removeFromSplit`;
  - a click gesture that focuses it (`makeFirstResponder` plus `ProjectSplit.focused`);
  - an outline on the focused cell.

  The panel's terminal styling (font and translucent background) is applied to every pane, not only the selected one.
- Drop overlay:
  - While a `LinkCTerminalDrag` is over the terminal area (single pane or split pane), an overlay highlights the edge under the pointer.
  - Dropping calls `model.addToSplit(project:terminal:onto:edge:)`.
  - A refused drop (another project's terminal, or a ninth) sets the panel's error bar text.
  - The tab strip accepts a `LinkCTerminalDrag` from a pane to remove it from the split.
- Selection: `AppModel.select(_:)` handles the `.split` tab. The pane switches to `SplitPane`, and the selected id becomes the focused member.
- `TerminalHostView.show(_:)` fix: today it returns early when the view is the one it last showed, even if that view has since been attached elsewhere. It must re-attach whenever `view.superview !== self`.

### Power

Panes on screen draw normally. Panes not on screen, behind another tab or with the panel hidden, take #43's "no window or not visible" path, so a grid costs nothing while hidden.

## Error handling

- Adding a ninth member, adding a terminal from another project, or splitting with an unknown id is refused with a typed error. Nothing changes and the error bar says why.
- A stored split entry that fails to decode is dropped with a log line naming the project, and the rest of the sidebar state still loads. The `splits` field is decoded entry by entry, so one bad entry can't make the whole `Stored` decode fail, and a `splits` value of the wrong type costs only the splits. A stored split with duplicate members, more than 8, or a focus that names no member is repaired as it is read, with a log line.

## Testing

- **Unit tests in LinkCKit:**
  - `SplitLayout` rows for 0–8, and insertion indexes for each edge, including a member being moved.
  - `ProjectSplit` add/move/remove/cap/prune/focus rules.
  - `SidebarState` round-trips splits, decodes a file without the field, and is decoded by older code (an extra key is ignored).
  - `ProjectTabs` puts the split tab after Board only when it is active (2 or more live members).
- **AppKit test:** `TerminalHostView` re-attaches a view that was moved to another host and back.
- **App target (no UI test harness):** the manual checks are:
  - drag to create a split;
  - grow it to 8 and see it refuse a ninth;
  - move a pane by dropping it elsewhere;
  - remove a pane with × and by dragging it to the tab strip;
  - a session ending reflows the grid;
  - single tabs still show full-size;
  - the split survives relaunch;
  - focus and outline follow clicks;
  - typing goes to the focused pane.

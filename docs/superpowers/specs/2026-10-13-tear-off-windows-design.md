# Tear-off windows

Pull a terminal, or a project's whole Split grid, out of the menu-bar panel into its own normal
macOS window. This is the second half of split terminals (`2026-10-12-split-terminals-design.md`), and
it reuses the grid that spec built.

## Behavior

### Tearing off
- Drag a terminal's tab chip, or the Split chip, out of the panel and let go anywhere outside it.
  A window opens there, centred on the point where you let go, like pulling a tab out of a browser.
- Or right-click the chip and choose **Open in Window**. The window then opens beside the panel.
- What can tear off:
  - a session or shell terminal, which shows alone;
  - a project's split, but only while it is active (two or more live panes), which shows as its grid.
- Tearing off something that is already in a window brings that window forward instead.

### The window
- It is a normal macOS window: title bar and traffic lights. It goes behind other apps when you
  click away, can go full screen, and shows in Mission Control.
- Its title is the session's title, or "<project name> — Split".
- Inside is the same dark glass look as the panel.
- A torn-off grid works like the Split tab:
  - click a pane to give it the keyboard and the focus outline;
  - drag a pane's title row onto another pane's edge to move it;
  - drag another of the project's terminals onto a pane's edge to add it;
  - the hover × takes a pane out.
- Clicking or typing in a window doesn't change what the panel shows. It does open the session
  the way clicking its tab does: a worker becomes yours, and a waiting agent reads as seen.
- Default size is 720 × 460 for a terminal and 960 × 600 for a grid. Each is clamped onto the screen
  under the drop point.

### Dock and ⌘-Tab
- While at least one torn-off window is open, linkC shows in the Dock and ⌘-Tab. When the last one
  closes, linkC goes back to being menu-bar only.

### The panel side
- A torn-off terminal's chip stays in the tab strip with a small window mark. So does a torn-off
  Split's chip.
- Opening it brings its window forward, focused on it. That covers:
  - clicking its chip;
  - clicking its sidebar row;
  - clicking its notification;
  - opening a member of a torn-off split.
- Where the panel would have shown it, it shows a quiet note, "Open in its own window", with **Show
  window** and **Bring back** buttons.
- Inside a grid, in the panel or in another window, a pane whose terminal lives in its own
  window shows the same note in place of the terminal.

### Bringing back and endings
- Closing the window (its close button or ⌘W), or clicking **Bring back**, puts it back in the panel.
  The session keeps running.
- A terminal that ends closes its window.
- A torn-off grid whose split stops being active (fewer than two live panes) closes its window. What
  is left shows in the panel again.

### Relaunch
- Open windows are saved with their frames and come back after a relaunch.
- Restored sessions keep their ids, so a restored session's window reopens.
- An entry whose terminal is no longer live, or whose split is no longer active, once start-up
  restore has run is dropped before any window opens.

## Architecture

Each terminal keeps exactly one live terminal view, which moves between hosts. The rule for which
host holds it, the **host rule**, is:
- a window that shows that terminal alone; else
- a window showing an active split that holds it live; else
- the panel.

Every view that can host a terminal shows it only if it is that terminal's host, and shows the note
otherwise.

### LinkCKit (pure, unit-tested)
- **`TornOffItem`:** `.terminal(id)` or `.split(canonicalProjectPath)`. It is `Codable` and `Hashable`.
- **`TornOffFrame`:** `x`, `y`, `w`, `h` as `Double`, in screen points.
- **`TornOffWindow`:** an item plus its frame.
- **`TornOff`:** the ordered windows.
  - `adding(_:frame:)`: no duplicates; an item already present keeps its frame.
  - `removing(_:)` and `framing(_:to:)`.
  - `host(of:splits:liveIDs:)`: applies the host rule.
  - `pruned(liveTerminals:activeSplits:)`: returns what stays and what closes.
- **`SidebarState`:** persists `windows` as a new optional `Stored` field.
  - It is decoded entry by entry.
  - An unreadable entry is dropped with a log line, and the file is rewritten without it.
  - API: `tornOff` and `setTornOff(_:)`.
- **`AppCoordinator.acknowledgeSession(_:)`:** what opening a session does besides selecting it
  (adopting a worker, a waiting non-Claude agent turning ready). `focusSession` calls it too.

### App target (`linkc`)
- **`AppModel`:**
  - `host(of:)`, `tearOff(_:at:)`, `bringBack(_:)`, `raise(_:focusing:)`, `setFrame(_:_:)`.
  - Pruning of torn-off windows runs alongside the splits' pruning, and once at start-up before any
    window opens.
  - `showSelection(opening:)` raises the window of an opened terminal that lives in one.
  - `onScreenSessionId` ignores a selection that lives in a window.
  - The terminal in the key torn-off window counts as watched, for notifications, and is marked
    seen, for attention.
  - The split operations take the project explicitly: focus, pick, click, remove, and drop. That way
    a torn-off grid works the same as the panel's, without touching the panel's selection.
- **Panel views:** `TerminalPane`, the Split route and `SplitCell` show the note where the host rule
  puts the terminal elsewhere.
- **`TornOffWindows`:**
  - It creates one `NSWindow` per `TornOff` entry and closes windows for removed ones.
  - It hosts a SwiftUI `TornOffView`: a single terminal through `TerminalContainer`, or a grid
    through `SplitPane`.
  - It saves frames on move and resize.
  - It reports the key window's terminal to the model.
  - It switches the activation policy between `.regular` and `.accessory`.
- **Chips:**
  - Session, terminal and Split chips get an AppKit drag source. It carries the same
    `com.linkc.terminal` data the split drops accept; the Split chip carries data nothing accepts. It
    reports where a drag ended without being accepted. Outside the panel, that tears the chip off at
    that point.
  - Each chip gains an **Open in Window** item in its context menu, or **Bring back** when the chip
    is already torn off. A torn-off chip also shows a small window mark.

## Error handling
- Tearing off a terminal that has ended, or a split that isn't active, is refused. The error bar says
  why.
- A window whose content is gone closes. That is pruning, not an error: the same rule as split members.
- A stored window entry that fails to decode is dropped with a log line naming it. The rest of the
  sidebar state still loads.

## Testing
- **Unit tests (LinkCKit):**
  - `TornOff`: add without duplicates, remove, frame, the host rule's priority (terminal window over
    split window over panel, inactive split ignored), and prune.
  - `SidebarState`: round-trips windows, drops and rewrites an unreadable entry, and loads a file
    without the field.
  - `acknowledgeSession`: adopts a worker and turns a waiting non-Claude agent ready, without moving
    the selection.
- **Manual checks (no app-target harness):**
  - drag a chip out to open a window, and use **Open in Window** from the menu;
  - the Dock icon appears and goes away;
  - typing goes to the window;
  - the panel shows the note; **Bring back** and the close button both return it to the panel;
  - a sidebar click and a notification click raise the window;
  - a torn-off grid's drag, drop, × and focus work;
  - a session ending closes its window;
  - windows come back after a relaunch;
  - ⌘C, ⌘V and ⌘W work in a window.

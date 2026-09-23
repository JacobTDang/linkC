# Panel polish: Board row, window dragging, agent logos, live activity

Four changes Jacob asked for after using the Project Board.

## 1 · No Board row in the sidebar

The Board row under each expanded project is removed. The Board is still reached as the first,
pinned tab of the strip above the terminal, which shows whenever one of the project's sessions
is open. `⌘1` and restoring the last-shown Board work as before.

## 2 · The window moves only by its top

Today a drag anywhere on the panel's body moves the whole window. On the Board canvas, that means
every drag moves linkC.

After this change, the window moves only when dragged by its top:
- the linkC row at the top of the sidebar;
- the empty space in the tab strip;
- in the right pane, when no strip shows (the launcher and the other screens), its top row.

Edges and corners still resize. A drag anywhere else never moves the window: the canvas, the
terminal, lists, cards, and text. Text becomes selectable with a plain drag everywhere.

The workaround that switched body-dragging off while the pointer was over selectable text
(`WindowDragGate`, `setWindowDraggable`, `.selectableText()`) no longer has a job and is removed.
Its call sites use `.textSelection(.enabled)` directly.

## 3 · Agent logos

Each agent's real logo replaces the coloured square, in brand colours:
- Claude: the orange spark.
- Codex: its app tile.
- Cursor: its cube, drawn in the sidebar's primary text colour.
- Antigravity: its colours.

The logos appear everywhere the square does today:
- sidebar session rows;
- Earlier rows (dimmed, as now);
- usage rows (faded when stale, as now);
- tab chips;
- the session header;
- the project dashboard.

Plain terminals keep their terminal icon. The text badge in `AgentPill` is not a square and
stays as it is.

**Where the logos come from:** `@lobehub/icons-static-svg` 1.95.1, MIT, © LobeHub. The files are
`claude-color`, `codex-color`, `cursor` and `antigravity-color`. They are embedded as SVG text in
the source, with the licence notice beside them. No package is added.

**How they are drawn:** macOS draws them natively (`NSImage` from SVG data, via CoreSVG).

**Preparing the files:** the arc commands in each path are rewritten with explicit separators.
The shipped Codex path packs its arc flags together (`012.285`), which CoreSVG misreads: it draws
a straight line and logs a warning. The rewritten files draw correctly with no warnings.

**Size:** a logo is drawn 12 pt in rows and tabs.

**Fail loud:** each logo is loaded once. A test proves every agent except `shell` has a logo that
loads as a valid SVG image.

## 4 · Live activity in tabs and sidebar rows

While a session is working or waiting on a permission, its tab and its sidebar row show what it is
doing in place of its name. This is the same line the session header shows (for example "Read the
panel's drag gate"), with the same icon and, while working, the same shimmer. When the session
goes idle, both show its name again. Hovering still shows the name.

**The rule (one place, in LinkCKit, tested):** show the activity only when both are true:
- the session is working or waiting on a permission;
- it has a non-empty current activity.

Otherwise, show the title. The text comes from `AppModel.currentActivity(_:)` unchanged:
- the hook-fed line;
- then the terminal-read line;
- then "Thinking…" or "Permission required".

**Subagents:** a subagent shows as its launch line, "▸ <what it was asked>", while it is the
session's latest action. A subagent's inner steps are not shown: several can run at once, and
the line would flicker between them. This matches the header today.

**One view for the line:** the icon + text + shimmer becomes one shared view, used by the header,
the tab chip and the sidebar row. The header's private icon mapping moves with it.

**Power:** a terminal-read activity is not observable, so it is re-read once a second, and only
while it can change:
- The strip runs one 1-second timeline, and only while at least one of its sessions is working
  or waiting.
- The sidebar re-reads inside the refresh it already has, with no second timer.
- Idle sessions cost nothing.

## Out of scope

- The Board itself.
- The launcher's agent menu.
- The pill badges.

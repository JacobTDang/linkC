# Codex-style sidebar — design

**Date:** 2026-09-19
**Status:** approved (design), not yet planned or implemented

## Goal

Make the panel cleaner and closer to the Codex desktop app: one always-visible sidebar of plain rows
(navigation, projects with their sessions nested under them, terminals, history) beside whatever is
open. The project cards and the per-agent banners go away; clicking a project shows its open agent
sessions under it.

## Non-goals

- Restyling the Skills, MCP servers, Tool servers, Settings, and Activity screens. They keep their
  current look and open in the right pane as today.
- Codex conversation titles. Codex writes thread names to `~/.codex/session_index.jsonl`, but linkC
  cannot tell exactly which thread a linkC session is running: Codex does not keep its rollout file
  open, so the only link is a guess from folder and start time, and two Codex sessions in one folder
  would be confused.
- Session lifecycle: duplicate sessions after a relaunch and closing idle workers. That is its own
  piece of work (see the backlog). This change adds only the per-session stop control.
- No change to the panel window itself: frameless glass, corner placement, saved size, and the
  menu-bar item stay as they are.

## What exists today

- `PanelView` stacks a header (`PanelHeader`: back chevron, `CountBadge`s, `TopNavBar`, the open
  session's spend, `LauncherMenu`) over one pane: a dock screen, the terminal (`TerminalHero`), the
  empty-state launcher (`EmptyStateView`), or home (`HomeView`). A floating `Dock` of the same screen
  icons rides the right edge of every pane but the terminal.
- Home is `SessionListColumn`: one `HomeCard` per project in NEEDS YOU / WORKING / IDLE sections.
  A card carries the title and path, one `AgentMiniLaneView` banner per session, a collision banner,
  a 3-line `PreviewText`, subagent `AgentLine`s, a context bar, and hover buttons (swarm inspect,
  add teammate, stop every session in the workspace). Below the cards: Terminals and Earlier.
- With a terminal open and the pane at least `Theme.splitBreakpoint` (600pt) wide, a 260pt compact
  `SessionListColumn` sits beside it (`CompactProjectRow` with lanes, `ServersSection`,
  `CloudSection`). Narrower, the terminal is full-bleed with a `SessionStrip` of sibling tabs.
- There is no way to stop one session in a project that has several: the card's ✕ stops them all.
- `SessionState.bucket` puts `finished`, `waitingIdle`, `waitingPermission`, and `error` in
  `.needsYou`. A Claude session that finished a turn stays coral until the user types into it.

## Layout

The panel becomes two columns at or above 600pt: the sidebar (260pt, `Theme.sidebarWidth`) and the
right pane. Below 600pt the sidebar fills the panel and a selected session or screen replaces it,
with a ‹ back button in a slim top strip.

### Sidebar, top to bottom

1. **Brand row.** "linkC" on the left. On the right, a ✎ glyph opening the current `LauncherMenu`
   contents unchanged: new session per agent, new terminal (zsh), Continue last, Resume, Quit linkC.
2. **Navigation rows** (icon + label, Codex style):
   - New session — shows the launcher in the right pane.
   - Activity, Skills, MCP servers — open those screens in the right pane.
   - More — expands in place to Tool servers, Terminals, Settings. Its open/closed state is
     remembered.
   A row is highlighted while its screen is open.
3. **Projects** (dim section label). One row per project with at least one live session: a
   disclosure chevron, the folder name, and the state dot. Expanded, its sessions are listed under it,
   indented. Hover shows ＋ (the add-agent menu, today's "Add <agent>") and ⋯ (Blackboard & handoff —
   today's `ProjectDashboardSheet`; Stop all sessions).
4. **Session rows**, nested under their project: an agent-colored mark, the title, and the state text
   on the right. Clicking one opens its terminal. Hover shows ✕, which stops only that session; it
   then appears under Earlier and can be restored. No confirmation, matching today's ✕.
5. **Terminals** — live dev shells, one row each with a running dot. Shown only when one exists.
6. **Servers** and **Cloud** — today's `ServersSection` and `CloudSection` rows, each a collapsible
   section (click the dim label) with a count on the right. Collapsed by default; state remembered.
   Hidden when empty, as today.
7. **Earlier** — restorable sessions and restorable shells. Click restores; the context menu keeps
   "Restore as <agent>"; hover ✕ dismisses. Collapsible, remembered, collapsed by default.
8. **Footer**, pinned: the plan-usage line (today's `windowUsageLabel`, honoring
   `showsUsageFooter`) and, when a fresh build is waiting, a round coral download button that runs
   `installUpdate()` (replacing `UpdateBar`).

### Right pane

- **A session is selected:** a one-line header strip above the terminal — agent mark, title,
  "<Agent> · <project>", a "N subagents ▾" chip when subagents exist (opens a popover of today's
  `AgentLine`s; picking one swaps in the existing `AgentReaderView`), and the session's spend
  (`selectedUsageLabel`). A 2pt context bar sits under the strip. The project's collision warning
  (`CollisionBanner`) appears under it when present. Then the terminal.
- **A screen is open:** the screen, as today. Screens still layer over an open terminal.
- **Nothing is selected:** the launcher (`EmptyStateView`: New session, Continue last, Resume, recent
  folders), which replaces Home. `goHome()` becomes "clear the selection".

### Removed

The header strip (`PanelHeader`, `TopNavBar`, `CountBadge`, `LauncherMenu`'s header placement),
`Dock`, `HomeView`, `HomeCard`, `AgentMiniLaneView`, `CompactProjectRow`, `SessionStrip`,
`PreviewText`, `UpdateBar`, the NEEDS YOU / WORKING / IDLE sections, and the constants only they use
(`dockBreakpoint`, `dockInset`, `previewHeight`). Anything else left unused afterwards is deleted too.

## What the rows say

### Session title — first match wins

1. **Claude's own title.** Claude Code appends `{"type":"ai-title","aiTitle":"…"}` lines to the
   conversation file; the latest one is the current title. linkC already binds each Claude session's
   transcript path (`UsageTracker.bind`). The file is read backward from its end until the last
   `ai-title` line is found, and the result is cached per session until the file's size or
   modification time changes.
2. **The task the session holds:** the `TaskRecord` whose `assigneeSessionId` is this session and
   whose state is `delivered` or `started`, shown as "Task <shortId>: <first line of the prompt>".
3. **The agent's display name.** When a project has more than one untitled session of the same agent,
   the second and later ones get " 2", " 3", … in the order they were opened.

A new Claude session reads "Claude" until Claude names it.

### State text and attention

| Session state | Row text | Coral? |
|---|---|---|
| `starting` | starting | no |
| `ready` | idle <age> | no |
| `working` | working | no (teal dot on the project) |
| `waitingPermission` | needs you · <age> | yes |
| `finished`, `waitingIdle` — not yet seen | done · <age> | yes |
| `finished`, `waitingIdle` — seen | idle <age> | no |
| `error` with an active agent limit | rate limited | yes |
| `error` otherwise | error | yes |

`<age>` is `AgeFormat.compact` of `stateChangedAt`.

**Seen:** a finished or waiting-for-input state is seen once that session's terminal has been on
screen (selected, no screen layered over it, panel visible) at any moment since the state began.
A state that begins while the terminal is on screen is seen at once. A new state starts unseen.
This is kept in memory only; after a relaunch every finished session starts seen.

**Project dot:** coral if any of its sessions is coral; else teal if any session is working or has a
running subagent; else none.

**Menu-bar tint** follows the same rule: tinted while any session is coral. Notifications are
unchanged.

### Expanding and order

- A project expands by itself when one of its sessions turns coral.
- The project holding the selected session is always expanded.
- A manual expand or collapse sticks until the next automatic expand, and is remembered per folder
  across relaunches.
- Projects keep the order they were first opened, remembered across relaunches: a project that
  closes and later reopens returns to its old place. The saved order is pruned at launch to folders
  that still have a live session or an Earlier entry.
- Sessions within a project are in the order they were opened. Nothing reorders on a state change.

## Architecture

Logic lives in `LinkCKit`, as plain types tested there; the `linkc` target has no SwiftUI test
harness, so views stay thin.

- **`ClaudeTitleReader`** — given a transcript path, returns the latest `aiTitle` or nil. Backward
  chunked scan splitting on newline bytes (the approach `TranscriptBackwardReader` uses), with a
  per-path cache keyed by size and modification time.
- **`SessionTitles`** — resolves the title list for a project's sessions: Claude title, held task,
  numbered agent name.
- **`SessionAttention`** — the table above: state text, coral or not, and the seen bookkeeping
  (`markViewed(sessionId:at:)`, fed from the app while a terminal is on screen).
- **`SidebarModel`** — builds the ordered project rows (dot, expanded flag, session rows) from
  sessions, attention, and `SidebarState`.
- **`SidebarState`** — the persisted project order, per-folder expand overrides, and section
  collapse flags, stored in an injectable `UserDefaults` suite as `AppPreferences` is.

Views in `linkc`: `Sidebar` (and its row views), `SessionHeaderStrip`, and a reworked `PanelView`
that lays out sidebar + right pane with the existing 600pt breakpoint.

## Error handling

- A transcript that cannot be read or has no `ai-title` line falls through to the next title
  source. An unreadable file is logged once per path and modification time, not every refresh.
- `SidebarState` that fails to decode is logged and replaced with an empty state; the sidebar then
  shows projects in session order with default expansion.

## Testing

- Test-first in `LinkCKitTests` for every rule above: the latest of several `ai-title` lines wins; a
  title past the first chunk is found; the cache re-reads only after the file changes; the held-task
  fallback and " 2" numbering; every row of the state table, including seen/unseen transitions and a
  state that begins while on screen; the project dot; auto-expand, the selected project's forced
  expansion, and a manual override surviving until the next auto-expand; stable order across a
  close-and-reopen and pruning at load.
- Each new test is revert-proofed: break the rule, watch the test fail, restore.
- The full suite passes. Then build and install, and capture the panel at 1365×788 and under 600pt
  for review.

## Known gaps

- Codex, Cursor, and agy sessions show their held task or agent name, never a conversation title.
- "Seen" does not survive a relaunch.
- Claude's `ai-title` line is an internal format of Claude Code; if it changes, Claude sessions fall
  back to the agent name until the reader is updated.

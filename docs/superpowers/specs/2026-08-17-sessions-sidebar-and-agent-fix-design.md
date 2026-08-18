# Sessions sidebar beside the terminal + phantom-agent fix

## Goal

Two changes:

1. When a terminal is open, keep the sessions list visible beside it instead of
   hiding it behind the mini-tab strip.
2. Fix subagent runs that show as "running" after the subagent has finished.

## Part 1 — Split layout

### Behavior

- When a session or dev terminal is selected **and** the pane is at least
  `splitBreakpoint` (600pt) wide, the terminal pane becomes a split:
  - **Left:** the home list in a fixed 260pt column — the same content home
    shows today (NEEDS YOU / WORKING / IDLE sections, TERMINALS section,
    EARLIER section), with live 1s-cadence previews. Every existing card
    action works from here: tap to switch, stop, relaunch, restore, dismiss.
  - **Right:** the live terminal, filling the remainder.
- The open item's card gets a selected treatment: brighter fill plus an accent
  hairline along the leading edge. Tapping the already-open card is a no-op.
- The session-strip mini-tabs do **not** render in split mode — the sidebar
  replaces them. The agent strip (live subagents) still rides above the
  terminal on the right side.
- The agent reader, when opened, replaces only the terminal side; the sidebar
  stays in place. (Narrow mode keeps today's full-pane swap.)
- Below `splitBreakpoint`, behavior is exactly today's: full-bleed terminal
  with the mini-tab strip. The dock/home/screens flow is untouched.
- Reduce Motion keeps its current meaning everywhere; the split appearing or
  collapsing on resize is a plain layout change, not animated.

### Panel width

`StatusPanelController` already widens the panel when a session is selected.
Raise the expanded default width to 760pt so the split fits out of the box.
User resizes are still remembered via the existing preference key.

### Structure

- Extract the home list (the scrolling sections column) out of `HomeView`
  into a reusable `SessionListColumn` view so home and the sidebar render the
  same component. `HomeView` keeps its usage footer; the sidebar does not
  show the footer.
- `TerminalHero` gains the split: `HStack { SessionListColumn; terminal }`
  when wide, current layout when narrow, measured with the `GeometryReader`
  already present in `PanelView`.
- Selection state comes from `model.selectedId` — no new state.

## Part 2 — Phantom "running" agents

### Defects (in `Sources/LinkCKit/Usage/AgentEvents.swift`)

1. **One malformed block drops the whole line.** `RawContent` decodes block
   arrays with `(try? container.decode([RawBlock].self)) ?? []` — if any
   block in the line fails to decode (a `tool_result` whose `content` is a
   plain string instead of a block array is real and common), every block in
   that line is discarded, completions included. The spawned agent then shows
   as running forever.
2. **Empty results are not completions.** `guard !text.isEmpty` skips
   `tool_result` blocks with no text, so those completions are dropped too.
3. **No backstop.** A run whose completion is never observed stays `isRunning`
   indefinitely.

### Fixes

1. Per-block tolerant decoding: a block that fails to decode becomes `nil`
   and is skipped alone; `tool_result` `content` accepts both a string and a
   block array.
2. An empty tool_result still completes the run (`resultText` stays nil —
   it is already optional).
3. Backstop sweep: when a session's state returns to a non-working bucket
   (ready / waiting / finished / ended), any still-running agent runs for that
   session are marked ended at that timestamp. Wired where session state
   changes are already observed, feeding the session's `AgentAssembler`.
   The async-launch marker case ("Async agent launched") keeps its current
   meaning: it is launch metadata, not a completion — but the sweep bounds
   how long a lost async completion can show as running.

### Tests (written first)

In `Tests/` beside the existing LinkCKit tests:

- A transcript line containing a string-content `tool_result` alongside a
  valid completion block → both parse; the completion is not lost.
- A `tool_result` with empty content for a known spawn → the run completes.
- Assembler sweep: spawn with no completion, then session goes idle → run is
  no longer running.
- Existing behavior guarded: async-launch tool_result still does not complete
  the run; unknown-id completions stay no-ops.

## Out of scope

- No changes to the dock, screens, home-when-nothing-selected, or the agent
  reader.
- No redesign of the card visuals beyond the selected treatment.

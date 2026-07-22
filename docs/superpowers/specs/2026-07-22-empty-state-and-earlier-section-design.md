# Empty state as launcher; Earlier section cleanup

## Problem

Two pieces of the home panel read as cluttered:

1. **Empty state** shows a center "New session" button while the header `+` menu offers the
   same action — two prominent affordances for one thing, on an otherwise empty panel.
2. **Earlier section** right-aligns "Restore all" in its header directly above each row's
   right-aligned "Restore" — two stacked orange labels, and with a single restorable session
   "Restore all" is pure redundancy. Rows also show "ended in 0s" (a
   `RelativeDateTimeFormatter` artifact for near-now dates).

## Design

### Empty state is the launcher

- Center column: pulsing status dot, "No sessions yet", primary **New session** button,
  then one quiet secondary line — `Continue last · Resume…` — small muted text buttons that
  warm on hover. The old subtitle line is dropped; the actions say it.
- The header `+` (LauncherMenu) is hidden exactly while the empty state shows
  (`sessions.isEmpty && restorables.isEmpty && selectedId == nil`), scale-fading back in
  when anything exists. Never two launch affordances on screen.
- `+` was the only Quit path, so the empty state adds a faint `quit linkC` text link,
  bottom-trailing, tertiary grey until hovered.
- The setup-error view is unaffected (it has its own Quit button).

### Earlier section

- Row layout unchanged: dot · title · path · ended-time · **Restore**, dismiss `×` on hover.
- "Restore all" moves inline into the header — `EARLIER · Restore all`, small accent text —
  and renders only when there are 2+ restorable sessions.
- Ended-time fix: intervals under a minute read "ended just now"; otherwise the existing
  abbreviated relative format. The label formatting moves into LinkCKit as a pure function
  (`RestorableSession.endedLabel(now:)`) so it is unit-testable; the view calls it.

## Testing

- TDD for `endedLabel(now:)`: nil `endedAt` → nil; <60s (including slight future skew) →
  "ended just now"; minutes/hours → abbreviated relative ("ended 5m ago").
- Layout changes (launcher hiding, secondary links, header inline Restore all) are SwiftUI
  view code with no snapshot harness — verified by rebuild and screenshot.

## Out of scope

Motion system, theme, card behavior, terminal rendering — all untouched.

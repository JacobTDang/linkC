# Restorable dev terminals

## Goal

Dev terminals survive quitting linkC the way sessions do: on relaunch, TERMINALS shows a
dimmed row per remembered terminal (title, folder, command for command-mode shells) with
one-tap Relaunch. Nothing spawns without the user; scrollback is honestly gone.

## Data

A `ShellManifest` beside `WorkspaceManifest` (same directory, `shells.json`, same
atomic-write/tolerant-load discipline): entries `{id, cwd, title, command?}` persisted on
launch and pruned on dismiss. On app start, entries load as restorable shell rows —
distinct from live rows, mirroring EARLIER's live/restorable split. Relaunch reuses
`ShellCoordinator.relaunch` semantics (fresh shell in the folder; command-mode rows re-run
their command). Dismiss forgets the entry. Retention mirrors the session manifest: stamp
orphans at load, 7-day age-out, newest per (cwd+command).

## UI

Home's TERMINALS section gains dimmed restorable rows under the live ones (Relaunch +
hover-dismiss, no preview well). The sidebar's compact TERMINALS shows live rows only —
restoring is a home decision, like EARLIER.

## Quit warning

The warning's "terminals aren't restored" copy softens to match reality: shells return as
relaunchable rows, scrollback doesn't. `QuitWarningBuilder` copy + tests updated.

## Testing

TDD: manifest round-trip/retention (mirror WorkspaceManifestTests), ShellCoordinator
restore-row plumbing, quit-warning copy.

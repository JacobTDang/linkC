# UI makeover — implementation plan

Spec: `docs/superpowers/specs/2026-07-23-ui-makeover-design.md`

## 0. SDK probe

Check whether the installed toolchain's macOS SDK is 26+ (`xcrun --show-sdk-version`).
If yes, the dock's glass branch compiles behind `#available(macOS 26.0, *)`; if not,
build the fallback only and note it in the dock's comment.

## 1. RecentFolders (TDD)

- `Tests/LinkCKitTests/RecentFoldersTests.swift` first: recording adds to front;
  re-recording an existing path moves it to front without duplicating; standardization
  (trailing slash) dedupes; cap 8 evicts the oldest; store round-trips through
  `recents.json`; corrupt file loads as empty.
- Implement `Sources/LinkCKit/App/RecentFolders.swift`: pure `RecentFoldersLog` +
  `RecentFoldersStore` following `WorkspaceManifest`'s IO pattern.
- Run: new tests red → green; full suite green. Commit.

## 2. Theme surgery (content plane tokens)

- `cardSurface` → near-opaque dark plane gradients (normal + needs-you + hover variants).
- New: `cardStroke(needsYou:)` gradient (rim-lit top → faint sides), `planeShadow`
  color/radius/y, vignette color. Retune `railBreakpoint` for the narrower dock; drop
  `railWidth`/`railTileSurface`/rail layout tokens once the rail dies in step 3.
- Shared `planeCard(needsYou:hovering:)` modifier in Theme.swift; adopt in `HomeCard`
  and `TerminalCard`. Vignette overlay on the panel root.
- Upgrade `PrimaryButtonStyle`: gradient capsule, inner top highlight, glow shadow.

## 3. The dock

- New `Sources/linkc/Dock.swift`: `Dock(model:selected:)` — capsule of five icon buttons,
  coral pill selection, `.help` tooltips; glass background behind `#available(macOS 26)`,
  hand-rolled fallback below.
- `PanelView`: dock as trailing overlay (center-right) whenever `selectedId == nil` and
  width ≥ breakpoint; content ZStack gets trailing inset while the dock shows.
- Delete `MetricsRail`/`RailTile`; strip rail plumbing from `HomeView`, `EmptyStateView`,
  `ScreenHost` (ScreenHost reduces to the content switch).

## 4. Hero + chips + wiring

- `EmptyStateView`: halo hero (new `HeroHalo` view, Reduce Motion honored), new copy,
  upgraded CTA, JUMP BACK IN chips (≤3) from `model.recentFolders`.
- `AppModel`: owns `RecentFoldersStore` (built in `start()`); records on newSession /
  restore / restoreAll? (restore records via its cwd) / newShellTerminal / relaunchShell;
  `startSession(in:)` for chips; `recentFolders` accessor.

## 5. Verify + ship

- Full suite. Build via `./build-app.sh`; install with `--install` only after the
  running-app/live-children check (swap protocol). Manual pass per spec's checklist —
  screenshots from the user drive any polish round.

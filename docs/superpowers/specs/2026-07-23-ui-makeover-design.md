# UI makeover: one sheet, one plane, one dock

## Thesis

Apple's Liquid Glass guidance (WWDC 2025, sessions 219/323) has two cardinal rules: glass
belongs only to the floating navigation layer, never to content — and never stack glass on
glass. The panel currently breaks both: the sheet is glass, cards are translucent washes of
the same material, and the rail is five separate glass tiles. When everything is glass,
nothing floats and nothing anchors. The makeover is layer discipline, not decoration:

- **The sheet** stays the frosted `NSVisualEffectView` — the one ambient glass.
- **Content** becomes a crisp, near-opaque dark plane sitting ON the sheet.
- **Navigation** becomes ONE floating glass capsule — the only element that floats.

Approved direction (with mockup): full — dock + content plane + empty-state hero with
Jump-back-in chips, using native Tahoe glass for the dock where available.

## The dock

The five rail tiles collapse into a single vertical capsule of icon-only buttons (SF symbols,
tooltips via `.help`), rendered by `PanelView` as a trailing overlay, vertically centered,
visible whenever no terminal is open (home, empty state, and rail screens alike — it replaces
`ScreenHost`'s sidebar too). The selected screen is a coral gradient pill inside the capsule;
hover brightens the glyph over a faint wash.

- On macOS 26 (`#available`), the capsule background is native Liquid Glass
  (`.glassEffect(.regular, in: .capsule)`) — one glass element, per Apple's grouping rule.
  Below 26, a hand-rolled fallback: top-lit gradient + inner highlight + drop shadow.
  If the installed SDK predates macOS 26, ship the fallback only (compile-time constraint).
- Content columns reserve trailing space for the dock; below a width breakpoint the dock
  hides entirely (same degradation the rail has today, retuned since the dock is narrower).
- `MetricsRail`/`RailTile` and the per-view GeometryReader/HStack rail plumbing in
  `HomeView`, `EmptyStateView`, and `ScreenHost` are deleted.

## The content plane

`Theme.cardSurface` stops being a white wash and becomes a near-opaque dark gradient —
darker than the sheet, so cards read as solid objects resting on glass. A shared card
treatment adds: a gradient hairline stroke (rim-lit top edge fading down the sides), and a
soft cast shadow. Needs-you cards get a warm coral-tinted plane and edge instead of a wash.
A faint radial vignette overlays the panel root (hit-testing off) to ground the sheet's
edges. Hover lightens the plane slightly; all existing motion/Reduce Motion behavior keeps.

Applied to `HomeCard` and `TerminalCard`. Quiet rows (restorables, screen lists) stay
transparent-until-hover — they are secondary and should not compete with the plane.

## The empty-state hero

- The lone dot grows into a halo: a 74pt radial coral glow with an inset ring and a 12pt
  breathing core (scale 0.92↔1.06, ~2.4s; Reduce Motion holds it steady).
- Copy warms: **"Ready when you are"** (19pt bold) over "Claude Code sessions run right
  here." The primary button becomes a coral gradient capsule with an inner top highlight
  and glow shadow (shared `PrimaryButtonStyle` upgrade). Continue last / Resume stay as
  quiet links; quit stays tucked bottom-trailing.
- **Jump back in**: up to 3 chips of recently used folders (name + tilde-abbreviated
  parent). Tapping one starts a new session in that folder directly — no folder picker.
  The section hides when there are no recents.

## Recent folders (new, LinkCKit)

The manifest can't back the chips — it drops entries on restore/dismiss, and the empty
state by definition has none. New `Sources/LinkCKit/App/RecentFolders.swift`:

- Pure `RecentFoldersLog`: `recording(path:)` standardizes the path, dedupes (an existing
  entry moves to front), caps at 8. Fully unit-tested (TDD).
- `@MainActor @Observable RecentFoldersStore`: persists `recents.json` in the same
  Application Support `linkC/` directory as the manifest, following its IO pattern —
  atomic writes, loud NSLog on write failure, missing/corrupt file tolerated as empty.
- Recorded from `AppModel` on every successful launch that has a folder: new session,
  restore, dev terminal, relaunch. `AppModel.startSession(in:)` is the chips' no-picker
  launch path (wraps `coordinator.newSession(cwd:mode:.new)`).

## Out of scope

Terminal-open layout, screens' internal list designs, header chrome, usage footer — all
unchanged. No new dependencies.

## Verification

- TDD for `RecentFoldersLog`/store (dedupe, cap, order, corrupt-file tolerance).
- Full existing suite stays green.
- Manual: dock on home/empty/screens at full and narrow widths; selection pill matches the
  open screen; cards read as planes over the wallpaper; needs-you card burns warm; hero
  breathes (and holds under Reduce Motion); chips appear after sessions exist and launch
  without a picker; vignette invisible as a feature, visible as depth.
